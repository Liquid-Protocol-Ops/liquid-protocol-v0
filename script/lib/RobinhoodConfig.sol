// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILiquidHookDynamicFee} from "../../src/hooks/interfaces/ILiquidHookDynamicFee.sol";
import {ILiquidHookV2} from "../../src/hooks/interfaces/ILiquidHookV2.sol";
import {ILiquid} from "../../src/interfaces/ILiquid.sol";
import {
    ILiquidLpLockerFeeConversion
} from "../../src/lp-lockers/interfaces/ILiquidLpLockerFeeConversion.sol";
import {
    ILiquidMevDescendingFees
} from "../../src/mev-modules/interfaces/ILiquidMevDescendingFees.sol";
import {TickCalc} from "./TickCalc.sol";

/// @notice Builds the spec §2/§3 breakout-ladder DeploymentConfig for a
///         SPY-paired Robinhood-template launch. Shared by the launch script
///         and the 4663 fork test so both exercise identical config.
library RobinhoodConfig {
    int24 internal constant TICK_SPACING = 60;

    struct Params {
        string name;
        string symbol;
        bytes32 salt; // pre-mined: token must sort below pairedToken
        address tokenAdmin; // creator
        address hook; // LiquidHookDynamicFeeV2
        address pairedToken; // SPY
        address locker; // v2 fee-conversion locker ONLY
        address mevModule; // LiquidMevDescendingFees
        address rewardRecipient; // the TopTraderRewardPool
        uint256 startMcUsdE8; // default 25_000e8
        uint256 spyUsdE8; // live SPY/USD × 1e8 at deploy
        uint256 chainId; // 4663
    }

    function ladderBps() internal pure returns (uint16[7] memory bps) {
        bps = [uint16(600), 2200, 2400, 2000, 1400, 900, 500];
    }

    /// MC boundaries above the start tick, USD × 1e8 (spec §2).
    function boundariesUsdE8() internal pure returns (uint256[6] memory b) {
        b = [
            uint256(2_000_000e8),
            4_000_000e8,
            16_000_000e8,
            256_000_000e8,
            4_000_000_000e8,
            65_536_000_000e8
        ];
    }

    function build(Params memory p)
        internal
        pure
        returns (ILiquid.DeploymentConfig memory config, int24 migrationTick)
    {
        uint16[7] memory bps = ladderBps();
        uint256[6] memory bounds = boundariesUsdE8();

        // 8 tick edges: start, 6 MC boundaries, max
        int24[] memory edges = new int24[](8);
        edges[0] = TickCalc.tickForMc(p.startMcUsdE8, p.spyUsdE8, TICK_SPACING);
        for (uint256 i = 0; i < 6; i++) {
            edges[i + 1] = TickCalc.tickForMc(bounds[i], p.spyUsdE8, TICK_SPACING);
        }
        edges[7] = TickCalc.maxUsableTick(TICK_SPACING);
        migrationTick = edges[1]; // $2M

        int24[] memory tickLower = new int24[](7);
        int24[] memory tickUpper = new int24[](7);
        uint16[] memory positionBps = new uint16[](7);
        for (uint256 i = 0; i < 7; i++) {
            tickLower[i] = edges[i];
            tickUpper[i] = edges[i + 1];
            positionBps[i] = bps[i];
            require(tickUpper[i] > tickLower[i], "degenerate rung"); // SPY-price sanity
        }

        address[] memory rewardAdmins = new address[](1);
        rewardAdmins[0] = p.tokenAdmin;
        address[] memory rewardRecipients = new address[](1);
        rewardRecipients[0] = p.rewardRecipient;
        uint16[] memory rewardBps = new uint16[](1);
        rewardBps[0] = 10_000;

        ILiquidLpLockerFeeConversion.FeeIn[] memory prefs =
            new ILiquidLpLockerFeeConversion.FeeIn[](1);
        prefs[0] = ILiquidLpLockerFeeConversion.FeeIn.Paired;
        bytes memory feeData =
            abi.encode(ILiquidLpLockerFeeConversion.LpFeeConversionInfo({feePreference: prefs}));

        // spec §3: 2% floor, 5% cap, volatility term ON
        bytes memory feeVars = abi.encode(
            ILiquidHookDynamicFee.PoolDynamicConfigVars({
                baseFee: 20_000,
                maxLpFee: 50_000,
                referenceTickFilterPeriod: 3600,
                resetPeriod: 86_400,
                resetTickFilter: 500,
                feeControlNumerator: 500_000_000,
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
                startingFee: 500_000, endingFee: 20_000, secondsToDecay: 120
            })
        );

        config = ILiquid.DeploymentConfig({
            tokenConfig: ILiquid.TokenConfig({
                tokenAdmin: p.tokenAdmin,
                name: p.name,
                symbol: p.symbol,
                salt: p.salt,
                image: "",
                metadata: "",
                context: "",
                originatingChainId: p.chainId
            }),
            poolConfig: ILiquid.PoolConfig({
                hook: p.hook,
                pairedToken: p.pairedToken,
                tickIfToken0IsLiquid: edges[0],
                tickSpacing: TICK_SPACING,
                poolData: poolData
            }),
            lockerConfig: ILiquid.LockerConfig({
                locker: p.locker,
                rewardAdmins: rewardAdmins,
                rewardRecipients: rewardRecipients,
                rewardBps: rewardBps,
                tickLower: tickLower,
                tickUpper: tickUpper,
                positionBps: positionBps,
                lockerData: feeData
            }),
            mevModuleConfig: ILiquid.MevModuleConfig({
                mevModule: p.mevModule, mevModuleData: mevData
            }),
            extensionConfigs: new ILiquid.ExtensionConfig[](0)
        });
    }
}
