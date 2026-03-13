// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {LiquidAirdropV2} from "../src/extensions/LiquidAirdropV2.sol";
import {LiquidVault} from "../src/extensions/LiquidVault.sol";
import {LiquidUniv4EthDevBuy} from "../src/extensions/LiquidUniv4EthDevBuy.sol";
import {LiquidUniv3EthDevBuy} from "../src/extensions/LiquidUniv3EthDevBuy.sol";
import {LiquidPresaleEthToCreator} from "../src/extensions/LiquidPresaleEthToCreator.sol";
import {LiquidPresaleAllowlist} from "../src/extensions/LiquidPresaleAllowlist.sol";

/// @notice Phase 2: Deploy all extension contracts — require Liquid factory from Phase 0
contract DeployExtensions is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address owner = vm.envAddress("OWNER_ADDRESS");

        // From Phase 0
        address liquidFactory = vm.envAddress("LIQUID_FACTORY");

        // External (Base mainnet constants)
        address weth = vm.envAddress("WETH");
        address universalRouter = vm.envAddress("UNISWAP_UNIVERSAL_ROUTER");
        address permit2 = vm.envAddress("PERMIT2");
        address swapRouterV3 = vm.envAddress("UNISWAP_V3_SWAP_ROUTER");

        // Protocol config
        address liquidFeeRecipient = vm.envAddress("LIQUID_PRESALE_FEE_RECIPIENT");

        vm.startBroadcast(deployerKey);

        LiquidAirdropV2 airdrop = new LiquidAirdropV2(liquidFactory);
        console.log("LiquidAirdropV2:", address(airdrop));

        LiquidVault vault = new LiquidVault(liquidFactory);
        console.log("LiquidVault:", address(vault));

        LiquidUniv4EthDevBuy devBuyV4 =
            new LiquidUniv4EthDevBuy(liquidFactory, weth, universalRouter, permit2);
        console.log("LiquidUniv4EthDevBuy:", address(devBuyV4));

        LiquidUniv3EthDevBuy devBuyV3 =
            new LiquidUniv3EthDevBuy(liquidFactory, weth, universalRouter, permit2, swapRouterV3);
        console.log("LiquidUniv3EthDevBuy:", address(devBuyV3));

        LiquidPresaleEthToCreator presale =
            new LiquidPresaleEthToCreator(owner, liquidFactory, liquidFeeRecipient);
        console.log("LiquidPresaleEthToCreator:", address(presale));

        LiquidPresaleAllowlist presaleAllowlist = new LiquidPresaleAllowlist(address(presale));
        console.log("LiquidPresaleAllowlist:", address(presaleAllowlist));

        vm.stopBroadcast();
    }
}
