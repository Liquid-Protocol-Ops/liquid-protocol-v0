// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IInferenceVault} from "./interfaces/IInferenceVault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IVVVStaking {
    function stake(uint256 vvvAmount) external returns (uint256 sVVV);
    function lock(uint256 sVVVAmount) external returns (uint256 diemMinted);
}

interface ICurvePool {
    function add_liquidity(uint256[] calldata amounts, uint256 min_mint_amount)
        external
        returns (uint256);
}

contract FeeRouter is Ownable {
    using SafeERC20 for IERC20;

    IInferenceVault public immutable vault;
    address public immutable weth;
    address public immutable vvv;
    address public immutable vvvStaking;
    address public curvePool;
    address public v4Pool;

    uint256 public maxSlippageBps = 50;
    uint256 public vvvBatchThreshold = 100e18;

    uint256 private _pendingVVV;
    uint256 private _pendingWETH;

    event WETHHarvested(uint256 wethIn, uint256 wstDIEMOut);
    event WstDIEMHarvested(uint256 amount);
    event VVVHarvested(uint256 vvvIn, uint256 diemCredited);

    constructor(
        address _vault,
        address _weth,
        address _vvv,
        address _vvvStaking,
        address _curvePool,
        address _v4Pool
    ) Ownable(msg.sender) {
        vault = IInferenceVault(_vault);
        weth = _weth;
        vvv = _vvv;
        vvvStaking = _vvvStaking;
        curvePool = _curvePool;
        v4Pool = _v4Pool;
    }

    // --- Receive paths ---

    function receiveWETH(uint256 amount) external {
        IERC20(weth).safeTransferFrom(msg.sender, address(this), amount);
        _pendingWETH += amount;
    }

    // Accumulates wstDIEM in this contract; routed to Curve VOL on harvest().
    // NOTE: intentionally does NOT call _addWstDIEMToVOL here — curvePool may
    // be an EOA during tests and a high-level call to a codeless address reverts.
    function receivewstDIEM(uint256 amount) external {
        IERC20(address(vault)).safeTransferFrom(msg.sender, address(this), amount);
    }

    function receiveVVV(uint256 amount) external {
        IERC20(vvv).safeTransferFrom(msg.sender, address(this), amount);
        _pendingVVV += amount;
    }

    // --- Harvest paths ---

    /// @notice Flush all pending fee tokens to Curve VOL.
    function harvest() external {
        // WETH path: swap → wstDIEM (stub until Phase E V4 wiring)
        uint256 pending = _pendingWETH;
        if (pending > 0) {
            _pendingWETH = 0;
            uint256 wstDIEMOut = _swapWETHForWstDIEM(pending);
            if (wstDIEMOut > 0) {
                _addWstDIEMToVOL(wstDIEMOut);
                emit WETHHarvested(pending, wstDIEMOut);
            }
        }

        // wstDIEM path: flush accumulated receivewstDIEM balance to Curve VOL
        uint256 heldWstDIEM = IERC20(address(vault)).balanceOf(address(this));
        if (heldWstDIEM > 0) {
            _addWstDIEMToVOL(heldWstDIEM); // _addWstDIEMToVOL emits WstDIEMHarvested
        }
    }

    /// @notice Batch-stake pending VVV → lock sVVV → mint DIEM → credit vault.
    /// No-op below vvvBatchThreshold to amortise gas.
    function harvestVVV() external {
        uint256 pending = _pendingVVV;
        if (pending < vvvBatchThreshold) return;
        _pendingVVV = 0;

        // Step 1: VVV → sVVV
        IERC20(vvv).approve(vvvStaking, pending);
        uint256 sVVV = IVVVStaking(vvvStaking).stake(pending);

        // Step 2: sVVV → DIEM
        // TODO: verify sVVV token address — VVV_STAKING may issue sVVV as a
        // separate ERC-20; approval target should be the sVVV token, not the
        // staking contract, if they differ on Base mainnet.
        IERC20(vvvStaking).approve(vvvStaking, sVVV);
        uint256 diemMinted = IVVVStaking(vvvStaking).lock(sVVV);

        // Step 3: credit vault non-dilutively
        address diem = vault.asset();
        IERC20(diem).approve(address(vault), diemMinted);
        vault.creditDIEM(diemMinted);

        emit VVVHarvested(pending, diemMinted);
    }

    // --- Internal helpers ---

    /// @dev TWAP-guarded V4 swap wired in Phase E; stub returns 0 for now.
    function _swapWETHForWstDIEM(
        uint256 /*wethAmount*/
    )
        internal
        pure
        returns (uint256)
    {
        return 0;
    }

    function _addWstDIEMToVOL(uint256 wstDIEMAmount) internal {
        if (curvePool == address(0) || wstDIEMAmount == 0) return;
        IERC20(address(vault)).approve(curvePool, wstDIEMAmount);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = wstDIEMAmount;
        ICurvePool(curvePool).add_liquidity(amounts, 0);
        emit WstDIEMHarvested(wstDIEMAmount);
    }

    // --- Views ---

    function pendingVVV() external view returns (uint256) {
        return _pendingVVV;
    }

    function pendingWETH() external view returns (uint256) {
        return _pendingWETH;
    }

    // --- Admin ---

    function setMaxSlippageBps(uint256 bps) external onlyOwner {
        maxSlippageBps = bps;
    }

    function setVVVBatchThreshold(uint256 amt) external onlyOwner {
        vvvBatchThreshold = amt;
    }

    function setCurvePool(address pool) external onlyOwner {
        curvePool = pool;
    }

    function setV4Pool(address pool) external onlyOwner {
        v4Pool = pool;
    }
}
