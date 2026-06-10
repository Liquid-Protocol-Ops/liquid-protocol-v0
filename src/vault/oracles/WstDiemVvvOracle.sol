// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IInferenceVault {
    function convertToAssets(uint256 shares) external view returns (uint256);
    function asset() external view returns (address);
}

// Aerodrome v2 (Solidly-style) pool — built-in TWAP via stored observations.
interface IAerodromePool {
    /// @notice TWAP amountOut for `amountIn` of `tokenIn`, averaged over the last
    ///         `granularity` recorded observations (each ~periodSize = 30 min apart).
    function quote(address tokenIn, uint256 amountIn, uint256 granularity)
        external
        view
        returns (uint256 amountOut);
    function token0() external view returns (address);
    function token1() external view returns (address);

    // Solidly-style stored TWAP observation. lastObservation() returns the most recently
    // committed observation; its timestamp bounds how stale quote() can be.
    struct Observation {
        uint256 timestamp;
        uint256 reserve0Cumulative;
        uint256 reserve1Cumulative;
    }
    function lastObservation() external view returns (Observation memory);
}

// Morpho oracle: wstDIEM collateral / VVV loan.
//
// Lenders supply VVV; wstDIEM holders borrow VVV against their shares (and can loop:
// borrow VVV -> VVVStaking.mintDiem -> deposit -> more wstDIEM).
//
// FULLY ON-CHAIN — no USD price feed. Both legs are read from chain:
//   1. Vault exchange rate:  wstDIEM -> DIEM   via convertToAssets() (one-way ratchet)
//   2. DIEM -> VVV TWAP:      Aerodrome volatile VVV/DIEM pool, quote() averaged
//
// Rationale: DIEM has no USD-liquid market — its only deep DEX liquidity is DIEM/VVV on
// Aerodrome (~$9M, 2026-06; see MOG-542). Denominating the market in VVV keeps the oracle
// trustless and matches DIEM's actual trading pair. VVV is liquid (~$700M mcap, ~$90M/24h
// volume), so it is a sound numeraire and borrowed VVV is easy to offload.
//
// Price formula (Morpho ORACLE_PRICE_SCALE = 1e36):
//   borrowable_VVV_units = collateral_wstDIEM_units * price() / 1e36
//
// Derivation (wstDIEM, DIEM, VVV are all 18 decimals):
//   A = convertToAssets(1e18)   = DIEM base units per 1 wstDIEM         (e.g. 1.05e18)
//   Q = quote(DIEM, 1e18, n)    = VVV  base units per 1 DIEM, TWAP'd    (e.g. 89e18)
//   1 wstDIEM base unit in VVV base units = A * Q / 1e36
//   Morpho price = (value per wstDIEM unit) * 1e36 = A * Q
//   (mirrors WstDiemUsdcOracle's `A * 1e6`, with the hardcoded $1 replaced by a live TWAP;
//    the two 1e18-scaled ratios multiply to Morpho's 1e36 scale)
//
// Verification (rate = 1.0 -> A = 1e18; 1 DIEM = 89 VVV -> Q = 89e18):
//   price() = 1e18 * 89e18 = 8.9e37
//   1 wstDIEM (1e18 units) -> 1e18 * 8.9e37 / 1e36 = 89e18 VVV units = 89 VVV  ✓
//
// Safety:
//   - TWAP window ~= twapGranularity * ~30 min (Aerodrome periodSize). DIEM has NO external
//     market, so a manipulated spot is NOT arbitraged back during the window — the real threat
//     is MULTI-block manipulation (sustaining a dislocation across the averaged observations),
//     not single-block. Use a LARGE granularity (~24 ≈ 12 h) so holding a dislocation across
//     the whole window costs more than the per-market borrow cap (MOG-548 security review).
//   - maxObservationAge fails the price CLOSED (revert) when the newest committed observation is
//     older than the bound — caps TWAP staleness on a quiet pool and forces fresh data before a
//     borrow/liquidation can read the price.
//   - The DIEM/VVV pool must have >= twapGranularity recorded observations and live activity;
//     otherwise quote() can revert or under-average. Verify cardinality before market creation.
//   - This oracle is IMMUTABLE (no owner). A Morpho market's oracle is fixed at creation, so to
//     change the TWAP source/window, deploy a new oracle and create a new market (the migration
//     is the circuit breaker).
//   - Size LLTV and per-market borrow caps to the DIEM/VVV pool depth (MOG-542): at ~$9M depth,
//     keep exposure modest (~$100-300k order) until DIEM/VVV liquidity deepens.
contract WstDiemVvvOracle {
    IInferenceVault public immutable vault;
    IAerodromePool public immutable pool;
    address public immutable diem;
    address public immutable vvv;
    uint256 public immutable twapGranularity;
    /// @notice Max age (seconds) of the newest committed Aerodrome observation before price()
    ///         reverts StaleObservation. Bounds TWAP staleness on a low-activity pool. Immutable.
    uint256 public immutable maxObservationAge;

    error ZeroPrice();
    error TokenNotInPool();
    error StaleObservation();

    constructor(
        address _vault,
        address _pool,
        address _vvv,
        uint256 _twapGranularity,
        uint256 _maxObservationAge
    ) {
        require(_vault != address(0) && _pool != address(0) && _vvv != address(0), "zero address");
        require(_twapGranularity > 0, "granularity=0");
        require(_maxObservationAge > 0, "maxAge=0");
        vault = IInferenceVault(_vault);
        pool = IAerodromePool(_pool);
        diem = IInferenceVault(_vault).asset();
        vvv = _vvv;
        twapGranularity = _twapGranularity;
        maxObservationAge = _maxObservationAge;

        // Sanity: the pool must be the DIEM/VVV pair.
        address t0 = IAerodromePool(_pool).token0();
        address t1 = IAerodromePool(_pool).token1();
        bool ok = (t0 == diem && t1 == _vvv) || (t0 == _vvv && t1 == diem);
        if (!ok) revert TokenNotInPool();
    }

    /// @notice Price of 1 wstDIEM quoted in VVV, scaled by 1e36 (Morpho Blue convention).
    function price() external view returns (uint256) {
        // Staleness gate: fail closed if the newest committed observation is older than
        // maxObservationAge, so a quiet pool can't serve a long-stale TWAP (which would delay
        // liquidations / let positions go silently underwater). Addition form is underflow-safe.
        IAerodromePool.Observation memory last = pool.lastObservation();
        if (last.timestamp + maxObservationAge < block.timestamp) revert StaleObservation();

        // VVV base units for 1 DIEM, TWAP-averaged over the last `twapGranularity` observations.
        uint256 vvvPerDiem = pool.quote(diem, 1e18, twapGranularity);
        // DIEM base units per 1 wstDIEM. One-way ratchet; pendingWithdrawalDiem is already
        // netted out of totalAssets(), so convertToAssets cannot be inflated during cooldown.
        uint256 diemPerWst = vault.convertToAssets(1e18);
        if (vvvPerDiem == 0 || diemPerWst == 0) revert ZeroPrice();

        // price = A * Q (see derivation). Max intermediate ~1e19 * 1e22 = 1e41 << uint256 max.
        return diemPerWst * vvvPerDiem;
    }
}
