// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {LiquidLpLockerFeeConversion} from "../src/lp-lockers/LiquidLpLockerFeeConversion.sol";

/// @notice Phase 3b: Deploy LpLockerFeeConversion (compiled with reduced optimizer runs
///         to fit within EIP-170 contract size limit)
contract DeployLpLocker is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address liquidFactory = vm.envAddress("LIQUID_FACTORY");
        address feeLocker = vm.envAddress("LIQUID_FEE_LOCKER");
        address poolManager = vm.envAddress("UNISWAP_V4_POOL_MANAGER");
        address positionManager = vm.envAddress("UNISWAP_V4_POSITION_MANAGER");
        address universalRouter = vm.envAddress("UNISWAP_UNIVERSAL_ROUTER");
        address permit2 = vm.envAddress("PERMIT2");

        vm.startBroadcast(deployerKey);

        LiquidLpLockerFeeConversion lpLocker = new LiquidLpLockerFeeConversion(
            deployer, liquidFactory, feeLocker, positionManager, permit2, universalRouter, poolManager
        );
        console.log("LiquidLpLockerFeeConversion:", address(lpLocker));

        vm.stopBroadcast();
    }
}
