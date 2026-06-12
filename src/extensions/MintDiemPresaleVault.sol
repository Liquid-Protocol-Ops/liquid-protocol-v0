// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ⚠ SUPERSEDED (2026-06-12, Linear MOG-497): the canonical Venice Agent Launchpad presale
// contract is LiquidPresaleVault (liquid-website repo, contracts/presale/). This contract is
// retained for tests/reference and must not be deployed for new launches.

/**
 * MintDiemPresaleVault — compute presale for Liquid Protocol agent launches.
 *
 * Two deposit paths — users bring VVV or DIEM:
 *
 *   deposit(vvvAmount, minDiemOut)   — VVV path
 *     1. Vault approves VVV_STAKING and calls stake(vault, vvvAmount) → accumulates sVVV
 *        (sVVV is the vault's internal staked balance, non-transferable, never seen by depositors)
 *     2. Calls VVV_STAKING.mintDiem(sVVV, minOut) → burns sVVV, mints DIEM to vault
 *        Real rate (Base mainnet, 2026-05): ~0.00141 DIEM per VVV staked
 *        getDiemAmountOut(uint256) on VVV_STAKING previews the live rate.
 *        For 100 DIEM: ~70,884 VVV needed (~$10,600 at $0.15/VVV).
 *
 *   depositDIEM(diemAmount)          — DIEM path
 *     Depositors bring DIEM directly; no conversion step.
 *
 * Both paths split DIEM: protocol fee → autonomopoly; remainder → agentWallet for Venice staking.
 *
 * Autonomopoly fee:
 *   The deploying protocol earns `protocolFeeBps` of every DIEM routed through the vault.
 *   Example: 200 bps (2%) on 100 DIEM = 2 DIEM to protocol, 98 DIEM to agent.
 *
 * Allocation:
 *   The vault receives an agent token airdrop via receiveTokens().
 *   MAX allocation = extensionSupply (e.g. 10% of total supply).
 *   Effective allocation scales linearly with DIEM routed vs diemTarget (default 100 DIEM):
 *
 *     effectiveAllocation = min(totalDiemMinted, diemTarget) * extensionSupply / diemTarget
 *
 *   Depositor shares are proportional to diemContributed — the DIEM-equivalent each address
 *   delivered (converted from VVV or deposited directly):
 *
 *     depositorShare = diemContributed[depositor] * effectiveAllocation / totalDiemMinted
 *
 *   If only 50% of diemTarget is reached, only 50% of extensionSupply is distributable;
 *   the rest is burned after the deposit window closes.
 *
 * Deposit window:
 *   Configurable at deploy time. Minimum: MIN_DEPOSIT_WINDOW (2 hours). Default in the
 *   deploy script: 24 hours. Maximum: 30 days.
 *
 * Deploy order:
 *   1. Deploy MintDiemPresaleVault (factory=LIQUID_FACTORY, protocol=autonomopoly)
 *   2. Launch token via Liquid Factory with extensionConfigs pointing to this vault
 *      → factory calls receiveTokens() → vault sets depositDeadline
 *   3. VVV or DIEM holders deposit during window
 *   4. After depositDeadline: depositors call claimTokens(); anyone can call burnUnclaimed()
 */

import {ILiquid} from "../interfaces/ILiquid.sol";
import {ILiquidExtension} from "../interfaces/ILiquidExtension.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
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

    // ── Constants ────────────────────────────────────────────────────────

    uint256 public constant MIN_DEPOSIT_WINDOW = 2 hours;
    uint256 public constant MAX_DEPOSIT_WINDOW = 30 days;

    // ── Immutable config ─────────────────────────────────────────────────

    IVVV public immutable vvv; // VVV ERC-20 (0xacfE6019...)
    IVVVStaking public immutable vvvStaking; // VVV staking / sVVV (0x321b7ff...)
    IERC20 public immutable diem; // DIEM ERC-20 (0xF4d97F2...)
    address public immutable agentWallet; // receives DIEM routed through the vault
    address public immutable factory; // only caller allowed to invoke receiveTokens
    address public immutable protocol; // autonomopoly fee recipient
    uint256 public immutable protocolFeeBps; // protocol fee in bps (e.g. 200 = 2%)

    uint256 public immutable diemTarget; // 100e18 — full allocation threshold
    uint256 public immutable depositWindow; // seconds the deposit window stays open

    // ── Mutable state ────────────────────────────────────────────────────

    address public token; // agent token (set on receiveTokens)
    uint256 public extensionSupply; // max token airdrop (set on receiveTokens)
    uint256 public depositDeadline; // block.timestamp + depositWindow

    uint256 public totalDiemMinted; // cumulative DIEM routed (VVV-converted + direct DIEM)

    // Informational (not used in share formula)
    uint256 public totalVvvDeposited;
    mapping(address => uint256) public vvvDeposited;
    mapping(address => uint256) public diemDeposited;

    // Share formula: diemContributed[depositor] / totalDiemMinted
    mapping(address => uint256) public diemContributed;

    mapping(address => bool) public tokensClaimed;

    bool public burnExecuted;

    // ── Events ───────────────────────────────────────────────────────────

    event VvvDeposited(
        address indexed depositor, uint256 vvvAmount, uint256 diemMinted, uint256 protocolFee
    );
    event DiemDeposited(address indexed depositor, uint256 diemAmount, uint256 protocolFee);
    event TokensClaimed(address indexed depositor, uint256 tokenAmount);
    event UnclaimedBurned(uint256 tokenAmount);

    // ── Errors ───────────────────────────────────────────────────────────

    error NotInitialized();
    error NotFactory();
    error InvalidDepositWindow();
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
        uint256 _diemTarget, // 100e18
        uint256 _depositWindow, // MIN_DEPOSIT_WINDOW (2h) – MAX_DEPOSIT_WINDOW (30d); default 24h
        address _factory, // Liquid Protocol factory — sole caller of receiveTokens
        address _protocol, // autonomopoly fee recipient
        uint256 _protocolFeeBps // fee in bps (e.g. 200 = 2%); 0 disables the fee
    ) {
        if (_depositWindow < MIN_DEPOSIT_WINDOW || _depositWindow > MAX_DEPOSIT_WINDOW) {
            revert InvalidDepositWindow();
        }
        vvv = IVVV(_vvv);
        vvvStaking = IVVVStaking(_vvvStaking);
        diem = IERC20(_diem);
        agentWallet = _agentWallet;
        diemTarget = _diemTarget;
        depositWindow = _depositWindow;
        factory = _factory;
        protocol = _protocol;
        protocolFeeBps = _protocolFeeBps;
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
        token = _token;
        extensionSupply = _extensionSupply;
        depositDeadline = block.timestamp + depositWindow;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ILiquidExtension).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    // ── Deposit: VVV path ────────────────────────────────────────────────

    /**
     * Deposit VVV. Vault stakes VVV → sVVV → mintDiem → DIEM split to protocol and agent.
     * Depositors never hold or see sVVV — it is the vault's internal staked balance.
     *
     * Size the deposit using:
     *   remainingCapacity()                        → DIEM remaining before cap
     *   vvvStaking.getDiemAmountOut(sVvvEstimate)  → preview DIEM output for a given sVVV amount
     *
     * @param vvvAmount   VVV to deposit (pre-approved to this vault).
     * @param minDiemOut  Minimum DIEM from mintDiem (slippage guard; 0 = no guard).
     */
    function deposit(uint256 vvvAmount, uint256 minDiemOut) external nonReentrant {
        if (token == address(0)) revert NotInitialized();
        if (block.timestamp >= depositDeadline) revert DepositWindowClosed();
        if (vvvAmount == 0) revert ZeroDeposit();
        if (totalDiemMinted >= diemTarget) revert DiemTargetReached();

        // 1. Pull VVV from depositor
        vvv.safeTransferFrom(msg.sender, address(this), vvvAmount);

        // 2. Stake → sVVV; track balance delta in case VVV:sVVV ratio shifts
        uint256 sVvvBefore = vvvStaking.balanceOf(address(this));
        vvv.safeIncreaseAllowance(address(vvvStaking), vvvAmount);
        vvvStaking.stake(address(this), vvvAmount);
        uint256 sVvvGained = vvvStaking.balanceOf(address(this)) - sVvvBefore;

        // 3. Preview and guard against overshooting the cap (no silent VVV waste)
        uint256 diemPreview = vvvStaking.getDiemAmountOut(sVvvGained);
        if (totalDiemMinted + diemPreview > diemTarget) revert WouldExceedCap();

        // 4. mintDiem on VVV_STAKING: burns vault's sVVV → DIEM to vault
        uint256 diemBefore = diem.balanceOf(address(this));
        vvvStaking.mintDiem(sVvvGained, minDiemOut);
        uint256 diemMinted = diem.balanceOf(address(this)) - diemBefore;

        // 5. Effects — all state before transfers (CEI)
        totalDiemMinted += diemMinted;
        diemContributed[msg.sender] += diemMinted;
        vvvDeposited[msg.sender] += vvvAmount;
        totalVvvDeposited += vvvAmount;

        // 6. Split DIEM: protocol fee → protocol, remainder → agent
        _distributeDiem(diemMinted);

        emit VvvDeposited(msg.sender, vvvAmount, diemMinted, _protocolFee(diemMinted));
    }

    // ── Deposit: DIEM path ───────────────────────────────────────────────

    /**
     * Deposit DIEM directly. Counts toward the diemTarget cap on the same terms as the VVV path.
     * Depositor share is proportional to DIEM deposited vs total DIEM routed by all depositors.
     *
     * @param diemAmount  DIEM to deposit (pre-approved to this vault).
     */
    function depositDIEM(uint256 diemAmount) external nonReentrant {
        if (token == address(0)) revert NotInitialized();
        if (block.timestamp >= depositDeadline) revert DepositWindowClosed();
        if (diemAmount == 0) revert ZeroDeposit();
        if (totalDiemMinted >= diemTarget) revert DiemTargetReached();
        if (totalDiemMinted + diemAmount > diemTarget) revert WouldExceedCap();

        // 1. Pull DIEM from depositor
        diem.safeTransferFrom(msg.sender, address(this), diemAmount);

        // 2. Effects
        totalDiemMinted += diemAmount;
        diemContributed[msg.sender] += diemAmount;
        diemDeposited[msg.sender] += diemAmount;

        // 3. Split DIEM: protocol fee → protocol, remainder → agent
        _distributeDiem(diemAmount);

        emit DiemDeposited(msg.sender, diemAmount, _protocolFee(diemAmount));
    }

    // ── Claim ────────────────────────────────────────────────────────────

    /**
     * Claim agent tokens after depositDeadline.
     *
     * effectiveAllocation = min(totalDiemMinted, diemTarget) * extensionSupply / diemTarget
     * depositorShare      = diemContributed[msg.sender] * effectiveAllocation / totalDiemMinted
     */
    function claimTokens() external {
        if (block.timestamp < depositDeadline) revert DepositWindowOpen();
        if (tokensClaimed[msg.sender]) revert AlreadyClaimed();
        if (diemContributed[msg.sender] == 0) revert NothingToMint();

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
        uint256 toBurn = extensionSupply - effective;
        if (toBurn > 0) {
            IERC20(token).safeTransfer(address(0xdead), toBurn);
        }

        emit UnclaimedBurned(toBurn);
    }

    // ── Views ────────────────────────────────────────────────────────────

    /// @notice Max tokens distributable given DIEM routed so far.
    function effectiveAllocation() public view returns (uint256) {
        uint256 minted = totalDiemMinted > diemTarget ? diemTarget : totalDiemMinted;
        return minted * extensionSupply / diemTarget;
    }

    /// @notice Token allocation for a specific depositor.
    function getShare(address depositor) public view returns (uint256) {
        if (totalDiemMinted == 0) return 0;
        return diemContributed[depositor] * effectiveAllocation() / totalDiemMinted;
    }

    /// @notice DIEM remaining before the cap is hit.
    function remainingCapacity() external view returns (uint256) {
        if (totalDiemMinted >= diemTarget) return 0;
        return diemTarget - totalDiemMinted;
    }

    // ── Internal ─────────────────────────────────────────────────────────

    function _protocolFee(uint256 amount) internal view returns (uint256) {
        return amount * protocolFeeBps / 10_000;
    }

    function _distributeDiem(uint256 amount) internal {
        uint256 fee = _protocolFee(amount);
        uint256 agentAmt = amount - fee;
        if (fee > 0) diem.safeTransfer(protocol, fee);
        diem.safeTransfer(agentWallet, agentAmt);
    }
}
