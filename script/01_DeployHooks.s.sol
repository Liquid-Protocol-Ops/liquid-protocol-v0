// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LiquidHookDynamicFeeV2} from "../src/hooks/LiquidHookDynamicFeeV2.sol";
import {LiquidHookStaticFeeV2} from "../src/hooks/LiquidHookStaticFeeV2.sol";

/// @notice Phase 1: Deploy hook contracts via CREATE2 with address mining.
///         Uniswap V4 hooks require specific bits set in the contract address.
contract DeployHooks is Script {
    // CREATE2 Deployer Proxy (deterministic deployer available on all EVM chains)
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Required hook flags for LiquidHookV2:
    // beforeInitialize | beforeAddLiquidity | beforeSwap | afterSwap |
    // beforeSwapReturnDelta | afterSwapReturnDelta
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    uint160 constant FLAG_MASK = uint160((1 << 14) - 1);

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // From Phase 0
        address liquidFactory = vm.envAddress("LIQUID_FACTORY");
        address poolExtAllowlist = vm.envAddress("POOL_EXTENSION_ALLOWLIST");

        // External (Base mainnet constants)
        address poolManager = vm.envAddress("UNISWAP_V4_POOL_MANAGER");
        address weth = vm.envAddress("WETH");

        bytes memory constructorArgs = abi.encode(poolManager, liquidFactory, poolExtAllowlist, weth);

        // Mine salt for LiquidHookDynamicFeeV2
        bytes memory dynamicCreationCode =
            abi.encodePacked(type(LiquidHookDynamicFeeV2).creationCode, constructorArgs);
        bytes32 dynamicSalt = _mineSalt(dynamicCreationCode, HOOK_FLAGS);
        address dynamicAddr = _computeAddress(dynamicSalt, dynamicCreationCode);
        console.log("Mined LiquidHookDynamicFeeV2 address:", dynamicAddr);
        console.log("  salt:", vm.toString(dynamicSalt));

        // Mine salt for LiquidHookStaticFeeV2
        bytes memory staticCreationCode =
            abi.encodePacked(type(LiquidHookStaticFeeV2).creationCode, constructorArgs);
        bytes32 staticSalt = _mineSalt(staticCreationCode, HOOK_FLAGS);
        address staticAddr = _computeAddress(staticSalt, staticCreationCode);
        console.log("Mined LiquidHookStaticFeeV2 address:", staticAddr);
        console.log("  salt:", vm.toString(staticSalt));

        vm.startBroadcast(deployerKey);

        // Deploy via CREATE2 using the deterministic deployer
        LiquidHookDynamicFeeV2 dynamicHook;
        {
            (bool success,) =
                CREATE2_DEPLOYER.call(abi.encodePacked(dynamicSalt, dynamicCreationCode));
            require(success, "Dynamic hook CREATE2 deploy failed");
            dynamicHook = LiquidHookDynamicFeeV2(payable(dynamicAddr));
            require(address(dynamicHook).code.length > 0, "Dynamic hook not deployed");
        }
        console.log("LiquidHookDynamicFeeV2:", address(dynamicHook));

        LiquidHookStaticFeeV2 staticHook;
        {
            (bool success,) =
                CREATE2_DEPLOYER.call(abi.encodePacked(staticSalt, staticCreationCode));
            require(success, "Static hook CREATE2 deploy failed");
            staticHook = LiquidHookStaticFeeV2(payable(staticAddr));
            require(address(staticHook).code.length > 0, "Static hook not deployed");
        }
        console.log("LiquidHookStaticFeeV2:", address(staticHook));

        vm.stopBroadcast();
    }

    function _mineSalt(bytes memory creationCode, uint160 flags) internal view returns (bytes32) {
        flags = flags & FLAG_MASK;
        for (uint256 salt; salt < 500_000; salt++) {
            address addr = _computeAddress(bytes32(salt), creationCode);
            if (uint160(addr) & FLAG_MASK == flags && addr.code.length == 0) {
                return bytes32(salt);
            }
        }
        revert("Could not find valid hook salt");
    }

    function _computeAddress(bytes32 salt, bytes memory creationCode)
        internal
        pure
        returns (address)
    {
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xFF), CREATE2_DEPLOYER, salt, keccak256(creationCode))))
            )
        );
    }
}
