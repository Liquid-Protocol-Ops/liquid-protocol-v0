// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IInferenceToken} from "../interfaces/IInferenceToken.sol";
import {IInferenceVault} from "../interfaces/IInferenceVault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Uniswap V3 SwapRouter02 multi-hop interface (exactInput).
///      Defined inline so adapters don't depend on the single-hop ISwapRouterV3.sol.
interface ISwapRouterV3Hop {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInput(ExactInputParams calldata params) external returns (uint256 amountOut);
}

/// @dev Minimal DIEM interface for reading Venice staked positions.
interface IDIEM {
    function stakedInfos(address account)
        external
        view
        returns (uint256 amountStaked, uint256 coolDownEnd, uint256 coolDownAmount);
}

/// @title  BaseInferenceAdapter
/// @notice Abstract base for venue adapters that route inference USDC revenue into
///         the wstDIEM InferenceVault. Implements IInferenceToken.
///
/// Revenue flow:
///   1. Settlement USDC accumulates via receiveSettlement() (or venue-specific paths).
///   2. routeYield(minDiemOut) (onlyOperator) swaps USDC→WETH→DIEM via Uniswap V3
///      multi-hop, enforcing minDiemOut as the swap's amountOutMinimum.
///   3. holderDiem  = diemOut × (10_000 − operatorFeeBps) / 10_000
///        → vault.creditDIEM()    — raises wstDIEM rate for ALL holders
///   4. operatorDiem = diemOut × operatorFeeBps / 10_000
///        → vault.creditWstDIEM() — mints wstDIEM to this adapter at the current rate
///           (no entry fee), compounding the operator's position.
///
/// routeYield is onlyOperator (not permissionless). The caller supplies minDiemOut —
/// the swap reverts if it would deliver less, so a sandwiched/under-delivering swap
/// fails rather than crediting a manipulated amount. The operator computes minDiemOut
/// off-chain from a fresh quote net of acceptable slippage (MOG-541).
abstract contract BaseInferenceAdapter is IInferenceToken, Ownable {
    using SafeERC20 for IERC20;

    // ─── Token constants (Base mainnet) ──────────────────────────────────────
    /// @notice WETH on Base — used in multi-hop swap path construction.
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    /// @notice Venice DIEM — identity view only. Actual token used for transfers
    ///         is vault.asset() so tests can use MockDIEM.
    address public constant DIEM_MAINNET = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;

    /// @notice Uniswap V3 USDC/WETH fee tier. Default 0.05%. Owner-updatable.
    uint24 public usdcWethFee = 500;

    /// @notice Uniswap V3 WETH/DIEM fee tier. Default 1%. Owner-updatable.
    uint24 public diemFee = 10_000;

    // ─── Config ──────────────────────────────────────────────────────────────
    uint256 public constant MAX_OPERATOR_FEE_BPS = 2000; // 20%

    IInferenceVault public vault;
    address public immutable usdc;
    address public immutable swapRouter;

    /// @notice Fraction of routed DIEM minted to this adapter as wstDIEM.
    ///         Default 1000 (10%). Settable by owner up to MAX_OPERATOR_FEE_BPS.
    uint256 public operatorFeeBps = 1000;

    /// @notice Secondary operator (keeper bot). May call onlyOperator functions.
    address public keeper;

    /// @notice Address authorised to call receiveSettlement() — typically the
    ///         venue's settlement contract or the keeper wallet.
    address public authorizedSettler;

    // ─── Events ──────────────────────────────────────────────────────────────
    event YieldRouted(uint256 usdc, uint256 diem, uint256 operatorShares);
    event SettlementReceived(uint256 amount);
    event VaultSet(address indexed vault);
    event KeeperSet(address indexed keeper);
    event AuthorizedSettlerSet(address indexed settler);
    event OperatorFeeBpsSet(uint256 bps);
    event SwapFeesSet(uint24 usdcWethFee, uint24 diemFee);

    // ─── Constructor ─────────────────────────────────────────────────────────
    constructor(address _vault, address _usdc, address _swapRouter, address initialOwner)
        Ownable(initialOwner)
    {
        vault = IInferenceVault(_vault);
        usdc = _usdc;
        swapRouter = _swapRouter;
    }

    // ─── Modifiers ───────────────────────────────────────────────────────────
    modifier onlyOperator() {
        require(msg.sender == owner() || msg.sender == keeper, "not operator");
        _;
    }
    modifier onlyAuthorized() {
        require(msg.sender == authorizedSettler || msg.sender == owner(), "not authorized");
        _;
    }

    // ─── IInferenceToken — identity ──────────────────────────────────────────
    function inferenceName() external view virtual returns (string memory);

    function inferenceAsset() external pure returns (address) {
        return DIEM_MAINNET;
    }

    // ─── IInferenceToken — position ──────────────────────────────────────────
    function inferenceStaked() external view returns (uint256) {
        (uint256 staked,,) = IDIEM(vault.asset()).stakedInfos(address(vault));
        return staked;
    }

    function pendingYieldInDIEM() external pure returns (uint256) {
        return 0; // tracked off-chain; USDC accumulates in contract until routeYield(minDiemOut)
    }

    // ─── IInferenceToken — yield routing ─────────────────────────────────────
    /// @notice Swap accumulated USDC to DIEM and credit the vault.
    /// @param  minDiemOut Minimum DIEM the multi-hop swap must deliver (the swap's
    ///         amountOutMinimum). The operator computes this off-chain from a fresh
    ///         quote net of acceptable slippage; the swap reverts if it would deliver
    ///         less, so a sandwiched/under-delivering swap fails (MOG-541).
    function routeYield(uint256 minDiemOut) external onlyOperator {
        uint256 usdcBal = IERC20(usdc).balanceOf(address(this));
        require(usdcBal > 0, "no USDC to route");

        address diem = vault.asset();

        IERC20(usdc).forceApprove(swapRouter, usdcBal);

        // Multi-hop: USDC → WETH (0.05%) → DIEM (1%)
        bytes memory path = abi.encodePacked(usdc, usdcWethFee, WETH, diemFee, diem);

        uint256 diemOut = ISwapRouterV3Hop(swapRouter)
            .exactInput(
                ISwapRouterV3Hop.ExactInputParams({
                    path: path,
                    recipient: address(this),
                    amountIn: usdcBal,
                    amountOutMinimum: minDiemOut
                })
            );
        require(diemOut > 0, "swap returned 0");

        uint256 operatorDiem = (diemOut * operatorFeeBps) / 10_000;
        uint256 holderDiem = diemOut - operatorDiem;

        // Raise rate for all holders
        if (holderDiem > 0) {
            IERC20(diem).forceApprove(address(vault), holderDiem);
            vault.creditDIEM(holderDiem);
        }

        // Compound operator's position as wstDIEM (no entry fee)
        uint256 operatorShares;
        if (operatorDiem > 0) {
            uint256 sharesBefore = IERC4626(address(vault)).balanceOf(address(this));
            IERC20(diem).forceApprove(address(vault), operatorDiem);
            vault.creditWstDIEM(operatorDiem, address(this));
            operatorShares = IERC4626(address(vault)).balanceOf(address(this)) - sharesBefore;
        }

        emit YieldRouted(usdcBal, diemOut, operatorShares);
    }

    // ─── Settlement entry ────────────────────────────────────────────────────
    /// @notice Accept USDC from the authorised venue settlement contract.
    ///         Accumulates until routeYield(minDiemOut) is called.
    function receiveSettlement(uint256 usdcAmount) external onlyAuthorized {
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcAmount);
        emit SettlementReceived(usdcAmount);
    }

    // ─── Admin ───────────────────────────────────────────────────────────────
    function setVault(address _vault) external onlyOwner {
        vault = IInferenceVault(_vault);
        emit VaultSet(_vault);
    }

    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
        emit KeeperSet(_keeper);
    }

    function setAuthorizedSettler(address _settler) external onlyOwner {
        authorizedSettler = _settler;
        emit AuthorizedSettlerSet(_settler);
    }

    function setOperatorFeeBps(uint256 bps) external onlyOwner {
        require(bps <= MAX_OPERATOR_FEE_BPS, "exceeds max fee");
        operatorFeeBps = bps;
        emit OperatorFeeBpsSet(bps);
    }

    function setSwapFees(uint24 _usdcWethFee, uint24 _diemFee) external onlyOwner {
        require(_usdcWethFee > 0 && _usdcWethFee <= 10_000, "invalid USDC/WETH fee");
        require(_diemFee > 0 && _diemFee <= 10_000, "invalid DIEM fee");
        usdcWethFee = _usdcWethFee;
        diemFee = _diemFee;
        emit SwapFeesSet(_usdcWethFee, _diemFee);
    }

    /// @notice Withdraw accumulated wstDIEM (operator cut) or any stranded token.
    function sweep(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }
}
