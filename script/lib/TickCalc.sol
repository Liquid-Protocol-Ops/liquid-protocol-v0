// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice USD market-cap target → pool tick, for SPY-paired Liquid launches.
/// Price convention: the launched token is currency0 (salt-mined to sort below
/// SPY), so pool price = SPY per TOKEN = MC_usd / (SUPPLY_TOKENS × SPY_usd).
/// Both tokens are 18-decimals, so the wei ratio equals the whole-token ratio.
library TickCalc {
    /// Factory-hardcoded supply (Liquid.sol TOKEN_SUPPLY), in whole tokens.
    uint256 internal constant SUPPLY_TOKENS = 100_000_000_000;

    /// @param mcUsdE8  market-cap target, USD × 1e8
    /// @param spyUsdE8 SPY/USD price, × 1e8
    /// @param spacing  pool tick spacing; result snaps toward -infinity
    function tickForMc(uint256 mcUsdE8, uint256 spyUsdE8, int24 spacing)
        internal
        pure
        returns (int24)
    {
        // price × 2^192; the 1e8 scale cancels between numerator and denominator
        uint256 ratioX192 = FullMath.mulDiv(mcUsdE8, 1 << 192, SUPPLY_TOKENS * spyUsdE8);
        uint160 sqrtPriceX96 = uint160(Math.sqrt(ratioX192));
        return snapDown(TickMath.getTickAtSqrtPrice(sqrtPriceX96), spacing);
    }

    function maxUsableTick(int24 spacing) internal pure returns (int24) {
        return (TickMath.MAX_TICK / spacing) * spacing;
    }

    function snapDown(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 snapped = (tick / spacing) * spacing;
        if (tick < 0 && tick % spacing != 0) snapped -= spacing;
        return snapped;
    }
}
