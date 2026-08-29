// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LiquidToken} from "../src/LiquidToken.sol";
import {Script, console} from "forge-std/Script.sol";

/// @notice Mine a tokenConfig.salt so the CREATE2-deployed token sorts BELOW SPY
///         (=> the launched token is currency0 => displays as SPYING/SPY).
/// The factory CREATE2-deploys with salt = keccak256(abi.encode(admin, tokenConfig.salt)).
contract MineSpyingSalt is Script {
    function run() external view {
        address factory = 0x65c40274A1a2178A5140F80fcd6Fe7eFB954e6C2;
        address admin = 0x4e68600Ba1F1D6C65B05b9287237D51a61F9A47A;
        address spy = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
        uint256 supply = 100_000_000_000e18;

        bytes32 initHash = keccak256(
            abi.encodePacked(
                type(LiquidToken).creationCode,
                abi.encode("newchaintest", "SPYING", supply, admin, "", "", "", uint256(4663))
            )
        );

        for (uint256 i = 1; i < 2_000_000; i++) {
            bytes32 derivedSalt = keccak256(abi.encode(admin, bytes32(i)));
            address predicted = vm.computeCreate2Address(derivedSalt, initHash, factory);
            if (predicted < spy) {
                console.log("TOKEN_SALT (uint):", i);
                console.log("predicted token:", predicted);
                console.log("sorts below SPY:", predicted < spy);
                return;
            }
        }
        revert("no salt found in range");
    }
}
