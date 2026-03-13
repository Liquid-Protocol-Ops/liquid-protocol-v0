// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {LiquidSniperAuctionV2} from "../src/mev-modules/LiquidSniperAuctionV2.sol";
import {LiquidMevDescendingFees} from "../src/mev-modules/LiquidMevDescendingFees.sol";
import {LiquidSniperUtilV2} from "../src/mev-modules/sniper-utils/LiquidSniperUtilV2.sol";

/// @notice Phase 3a: Deploy MEV modules (without LpLocker which exceeds EIP-170)
contract DeployMev is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // From Phase 0
        address liquidFactory = vm.envAddress("LIQUID_FACTORY");
        address feeLocker = vm.envAddress("LIQUID_FEE_LOCKER");

        // External
        address universalRouter = vm.envAddress("UNISWAP_UNIVERSAL_ROUTER");
        address permit2 = vm.envAddress("PERMIT2");
        address weth = vm.envAddress("WETH");

        vm.startBroadcast(deployerKey);

        LiquidSniperAuctionV2 sniperAuction =
            new LiquidSniperAuctionV2(deployer, liquidFactory, feeLocker, weth);
        console.log("LiquidSniperAuctionV2:", address(sniperAuction));

        LiquidMevDescendingFees descendingFees = new LiquidMevDescendingFees();
        console.log("LiquidMevDescendingFees:", address(descendingFees));

        LiquidSniperUtilV2 sniperUtil =
            new LiquidSniperUtilV2(address(sniperAuction), universalRouter, permit2, weth);
        console.log("LiquidSniperUtilV2:", address(sniperUtil));

        vm.stopBroadcast();
    }
}
