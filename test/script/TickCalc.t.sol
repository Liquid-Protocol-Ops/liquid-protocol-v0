// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TickCalc} from "../../script/lib/TickCalc.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Test} from "forge-std/Test.sol";

contract TickCalcTest is Test {
    // Reference vector: SPY=$650.00 (650e8), supply 1e11 tokens, spacing 60.
    // python3: floor(ln(mc/(1e11*650))/ln(1.0001)) snapped down to 60.
    uint256 constant SPY_E8 = 650e8;

    function test_referenceVector_spy650() public pure {
        int24[7] memory expected =
            [int24(-216_840), -172_980, -166_080, -152_220, -124_500, -97_020, -69_000];
        uint256[7] memory mcE8 = [
            uint256(25_000e8),
            2_000_000e8,
            4_000_000e8,
            16_000_000e8,
            256_000_000e8,
            4_000_000_000e8,
            65_536_000_000e8
        ];
        for (uint256 i = 0; i < 7; i++) {
            int24 got = TickCalc.tickForMc(mcE8[i], SPY_E8, 60);
            // integer sqrt may land one snap lower than the float reference
            assertLe(got, expected[i], "tick above float reference");
            assertGe(got, expected[i] - 60, "tick more than one snap below reference");
        }
    }

    function test_snapDown_negativeAndPositive() public pure {
        assertEq(TickCalc.snapDown(-172_976, 60), -172_980);
        assertEq(TickCalc.snapDown(-172_980, 60), -172_980);
        assertEq(TickCalc.snapDown(121, 60), 60);
        assertEq(TickCalc.snapDown(0, 60), 0);
    }

    function test_maxUsableTick() public pure {
        assertEq(TickCalc.maxUsableTick(60), 887_220);
    }

    function test_monotone_inMc() public pure {
        // strictly non-decreasing ticks for increasing MC
        int24 prev = TickCalc.tickForMc(25_000e8, SPY_E8, 60);
        uint256[6] memory mcs = [
            uint256(2_000_000e8),
            4_000_000e8,
            16_000_000e8,
            256_000_000e8,
            4_000_000_000e8,
            65_536_000_000e8
        ];
        for (uint256 i = 0; i < 6; i++) {
            int24 t = TickCalc.tickForMc(mcs[i], SPY_E8, 60);
            assertGt(t, prev);
            prev = t;
        }
    }

    function test_roundtrip_priceBracketsTick() public pure {
        // invariant: sqrtPrice(tick) <= sqrt(ratio) < sqrtPrice(tick + spacing)
        uint256 mcE8 = 2_000_000e8;
        int24 t = TickCalc.tickForMc(mcE8, SPY_E8, 60);
        uint256 ratioX192 = FullMath.mulDiv(mcE8, 1 << 192, 100_000_000_000 * SPY_E8);
        uint160 lower = TickMath.getSqrtPriceAtTick(t);
        uint160 upper = TickMath.getSqrtPriceAtTick(t + 60);
        assertLe(uint256(lower) * uint256(lower), ratioX192);
        assertGt(uint256(upper) * uint256(upper), ratioX192);
    }
}
