// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILiquidHookV2} from "../hooks/interfaces/ILiquidHookV2.sol";
import {ILiquidMevModule} from "../interfaces/ILiquidMevModule.sol";
import {ILiquidMevDescendingFees} from "./interfaces/ILiquidMevDescendingFees.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/*
 .--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--.
/ .. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \
\ \/\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ \/ /
 \/ /`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'\/ /
 / /\  ````````````````````````````````````````````````````````````````````````````````````  / /\
/ /\ \ ```````````````````````````````````````````````````````````````````````````````````` / /\ \
\ \/ / ```````::::::::``:::````````````:::`````::::````:::`:::````:::`::::::::::`:::::::::` \ \/ /
 \/ /  `````:+:````:+:`:+:``````````:+:`:+:```:+:+:```:+:`:+:```:+:``:+:````````:+:````:+:`  \/ /
 / /\  ````+:+````````+:+`````````+:+```+:+``:+:+:+``+:+`+:+``+:+```+:+````````+:+````+:+``  / /\
/ /\ \ ```+#+````````+#+````````+#++:++#++:`+#+`+:+`+#+`+#++:++````+#++:++#```+#++:++#:```` / /\ \
\ \/ / ``+#+````````+#+````````+#+`````+#+`+#+``+#+#+#`+#+``+#+```+#+````````+#+````+#+```` \ \/ /
 \/ /  `#+#````#+#`#+#````````#+#`````#+#`#+#```#+#+#`#+#```#+#``#+#````````#+#````#+#`````  \/ /
 / /\  `########``##########`###`````###`###````####`###````###`##########`###````###``````  / /\
/ /\ \ ```````````````````````````````````````````````````````````````````````````````````` / /\ \
\ \/ / ```````````````````````````````````````````````````````````````````````````````````` \ \/ /
 \/ /  ````````````````````````````````````````````````````````````````````````````````````  \/ /
 / /\.--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--./ /\
/ /\ \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \/\ \
\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `' /
 `--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'
*/

contract LiquidMevDescendingFees is ILiquidMevDescendingFees {
    string public constant PROTOCOL = "Liquid Protocol";
    mapping(PoolId poolId => FeeConfig feeConfig) public feeConfig;
    mapping(PoolId poolId => uint256 poolStartTime) public poolStartTime;

    uint256 public delayGuard = 1;

    modifier onlyHook(PoolKey calldata poolKey) {
        if (msg.sender != address(poolKey.hooks)) {
            revert OnlyHook();
        }
        _;
    }

    // initialize the mev module, called once by the hook per pool
    function initialize(PoolKey calldata poolKey, bytes calldata poolFeeConfig)
        external
        onlyHook(poolKey)
    {
        // only initialize once
        if (poolStartTime[poolKey.toId()] != 0) {
            revert PoolAlreadyInitialized();
        }

        // set pool's start time
        poolStartTime[poolKey.toId()] = block.timestamp;

        // decode the fee config
        FeeConfig memory feeConfigData = abi.decode(poolFeeConfig, (FeeConfig));

        // validate the fee config
        if (feeConfigData.secondsToDecay == 0) {
            revert TimeDecayMustBeGreaterThanZero();
        }
        if (feeConfigData.startingFee == 0) {
            revert StartingFeeMustBeGreaterThanZero();
        }
        if (feeConfigData.startingFee < feeConfigData.endingFee) {
            revert StartingFeeMustBeGreaterThanEndingFee();
        }

        // ensure that the associated hook is a LiquidHookV2
        if (!ILiquidHookV2(address(poolKey.hooks))
                .supportsInterface(type(ILiquidHookV2).interfaceId)) {
            revert OnlyLiquidHookV2();
        }

        // ensure the starting fee is not greater than the max mev LP fee
        if (feeConfigData.startingFee > ILiquidHookV2(address(poolKey.hooks)).MAX_MEV_LP_FEE()) {
            revert StartingFeeGreaterThanMaxLpFee();
        }

        // ensure the max time length is not longer than the max auction length
        if (
            feeConfigData.secondsToDecay
                > ILiquidHookV2(address(poolKey.hooks)).MAX_MEV_MODULE_DELAY()
        ) {
            revert TimeDecayLongerThanMaxMevDelay();
        }

        // set the fee config
        feeConfig[poolKey.toId()] = FeeConfig({
            startingFee: feeConfigData.startingFee,
            endingFee: feeConfigData.endingFee,
            secondsToDecay: feeConfigData.secondsToDecay
        });

        emit FeeConfigSet(
            poolKey.toId(),
            feeConfigData.startingFee,
            feeConfigData.endingFee,
            feeConfigData.secondsToDecay
        );
    }

    function getFee(PoolId poolId) external view returns (uint24) {
        // if the pool is not initialized, return zero
        if (poolStartTime[poolId] == 0) {
            return 0;
        }

        // check if the decay period is over
        if (block.timestamp > poolStartTime[poolId] + feeConfig[poolId].secondsToDecay) {
            // decay period is over, return zero
            return 0;
        }

        // check if this is the same block as deployment, if so, return the starting fee
        if (block.timestamp == poolStartTime[poolId]) {
            return feeConfig[poolId].startingFee;
        }

        // return the fee for the swap
        return _calculateFee(poolId);
    }

    function _calculateFee(PoolId poolId) internal view returns (uint24) {
        // how much time has passed since pool creation
        uint256 timeDecay = feeConfig[poolId].secondsToDecay
            - (block.timestamp - (poolStartTime[poolId] + delayGuard));
        uint256 feeRange = feeConfig[poolId].startingFee - feeConfig[poolId].endingFee;

        // Parabolic decay: fee = endingFee + feeRange * (timeDecay / timeToDecay)²
        uint256 normalizedTime = (timeDecay * 1e18) / feeConfig[poolId].secondsToDecay; // Scale for precision
        uint256 squaredTime = (normalizedTime * normalizedTime) / 1e18;
        uint256 decayAmount = (feeRange * squaredTime) / 1e18;

        return uint24(feeConfig[poolId].endingFee + decayAmount);
    }

    // called by the hook before a swap, update the fee for the swap
    function beforeSwap(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata,
        bool,
        bytes calldata
    ) external onlyHook(poolKey) returns (bool disableMevModule) {
        // don't allow trading in the same second as deployment
        if (block.timestamp == poolStartTime[poolKey.toId()]) {
            revert SameSecondAsDeployment();
        }

        // check if tax period is over
        if (
            block.timestamp
                >= poolStartTime[poolKey.toId()] + feeConfig[poolKey.toId()].secondsToDecay
                    + delayGuard
        ) {
            // disable the mev module without setting the fee
            emit DecayPeriodOver(poolKey.toId());
            return true;
        }

        // calculate the fee for the swap
        uint24 swapFee = _calculateFee(poolKey.toId());

        // call back into the hook to update the fee for the swap
        ILiquidHookV2(msg.sender).mevModuleSetFee(poolKey, swapFee);

        // mev module is still active
        return false;
    }

    // implements the ILiquidMevModule interface
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ILiquidMevModule).interfaceId;
    }
}
