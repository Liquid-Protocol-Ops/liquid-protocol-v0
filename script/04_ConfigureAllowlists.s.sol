// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Liquid} from "../src/Liquid.sol";

/// @notice Phase 4: Post-deploy — enable hooks, lockers, extensions, and MEV modules on the
///         Liquid factory allowlists. Run AFTER all contracts are deployed.
///
///         This script reads deployed addresses from env vars and calls the factory's
///         set functions. Adjust which modules to enable based on your needs.
contract ConfigureAllowlists is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        Liquid liquid = Liquid(vm.envAddress("LIQUID_FACTORY"));

        // Hooks
        address dynamicHook = vm.envAddress("LIQUID_HOOK_DYNAMIC_FEE_V2");
        address staticHook = vm.envAddress("LIQUID_HOOK_STATIC_FEE_V2");

        // LP Locker
        address lpLocker = vm.envAddress("LIQUID_LP_LOCKER_FEE_CONVERSION");

        // Extensions
        address airdrop = vm.envAddress("LIQUID_AIRDROP_V2");
        address vault = vm.envAddress("LIQUID_VAULT");
        address devBuyV4 = vm.envAddress("LIQUID_UNIV4_ETH_DEV_BUY");
        address devBuyV3 = vm.envAddress("LIQUID_UNIV3_ETH_DEV_BUY");
        address presale = vm.envAddress("LIQUID_PRESALE_ETH_TO_CREATOR");
        address presaleAllowlist = vm.envAddress("LIQUID_PRESALE_ALLOWLIST");

        // MEV Modules
        address sniperAuction = vm.envAddress("LIQUID_SNIPER_AUCTION_V2");
        address descendingFees = vm.envAddress("LIQUID_MEV_DESCENDING_FEES");

        vm.startBroadcast(deployerKey);

        // Enable hooks
        liquid.setHook(dynamicHook, true);
        console.log("Enabled hook:", dynamicHook);
        liquid.setHook(staticHook, true);
        console.log("Enabled hook:", staticHook);

        // Enable locker for each hook
        liquid.setLocker(lpLocker, dynamicHook, true);
        console.log("Enabled locker for dynamic hook:", lpLocker);
        liquid.setLocker(lpLocker, staticHook, true);
        console.log("Enabled locker for static hook:", lpLocker);

        // Enable extensions
        liquid.setExtension(airdrop, true);
        console.log("Enabled extension:", airdrop);
        liquid.setExtension(vault, true);
        console.log("Enabled extension:", vault);
        liquid.setExtension(devBuyV4, true);
        console.log("Enabled extension:", devBuyV4);
        liquid.setExtension(devBuyV3, true);
        console.log("Enabled extension:", devBuyV3);
        liquid.setExtension(presale, true);
        console.log("Enabled extension:", presale);
        liquid.setExtension(presaleAllowlist, true);
        console.log("Enabled extension:", presaleAllowlist);

        // Enable MEV modules
        liquid.setMevModule(sniperAuction, true);
        console.log("Enabled MEV module:", sniperAuction);
        liquid.setMevModule(descendingFees, true);
        console.log("Enabled MEV module:", descendingFees);

        vm.stopBroadcast();

        console.log("All allowlists configured.");
    }
}
