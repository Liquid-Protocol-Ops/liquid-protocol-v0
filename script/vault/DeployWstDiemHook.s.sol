// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {WstDIEMHook} from "../../src/vault/WstDIEMHook.sol";
import {IInferenceVault} from "../../src/vault/interfaces/IInferenceVault.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Script, console} from "forge-std/Script.sol";

contract DeployWstDiemHook is Script {
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant VAULT = 0xb9f23c33FfD2213f31C0cFb6c9e2fDf525a9Dd2D; // v5
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG); // 0x1080
        bytes memory args = abi.encode(IPoolManager(POOL_MANAGER), IInferenceVault(VAULT));
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(WstDIEMHook).creationCode, args);
        console.log("Mined hook address:", expected);
        console.logBytes32(salt);

        vm.startBroadcast(vm.envUint("DEPLOYER_PK"));
        WstDIEMHook hook =
            new WstDIEMHook{salt: salt}(IPoolManager(POOL_MANAGER), IInferenceVault(VAULT));
        vm.stopBroadcast();

        require(address(hook) == expected, "hook address mismatch");
        console.log("WstDIEMHook deployed:", address(hook));
        console.log(
            "Export WSTDIEM_HOOK and use in InitV4Pool + ConfigureRouterV4 + SafeManageV4LP."
        );
    }
}
