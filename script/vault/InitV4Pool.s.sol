// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Script, console} from "forge-std/Script.sol";

interface IVaultRate {
    function convertToAssets(uint256 shares) external view returns (uint256);
    function asset() external view returns (address); // DIEM
}

interface IAeroPool {
    function quote(address tokenIn, uint256 amountIn, uint256 granularity)
        external
        view
        returns (uint256);
}

interface IChainlink {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IWethOracle {
    function ethUsdFeed() external view returns (address); // canonical Base ETH/USD feed
}

interface IPMInit {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }
    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external returns (int24 tick);
}

contract InitV4Pool is Script {
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant WSTDIEM = 0xb9f23c33FfD2213f31C0cFb6c9e2fDf525a9Dd2D; // v5
    address constant AERO_DIEM_VVV = 0xbB345D35450BF9Ee76F3D2cE214E8e7AC5e1071d;
    // Reuse the (deprecated) WETH oracle purely as an on-chain source of the canonical
    // Chainlink ETH/USD feed address — its immutable is still correct.
    address constant WETH_ORACLE = 0x73FddCCBB524b04b43EdED9C4d20C061DE291F07;
    uint24 constant DYNAMIC_FEE = 0x800000;
    int24 constant TICK_SPACING = 60;
    int24 constant TOLERANCE_TICKS = 300; // ~3% price tolerance

    function run() external {
        address hook = vm.envAddress("WSTDIEM_HOOK");
        uint160 sqrtPriceX96 = uint160(vm.envUint("SQRT_PRICE_X96"));
        uint256 vvvUsdE8 = vm.envUint("VVV_USD_E8"); // single operator price input, 1e8-scaled

        // On-chain reads
        address diem = IVaultRate(WSTDIEM).asset();
        uint256 a = IVaultRate(WSTDIEM).convertToAssets(1e18); // DIEM/wstDIEM, 1e18
        uint256 q = IAeroPool(AERO_DIEM_VVV).quote(diem, 1e18, 2); // VVV/DIEM, 1e18
        (, int256 ans,,,) = IChainlink(IWethOracle(WETH_ORACLE).ethUsdFeed()).latestRoundData();
        require(ans > 0, "bad ETH/USD");
        uint256 e = uint256(ans); // USD/WETH, 1e8

        // expectedTick from independent on-chain path
        uint256 denom = a * q * vvvUsdE8; // 1e18·1e18·1e8 = 1e44 scale
        require(denom > 0, "zero denom");
        uint256 priceX192 = FullMath.mulDiv(e * 1e36, uint256(1) << 192, denom);
        uint160 expectedSqrt = uint160(Math.sqrt(priceX192));
        int24 expectedTick = TickMath.getTickAtSqrtPrice(expectedSqrt);
        int24 impliedTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        console.log("convertToAssets(1e18):", a);
        console.log("VVV/DIEM (1e18):", q);
        console.log("ETH/USD (1e8):", e);
        console.log("VVV/USD (1e8, operator):", vvvUsdE8);
        console.log("expected tick:");
        console.logInt(expectedTick);
        console.log("implied tick (supplied):");
        console.logInt(impliedTick);

        int24 diff =
            impliedTick > expectedTick ? impliedTick - expectedTick : expectedTick - impliedTick;
        require(diff <= TOLERANCE_TICKS, "supplied price deviates from on-chain anchor");

        (address c0, address c1) = WETH < WSTDIEM ? (WETH, WSTDIEM) : (WSTDIEM, WETH);
        IPMInit.PoolKey memory key = IPMInit.PoolKey({
            currency0: c0, currency1: c1, fee: DYNAMIC_FEE, tickSpacing: TICK_SPACING, hooks: hook
        });

        vm.startBroadcast(vm.envUint("DEPLOYER_PK"));
        int24 tick = IPMInit(POOL_MANAGER).initialize(key, sqrtPriceX96);
        vm.stopBroadcast();
        console.log("Pool initialized. Tick:");
        console.logInt(tick);
    }
}
