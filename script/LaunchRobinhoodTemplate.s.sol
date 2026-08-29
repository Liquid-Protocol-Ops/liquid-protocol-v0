// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Liquid} from "../src/Liquid.sol";
import {ILiquid} from "../src/interfaces/ILiquid.sol";
import {TopTraderRewardPool} from "../src/periphery/TopTraderRewardPool.sol";
import {RobinhoodConfig} from "./lib/RobinhoodConfig.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Script, console} from "forge-std/Script.sol";

/// Launch a Robinhood-template token per the 2026-08-29 spec:
/// SPY-paired, dynamic fee 2→5%, 7-position breakout ladder, LP fees routed
/// to a TopTraderRewardPool ($2M-MC migration latch).
///
/// env (see spec §1 for addresses):
///   DEPLOYER_PRIVATE_KEY  broadcast key
///   TOKEN_NAME / TOKEN_SYMBOL
///   TOKEN_SALT            uint, pre-mined via MineRobinhoodSalt.s.sol
///   SPY_USD_E8            live SPY/USD × 1e8 (operator-confirmed)
///   START_MC_USD_E8       optional, default 25_000e8
///   KEEPER_ADDRESS        monthly rPNL award poster
///   LIQUID_FACTORY / LIQUID_HOOK_DYNAMIC_FEE_V2 / LIQUID_MEV_DESCENDING_FEES
///   LOCKER_V2             0x4AB39080B54121136fEfFf86857641F40dA6b964 (NEVER v1)
///   SPY_TOKEN             0x117cc2133c37B721F49dE2A7a74833232B3B4C0C
///   STATE_VIEW            0xF3334192D15450CDd385C8b70E03f9A6bd9E673B
///   TREASURY              0xF0E1D993E7ec19a1E83e6288bBE531A2C5ce4131 (RH Safe)
contract LaunchRobinhoodTemplate is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address spy = vm.envAddress("SPY_TOKEN");

        require(block.chainid == 4663, "wrong chain");
        require(IERC20Metadata(spy).decimals() == 18, "SPY decimals != 18 - TickCalc assumes 18");

        RobinhoodConfig.Params memory p = RobinhoodConfig.Params({
            name: vm.envString("TOKEN_NAME"),
            symbol: vm.envString("TOKEN_SYMBOL"),
            salt: bytes32(vm.envUint("TOKEN_SALT")),
            tokenAdmin: deployer,
            hook: vm.envAddress("LIQUID_HOOK_DYNAMIC_FEE_V2"),
            pairedToken: spy,
            locker: vm.envAddress("LOCKER_V2"),
            mevModule: vm.envAddress("LIQUID_MEV_DESCENDING_FEES"),
            rewardRecipient: address(0), // filled after pool deploy below
            startMcUsdE8: vm.envOr("START_MC_USD_E8", uint256(25_000e8)),
            spyUsdE8: vm.envUint("SPY_USD_E8"),
            chainId: block.chainid
        });

        vm.startBroadcast(pk);

        // 1. reward pool first — it must exist as rewardRecipient at deployToken
        (, int24 migrationTick) = RobinhoodConfig.build(p); // pre-compute for constructor
        TopTraderRewardPool rewardPool = new TopTraderRewardPool(
            spy,
            deployer, // creator
            vm.envAddress("TREASURY"),
            vm.envAddress("KEEPER_ADDRESS"),
            migrationTick,
            vm.envAddress("STATE_VIEW")
        );
        p.rewardRecipient = address(rewardPool);
        (ILiquid.DeploymentConfig memory config,) = RobinhoodConfig.build(p);

        // 2. deploy token + pool + ladder through the factory
        address factory = vm.envAddress("LIQUID_FACTORY");
        if (Liquid(factory).deprecated()) Liquid(factory).setDeprecated(false);
        address token = Liquid(factory).deployToken(config);
        require(token < spy, "salt not mined: token is currency1");

        // 3. bind the pool id (dynamic-fee pools use the DYNAMIC_FEE_FLAG fee)
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token),
            currency1: Currency.wrap(spy),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: RobinhoodConfig.TICK_SPACING,
            hooks: IHooks(config.poolConfig.hook)
        });
        rewardPool.setPool(keccak256(abi.encode(key)));

        vm.stopBroadcast();

        console.log("token:", token);
        console.log("rewardPool:", address(rewardPool));
        console.log("migrationTick:", migrationTick);
        console.log("startTick:", config.poolConfig.tickIfToken0IsLiquid);
    }
}
