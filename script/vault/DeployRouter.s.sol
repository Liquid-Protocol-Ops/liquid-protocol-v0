// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Router} from "../../src/vault/Router.sol";

contract DeployRouter is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        vm.startBroadcast(pk);

        Router router = new Router(
            0xa6076Ac24f21A9c526d6d32774d66cBB804Cf649,  // InferenceVault v2 (stakes DIEM in Venice)
            0x4200000000000000000000000000000000000006,  // WETH
            0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf,  // VVV
            0x321b7ff75154472B18EDb199033fF4D116F340Ff   // vvvStaking (sVVV)
        );

        // Curve pool wiring moved to FeeRouter; Router no longer holds curvePool.
        router.transferOwnership(0x872c561f699B42977c093F0eD8b4C9a431280c6c);

        console.log("Router:", address(router));
        vm.stopBroadcast();
    }
}
