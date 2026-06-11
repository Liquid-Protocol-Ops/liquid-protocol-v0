// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IInferenceVault {
    function convertToAssets(uint256 shares) external view returns (uint256);
}

interface IChainlinkAggregator {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
    function decimals() external view returns (uint8);
}

// Morpho oracle: wstDIEM collateral / WETH loan.
//
// Prices wstDIEM in WETH using:
//   1. Vault exchange rate: wstDIEM -> DIEM (via convertToAssets)
//   2. Chainlink ETH/USD feed: WETH price in USD (8 dec)
//   3. DIEM ~= $1 USD (Venice's inference credit floor — see WstDiemUsdcOracle for rationale)
//
// Price formula (Morpho ORACLE_PRICE_SCALE = 1e36):
//   borrowable_WETH_units = collateral_wstDIEM_units * price() / 1e36
//
// Derivation:
//   1 wstDIEM base unit ~= convertToAssets(1e18)/1e18 USD
//   1 WETH = ethUsdPrice / 1e8 USD  (Chainlink 8-dec)
//   1 wstDIEM base unit in WETH base units = convertToAssets(1e18) * 1e8 / (ethUsdPrice * 1e18)
//   Morpho price = (value in WETH units) * 1e36 = convertToAssets(1e18) * 1e26 / ethUsdPrice
//
// Verification (rate = 1.0, ETH = $2500 = 250_000_000_00):
//   price() = 1e18 * 1e26 / 2.5e11 = 1e44 / 2.5e11 ~= 4e32
//   1 wstDIEM (1e18 units) -> 1e18 * 4e32 / 1e36 = 4e14 WETH units = 0.0004 WETH ~= $1 @ $2500 ✓
//
// Chainlink ETH/USD on Base mainnet: 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb7
// Staleness threshold: 1 hour (Chainlink heartbeat is 20 min on Base)
/// @custom:deprecated DIEM has no USD-liquid market; DIEM != $1 (it trades ~$1,450 as a
/// Venice inference perpetuity). This oracle prices wstDIEM collateral via a hardcoded
/// DIEM = $1 term, so it mis-prices the collateral and its Morpho market is unseeded. DO
/// NOT supply or borrow. Canonical lending venue: wstDIEM/VVV (WstDiemVvvOracle, MOG-544).
/// See MOG-542 / MOG-549.
contract WstDiemWethOracle {
    IInferenceVault public immutable vault;
    IChainlinkAggregator public immutable ethUsdFeed;
    uint256 public immutable stalenessThreshold; // seconds

    error StalePrice();
    error InvalidPrice();

    constructor(address _vault, address _ethUsdFeed, uint256 _stalenessThreshold) {
        require(_vault != address(0) && _ethUsdFeed != address(0), "zero address");
        vault = IInferenceVault(_vault);
        ethUsdFeed = IChainlinkAggregator(_ethUsdFeed);
        stalenessThreshold = _stalenessThreshold;
    }

    function price() external view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = ethUsdFeed.latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        if (block.timestamp - updatedAt > stalenessThreshold) revert StalePrice();

        uint256 ethUsdPrice = uint256(answer); // 8 dec, e.g. 250000000000 for $2500
        // convertToAssets(1e18) * 1e26 / ethUsdPrice
        // Max intermediate: ~1e18 * 1e26 = 1e44 — fits in uint256 (max ~1.16e77)
        return vault.convertToAssets(1e18) * 1e26 / ethUsdPrice;
    }
}
