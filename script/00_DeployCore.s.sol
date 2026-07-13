// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Liquid} from "../src/Liquid.sol";
import {LiquidFeeLocker} from "../src/LiquidFeeLocker.sol";
import {LiquidPoolExtensionAllowlist} from "../src/hooks/LiquidPoolExtensionAllowlist.sol";

/// @notice Phase 0: Deploy core infrastructure — Liquid factory, FeeLocker, PoolExtensionAllowlist
contract DeployCore is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // Deployer is initial owner — ownership transferred to Safe in Phase 5
        Liquid liquid = new Liquid(deployer);
        console.log("Liquid factory:", address(liquid));

        LiquidFeeLocker feeLocker = new LiquidFeeLocker(deployer);
        console.log("LiquidFeeLocker:", address(feeLocker));

        LiquidPoolExtensionAllowlist poolExtAllowlist = new LiquidPoolExtensionAllowlist(deployer);
        console.log("LiquidPoolExtensionAllowlist:", address(poolExtAllowlist));

        vm.stopBroadcast();
    }
}
