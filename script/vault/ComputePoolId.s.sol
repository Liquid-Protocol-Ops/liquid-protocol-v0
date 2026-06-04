// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Script, console} from "forge-std/Script.sol";

contract ComputePoolId is Script {
    using PoolIdLibrary for PoolKey;

    function run() external view {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(0x4200000000000000000000000000000000000006),
            currency1: Currency.wrap(0x4751BA2b09374C1929FC01734a166e3c8cd75810), // wstDIEM v4
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        bytes32 poolId = PoolId.unwrap(key.toId());
        console.logBytes32(poolId);
    }
}
