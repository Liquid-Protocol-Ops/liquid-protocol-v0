// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LiquidToken} from "../src/LiquidToken.sol";
import {Script, console} from "forge-std/Script.sol";

/// @notice Mine a tokenConfig.salt so the CREATE2-deployed token sorts BELOW
///         pairedToken (=> the launched token is currency0 / "liquid" side).
/// The factory CREATE2-deploys with salt = keccak256(abi.encode(admin, tokenConfig.salt)).
contract MineRobinhoodSalt is Script {
    function run() external view {
        address factory = vm.envAddress("factory");
        address admin = vm.envAddress("admin");
        address pairedToken = vm.envAddress("pairedToken");
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
