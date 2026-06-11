// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IInferenceVault {
    function convertToAssets(uint256 shares) external view returns (uint256);
}

// Morpho oracle: wstDIEM collateral / USDC loan.
//
// Assumes DIEM = $1 USDC (Venice's inference credit floor: $1/DIEM/day).
// This is the intrinsic value floor — arbitrageurs buy DIEM below $1 to capture credits.
// Use a conservative LLTV (62.5%) to absorb any DIEM/USD deviation.
//
// Price formula (Morpho ORACLE_PRICE_SCALE = 1e36):
//   borrowable_USDC_units = collateral_wstDIEM_units * price() / 1e36
//
// Derivation:
//   1 wstDIEM = convertToAssets(1e18) DIEM base units
//   1 DIEM base unit ~= 1e-18 DIEM ~= 1e-18 USD = 1e-12 USDC base units (1 USD = 1e6 USDC)
//   1 wstDIEM base unit in USDC base units = convertToAssets(1e18) / 1e18 * (1e6 / 1) * (1 / 1e18)
//   Morpho price = (1 wstDIEM unit in USDC units) * 1e36 = convertToAssets(1e18) * 1e6
//
// Verification (fresh vault, rate = 1.0):
//   price() = 1e18 * 1e6 = 1e24
//   1 wstDIEM (1e18 units) -> 1e18 * 1e24 / 1e36 = 1e6 USDC units = 1 USDC ✓
/// @custom:deprecated DIEM has no USD-liquid market; DIEM != $1 (it trades ~$1,450 as a
/// Venice inference perpetuity). This oracle prices wstDIEM collateral with a hardcoded
/// DIEM = $1, so it mis-prices the collateral and its Morpho market is unseeded. DO NOT
/// supply or borrow. Canonical lending venue: wstDIEM/VVV (WstDiemVvvOracle, MOG-544).
/// See MOG-542 / MOG-549.
contract WstDiemUsdcOracle {
    IInferenceVault public immutable vault;

    constructor(address _vault) {
        vault = IInferenceVault(_vault);
    }

    function price() external view returns (uint256) {
        // convertToAssets(1e18) = wstDIEM->DIEM exchange rate (18 dec)
        // * 1e6: scale from DIEM (18 dec) to USDC (6 dec)
        return vault.convertToAssets(1e18) * 1e6;
    }
}
