// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Liquid} from "../src/Liquid.sol";
import {ILiquidHookDynamicFee} from "../src/hooks/interfaces/ILiquidHookDynamicFee.sol";
import {ILiquidHookV2} from "../src/hooks/interfaces/ILiquidHookV2.sol";
import {ILiquid} from "../src/interfaces/ILiquid.sol";
import {
    ILiquidLpLockerFeeConversion
} from "../src/lp-lockers/interfaces/ILiquidLpLockerFeeConversion.sol";
import {ILiquidMevDescendingFees} from "../src/mev-modules/interfaces/ILiquidMevDescendingFees.sol";
import {Script, console} from "forge-std/Script.sol";

/// @notice Validation launch: a token paired against WETH through the Liquid factory,
///         using the FIXED LP locker (6-field swap struct) with Paired fee preference.
///         Mirrors the working SPYING geometry (token=currency0, single-sided above start).
/// Env: DEPLOYER_PRIVATE_KEY, LIQUID_FACTORY, LIQUID_HOOK_DYNAMIC_FEE_V2,
///      LIQUID_MEV_DESCENDING_FEES, LP_LOCKER (the FIXED locker), PAIRED_TOKEN (WETH),
///      TOKEN_NAME, TOKEN_SYMBOL, TOKEN_SALT (mined so token < PAIRED_TOKEN)
contract LaunchEthPair is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address factory = vm.envAddress("LIQUID_FACTORY");
        address hook = vm.envAddress("LIQUID_HOOK_DYNAMIC_FEE_V2");
        address locker = vm.envAddress("LP_LOCKER");
        address mevModule = vm.envAddress("LIQUID_MEV_DESCENDING_FEES");
        address paired = vm.envAddress("PAIRED_TOKEN");

        address[] memory rewardAdmins = new address[](1);
        rewardAdmins[0] = deployer;
        address[] memory rewardRecipients = new address[](1);
        rewardRecipients[0] = deployer;
        uint16[] memory rewardBps = new uint16[](1);
        rewardBps[0] = 10_000;
        int24[] memory tickLower = new int24[](1);
        tickLower[0] = -198_720;
        int24[] memory tickUpper = new int24[](1);
        tickUpper[0] = 887_220;
        uint16[] memory positionBps = new uint16[](1);
        positionBps[0] = 10_000;

        // Paired => convert all token-side fees to the paired token (WETH). This is the
        // exact path that reverted on the old locker; the new locker fixes the encoding.
        ILiquidLpLockerFeeConversion.FeeIn[] memory prefs =
            new ILiquidLpLockerFeeConversion.FeeIn[](1);
        prefs[0] = ILiquidLpLockerFeeConversion.FeeIn.Paired;
        bytes memory lockerData =
            abi.encode(ILiquidLpLockerFeeConversion.LpFeeConversionInfo({feePreference: prefs}));

        bytes memory feeVars = abi.encode(
            ILiquidHookDynamicFee.PoolDynamicConfigVars({
                baseFee: 10_000,
                maxLpFee: 50_000,
                referenceTickFilterPeriod: 3600,
                resetPeriod: 86_400,
                resetTickFilter: 500,
                feeControlNumerator: 0,
                decayFilterBps: 9000
            })
        );
        bytes memory poolData = abi.encode(
            ILiquidHookV2.PoolInitializationData({
                extension: address(0), extensionData: "", feeData: feeVars
            })
        );
        bytes memory mevData = abi.encode(
            ILiquidMevDescendingFees.FeeConfig({
                startingFee: 500_000, endingFee: 10_000, secondsToDecay: 120
            })
        );

        ILiquid.DeploymentConfig memory config = ILiquid.DeploymentConfig({
            tokenConfig: ILiquid.TokenConfig({
                tokenAdmin: deployer,
                name: vm.envString("TOKEN_NAME"),
                symbol: vm.envString("TOKEN_SYMBOL"),
                salt: bytes32(vm.envUint("TOKEN_SALT")),
                image: "",
                metadata: "",
                context: "",
                originatingChainId: 4663
            }),
            poolConfig: ILiquid.PoolConfig({
                hook: hook,
                pairedToken: paired,
                // ⚠ Reused from the SPYING/SPY config. SPY≈$600 vs WETH≈$3.5k, so this
                // tick gives a HIGH starting MC (~230 WETH ≈ $0.8M) when paired vs WETH —
                // the ELT validation launched high because of this. For a real WETH launch,
                // recompute: tick = ln(MC_target / (supply × ETH_usd)) / ln(1.0001), snap to 60.
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
                lockerData: lockerData
            }),
            mevModuleConfig: ILiquid.MevModuleConfig({
                mevModule: mevModule, mevModuleData: mevData
            }),
            extensionConfigs: new ILiquid.ExtensionConfig[](0)
        });

        vm.startBroadcast(pk);
        if (Liquid(factory).deprecated()) Liquid(factory).setDeprecated(false);
        address token = Liquid(factory).deployToken(config);
        vm.stopBroadcast();

        console.log("token:", token);
        console.log("  paired vs WETH:", paired);
        console.log("  locker:", locker);
    }
}
