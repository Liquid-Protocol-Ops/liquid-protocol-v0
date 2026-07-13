// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LiquidToken} from "../src/LiquidToken.sol";
import {Script, console} from "forge-std/Script.sol";

/// @notice Mine tokenConfig.salt so the CREATE2 token sorts BELOW the paired token
///         (=> launched token is currency0 => single-sided token liquidity above start tick,
///         mirroring the working SPYING/SPY geometry). Factory CREATE2 salt =
///         keccak256(abi.encode(admin, tokenConfig.salt)).
/// Env: TOKEN_NAME, TOKEN_SYMBOL, PAIRED_TOKEN, LIQUID_FACTORY, DEPLOYER_ADDRESS
contract MineEthPairSalt is Script {
    function run() external view {
        address factory = vm.envAddress("LIQUID_FACTORY");
        address admin = vm.envAddress("DEPLOYER_ADDRESS");
        address paired = vm.envAddress("PAIRED_TOKEN");
        string memory name = vm.envString("TOKEN_NAME");
        string memory symbol = vm.envString("TOKEN_SYMBOL");
        uint256 supply = 100_000_000_000e18;

        bytes32 initHash = keccak256(
            abi.encodePacked(
                type(LiquidToken).creationCode,
                abi.encode(name, symbol, supply, admin, "", "", "", uint256(4663))
            )
        );

        for (uint256 i = 1; i < 5_000_000; i++) {
            bytes32 derivedSalt = keccak256(abi.encode(admin, bytes32(i)));
            address predicted = vm.computeCreate2Address(derivedSalt, initHash, factory);
            if (predicted < paired) {
                console.log("TOKEN_SALT (uint):", i);
                console.log("predicted token:", predicted);
                console.log("paired token:   ", paired);
                console.log("sorts below paired:", predicted < paired);
                return;
            }
        }
        revert("no salt found in range");
    }
}
