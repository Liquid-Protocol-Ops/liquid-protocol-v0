// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LiquidHookV2} from "./LiquidHookV2.sol";
import {ILiquidHookStaticFee} from "./interfaces/ILiquidHookStaticFee.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract LiquidHookStaticFeeV2 is LiquidHookV2, ILiquidHookStaticFee {
    mapping(PoolId => uint24) public liquidFee;
    mapping(PoolId => uint24) public pairedFee;

    constructor(
        address _poolManager,
        address _factory,
        address _poolExtensionAllowlist,
        address _weth
    ) LiquidHookV2(_poolManager, _factory, _poolExtensionAllowlist, _weth) {}

    function _initializeFeeData(PoolKey memory poolKey, bytes memory feeData) internal override {
        PoolStaticConfigVars memory _poolConfigVars = abi.decode(feeData, (PoolStaticConfigVars));

        if (_poolConfigVars.liquidFee > MAX_LP_FEE) {
            revert LiquidFeeTooHigh();
        }

        if (_poolConfigVars.pairedFee > MAX_LP_FEE) {
            revert PairedFeeTooHigh();
        }

        liquidFee[poolKey.toId()] = _poolConfigVars.liquidFee;
        pairedFee[poolKey.toId()] = _poolConfigVars.pairedFee;

        emit PoolInitialized(poolKey.toId(), _poolConfigVars.liquidFee, _poolConfigVars.pairedFee);
    }

    // set the LP fee according to the liquid/paired fee configuration
    function _setFee(PoolKey calldata poolKey, IPoolManager.SwapParams calldata swapParams)
        internal
        override
    {
        uint24 fee = swapParams.zeroForOne != liquidIsToken0[poolKey.toId()]
            ? pairedFee[poolKey.toId()]
            : liquidFee[poolKey.toId()];

        _setProtocolFee(fee);
        IPoolManager(poolManager).updateDynamicLPFee(poolKey, fee);
    }
}
