// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IInferenceVault} from "./interfaces/IInferenceVault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ISwapRouterV3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256);
    function exactInput(ExactInputParams calldata params) external returns (uint256);
}

interface IVVVStaking {
    function stake(address to, uint256 vvvAmount) external;
    // mintDiem returns void — use balance delta to measure DIEM output.
    function mintDiem(uint256 sVVVAmount, uint256 minDiemOut) external;
}

interface ICurvePool {
    function add_liquidity(uint256[] calldata amounts, uint256 min_mint_amount)
        external
        returns (uint256);
}

contract FeeRouter is Ownable {
    using SafeERC20 for IERC20;

    // Routing modes — owner (or governance) chooses per income type.
    // CREDIT_VAULT: convert to DIEM → vault.creditDIEM() (increases wstDIEM rate)
    // CURVE_VOL:    convert to wstDIEM → add to Curve VOL position
    // HOLD:         accumulate in FeeRouter; manual sweep by owner
    enum FeeMode {
        CREDIT_VAULT,
        CURVE_VOL,
        HOLD
    }

    // Uniswap V3 SwapRouter02 on Base
    address constant V3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint24 public diemFee = 10_000; // WETH/DIEM V3 pool fee tier. Owner-updatable.
    uint24 public usdcWethFee = 500; // USDC/WETH V3 pool fee tier. Owner-updatable.

    IInferenceVault public immutable vault;
    address public immutable weth;
    address public immutable vvv;
    address public immutable vvvStaking;

    address public curvePool;

    // Routing modes (configurable by owner/governance)
    FeeMode public wethMode = FeeMode.CREDIT_VAULT;
    FeeMode public usdcMode = FeeMode.CREDIT_VAULT;
    FeeMode public vvvMode = FeeMode.CREDIT_VAULT;
    FeeMode public wstDiemMode = FeeMode.CURVE_VOL;

    uint256 public vvvBatchThreshold = 100e18;

    // Governance: address(0) = governance not yet initialized (owner controls).
    // Once set, governance contract takes ownership. Owner can transfer to gov.
    address public governance;

    uint256 private _pendingWETH;
    uint256 private _pendingUSDC;
    uint256 private _pendingVVV;
    uint256 private _pendingWstDIEM;

    // Keeper: trusted off-chain EOA that serves inference and settles x402 revenue.
    // Can call harvest() and settleAndHarvest() without going through the Safe.
    address public keeper;

    // ── Channel registry ──────────────────────────────────────────────────────
    // Each entry is an external inference marketplace (Surplus Intelligence, AntSeed, etc.).
    // The vault manager (Safe) registers channels via addChannel(). The keeper reads
    // payoutWallet to configure its x402 settlement address and platformFeeBps to
    // account for the marketplace's cut. receiveFromChannel() accepts net USDC
    // (after the marketplace fee has already been deducted off-chain by the keeper).
    struct Channel {
        string name; // human label: "SurplusIntelligence", "AntSeed", …
        address payoutWallet; // keeper EOA x402 settles to; keeper calls receiveFromChannel
        uint256 platformFeeBps; // marketplace's fee rate (informational — deducted off-chain)
        bool active;
        uint256 totalRevenue; // lifetime net USDC routed to vault from this channel
    }

    mapping(uint256 => Channel) public channels;
    uint256 public nextChannelId;

    event WETHReceived(uint256 amount);
    event USDCReceived(uint256 amount);
    event VVVReceived(uint256 amount);
    event WstDIEMReceived(uint256 amount);
    event Harvested(uint256 diemCredited, uint256 wstDiemToVOL);
    event VVVHarvested(uint256 vvvIn, uint256 diemCredited);
    event FeeModeChanged(string token, FeeMode mode);
    event SwapFeesSet(uint24 diemFee, uint24 usdcWethFee);
    event GovernanceInitialized(address governance);
    event KeeperUpdated(address indexed keeper);
    event ChannelAdded(
        uint256 indexed channelId, string name, address payoutWallet, uint256 platformFeeBps
    );
    event ChannelUpdated(uint256 indexed channelId);
    event ChannelRevenue(uint256 indexed channelId, string name, uint256 amount);

    modifier onlyOwnerOrKeeper() {
        require(msg.sender == owner() || msg.sender == keeper, "not owner or keeper");
        _;
    }

    constructor(
        address _vault,
        address _weth,
        address _vvv,
        address _vvvStaking,
        address _curvePool,
        address, /*_v4Pool — reserved for ABI compat; unused*/
        address initialOwner
    ) Ownable(initialOwner) {
        vault = IInferenceVault(_vault);
        weth = _weth;
        vvv = _vvv;
        vvvStaking = _vvvStaking;
        curvePool = _curvePool;
    }

    // ── Receive paths ─────────────────────────────────────────────────────

    function receiveWETH(uint256 amount) external {
        IERC20(weth).safeTransferFrom(msg.sender, address(this), amount);
        _pendingWETH += amount;
        emit WETHReceived(amount);
    }

    // Inference revenue from external providers (AntSeed/Surplus AI → USDC).
    // USDC is routed per usdcMode; default CREDIT_VAULT increases wstDIEM rate.
    function receiveUSDC(uint256 amount) external {
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), amount);
        _pendingUSDC += amount;
        emit USDCReceived(amount);
    }

    function receivewstDIEM(uint256 amount) external {
        IERC20(address(vault)).safeTransferFrom(msg.sender, address(this), amount);
        _pendingWstDIEM += amount;
        emit WstDIEMReceived(amount);
    }

    function receiveVVV(uint256 amount) external {
        IERC20(vvv).safeTransferFrom(msg.sender, address(this), amount);
        _pendingVVV += amount;
        emit VVVReceived(amount);
    }

    // Route inference revenue from a registered external marketplace (Surplus Intelligence,
    // AntSeed, etc.). Caller must be the channel's registered payoutWallet or the owner.
    // Caller passes the NET amount after the marketplace's platform fee has been deducted.
    function receiveFromChannel(uint256 channelId, uint256 amount) external {
        Channel storage c = channels[channelId];
        require(c.active, "channel inactive");
        require(msg.sender == c.payoutWallet || msg.sender == owner(), "not channel wallet");
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), amount);
        _pendingUSDC += amount;
        c.totalRevenue += amount;
        emit ChannelRevenue(channelId, c.name, amount);
        emit USDCReceived(amount);
    }

    // Single-call keeper entry: settle x402 USDC and immediately harvest into vault.
    // Keeper calls this after receiving USDC from Surplus Intelligence / AntSeed.
    // Replaces the 3-step: approve + receiveFromChannel + harvest.
    function settleAndHarvest(uint256 channelId, uint256 amount) external onlyOwnerOrKeeper {
        Channel storage c = channels[channelId];
        require(c.active, "channel inactive");
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), amount);
        _pendingUSDC += amount;
        c.totalRevenue += amount;
        emit ChannelRevenue(channelId, c.name, amount);
        emit USDCReceived(amount);
        _harvest();
    }

    // ── Harvest: WETH + USDC ──────────────────────────────────────────────

    // Owner or keeper: routes pending WETH, USDC, and wstDIEM per their configured FeeModes.
    // Zero-slippage swaps — caller is trusted to avoid sandwich attacks by timing calls.
    function harvest() external onlyOwnerOrKeeper {
        _harvest();
    }

    function _harvest() internal {
        address diem = vault.asset();
        uint256 diemBefore = IERC20(diem).balanceOf(address(this));
        uint256 totalWstVol = 0; // accumulates ALL wstDIEM routed to Curve VOL this harvest

        // --- WETH ---
        uint256 pendingW = _pendingWETH;
        if (pendingW > 0 && wethMode != FeeMode.HOLD) {
            _pendingWETH = 0;
            IERC20(weth).approve(V3_ROUTER, pendingW);
            uint256 diemOut = ISwapRouterV3(V3_ROUTER)
                .exactInputSingle(
                    ISwapRouterV3.ExactInputSingleParams({
                        tokenIn: weth,
                        tokenOut: diem,
                        fee: diemFee,
                        recipient: address(this),
                        amountIn: pendingW,
                        amountOutMinimum: 0,
                        sqrtPriceLimitX96: 0
                    })
                );
            if (wethMode == FeeMode.CURVE_VOL && diemOut > 0) {
                IERC20(diem).approve(address(vault), diemOut);
                uint256 wstOut = vault.deposit(diemOut, address(this));
                _addWstDIEMToVOL(wstOut);
                totalWstVol += wstOut;
            }
            // CREDIT_VAULT: diemOut stays in balance, credited below
        }

        // --- USDC ---
        uint256 pendingU = _pendingUSDC;
        if (pendingU > 0 && usdcMode != FeeMode.HOLD) {
            _pendingUSDC = 0;
            IERC20(USDC).approve(V3_ROUTER, pendingU);
            bytes memory path = abi.encodePacked(USDC, usdcWethFee, weth, diemFee, diem);
            uint256 diemOut = ISwapRouterV3(V3_ROUTER)
                .exactInput(
                    ISwapRouterV3.ExactInputParams({
                        path: path,
                        recipient: address(this),
                        amountIn: pendingU,
                        amountOutMinimum: 0
                    })
                );
            if (usdcMode == FeeMode.CURVE_VOL && diemOut > 0) {
                IERC20(diem).approve(address(vault), diemOut);
                uint256 wstOut = vault.deposit(diemOut, address(this));
                _addWstDIEMToVOL(wstOut);
                totalWstVol += wstOut;
            }
            // CREDIT_VAULT: diemOut stays in balance, credited below
        }

        // --- wstDIEM (from receivewstDIEM calls) ---
        uint256 pendingWst = _pendingWstDIEM;
        if (pendingWst > 0 && wstDiemMode != FeeMode.HOLD) {
            _pendingWstDIEM = 0;
            _addWstDIEMToVOL(pendingWst);
            totalWstVol += pendingWst;
        }

        // --- Credit vault with all DIEM acquired via CREDIT_VAULT paths ---
        uint256 diemAcquired = IERC20(diem).balanceOf(address(this)) - diemBefore;
        if (diemAcquired > 0) {
            IERC20(diem).approve(address(vault), diemAcquired);
            vault.creditDIEM(diemAcquired);
        }

        emit Harvested(diemAcquired, totalWstVol);
    }

    // ── Harvest: VVV → sVVV → mintDiem → creditDIEM/VOL ─────────────────

    function harvestVVV() external onlyOwnerOrKeeper {
        uint256 pending = _pendingVVV;
        if (pending < vvvBatchThreshold) return;
        _pendingVVV = 0;

        address diem = vault.asset();
        uint256 diemBefore = IERC20(diem).balanceOf(address(this));

        IERC20(vvv).approve(vvvStaking, pending);
        IVVVStaking(vvvStaking).stake(address(this), pending);

        uint256 sVVV = IERC20(vvvStaking).balanceOf(address(this));
        IVVVStaking(vvvStaking).mintDiem(sVVV, 0);

        uint256 diemMinted = IERC20(diem).balanceOf(address(this)) - diemBefore;
        if (diemMinted > 0) {
            if (vvvMode == FeeMode.CREDIT_VAULT) {
                IERC20(diem).approve(address(vault), diemMinted);
                vault.creditDIEM(diemMinted);
            } else if (vvvMode == FeeMode.CURVE_VOL) {
                IERC20(diem).approve(address(vault), diemMinted);
                uint256 wstOut = vault.deposit(diemMinted, address(this));
                _addWstDIEMToVOL(wstOut);
                diemMinted = 0;
            }
            // HOLD: DIEM stays in FeeRouter
            emit VVVHarvested(pending, diemMinted);
        }
    }

    // ── Owner sweep (for HOLD mode or emergency) ──────────────────────────

    function sweep(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }

    // ── Internal ──────────────────────────────────────────────────────────

    function _addWstDIEMToVOL(uint256 wstDIEMAmount) internal {
        if (curvePool == address(0) || wstDIEMAmount == 0) return;
        IERC20(address(vault)).approve(curvePool, wstDIEMAmount);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = wstDIEMAmount;
        ICurvePool(curvePool).add_liquidity(amounts, 0);
    }

    // ── Views ─────────────────────────────────────────────────────────────

    function pendingWETH() external view returns (uint256) {
        return _pendingWETH;
    }

    function pendingUSDC() external view returns (uint256) {
        return _pendingUSDC;
    }

    function pendingVVV() external view returns (uint256) {
        return _pendingVVV;
    }

    function pendingWstDIEM() external view returns (uint256) {
        return _pendingWstDIEM;
    }

    // ── Owner / Governance config ─────────────────────────────────────────

    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
        emit KeeperUpdated(_keeper);
    }

    function setWethMode(FeeMode mode) external onlyOwner {
        wethMode = mode;
        emit FeeModeChanged("WETH", mode);
    }

    function setUsdcMode(FeeMode mode) external onlyOwner {
        usdcMode = mode;
        emit FeeModeChanged("USDC", mode);
    }

    function setVvvMode(FeeMode mode) external onlyOwner {
        vvvMode = mode;
        emit FeeModeChanged("VVV", mode);
    }

    function setWstDiemMode(FeeMode mode) external onlyOwner {
        wstDiemMode = mode;
        emit FeeModeChanged("wstDIEM", mode);
    }

    function setSwapFees(uint24 _diemFee, uint24 _usdcWethFee) external onlyOwner {
        require(_diemFee > 0 && _diemFee <= 10_000, "invalid DIEM fee");
        require(_usdcWethFee > 0 && _usdcWethFee <= 10_000, "invalid USDC/WETH fee");
        diemFee = _diemFee;
        usdcWethFee = _usdcWethFee;
        emit SwapFeesSet(_diemFee, _usdcWethFee);
    }

    function setVVVBatchThreshold(uint256 amt) external onlyOwner {
        vvvBatchThreshold = amt;
    }

    function setCurvePool(address pool) external onlyOwner {
        curvePool = pool;
    }

    // One-time governance initialization. Transfers ownership to a governance
    // contract (timelock, DAO, etc.). Cannot be undone except by governance itself.
    // Off at launch — call when protocol is ready for decentralized control.
    function initializeGovernance(address gov) external onlyOwner {
        require(governance == address(0), "already initialized");
        require(gov != address(0), "zero address");
        governance = gov;
        transferOwnership(gov);
        emit GovernanceInitialized(gov);
    }

    // ── Channel management (vault manager / Safe) ─────────────────────────

    // Register a new inference marketplace integration.
    // name:            human label shown in events/analytics (e.g. "SurplusIntelligence")
    // payoutWallet:    keeper EOA where x402 settles; keeper reads this to configure its server
    // platformFeeBps:  marketplace's take rate (informational; keeper deducts before calling receiveFromChannel)
    function addChannel(string calldata name, address payoutWallet, uint256 platformFeeBps)
        external
        onlyOwner
        returns (uint256 channelId)
    {
        require(platformFeeBps <= 5000, "fee > 50%");
        channelId = nextChannelId++;
        channels[channelId] = Channel({
            name: name,
            payoutWallet: payoutWallet,
            platformFeeBps: platformFeeBps,
            active: true,
            totalRevenue: 0
        });
        emit ChannelAdded(channelId, name, payoutWallet, platformFeeBps);
    }

    function setChannelActive(uint256 channelId, bool active) external onlyOwner {
        channels[channelId].active = active;
        emit ChannelUpdated(channelId);
    }

    // Update the keeper wallet for a channel (e.g., key rotation, new integration config).
    function setChannelPayoutWallet(uint256 channelId, address payoutWallet) external onlyOwner {
        channels[channelId].payoutWallet = payoutWallet;
        emit ChannelUpdated(channelId);
    }

    function setChannelFee(uint256 channelId, uint256 platformFeeBps) external onlyOwner {
        require(platformFeeBps <= 5000, "fee > 50%");
        channels[channelId].platformFeeBps = platformFeeBps;
        emit ChannelUpdated(channelId);
    }

    // ── Channel views ─────────────────────────────────────────────────────

    function getChannel(uint256 channelId) external view returns (Channel memory) {
        return channels[channelId];
    }
}
