// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Venice DIEM token — self-staking only. stake(amount) moves DIEM from
// msg.sender's balanceOf into msg.sender's Venice account. No stakeFor exists.
interface IDIEM is IERC20 {
    function stake(uint256 amount) external;
    function initiateUnstake(uint256 amount) external;
    function unstake() external;
    // Real field order confirmed from verified Diem.sol source on Sourcify:
    //   slot 0: amountStaked   — actively staked DIEM
    //   slot 1: coolDownEnd    — cooldown expiry TIMESTAMP (not an amount)
    //   slot 2: coolDownAmount — DIEM queued for withdrawal
    function stakedInfos(address account)
        external
        view
        returns (uint256 amountStaked, uint256 coolDownEnd, uint256 coolDownAmount);
    function cooldownDuration() external view returns (uint256);
}

/// @title  InferenceVault — wstDIEM
/// @notice ERC-4626 vault that stakes DIEM on Venice AI and mints wstDIEM.
///
/// Yield: venue adapters (AntSeed, Surplus, X402, InferenceProduct) convert
/// inference USDC to DIEM off-chain and call creditDIEM(). Staking that DIEM
/// grows totalAssets() without issuing new shares — wstDIEM appreciates like
/// wstETH (share-price model, not rebasing).
///
/// Withdrawal lifecycle — async, permissionless, pull model:
///
///   1. requestRedeem(shares, receiver)
///         Burns shares immediately. Locks the DIEM amount at the current rate.
///         Returns a requestId. Rate is unaffected: pendingWithdrawalDiem
///         subtracts the earmarked DIEM from totalAssets() so convertToAssets()
///         stays constant for all remaining holders.
///
///   2. flush()
///         Anyone calls after the batch is full (50 users) OR minBatchOpenSecs
///         has elapsed (default 1 day). Initiates the Venice 24h unstake.
///         Only one batch may be unstaking at a time (Venice constraint).
///
///   3. settle()
///         Anyone calls after the Venice cooldown (~24h). Moves DIEM from
///         Venice back to the vault balance; marks the batch claimable.
///
///   4. claimRedeem(requestId)
///         The receiver (or anyone on their behalf) pulls their DIEM.
///         No deadline — funds sit in vault until claimed.
///
/// ERC-1271: vault holds a Venice API key registered to address(this).
///   veniceSigner (a hot key separate from the Safe) signs Venice challenges.
///   Venice calls isValidSignature; inference budget = stakedInfos[address(this)].
///   Rotate veniceSigner without a Safe transaction via setVeniceSigner().
///
/// Oracle safety: pendingWithdrawalDiem is always subtracted from totalAssets()
///   so the Morpho oracle (and any integration reading convertToAssets) is not
///   distorted during the flush→settle cooldown window.
contract InferenceVault is ERC4626, Ownable, Pausable, ReentrancyGuard, IERC1271 {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ─── Errors ──────────────────────────────────────────────────────────────
    error NotVenueAdapter();
    error NotInferenceToken();
    error MaxStakeExceeded();
    error BatchFull();
    error BatchNotOpen(); // flush called with no pending requests
    error BatchTooNew(); // minBatchOpenSecs not elapsed, batch not full
    error PriorBatchUnstaking(); // another batch already in Venice unstake
    error BatchNotFlushed(); // settle called before flush
    error BatchNotReady(); // Venice cooldown not yet elapsed
    error BatchAlreadySettled();
    error BatchNotSettled(); // claimRedeem called before settle
    error AlreadyClaimed();

    // ─── Events ──────────────────────────────────────────────────────────────
    event RedeemRequested(
        uint256 indexed requestId,
        address indexed receiver,
        uint32 indexed batchId,
        uint256 shares,
        uint256 diem
    );
    event BatchFlushed(uint32 indexed batchId, uint256 diemTotal, uint64 unlockAt);
    event BatchSettled(uint32 indexed batchId, uint256 diemTotal);
    event Claimed(uint256 indexed requestId, address indexed receiver, uint256 diem);
    event DIEMCredited(address indexed adapter, uint256 amount);
    event DepositFeeBpsSet(uint256 bps);
    event YieldFeeBpsSet(uint256 bps);
    event WstDIEMCredited(
        address indexed source, address indexed recipient, uint256 diem, uint256 shares
    );
    event VenueAdapterSet(address indexed adapter, bool enabled);
    event InferenceTokenSet(address indexed token, bool enabled);
    event VeniceSignerSet(address indexed signer);

    // ─── Constants ───────────────────────────────────────────────────────────
    bytes4 private constant ERC1271_MAGIC = 0x1626ba7e;
    uint32 public constant MAX_BATCH_SIZE = 50;
    uint64 public constant MAX_BATCH_OPEN_SECS = 7 days;
    uint256 public constant MAX_DEPOSIT_FEE_BPS = 1000; // 10% hard cap
    uint256 public constant MAX_YIELD_FEE_BPS = 2000; // 20% hard cap

    uint256 public depositFeeBps = 250; // 2.5% on deposits, owner-updatable
    uint256 public yieldFeeBps = 500; // 5% on creditDIEM revenue, owner-updatable

    // ─── Signer / adapter / treasury ─────────────────────────────────────────
    /// @notice Hot key that signs Venice API key challenges. Separate from owner()
    ///         so the Safe never needs to participate in API key operations.
    address public veniceSigner;

    /// @notice Approved callers of creditDIEM / creditWstDIEM.
    ///         (AntSeedAdapter, SurplusAdapter, X402Adapter, FeeRouter, etc.)
    mapping(address => bool) public isVenueAdapter;

    /// @notice Registered inference token sources (IInferenceToken implementors).
    ///         Subset of isVenueAdapter — must also be a venue adapter to route yield.
    ///         Bounded to MAX_INFERENCE_TOKENS to cap totalAssets() loop cost if
    ///         on-chain aggregation is added in a future upgrade.
    mapping(address => bool) public isInferenceToken;
    address[] private _inferenceTokens;
    uint256 public constant MAX_INFERENCE_TOKENS = 16;

    address public treasury;

    // ─── Deposit cap ─────────────────────────────────────────────────────────
    /// @notice Maximum gross DIEM the vault may hold (staked + unstaking + idle).
    ///         0 = uncapped. Set before launch if Venice has a per-address limit.
    uint256 public maxTotalStake;

    // ─── Withdrawal queue ────────────────────────────────────────────────────
    /// @notice Minimum seconds a batch must stay open before flush() is allowed,
    ///         unless the batch is already full. Default: 1 day. Max: 7 days.
    uint64 public minBatchOpenSecs = 1 days;

    struct UnstakeBatch {
        uint128 diemTotal; // sum of DIEM owed; accumulated at requestRedeem time
        uint64 openedAt; // timestamp of first request (0 = batch is empty)
        uint64 unlockAt; // set at flush() = block.timestamp + cooldownDuration
        uint32 userCount; // number of requests in this batch
        bool settled; // true after settle() calls Venice unstake()
    }
    mapping(uint32 => UnstakeBatch) public unstakeBatches;

    /// @notice The batch currently accepting new requestRedeem calls.
    uint32 public currentBatch = 1;

    /// @notice The batch currently in Venice's unstake queue. 0 = none.
    ///         Venice only supports one pending unstake per address at a time.
    uint32 public unstakingBatch;

    struct RedeemRequest {
        address receiver; // who receives the DIEM; fixed at request time
        uint128 diem; // amount locked at requestRedeem; never changes
        uint32 batchId;
        bool claimed;
    }
    mapping(uint256 => RedeemRequest) public redeemRequests;
    uint256 private _nextRequestId = 1;

    /// @notice Owner → list of requestIds. Enables getRedeemRequests(address).
    mapping(address => uint256[]) private _ownerRequests;

    /// @notice Minimum wstDIEM shares per requestRedeem call.
    ///         Prevents dust requests from griefing the 50-user batch cap.
    ///         Default: 0.001 wstDIEM. Owner-settable.
    uint256 public minRedeemShares = 1e15;

    /// @notice DIEM earmarked for pending requests, excluded from totalAssets().
    ///         Set at requestRedeem; cleared per-request at claimRedeem.
    ///         Keeps convertToAssets() stable throughout the entire withdrawal
    ///         lifecycle so the Morpho oracle cannot be manipulated.
    uint256 public pendingWithdrawalDiem;

    // ─── Constructor ─────────────────────────────────────────────────────────
    constructor(address diem, address _treasury, address _veniceSigner, address initialOwner)
        ERC4626(IERC20(diem))
        ERC20("Wrapped Staked DIEM", "wstDIEM")
        Ownable(initialOwner)
    {
        treasury = _treasury;
        veniceSigner = _veniceSigner;
    }

    // ─── ERC-1271 ────────────────────────────────────────────────────────────
    /// @dev Venice calls this when registering an API key for address(this).
    ///      veniceSigner (a keeper/Privy hot key) signs Venice's challenge
    ///      off-chain. Rotating veniceSigner requires only one Safe tx.
    function isValidSignature(bytes32 hash, bytes calldata sig)
        external
        view
        override
        returns (bytes4)
    {
        (address recovered,,) = ECDSA.tryRecover(hash, sig);
        return recovered == veniceSigner ? ERC1271_MAGIC : bytes4(0xffffffff);
    }

    // ─── Asset accounting ────────────────────────────────────────────────────
    /// @dev Subtracts pendingWithdrawalDiem (earmarked for withdrawal) from gross
    ///      DIEM so convertToAssets() is unaffected by in-flight redemptions.
    function totalAssets() public view override returns (uint256) {
        (uint256 amountStaked,, uint256 coolDownAmount) = IDIEM(asset()).stakedInfos(address(this));
        uint256 gross = IERC20(asset()).balanceOf(address(this)) + amountStaked + coolDownAmount;
        return gross - pendingWithdrawalDiem;
    }

    function vaultOwnedShares() public view returns (uint256) {
        return balanceOf(address(this));
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 0;
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding)
        internal
        view
        override
        returns (uint256)
    {
        return assets.mulDiv(totalSupply() + 10 ** _decimalsOffset(), totalAssets() + 1, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding)
        internal
        view
        override
        returns (uint256)
    {
        return shares.mulDiv(totalAssets() + 1, totalSupply() + 10 ** _decimalsOffset(), rounding);
    }

    // ─── Deposit fee ─────────────────────────────────────────────────────────
    function currentDepositFeeBps() public view returns (uint256) {
        return depositFeeBps;
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        uint256 fee = assets.mulDiv(currentDepositFeeBps(), 10_000, Math.Rounding.Ceil);
        return _convertToShares(assets - fee, Math.Rounding.Floor);
    }

    function previewMint(uint256 shares) public view override returns (uint256) {
        uint256 netAssets = _convertToAssets(shares, Math.Rounding.Ceil);
        uint256 feeBps = currentDepositFeeBps();
        return netAssets.mulDiv(10_000, 10_000 - feeBps, Math.Rounding.Ceil);
    }

    // ─── Deposit ─────────────────────────────────────────────────────────────
    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        return super.mint(shares, receiver);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
    {
        if (maxTotalStake > 0) {
            (uint256 staked,, uint256 unstaking) = IDIEM(asset()).stakedInfos(address(this));
            uint256 gross = IERC20(asset()).balanceOf(address(this)) + staked + unstaking;
            if (gross + assets > maxTotalStake) revert MaxStakeExceeded();
        }
        uint256 feeAssets = assets.mulDiv(currentDepositFeeBps(), 10_000, Math.Rounding.Ceil);
        uint256 feeShares;
        if (feeAssets > 0 && treasury != address(0)) {
            feeShares = _convertToShares(feeAssets, Math.Rounding.Floor);
        }
        IERC20(asset()).safeTransferFrom(caller, address(this), assets);
        if (feeShares > 0) _mint(treasury, feeShares);
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
        IDIEM(asset()).stake(assets);
    }

    // Instant withdrawal is disabled — all exits use requestRedeem.
    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }

    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }

    // ─── Step 1: request redemption ──────────────────────────────────────────
    /// @notice Queue a redemption. Shares are burned immediately; the DIEM amount
    ///         is locked at the current exchange rate.
    /// @param  shares   wstDIEM to redeem. Burned from msg.sender.
    /// @param  receiver Address that receives DIEM after the batch settles.
    ///                  Can differ from msg.sender (e.g., a smart contract wrapper).
    /// @return requestId Save this — pass it to claimRedeem() once the batch settles.
    function requestRedeem(uint256 shares, address receiver)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        require(shares >= minRedeemShares, "below minRedeemShares");
        require(receiver != address(0), "zero receiver");

        uint32 batchId = currentBatch;
        UnstakeBatch storage b = unstakeBatches[batchId];

        if (b.unlockAt != 0) revert BatchFull(); // already flushed
        if (b.userCount >= MAX_BATCH_SIZE) revert BatchFull();

        // Snapshot the DIEM value at the current rate and burn shares immediately.
        // pendingWithdrawalDiem registers a liability so totalAssets() excludes
        // this DIEM — rate stays constant for all remaining wstDIEM holders.
        uint256 diem = previewRedeem(shares);
        _burn(msg.sender, shares);
        pendingWithdrawalDiem += diem;

        if (b.openedAt == 0) b.openedAt = uint64(block.timestamp);
        b.diemTotal += uint128(diem);
        b.userCount += 1;

        requestId = _nextRequestId++;
        redeemRequests[requestId] = RedeemRequest({
            receiver: receiver, diem: uint128(diem), batchId: batchId, claimed: false
        });
        _ownerRequests[receiver].push(requestId);

        emit RedeemRequested(requestId, receiver, batchId, shares, diem);
    }

    // ─── Step 2: flush ───────────────────────────────────────────────────────
    /// @notice Initiate the Venice 24h unstake for the current batch.
    ///         Permissionless: anyone can call once conditions are met.
    ///         Conditions: batch is full (50 requests) OR minBatchOpenSecs elapsed.
    ///         Only one batch may be in Venice's unstake queue at a time.
    function flush() external nonReentrant whenNotPaused {
        if (unstakingBatch != 0) revert PriorBatchUnstaking();

        uint32 batchId = currentBatch;
        UnstakeBatch storage b = unstakeBatches[batchId];
        if (b.diemTotal == 0) revert BatchNotOpen();
        if (b.userCount < MAX_BATCH_SIZE && block.timestamp < b.openedAt + minBatchOpenSecs) {
            revert BatchTooNew();
        }

        uint64 unlockAt = uint64(block.timestamp + IDIEM(asset()).cooldownDuration());
        b.unlockAt = unlockAt;
        unstakingBatch = batchId;
        currentBatch = batchId + 1;

        IDIEM(asset()).initiateUnstake(b.diemTotal);
        emit BatchFlushed(batchId, b.diemTotal, unlockAt);
    }

    // ─── Step 3: settle ──────────────────────────────────────────────────────
    /// @notice After the Venice cooldown, move DIEM to the vault and mark the
    ///         batch claimable. Permissionless — keeper, user, or anyone may call.
    ///         settle() is intentionally NOT pausable so existing commitments
    ///         can always complete regardless of vault pause state.
    function settle() external nonReentrant {
        uint32 batchId = unstakingBatch;
        if (batchId == 0) revert BatchNotFlushed();
        UnstakeBatch storage b = unstakeBatches[batchId];
        if (block.timestamp < b.unlockAt) revert BatchNotReady();
        if (b.settled) revert BatchAlreadySettled();

        b.settled = true;
        unstakingBatch = 0;

        IDIEM(asset()).unstake();
        emit BatchSettled(batchId, b.diemTotal);
    }

    // ─── Step 4: claim ───────────────────────────────────────────────────────
    /// @notice Pull DIEM for a settled request. Sends to the receiver recorded
    ///         at requestRedeem — anyone may trigger the claim on their behalf.
    ///         Not pausable: once a batch is settled, claims must always proceed.
    /// @param  requestId The id returned by requestRedeem.
    function claimRedeem(uint256 requestId) external nonReentrant {
        RedeemRequest storage req = redeemRequests[requestId];
        if (req.claimed) revert AlreadyClaimed();
        if (!unstakeBatches[req.batchId].settled) revert BatchNotSettled();

        req.claimed = true;
        pendingWithdrawalDiem -= req.diem;

        IERC20(asset()).safeTransfer(req.receiver, req.diem);
        emit Claimed(requestId, req.receiver, req.diem);
    }

    // ─── View helpers ────────────────────────────────────────────────────────
    function currentBatchInfo()
        external
        view
        returns (
            uint32 batchId,
            uint128 diemTotal,
            uint64 openedAt,
            uint32 userCount,
            uint64 flushableAt
        )
    {
        UnstakeBatch storage b = unstakeBatches[currentBatch];
        uint64 fa = b.openedAt == 0 ? 0 : b.openedAt + minBatchOpenSecs;
        return (currentBatch, b.diemTotal, b.openedAt, b.userCount, fa);
    }

    function requestStatus(uint256 requestId)
        external
        view
        returns (
            address receiver,
            uint256 diem,
            uint32 batchId,
            uint64 unlockAt,
            bool settled,
            bool claimed
        )
    {
        RedeemRequest storage req = redeemRequests[requestId];
        UnstakeBatch storage b = unstakeBatches[req.batchId];
        return (req.receiver, req.diem, req.batchId, b.unlockAt, b.settled, req.claimed);
    }

    /// @notice Returns all requestIds created with `receiver` as the recipient.
    ///         Required for frontends to display a user's pending withdrawals.
    ///         Analogous to Lido's `getWithdrawalRequests(owner)`.
    function getRedeemRequests(address owner) external view returns (uint256[] memory) {
        return _ownerRequests[owner];
    }

    // ─── Yield credit ────────────────────────────────────────────────────────

    /// @notice Route inference revenue to ALL wstDIEM holders.
    ///         Staking the DIEM grows totalAssets() → convertToAssets(1e18)
    ///         increases → every holder appreciates proportionally.
    ///         Called by venue adapters after converting inference USDC → DIEM.
    function creditDIEM(uint256 amount) external nonReentrant {
        if (!isVenueAdapter[msg.sender]) revert NotVenueAdapter();

        // Snapshot fee shares at current rate BEFORE the incoming DIEM changes totalAssets.
        // This mirrors creditWstDIEM's pre-transfer snapshot to avoid rate manipulation.
        uint256 feeShares;
        if (yieldFeeBps > 0 && treasury != address(0)) {
            uint256 feeAmount = amount.mulDiv(yieldFeeBps, 10_000, Math.Rounding.Floor);
            if (feeAmount > 0) feeShares = _convertToShares(feeAmount, Math.Rounding.Floor);
        }

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        if (feeShares > 0) _mint(treasury, feeShares);
        IDIEM(asset()).stake(amount);
        emit DIEMCredited(msg.sender, amount);
    }

    /// @notice Credit an inference source with wstDIEM for their share of revenue.
    ///         Pulls DIEM from the caller (a registered venue adapter), stakes it,
    ///         and mints wstDIEM to `recipient` at the current rate with no entry fee.
    ///
    ///         Use case: an inference source earns N DIEM from serving inference.
    ///         They call creditDIEM(N * holderBps / 10_000) to raise the rate for
    ///         all holders, then call creditWstDIEM(N * sourceBps / 10_000, self) so
    ///         their own cut compounds as a growing wstDIEM position rather than
    ///         sitting idle in their adapter.
    ///
    ///         No deposit fee is applied — this is earned revenue reinvested, not
    ///         external capital entering the vault.
    function creditWstDIEM(uint256 amount, address recipient) external nonReentrant {
        if (!isVenueAdapter[msg.sender]) revert NotVenueAdapter();
        require(recipient != address(0), "zero recipient");

        // Snapshot shares at the CURRENT rate before the transfer changes totalAssets.
        // If calculated after safeTransferFrom, the idle DIEM inflates totalAssets
        // relative to totalSupply and the source receives fewer shares than deserved.
        uint256 shares = _convertToShares(amount, Math.Rounding.Floor);

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        _mint(recipient, shares);

        // Stake the DIEM to back the new shares. totalAssets() stays consistent.
        IDIEM(asset()).stake(amount);

        emit WstDIEMCredited(msg.sender, recipient, amount, shares);
    }

    // ─── Admin ───────────────────────────────────────────────────────────────

    function setVenueAdapter(address adapter, bool enabled) external onlyOwner {
        isVenueAdapter[adapter] = enabled;
        emit VenueAdapterSet(adapter, enabled);
    }

    /// @notice Register or deregister an inference token source.
    ///         The source must also be a venue adapter (setVenueAdapter) before
    ///         it can call creditDIEM or creditWstDIEM.
    function addInferenceToken(address token, bool enabled) external onlyOwner {
        if (enabled && !isInferenceToken[token]) {
            require(_inferenceTokens.length < MAX_INFERENCE_TOKENS, "max sources reached");
            _inferenceTokens.push(token);
        }
        isInferenceToken[token] = enabled;
        emit InferenceTokenSet(token, enabled);
    }

    /// @notice Enumerate registered inference token sources.
    function inferenceTokenList() external view returns (address[] memory) {
        return _inferenceTokens;
    }

    function setVeniceSigner(address signer) external onlyOwner {
        veniceSigner = signer;
        emit VeniceSignerSet(signer);
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    function setDepositFeeBps(uint256 bps) external onlyOwner {
        require(bps <= MAX_DEPOSIT_FEE_BPS, "exceeds 10% cap");
        depositFeeBps = bps;
        emit DepositFeeBpsSet(bps);
    }

    function setYieldFeeBps(uint256 bps) external onlyOwner {
        require(bps <= MAX_YIELD_FEE_BPS, "exceeds 20% cap");
        yieldFeeBps = bps;
        emit YieldFeeBpsSet(bps);
    }

    function setMaxTotalStake(uint256 cap) external onlyOwner {
        maxTotalStake = cap;
    }

    function setMinBatchOpenSecs(uint64 secs) external onlyOwner {
        require(secs <= MAX_BATCH_OPEN_SECS, "exceeds 7-day max");
        minBatchOpenSecs = secs;
    }

    function setMinRedeemShares(uint256 minShares) external onlyOwner {
        minRedeemShares = minShares;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
