// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILiquid} from "../../interfaces/ILiquid.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

interface ILiquidHookV2PoolExtension {
    error OnlyHook();

    // initialize the user extension, called once by the hook per pool during pool initialization flow
    function initializePreLockerSetup(
        PoolKey calldata poolKey,
        bool liquidIsToken0,
        bytes calldata poolExtensionInitData
    ) external;

    // initialize the user extension, called once by the hook per pool after the locker is setup,
    // during the mev module initialization flow
    function initializePostLockerSetup(
        PoolKey calldata poolKey,
        address locker,
        bool liquidIsToken0
    ) external;

    // after a swap, call the user extension to perform any post-swap actions
    function afterSwap(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bool liquidIsToken0,
        bytes calldata poolExtensionSwapData
    ) external;

    // implements the ILiquidHookV2PoolExtension interface
    function supportsInterface(bytes4 interfaceId) external pure returns (bool);
}
