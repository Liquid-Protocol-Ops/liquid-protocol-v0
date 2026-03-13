// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {LiquidHookDynamicFeeV2} from "../src/hooks/LiquidHookDynamicFeeV2.sol";
import {LiquidHookStaticFeeV2} from "../src/hooks/LiquidHookStaticFeeV2.sol";

/// @notice Phase 1: Deploy hook contracts — require Liquid factory, PoolExtensionAllowlist, and
///         external Uniswap V4 PoolManager + WETH addresses from Phase 0
contract DeployHooks is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // From Phase 0
        address liquidFactory = vm.envAddress("LIQUID_FACTORY");
        address poolExtAllowlist = vm.envAddress("POOL_EXTENSION_ALLOWLIST");

        // External (Base mainnet constants)
        address poolManager = vm.envAddress("UNISWAP_V4_POOL_MANAGER");
        address weth = vm.envAddress("WETH");

        vm.startBroadcast(deployerKey);

        LiquidHookDynamicFeeV2 dynamicHook =
            new LiquidHookDynamicFeeV2(poolManager, liquidFactory, poolExtAllowlist, weth);
        console.log("LiquidHookDynamicFeeV2:", address(dynamicHook));

        LiquidHookStaticFeeV2 staticHook =
            new LiquidHookStaticFeeV2(poolManager, liquidFactory, poolExtAllowlist, weth);
        console.log("LiquidHookStaticFeeV2:", address(staticHook));

        vm.stopBroadcast();
    }
}
