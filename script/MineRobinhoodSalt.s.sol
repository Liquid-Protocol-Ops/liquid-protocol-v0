// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LiquidToken} from "../src/LiquidToken.sol";
import {Script, console} from "forge-std/Script.sol";

/// @notice Mine a tokenConfig.salt so the CREATE2-deployed token sorts BELOW
///         pairedToken (=> the launched token is currency0 / "liquid" side).
/// The factory CREATE2-deploys with salt = keccak256(abi.encode(admin, tokenConfig.salt)).
///
/// env (matches LaunchRobinhoodTemplate.s.sol's names for a single runbook):
///   LIQUID_FACTORY     the Liquid factory (CREATE2 deployer)
///   DEPLOYER_ADDRESS   tokenAdmin — address, not the private key
///   SPY_TOKEN          paired token; mined salt makes the launched token sort below it
///   TOKEN_NAME / TOKEN_SYMBOL
contract MineRobinhoodSalt is Script {
    function run() external view {
        address factory = vm.envAddress("LIQUID_FACTORY");
        address admin = vm.envAddress("DEPLOYER_ADDRESS");
        address pairedToken = vm.envAddress("SPY_TOKEN");
        string memory name = vm.envString("TOKEN_NAME");
        string memory symbol = vm.envString("TOKEN_SYMBOL");
        uint256 supply = 100_000_000_000e18;

        bytes32 initHash = keccak256(
            abi.encodePacked(
                type(LiquidToken).creationCode,
                abi.encode(name, symbol, supply, admin, "", "", "", uint256(4663))
            )
        );

        for (uint256 i = 1; i < 2_000_000; i++) {
            bytes32 derivedSalt = keccak256(abi.encode(admin, bytes32(i)));
            address predicted = vm.computeCreate2Address(derivedSalt, initHash, factory);
            if (predicted < pairedToken) {
                console.log("TOKEN_SALT (uint):", i);
                console.log("predicted token:", predicted);
                console.log("sorts below pairedToken:", predicted < pairedToken);
                return;
            }
        }
        revert("no salt found in range");
    }
}
