// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IFeeRouter {
    function receiveUSDC(uint256 amount) external;
}

// InferenceProduct — USDC settlement layer for Venice AI inference capacity.
//
// The vault (InferenceVault) holds a unified sDIEM position. $1 of DIEM staked =
// $1/day of Venice inference budget. The vault is the single Venice identity —
// no DIEM ever leaves it. A keeper maps on-chain purchase records to API access.
//
// Capacity is grown by routing VVV through FeeRouter.harvestVVV() → vault.creditDIEM()
// which stakes additional DIEM into the vault's existing sDIEM position.
//
// Buyers purchase time-bounded allocations from the pool. When a purchase expires
// the capacity is returned to the pool via releaseExpired(). The keeper stops
// serving expired allocations off-chain on the same event.
//
// Marketplace parameters (model list, per-token pricing, revenue split) are
// set by owner to mirror the provider config in Surplus AI / AntPool.
contract InferenceProduct is Ownable {
    using SafeERC20 for IERC20;

    // --- Types ---

    struct Purchase {
        address buyer;
        uint256 diemAmount; // DIEM capacity allocated (18 dec); $1/DIEM/day inference credit
        uint256 numDays; // duration of the allocation
        uint256 priceUSDC; // USDC paid (6 dec)
        uint256 expiresAt; // block.timestamp when capacity returns to pool
        bool released;
    }

    // Mirrors Surplus AI / AntPool provider config.
    // modelIds:            Venice model IDs offered (e.g. "llama-3.3-70b", "mistral-nemo")
    // pricePerMilInUSDC:   USDC per million input tokens (6 dec); 0 = use DIEM-day pricing
    // pricePerMilOutUSDC:  USDC per million output tokens (6 dec)
    // maxDailyTokens:      per-purchase daily token budget cap (keeper enforces off-chain)
    // platformFeeBps:      share going to Surplus/AntPool as platform fee (out of 10_000)
    struct MarketplaceConfig {
        string[] modelIds;
        uint256 pricePerMilInUSDC;
        uint256 pricePerMilOutUSDC;
        uint256 maxDailyTokens;
        uint256 platformFeeBps;
    }

    // --- State ---

    address public immutable usdc; // Base: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
    address public feeRouter;

    // Available inference pool: owner sets this to the DIEM amount the vault has
    // designated for inference sales (subset of totalAssets() that is for sale).
    // Grows as FeeRouter.harvestVVV() / external VVV donations credit the vault.
    uint256 public totalCapacityDIEM;
    uint256 public allocatedDIEM; // currently sold / in active allocations

    // Default price: USDC per DIEM per day (6 dec).
    // $0.80/DIEM/day = 80% of Venice's $1/DIEM/day cost, leaving margin.
    uint256 public pricePerDiemDayUSDC = 0.8e6;

    MarketplaceConfig private _config;

    // Per-model x402 pricing for the keeper's price schedule.
    // Keeper reads these on startup to set per-endpoint x402 prices.
    // Keys are Venice model IDs (e.g. "llama-3.3-70b", "mistral-nemo").
    mapping(string => uint256) public pricePerMilInByModel; // USDC per million input tokens (6 dec)
    mapping(string => uint256) public pricePerMilOutByModel; // USDC per million output tokens (6 dec)

    mapping(uint256 => Purchase) public purchases;
    uint256 public nextPurchaseId;

    uint256 public totalRevenueUSDC;

    // --- Events ---

    event CapacityUpdated(uint256 totalCapacityDIEM);
    event InferencePurchased(
        uint256 indexed purchaseId,
        address indexed buyer,
        uint256 diemAmount,
        uint256 numDays,
        uint256 priceUSDC,
        uint256 expiresAt
    );
    event AllocationReleased(uint256 indexed purchaseId);
    event MarketplaceConfigUpdated();
    event ModelPricingUpdated(string modelId, uint256 pricePerMilIn, uint256 pricePerMilOut);

    // --- Errors ---

    error InsufficientCapacity(uint256 requested, uint256 available);
    error NotExpired();
    error AlreadyReleased();
    error ZeroAmount();
    error ZeroDuration();
    error PriceExceeded(uint256 price, uint256 maxPrice);

    constructor(address _usdc, address _feeRouter, address initialOwner) Ownable(initialOwner) {
        usdc = _usdc;
        feeRouter = _feeRouter;
    }

    // --- Capacity management ---

    // Set the DIEM amount available for inference sales.
    // Call after FeeRouter.harvestVVV() or any action that grows vault.totalAssets().
    // Can only be raised (or lowered to at least allocatedDIEM) — never below active allocs.
    function setCapacity(uint256 diemAmount) external onlyOwner {
        require(diemAmount >= allocatedDIEM, "below active allocations");
        totalCapacityDIEM = diemAmount;
        emit CapacityUpdated(diemAmount);
    }

    // --- Purchase ---

    // Buy an inference allocation: `diemAmount` DIEM capacity for `numDays` days.
    // `maxPriceUSDC`: caller's slippage ceiling — reverts if price moved above it (0 = no cap).
    // After purchase the keeper wires this purchaseId to API access for buyer.
    function buy(uint256 diemAmount, uint256 numDays, uint256 maxPriceUSDC)
        external
        returns (uint256 purchaseId)
    {
        if (diemAmount == 0) revert ZeroAmount();
        if (numDays == 0) revert ZeroDuration();
        uint256 available = totalCapacityDIEM - allocatedDIEM;
        if (diemAmount > available) revert InsufficientCapacity(diemAmount, available);

        uint256 price = _computePrice(diemAmount, numDays);
        if (maxPriceUSDC != 0 && price > maxPriceUSDC) revert PriceExceeded(price, maxPriceUSDC);
        uint256 expires = block.timestamp + numDays * 1 days;

        allocatedDIEM += diemAmount;
        totalRevenueUSDC += price;
        purchaseId = nextPurchaseId++;

        purchases[purchaseId] = Purchase({
            buyer: msg.sender,
            diemAmount: diemAmount,
            numDays: numDays,
            priceUSDC: price,
            expiresAt: expires,
            released: false
        });

        IERC20(usdc).safeTransferFrom(msg.sender, address(this), price);
        IERC20(usdc).approve(feeRouter, price);
        IFeeRouter(feeRouter).receiveUSDC(price);

        emit InferencePurchased(purchaseId, msg.sender, diemAmount, numDays, price, expires);
    }

    // Returns expired capacity to the pool. Anyone can call (incentivises keepers to clean up).
    function releaseExpired(uint256 purchaseId) external {
        Purchase storage p = purchases[purchaseId];
        if (p.released) revert AlreadyReleased();
        if (block.timestamp < p.expiresAt) revert NotExpired();
        p.released = true;
        allocatedDIEM -= p.diemAmount;
        emit AllocationReleased(purchaseId);
    }

    // Owner can force-release (e.g., buyer's API key revoked, allocation cancelled).
    function forceRelease(uint256 purchaseId) external onlyOwner {
        Purchase storage p = purchases[purchaseId];
        if (p.released) revert AlreadyReleased();
        p.released = true;
        allocatedDIEM -= p.diemAmount;
        emit AllocationReleased(purchaseId);
    }

    // --- Marketplace config (Surplus AI / AntPool) ---

    // Update model list and per-token pricing. Call whenever provider settings change.
    function setMarketplaceConfig(
        string[] calldata modelIds,
        uint256 pricePerMilInUSDC,
        uint256 pricePerMilOutUSDC,
        uint256 maxDailyTokens,
        uint256 platformFeeBps
    ) external onlyOwner {
        _config.modelIds = modelIds;
        _config.pricePerMilInUSDC = pricePerMilInUSDC;
        _config.pricePerMilOutUSDC = pricePerMilOutUSDC;
        _config.maxDailyTokens = maxDailyTokens;
        _config.platformFeeBps = platformFeeBps;
        emit MarketplaceConfigUpdated();
    }

    // Override the default DIEM-day price (6 dec USDC per DIEM per day).
    function setPricePerDiemDay(uint256 priceUSDC) external onlyOwner {
        pricePerDiemDayUSDC = priceUSDC;
    }

    function setFeeRouter(address _feeRouter) external onlyOwner {
        feeRouter = _feeRouter;
    }

    // Set per-model x402 token pricing. Keeper reads on startup to configure its price schedule.
    // Call whenever Venice updates model pricing or a new model is added to the catalog.
    // pricePerMilIn/Out: USDC per million tokens (6 dec), e.g. 0.20e6 = $0.20/M tokens.
    function setModelPricing(string calldata modelId, uint256 pricePerMilIn, uint256 pricePerMilOut)
        external
        onlyOwner
    {
        pricePerMilInByModel[modelId] = pricePerMilIn;
        pricePerMilOutByModel[modelId] = pricePerMilOut;
        emit ModelPricingUpdated(modelId, pricePerMilIn, pricePerMilOut);
    }

    // Batch version — set pricing for multiple models in one Safe tx.
    function setModelPricingBatch(
        string[] calldata modelIds,
        uint256[] calldata pricesIn,
        uint256[] calldata pricesOut
    ) external onlyOwner {
        require(
            modelIds.length == pricesIn.length && pricesIn.length == pricesOut.length,
            "length mismatch"
        );
        for (uint256 i; i < modelIds.length; ++i) {
            pricePerMilInByModel[modelIds[i]] = pricesIn[i];
            pricePerMilOutByModel[modelIds[i]] = pricesOut[i];
            emit ModelPricingUpdated(modelIds[i], pricesIn[i], pricesOut[i]);
        }
    }

    // --- Views ---

    function availableCapacityDIEM() external view returns (uint256) {
        return totalCapacityDIEM - allocatedDIEM;
    }

    // Quote USDC cost for `diemAmount` capacity over `numDays`. Pass as `maxPriceUSDC` to buy().
    function quotePrice(uint256 diemAmount, uint256 numDays) external view returns (uint256) {
        return _computePrice(diemAmount, numDays);
    }

    function getPurchase(uint256 purchaseId) external view returns (Purchase memory) {
        return purchases[purchaseId];
    }

    function getModelIds() external view returns (string[] memory) {
        return _config.modelIds;
    }

    function getMarketplaceConfig()
        external
        view
        returns (
            uint256 pricePerMilInUSDC,
            uint256 pricePerMilOutUSDC,
            uint256 maxDailyTokens,
            uint256 platformFeeBps
        )
    {
        return (
            _config.pricePerMilInUSDC,
            _config.pricePerMilOutUSDC,
            _config.maxDailyTokens,
            _config.platformFeeBps
        );
    }

    // --- Internal ---

    // Multiply before divide to avoid truncation on sub-1e18 diemAmount inputs.
    function _computePrice(uint256 diemAmount, uint256 numDays) internal view returns (uint256) {
        return (diemAmount * numDays * pricePerDiemDayUSDC) / 1e18;
    }
}
