// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * StakesaleVault — time-weighted DIEM presale for Liquid Protocol agent launches.
 *
 * DIEM holders lock DIEM for a chosen duration (30, 60, or 90 days) during the
 * deposit window. Token allocation is proportional to time-weighted shares:
 *
 *   weight = amount × lockMultiplier
 *
 * Lock multipliers:
 *   30 days → 1× (base rate)
 *   60 days → 2× (double allocation per DIEM)
 *   90 days → 3× (triple allocation per DIEM)
 *
 * Token allocation formula:
 *   depositorShare = weight[depositor] / totalWeight × totalTokenSupply
 *
 * Per-address cap: MAX_DEPOSIT (10 DIEM). Top-ups are allowed within the cap,
 * but the lock tier may not change after the first deposit.
 *
 * DIEM is held in the vault during the lock period. After lock expiry, each
 * depositor can withdraw their full DIEM principal. DIEM has no staking-delegation
 * mechanism — the vault holds DIEM without staking it on Venice.
 *
 * Lock expiry timing:
 *   lockExpiry[address] = depositDeadline + lockDuration[address]
 * All depositors who chose the same lock duration unlock at the same time,
 * regardless of when during the deposit window they deposited.
 *
 * Dust sweep: any remaining token balance can be swept to TREASURY after
 * depositDeadline + LOCK_90 (once all possible locks have expired). Anyone
 * can call sweepDust() — proceeds go to the Liquid Protocol treasury.
 *
 * extensionBps (default 2000 = 20%) is admin-adjustable by owner. It is
 * advisory only — used by the deploy script when printing the token launch
 * command. The factory enforces the actual allocation via extensionConfigs.
 *
 * Deploy order:
 *   1. Deploy StakesaleVault (diem=DIEM_ADDRESS, factory=LIQUID_FACTORY, depositWindow)
 *   2. Launch token via Liquid Factory with extensionConfigs pointing to this vault
 *      → factory calls receiveTokens() → vault sets depositDeadline
 *   3. DIEM holders deposit during window, each choosing a lock duration
 *   4. After depositDeadline: depositors call claimTokens()
 *   5. After lockExpiry: depositors call withdrawDiem() to reclaim principal
 *   6. After depositDeadline + LOCK_90: anyone may call sweepDust()
 */

import {ILiquid} from "../interfaces/ILiquid.sol";
import {ILiquidExtension} from "../interfaces/ILiquidExtension.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract StakesaleVault is ILiquidExtension, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Lock tiers ────────────────────────────────────────────────────────

    uint256 public constant LOCK_30 = 30 days;
    uint256 public constant LOCK_60 = 60 days;
    uint256 public constant LOCK_90 = 90 days;

    uint256 public constant MULTIPLIER_30 = 1;
    uint256 public constant MULTIPLIER_60 = 2;
    uint256 public constant MULTIPLIER_90 = 3;

    // ── Deposit window bounds ─────────────────────────────────────────────

    uint256 public constant MIN_DEPOSIT_WINDOW = 2 hours;
    uint256 public constant MAX_DEPOSIT_WINDOW = 30 days;

    // ── Per-address deposit cap ───────────────────────────────────────────

    uint256 public constant MAX_DEPOSIT = 10 ether; // 10 DIEM (18 decimals)

    // ── Treasury — dust sweep recipient ──────────────────────────────────

    address public constant TREASURY = 0x872c561f699B42977c093F0eD8b4C9a431280c6c;

    // ── Immutable config ──────────────────────────────────────────────────

    IERC20 public immutable diem;
    address public immutable factory;
    uint256 public immutable depositWindow;

    // ── Admin ─────────────────────────────────────────────────────────────

    address public owner;
    uint256 public extensionBps = 2000; // 20% — advisory; read by deploy script

    // ── Mutable state ─────────────────────────────────────────────────────

    address public token;
    uint256 public totalTokenSupply;
    uint256 public depositDeadline;
    bool public initialized;

    uint256 public totalDeposited;
    uint256 public totalWeight;

    mapping(address => uint256) public deposited;
    mapping(address => uint256) public chosenLock; // 0 = not deposited
    mapping(address => uint256) public weight;
    mapping(address => bool) public tokensClaimed;
    mapping(address => bool) public diemWithdrawn;

    // ── Errors ────────────────────────────────────────────────────────────

    error NotFactory();
    error NotOwner();
    error AlreadyInitialized();
    error NotInitialized();
    error InvalidDepositWindow();
    error InvalidLockDuration();
    error DepositWindowClosed();
    error DepositWindowOpen();
    error LockDurationMismatch();
    error LockNotExpired();
    error AlreadyClaimed();
    error AlreadyWithdrawn();
    error NothingDeposited();
    error ZeroDeposit();
    error NoDeposits();
    error DepositCapExceeded();
    error SweepTooEarly();

    // ── Events ────────────────────────────────────────────────────────────

    event VaultInitialized(address indexed token, uint256 tokenSupply, uint256 depositDeadline);
    event Deposited(
        address indexed depositor, uint256 amount, uint256 lockDuration, uint256 weight
    );
    event TokensClaimed(address indexed depositor, uint256 tokenAmount);
    event DiemWithdrawn(address indexed depositor, uint256 amount);
    event DustSwept(uint256 tokenAmount);
    event ExtensionBpsUpdated(uint256 oldBps, uint256 newBps);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ── Constructor ───────────────────────────────────────────────────────

    constructor(address diem_, address factory_, uint256 depositWindow_) {
        if (depositWindow_ < MIN_DEPOSIT_WINDOW || depositWindow_ > MAX_DEPOSIT_WINDOW) {
            revert InvalidDepositWindow();
        }
        diem = IERC20(diem_);
        factory = factory_;
        depositWindow = depositWindow_;
        owner = msg.sender;
    }

    // ── Admin ─────────────────────────────────────────────────────────────

    function setExtensionBps(uint256 newBps) external {
        if (msg.sender != owner) revert NotOwner();
        emit ExtensionBpsUpdated(extensionBps, newBps);
        extensionBps = newBps;
    }

    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert NotOwner();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ── ILiquidExtension ──────────────────────────────────────────────────

    /// @notice Called by the Liquid factory during deployToken(). Opens the deposit window.
    function receiveTokens(
        ILiquid.DeploymentConfig calldata,
        PoolKey memory,
        address token_,
        uint256 extensionSupply,
        uint256
    ) external payable override {
        if (msg.sender != factory) revert NotFactory();
        if (initialized) revert AlreadyInitialized();
        if (msg.value != 0) revert InvalidMsgValue();

        IERC20(token_).safeTransferFrom(msg.sender, address(this), extensionSupply);
        token = token_;
        totalTokenSupply = extensionSupply;
        depositDeadline = block.timestamp + depositWindow;
        initialized = true;

        emit VaultInitialized(token_, extensionSupply, depositDeadline);
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ILiquidExtension).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    // ── Deposit ───────────────────────────────────────────────────────────

    /**
     * Lock DIEM during the deposit window and choose a lock duration (LOCK_30/60/90).
     * First deposit sets the lock duration for this address; subsequent deposits must
     * use the same duration. Total deposits per address capped at MAX_DEPOSIT (10 DIEM).
     *
     * Weight = amount × lockMultiplier. Token allocation is proportional to weight.
     *
     * @param amount        DIEM to deposit (pre-approved to this vault).
     * @param lockDuration_ LOCK_30 (30d), LOCK_60 (60d), or LOCK_90 (90d).
     */
    function deposit(uint256 amount, uint256 lockDuration_) external nonReentrant {
        if (!initialized) revert NotInitialized();
        if (block.timestamp >= depositDeadline) revert DepositWindowClosed();
        if (amount == 0) revert ZeroDeposit();

        uint256 multiplier = _multiplier(lockDuration_);

        if (deposited[msg.sender] > 0 && chosenLock[msg.sender] != lockDuration_) {
            revert LockDurationMismatch();
        }

        if (deposited[msg.sender] + amount > MAX_DEPOSIT) {
            revert DepositCapExceeded();
        }

        diem.safeTransferFrom(msg.sender, address(this), amount);

        if (deposited[msg.sender] == 0) {
            chosenLock[msg.sender] = lockDuration_;
        }

        uint256 addedWeight = amount * multiplier;
        deposited[msg.sender] += amount;
        weight[msg.sender] += addedWeight;
        totalDeposited += amount;
        totalWeight += addedWeight;

        emit Deposited(msg.sender, amount, lockDuration_, addedWeight);
    }

    // ── Claim tokens ──────────────────────────────────────────────────────

    /// @notice Claim weighted pro-rata token allocation after depositDeadline.
    function claimTokens() external nonReentrant {
        if (!initialized) revert NotInitialized();
        if (block.timestamp < depositDeadline) revert DepositWindowOpen();
        if (tokensClaimed[msg.sender]) revert AlreadyClaimed();
        if (deposited[msg.sender] == 0) revert NothingDeposited();
        if (totalWeight == 0) revert NoDeposits();

        tokensClaimed[msg.sender] = true;

        // Integer division rounds down; dust accumulates in vault (see sweepDust).
        uint256 tokenAmount = weight[msg.sender] * totalTokenSupply / totalWeight;
        IERC20(token).safeTransfer(msg.sender, tokenAmount);

        emit TokensClaimed(msg.sender, tokenAmount);
    }

    // ── Withdraw DIEM ─────────────────────────────────────────────────────

    /// @notice Return locked DIEM principal after lockExpiry.
    ///         lockExpiry = depositDeadline + chosenLock[depositor]
    function withdrawDiem() external nonReentrant {
        if (!initialized) revert NotInitialized();
        if (deposited[msg.sender] == 0) revert NothingDeposited();
        if (diemWithdrawn[msg.sender]) revert AlreadyWithdrawn();
        if (block.timestamp < _lockExpiryOf(msg.sender)) revert LockNotExpired();

        diemWithdrawn[msg.sender] = true;

        diem.safeTransfer(msg.sender, deposited[msg.sender]);

        emit DiemWithdrawn(msg.sender, deposited[msg.sender]);
    }

    // ── Dust sweep ────────────────────────────────────────────────────────

    /**
     * Sweep remaining token balance to TREASURY after all locks have expired.
     * Callable by anyone after depositDeadline + LOCK_90. Handles:
     *   - Integer-division dust from claimTokens()
     *   - Full supply when no one deposited (totalWeight == 0)
     */
    function sweepDust() external nonReentrant {
        if (!initialized) revert NotInitialized();
        if (block.timestamp < depositDeadline + LOCK_90 + 14 days) revert SweepTooEarly();

        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) return;

        IERC20(token).safeTransfer(TREASURY, bal);
        emit DustSwept(bal);
    }

    // ── Views ─────────────────────────────────────────────────────────────

    /// @notice Preview token allocation for a depositor.
    function getShare(address who) external view returns (uint256) {
        if (totalWeight == 0 || weight[who] == 0) return 0;
        return weight[who] * totalTokenSupply / totalWeight;
    }

    /// @notice Depositor's lock expiry timestamp. Returns 0 if not deposited.
    function lockExpiryOf(address who) external view returns (uint256) {
        if (deposited[who] == 0) return 0;
        return _lockExpiryOf(who);
    }

    // ── Internal ──────────────────────────────────────────────────────────

    function _multiplier(uint256 duration) internal pure returns (uint256) {
        if (duration == LOCK_30) return MULTIPLIER_30;
        if (duration == LOCK_60) return MULTIPLIER_60;
        if (duration == LOCK_90) return MULTIPLIER_90;
        revert InvalidLockDuration();
    }

    function _lockExpiryOf(address who) internal view returns (uint256) {
        return depositDeadline + chosenLock[who];
    }
}
