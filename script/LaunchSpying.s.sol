// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Liquid} from "../src/Liquid.sol";
import {ILiquid} from "../src/interfaces/ILiquid.sol";
import {ILiquidLpLockerFeeConversion} from "../src/lp-lockers/interfaces/ILiquidLpLockerFeeConversion.sol";
import {ILiquidHookDynamicFee} from "../src/hooks/interfaces/ILiquidHookDynamicFee.sol";
import {ILiquidHookV2} from "../src/hooks/interfaces/ILiquidHookV2.sol";
import {ILiquidMevDescendingFees} from "../src/mev-modules/interfaces/ILiquidMevDescendingFees.sol";

/// @notice Launch "newchaintest" (SPYING) through the deployed Liquid factory,
///         paired against tokenized SPY, dynamic-fee hook. Mirrors the SDK's
///         default deploy config. Fees accrue in SPY + the token.
///
/// Env:
///   DEPLOYER_PRIVATE_KEY
///   LIQUID_FACTORY, LIQUID_HOOK_DYNAMIC_FEE_V2, LIQUID_MEV_DESCENDING_FEES
///   SPYING_LOCKER    the LockerConfig.locker (must be allowlisted for the hook)
///   SPY_TOKEN        paired token (tokenized SPY)
contract LaunchSpying is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address factory = vm.envAddress("LIQUID_FACTORY");
        address hook = vm.envAddress("LIQUID_HOOK_DYNAMIC_FEE_V2");
        address locker = vm.envAddress("SPYING_LOCKER");
        address mevModule = vm.envAddress("LIQUID_MEV_DESCENDING_FEES");
        address spy = vm.envAddress("SPY_TOKEN");

        address[] memory rewardAdmins = new address[](1);
        rewardAdmins[0] = deployer;
        address[] memory rewardRecipients = new address[](1);
        rewardRecipients[0] = deployer;
        uint16[] memory rewardBps = new uint16[](1);
        rewardBps[0] = 10_000;
        // With the mined salt SPYING < SPY => it's currency0 (token0 is liquid).
        // Pool starts at tick -198720; single-sided liquid range is [start, MAX].
        int24[] memory tickLower = new int24[](1);
        tickLower[0] = -198_720;
        int24[] memory tickUpper = new int24[](1);
        tickUpper[0] = 887_220;
        uint16[] memory positionBps = new uint16[](1);
        positionBps[0] = 10_000;

        // Fee preference per reward recipient: Paired => all fees converted to the
        // paired token (SPY). "SPY fees only", never WETH.
        ILiquidLpLockerFeeConversion.FeeIn[] memory prefs = new ILiquidLpLockerFeeConversion.FeeIn[](1);
        prefs[0] = ILiquidLpLockerFeeConversion.FeeIn.Paired;
        bytes memory feeData =
            abi.encode(ILiquidLpLockerFeeConversion.LpFeeConversionInfo({feePreference: prefs}));

        // Dynamic-fee hook config (feeData). baseFee/maxLpFee/decayFilterBps are
        // validated at init; feeControlNumerator=0 => flat baseFee (no volatility term).
        bytes memory feeVars = abi.encode(
            ILiquidHookDynamicFee.PoolDynamicConfigVars({
                baseFee: 10_000, // 1%
                maxLpFee: 50_000, // 5%
                referenceTickFilterPeriod: 3600,
                resetPeriod: 86_400,
                resetTickFilter: 500,
                feeControlNumerator: 0,
                decayFilterBps: 9_000
            })
        );
        // poolData is the wrapper the hook decodes: {extension, extensionData, feeData}.
        bytes memory poolData = abi.encode(
            ILiquidHookV2.PoolInitializationData({extension: address(0), extensionData: "", feeData: feeVars})
        );

        // MEV descending-fee schedule: 50% -> 1% over 2 min (max), anti-sniper.
        bytes memory mevData = abi.encode(
            ILiquidMevDescendingFees.FeeConfig({startingFee: 500_000, endingFee: 10_000, secondsToDecay: 120})
        );

        ILiquid.DeploymentConfig memory config = ILiquid.DeploymentConfig({
            tokenConfig: ILiquid.TokenConfig({
                tokenAdmin: deployer,
                name: "newchaintest",
                symbol: "SPYING",
                salt: bytes32(vm.envUint("TOKEN_SALT")), // mined so token < SPY => currency0
                image: "",
                metadata: "",
                context: "",
                originatingChainId: 4663
            }),
            poolConfig: ILiquid.PoolConfig({
                hook: hook,
                pairedToken: spy,
                tickIfToken0IsLiquid: -198_720,
                tickSpacing: 60,
                poolData: poolData
            }),
            lockerConfig: ILiquid.LockerConfig({
                locker: locker,
                rewardAdmins: rewardAdmins,
                rewardRecipients: rewardRecipients,
                rewardBps: rewardBps,
                tickLower: tickLower,
                tickUpper: tickUpper,
                positionBps: positionBps,
                lockerData: feeData
            }),
            mevModuleConfig: ILiquid.MevModuleConfig({mevModule: mevModule, mevModuleData: mevData}),
            extensionConfigs: new ILiquid.ExtensionConfig[](0)
        });

        vm.startBroadcast(pk);
        // Factory ships deprecated (deployments disabled). Owner enables once.
        if (Liquid(factory).deprecated()) {
            Liquid(factory).setDeprecated(false);
            console.log("enabled token deployments (setDeprecated=false)");
        }
        address token = Liquid(factory).deployToken(config);
        vm.stopBroadcast();

        console.log("SPYING token:", token);
        console.log("  hook:", hook);
        console.log("  locker:", locker);
        console.log("  paired vs SPY:", spy);
    }
}
