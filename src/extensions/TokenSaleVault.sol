// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * TokenSaleVault — sell any ERC-20 token via time-locked DIEM commitments.
 *
 * Any seller can offer a fixed number of any ERC-20 token. Buyers commit DIEM
 * during a configurable deposit window. After the window closes, each buyer
 * claims a pro-rata share of the tokens proportional to their DIEM committed:
 *
 *   share[buyer] = deposited[buyer] / totalDeposited × totalTokenSupply
 *
 * The committed DIEM is held in the vault for `lockDuration` after the window
 * closes, then returned to each buyer in full. Buyers bear only the opportunity
 * cost of the lock (forfeited inference credits if using DIEM on Venice).
 *
 * Pricing:
 *   `targetDiemWei` — the DIEM amount representing "fully subscribed". This is
 *   a price signal only: there is no hard cap. If totalDeposited > targetDiemWei
 *   the per-token allocation is diluted; if under, buyers get more than the
 *   reference rate implies. `usdValueE6` stores the per-token USD price
 *   (×10^6) as metadata; there is no on-chain oracle.
 *
 *   `effectivePriceWei()` returns the real price (totalDeposited / totalTokenSupply)
 *   after the window closes.
 *
 * Per-address cap:
 *   `maxDeposit` limits how much DIEM a single address may lock (0 = uncapped).
 *
 * Lifecycle:
 *   1. Deploy TokenSaleVault with config params.
 *   2. Seller calls initialize(saleToken, amount) — transfers tokens, opens window.
 *   3. Buyers call deposit(amount) — locks DIEM.
 *   4. After depositDeadline: buyers call claimTokens().
 *   5. After depositDeadline + lockDuration: buyers call withdrawDiem().
 *   6. After lockExpiry() + SWEEP_GRACE: seller calls sweepUnsold() for dust /
 *      full supply if no one deposited.
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract TokenSaleVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Window / lock bounds ──────────────────────────────────────────

    uint256 public constant MIN_LOCK = 1 days;
    uint256 public constant MAX_LOCK = 365 days;
    uint256 public constant MIN_WINDOW = 2 hours;
    uint256 public constant MAX_WINDOW = 30 days;
    uint256 public constant SWEEP_GRACE = 14 days;

    // ── Immutable config ──────────────────────────────────────────────

    IERC20 public immutable diem; // deposit token (Venice DIEM on Base)
    address public immutable seller; // initializes vault; reclaims unsold
    uint256 public immutable lockDuration; // seconds DIEM is locked after depositDeadline
    uint256 public immutable depositWindow; // seconds the deposit window stays open
    uint256 public immutable targetDiemWei; // reference: DIEM for "fully subscribed" (0 = none)
    uint256 public immutable maxDeposit; // per-address DIEM cap in wei (0 = uncapped)
    uint256 public immutable usdValueE6; // metadata: USD per sale token × 10^6 (0 = not set)

    // ── Mutable state ─────────────────────────────────────────────────

    IERC20 public saleToken;
    uint256 public totalTokenSupply;
    uint256 public depositDeadline;
    bool public initialized;

    uint256 public totalDeposited;
    mapping(address => uint256) public deposited;
    mapping(address => bool) public tokensClaimed;
    mapping(address => bool) public diemWithdrawn;

    // ── Errors ────────────────────────────────────────────────────────

    error NotSeller();
    error AlreadyInitialized();
    error NotInitialized();
    error InvalidLock();
    error InvalidWindow();
    error ZeroAmount();
    error DepositWindowClosed();
    error DepositWindowOpen();
    error ZeroDeposit();
    error DepositCapExceeded();
    error NothingDeposited();
    error NoDeposits();
    error AlreadyClaimed();
    error AlreadyWithdrawn();
    error LockNotExpired();
    error SweepTooEarly();

    // ── Events ────────────────────────────────────────────────────────

    event VaultInitialized(address indexed saleToken, uint256 tokenSupply, uint256 depositDeadline);
    event Deposited(address indexed depositor, uint256 amount);
    event TokensClaimed(address indexed depositor, uint256 tokenAmount);
    event DiemWithdrawn(address indexed depositor, uint256 amount);
    event UnsoldSwept(uint256 tokenAmount);

    // ── Constructor ───────────────────────────────────────────────────

    /**
     * @param diem_          DIEM token address (deposit currency).
     * @param seller_        Address that will call initialize() and receive unsold tokens.
     * @param lockDuration_  Seconds DIEM stays locked after depositDeadline.
     * @param depositWindow_ Seconds the deposit window stays open after initialize().
     * @param targetDiemWei_ Reference DIEM for "fully subscribed" (0 = no reference).
     * @param maxDeposit_    Per-address DIEM cap in wei (0 = uncapped).
     * @param usdValueE6_    Metadata: USD per sale token × 10^6 (0 = not set).
     */
    constructor(
        address diem_,
        address seller_,
        uint256 lockDuration_,
        uint256 depositWindow_,
        uint256 targetDiemWei_,
        uint256 maxDeposit_,
        uint256 usdValueE6_
    ) {
        if (lockDuration_ < MIN_LOCK || lockDuration_ > MAX_LOCK) {
            revert InvalidLock();
        }
        if (depositWindow_ < MIN_WINDOW || depositWindow_ > MAX_WINDOW) revert InvalidWindow();
        diem = IERC20(diem_);
        seller = seller_;
        lockDuration = lockDuration_;
        depositWindow = depositWindow_;
        targetDiemWei = targetDiemWei_;
        maxDeposit = maxDeposit_;
        usdValueE6 = usdValueE6_;
    }

    // ── Initialization ────────────────────────────────────────────────

    /**
     * Seller deposits sale tokens and opens the deposit window.
     * Caller must approve this contract for `amount_` of `saleToken_` beforehand.
     * @param saleToken_ Any ERC-20 token to put up for sale.
     * @param amount_    Number of tokens to sell (in the token's native decimals).
     */
    function initialize(address saleToken_, uint256 amount_) external nonReentrant {
        if (msg.sender != seller) revert NotSeller();
        if (initialized) revert AlreadyInitialized();
        if (amount_ == 0) revert ZeroAmount();

        IERC20(saleToken_).safeTransferFrom(msg.sender, address(this), amount_);
        saleToken = IERC20(saleToken_);
        totalTokenSupply = amount_;
        depositDeadline = block.timestamp + depositWindow;
        initialized = true;

        emit VaultInitialized(saleToken_, amount_, depositDeadline);
    }

    // ── Deposit ───────────────────────────────────────────────────────

    /**
     * Lock DIEM during the deposit window. Allocation is proportional to
     * totalDeposited at window close. DIEM is returned after lockExpiry.
     *
     * Top-ups are allowed within maxDeposit (if set). Deposit more than
     * once to accumulate a larger share while the window is open.
     *
     * @param amount DIEM to lock in wei (must pre-approve this vault).
     */
    function deposit(uint256 amount) external nonReentrant {
        if (!initialized) revert NotInitialized();
        if (block.timestamp >= depositDeadline) revert DepositWindowClosed();
        if (amount == 0) revert ZeroDeposit();
        if (maxDeposit > 0 && deposited[msg.sender] + amount > maxDeposit) {
            revert DepositCapExceeded();
        }

        diem.safeTransferFrom(msg.sender, address(this), amount);

        deposited[msg.sender] += amount;
        totalDeposited += amount;

        emit Deposited(msg.sender, amount);
    }

    // ── Claim tokens ──────────────────────────────────────────────────

    /**
     * Claim pro-rata token allocation after the deposit window closes.
     * share = deposited[msg.sender] / totalDeposited × totalTokenSupply
     *
     * Integer-division dust accumulates in the vault and is swept via sweepUnsold().
     */
    function claimTokens() external nonReentrant {
        if (!initialized) revert NotInitialized();
        if (block.timestamp < depositDeadline) revert DepositWindowOpen();
        if (tokensClaimed[msg.sender]) revert AlreadyClaimed();
        if (deposited[msg.sender] == 0) revert NothingDeposited();
        if (totalDeposited == 0) revert NoDeposits();

        tokensClaimed[msg.sender] = true;

        uint256 tokenAmount = deposited[msg.sender] * totalTokenSupply / totalDeposited;
        saleToken.safeTransfer(msg.sender, tokenAmount);

        emit TokensClaimed(msg.sender, tokenAmount);
    }

    // ── Withdraw DIEM ─────────────────────────────────────────────────

    /**
     * Return locked DIEM principal after lockExpiry.
     * lockExpiry = depositDeadline + lockDuration
     */
    function withdrawDiem() external nonReentrant {
        if (!initialized) revert NotInitialized();
        if (deposited[msg.sender] == 0) revert NothingDeposited();
        if (diemWithdrawn[msg.sender]) revert AlreadyWithdrawn();
        if (block.timestamp < _lockExpiry()) revert LockNotExpired();

        diemWithdrawn[msg.sender] = true;

        diem.safeTransfer(msg.sender, deposited[msg.sender]);

        emit DiemWithdrawn(msg.sender, deposited[msg.sender]);
    }

    // ── Sweep unsold ──────────────────────────────────────────────────

    /**
     * Return unsold / dust tokens to the seller.
     * Callable by anyone after lockExpiry() + SWEEP_GRACE.
     * Handles:
     *   - Integer-division dust remaining after all claimTokens() calls
     *   - Full supply when totalDeposited == 0 (no buyers)
     */
    function sweepUnsold() external nonReentrant {
        if (!initialized) revert NotInitialized();
        if (block.timestamp < _lockExpiry() + SWEEP_GRACE) revert SweepTooEarly();

        uint256 bal = saleToken.balanceOf(address(this));
        if (bal == 0) return;

        saleToken.safeTransfer(seller, bal);
        emit UnsoldSwept(bal);
    }

    // ── Views ─────────────────────────────────────────────────────────

    /// @notice Preview pro-rata token allocation for `who` at current deposits.
    function getShare(address who) external view returns (uint256) {
        if (totalDeposited == 0 || deposited[who] == 0) return 0;
        return deposited[who] * totalTokenSupply / totalDeposited;
    }

    /// @notice Lock expiry timestamp (0 before initialize()).
    function lockExpiry() external view returns (uint256) {
        if (!initialized) return 0;
        return _lockExpiry();
    }

    /**
     * @notice Effective per-token price in DIEM wei based on current deposits.
     *         Returns 0 before window closes or if no deposits exist.
     *         Compare against targetDiemWei / totalTokenSupply for the reference rate.
     */
    function effectivePriceWei() external view returns (uint256) {
        if (totalDeposited == 0 || totalTokenSupply == 0) return 0;
        return totalDeposited * 1e18 / totalTokenSupply;
    }

    // ── Internal ──────────────────────────────────────────────────────

    function _lockExpiry() internal view returns (uint256) {
        return depositDeadline + lockDuration;
    }
}
