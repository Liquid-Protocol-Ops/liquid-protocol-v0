// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {LiquidLpLockerFeeConversion} from "../src/lp-lockers/LiquidLpLockerFeeConversion.sol";
import {LiquidSniperAuctionV2} from "../src/mev-modules/LiquidSniperAuctionV2.sol";
import {LiquidMevDescendingFees} from "../src/mev-modules/LiquidMevDescendingFees.sol";
import {LiquidSniperUtilV2} from "../src/mev-modules/sniper-utils/LiquidSniperUtilV2.sol";

/// @notice Phase 3: Deploy LP locker, MEV modules, and sniper utility
contract DeployLpLockerAndMev is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address owner = vm.envAddress("OWNER_ADDRESS");

        // From Phase 0
        address liquidFactory = vm.envAddress("LIQUID_FACTORY");
        address feeLocker = vm.envAddress("LIQUID_FEE_LOCKER");

        // External (Base mainnet constants)
        address poolManager = vm.envAddress("UNISWAP_V4_POOL_MANAGER");
        address positionManager = vm.envAddress("UNISWAP_V4_POSITION_MANAGER");
        address universalRouter = vm.envAddress("UNISWAP_UNIVERSAL_ROUTER");
        address permit2 = vm.envAddress("PERMIT2");
        address weth = vm.envAddress("WETH");

        vm.startBroadcast(deployerKey);

        // LP Locker
        LiquidLpLockerFeeConversion lpLocker = new LiquidLpLockerFeeConversion(
            owner, liquidFactory, feeLocker, positionManager, permit2, universalRouter, poolManager
        );
        console.log("LiquidLpLockerFeeConversion:", address(lpLocker));

        // MEV Modules
        LiquidSniperAuctionV2 sniperAuction =
            new LiquidSniperAuctionV2(owner, liquidFactory, feeLocker, weth);
        console.log("LiquidSniperAuctionV2:", address(sniperAuction));

        LiquidMevDescendingFees descendingFees = new LiquidMevDescendingFees();
        console.log("LiquidMevDescendingFees:", address(descendingFees));

        // Sniper Utility (depends on SniperAuctionV2 deployed above)
        LiquidSniperUtilV2 sniperUtil =
            new LiquidSniperUtilV2(address(sniperAuction), universalRouter, permit2, weth);
        console.log("LiquidSniperUtilV2:", address(sniperUtil));

        vm.stopBroadcast();
    }
}
