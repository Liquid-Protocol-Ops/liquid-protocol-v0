// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * MintDiemPresaleVault — sVVV-backed compute presale for Liquid Protocol agent launches.
 *
 * Depositors bring VVV tokens. The vault:
 *   1. Approves VVV_STAKING and calls stake(vault, amount) → accumulates sVVV
 *   2. Calls VVV_STAKING.mintDiem(sVVV, minOut) → burns sVVV, mints DIEM to vault
 *      Real rate (Base mainnet, 2026-05): ~0.00141 DIEM per sVVV (1.41e15 wei per 1e18 wei)
 *      getDiemAmountOut(uint256) on VVV_STAKING previews the live rate.
 *      For 100 DIEM: ~70,884 VVV needed (~$10,600 at $0.15/VVV).
 *   3. Splits DIEM: protocol fee → autonomopoly; remainder → agentWallet for staking
 *
 * Autonomopoly fee:
 *   The deploying protocol earns `protocolFeeBps` of every DIEM minted.
 *   Example: 200 bps (2%) on 100 DIEM = 2 DIEM to protocol, 98 DIEM to agent.
 *
 * Allocation:
 *   The vault receives an agent token airdrop via receiveTokens().
 *   MAX allocation = extensionSupply (e.g. 10% of total supply).
 *   Effective allocation scales linearly with DIEM minted vs diemTarget (100 DIEM):
 *
 *     effectiveAllocation = min(totalDiemMinted, diemTarget) * extensionSupply / diemTarget
 *
 *   If only 10 DIEM minted → 10% of max allocation distributable.
 *   Remaining unallocated tokens are burned at claimDeadline.
 *
 *   Per depositor: proportional to VVV deposited / totalVvvDeposited.
 *
 * Deploy order:
 *   1. Deploy MintDiemPresaleVault (with factory=LIQUID_FACTORY, protocol=autonomopoly)
 *   2. Launch token via Liquid Factory with extensionConfigs pointing to this vault
 *      → factory calls receiveTokens() → vault sets depositDeadline
 *   3. VVV holders deposit during window (default 7 days)
 *   4. After depositDeadline: depositors call claimTokens(), unallocated tokens burned
 */

import {ILiquidExtension} from "../interfaces/ILiquidExtension.sol";
import {ILiquid} from "../interfaces/ILiquid.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

// VVV token is a plain ERC-20; no mintDiem here.
interface IVVV is IERC20 {}

interface IVVVStaking {
    /// @notice Stakes VVV on behalf of `staker`, crediting sVVV to `staker`'s balance.
    /// @dev VVV_STAKING proxy: 0x321b7ff75154472B18EDb199033fF4D116F340Ff (Base mainnet)
    function stake(address staker, uint256 amount) external;

    /// @notice sVVV balance of `account` tracked inside the staking contract (non-transferable).
    function balanceOf(address account) external view returns (uint256);

    /// @notice Preview DIEM out for burning `sVvvAmount` sVVV. Rate ~1.41e-3 DIEM/sVVV (2026-05).
    function getDiemAmountOut(uint256 sVvvAmount) external view returns (uint256);

    /// @notice Burns `sVVVAmountToLock` sVVV from msg.sender, mints DIEM to msg.sender.
    /// selector: 0x2006efcb
    function mintDiem(uint256 sVVVAmountToLock, uint256 minDiemAmountOut) external;
}

contract MintDiemPresaleVault is ILiquidExtension, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IVVV;

    // ── Immutable config ─────────────────────────────────────────────────

    IVVV        public immutable vvv;            // VVV ERC-20 (0xacfE6019...)
    IVVVStaking public immutable vvvStaking;     // VVV staking / sVVV (0x321b7ff...)
    IERC20      public immutable diem;           // DIEM ERC-20 (0xF4d97F2...)
    address     public immutable agentWallet;    // receives minted DIEM (minus protocol fee)
    address     public immutable factory;        // only caller allowed to invoke receiveTokens
    address     public immutable protocol;       // autonomopoly fee recipient
    uint256     public immutable protocolFeeBps; // protocol fee in bps (e.g. 200 = 2%)

    uint256     public immutable diemTarget;     // 100e18 — full allocation threshold
    uint256     public immutable depositWindow;  // seconds after receiveTokens to accept deposits

    // ── Mutable state ────────────────────────────────────────────────────

    address public token;               // agent token (set on receiveTokens)
    uint256 public extensionSupply;     // max token airdrop (set on receiveTokens)
    uint256 public depositDeadline;     // block.timestamp + depositWindow

    uint256 public totalDiemMinted;     // cumulative DIEM minted via this vault
    uint256 public totalVvvDeposited;   // cumulative VVV deposited (denominator for shares)

    mapping(address => uint256) public vvvDeposited;
    mapping(address => bool)    public tokensClaimed;

    bool public burnExecuted;

    // ── Events ───────────────────────────────────────────────────────────

    event Deposited(address indexed depositor, uint256 vvvAmount, uint256 diemMinted, uint256 protocolFee);
    event TokensClaimed(address indexed depositor, uint256 tokenAmount);
    event UnclaimedBurned(uint256 tokenAmount);

    // ── Errors ───────────────────────────────────────────────────────────

    error NotInitialized();
    error NotFactory();
    error DepositWindowClosed();
    error DepositWindowOpen();
    error AlreadyClaimed();
    error NothingToMint();
    error DiemTargetReached();
    error WouldExceedCap();
    error ZeroDeposit();

    // ── Constructor ──────────────────────────────────────────────────────

    constructor(
        address _vvv,
        address _vvvStaking,
        address _diem,
        address _agentWallet,
        uint256 _diemTarget,    // 100e18
        uint256 _depositWindow, // e.g. 7 days = 604800
        address _factory,       // Liquid Protocol factory — sole caller of receiveTokens
        address _protocol,      // autonomopoly fee recipient
        uint256 _protocolFeeBps // fee in bps (e.g. 200 = 2%); 0 disables the fee
    ) {
        vvv             = IVVV(_vvv);
        vvvStaking      = IVVVStaking(_vvvStaking);
        diem            = IERC20(_diem);
        agentWallet     = _agentWallet;
        diemTarget      = _diemTarget;
        depositWindow   = _depositWindow;
        factory         = _factory;
        protocol        = _protocol;
        protocolFeeBps  = _protocolFeeBps;
    }

    // ── ILiquidExtension ─────────────────────────────────────────────────

    function receiveTokens(
        ILiquid.DeploymentConfig calldata,
        PoolKey memory,
        address _token,
        uint256 _extensionSupply,
        uint256
    ) external payable override {
        if (msg.sender != factory) revert NotFactory();
        require(token == address(0), "Already initialized");
        IERC20(_token).transferFrom(msg.sender, address(this), _extensionSupply);
        token           = _token;
        extensionSupply = _extensionSupply;
        depositDeadline = block.timestamp + depositWindow;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ILiquidExtension).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    // ── Deposit ──────────────────────────────────────────────────────────

    /**
     * Deposit VVV. The vault stakes it → burns sVVV → mints DIEM → splits to protocol and agent.
     *
     * Depositors should call remainingCapacity() and vvvStaking.getDiemAmountOut() off-chain
     * to size their deposit so it doesn't hit WouldExceedCap.
     *
     * @param vvvAmount   Amount of VVV to deposit (must be pre-approved to this vault).
     * @param minDiemOut  Minimum DIEM to receive from mintDiem (slippage guard).
     */
    function deposit(uint256 vvvAmount, uint256 minDiemOut) external nonReentrant {
        if (token == address(0))                revert NotInitialized();
        if (block.timestamp >= depositDeadline) revert DepositWindowClosed();
        if (vvvAmount == 0)                     revert ZeroDeposit();
        if (totalDiemMinted >= diemTarget)      revert DiemTargetReached();

        // 1. Pull VVV from depositor
        vvv.safeTransferFrom(msg.sender, address(this), vvvAmount);

        // 2. Stake → vault accumulates sVVV; use balance delta, not vvvAmount, in case ratio shifts
        uint256 sVvvBefore = vvvStaking.balanceOf(address(this));
        vvv.safeIncreaseAllowance(address(vvvStaking), vvvAmount);
        vvvStaking.stake(address(this), vvvAmount);
        uint256 sVvvGained = vvvStaking.balanceOf(address(this)) - sVvvBefore;

        // 3. Preview and guard against overshooting the cap; revert so VVV is never silently wasted
        uint256 diemPreview = vvvStaking.getDiemAmountOut(sVvvGained);
        if (totalDiemMinted + diemPreview > diemTarget) revert WouldExceedCap();

        // 4. mintDiem on VVV_STAKING: burns vault's sVVV → DIEM minted to vault
        uint256 diemBefore = diem.balanceOf(address(this));
        vvvStaking.mintDiem(sVvvGained, minDiemOut);
        uint256 diemMinted = diem.balanceOf(address(this)) - diemBefore;

        // 5. Effects — all state writes before external transfers (CEI)
        totalDiemMinted          += diemMinted;
        vvvDeposited[msg.sender] += vvvAmount;
        totalVvvDeposited        += vvvAmount;

        // 6. Distribute DIEM: protocol fee first, remainder to agent wallet
        uint256 protocolFee = diemMinted * protocolFeeBps / 10_000;
        uint256 agentDiem   = diemMinted - protocolFee;
        if (protocolFee > 0) diem.safeTransfer(protocol, protocolFee);
        diem.safeTransfer(agentWallet, agentDiem);

        emit Deposited(msg.sender, vvvAmount, diemMinted, protocolFee);
    }

    // ── Claim ────────────────────────────────────────────────────────────

    /**
     * Claim agent tokens after depositDeadline.
     *
     * effectiveAllocation = min(totalDiemMinted, diemTarget) * extensionSupply / diemTarget
     * depositorShare      = vvvDeposited[msg.sender] * effectiveAllocation / totalVvvDeposited
     */
    function claimTokens() external {
        if (block.timestamp < depositDeadline) revert DepositWindowOpen();
        if (tokensClaimed[msg.sender])         revert AlreadyClaimed();
        if (vvvDeposited[msg.sender] == 0)     revert NothingToMint();

        tokensClaimed[msg.sender] = true;

        uint256 amount = getShare(msg.sender);
        if (amount > 0) {
            IERC20(token).safeTransfer(msg.sender, amount);
        }

        emit TokensClaimed(msg.sender, amount);
    }

    /**
     * Burn tokens that will never be claimable due to DIEM shortfall.
     * Can be called by anyone after depositDeadline.
     *
     * Burned = extensionSupply - effectiveAllocation
     */
    function burnUnclaimed() external {
        if (block.timestamp < depositDeadline) revert DepositWindowOpen();
        if (burnExecuted) return;
        burnExecuted = true;

        uint256 effective = effectiveAllocation();
        uint256 toBurn    = extensionSupply - effective;
        if (toBurn > 0) {
            IERC20(token).safeTransfer(address(0xdead), toBurn);
        }

        emit UnclaimedBurned(toBurn);
    }

    // ── Views ────────────────────────────────────────────────────────────

    /// @notice Max tokens distributable given DIEM minted so far.
    function effectiveAllocation() public view returns (uint256) {
        uint256 minted = totalDiemMinted > diemTarget ? diemTarget : totalDiemMinted;
        return minted * extensionSupply / diemTarget;
    }

    /// @notice Token allocation for a specific depositor.
    function getShare(address depositor) public view returns (uint256) {
        if (totalVvvDeposited == 0) return 0;
        return vvvDeposited[depositor] * effectiveAllocation() / totalVvvDeposited;
    }

    /// @notice DIEM remaining before the cap is hit.
    function remainingCapacity() external view returns (uint256) {
        if (totalDiemMinted >= diemTarget) return 0;
        return diemTarget - totalDiemMinted;
    }
}
