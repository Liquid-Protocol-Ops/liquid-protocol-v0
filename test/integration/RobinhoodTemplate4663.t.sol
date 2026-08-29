// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RobinhoodConfig} from "../../script/lib/RobinhoodConfig.sol";
import {Liquid} from "../../src/Liquid.sol";
import {LiquidToken} from "../../src/LiquidToken.sol";
import {ILiquid} from "../../src/interfaces/ILiquid.sol";
import {TopTraderRewardPool} from "../../src/periphery/TopTraderRewardPool.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Test} from "forge-std/Test.sol";

interface IStateViewFork {
    function getSlot0(bytes32) external view returns (uint160, int24, uint24, uint24);
}

contract RobinhoodTemplate4663Test is Test {
    address constant FACTORY = 0x65c40274A1a2178A5140F80fcd6Fe7eFB954e6C2;
    address constant HOOK = 0xDee7DcDCf599306D3c29e8dd0E6F4C9c4b6F68Cc;
    address constant MEV = 0xd86416EEdb067213dF7336662b3fa3B3a1a5E205;
    address constant LOCKER_V2 = 0x4AB39080B54121136fEfFf86857641F40dA6b964;
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address constant TREASURY = 0xF0E1D993E7ec19a1E83e6288bBE531A2C5ce4131;

    address deployer = makeAddr("deployer");
    address keeper = makeAddr("keeper");
    uint256 constant SPY_USD_E8 = 650e8;

    function setUp() public {
        string memory rpc = vm.envOr("RH_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0);
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 4663, "not robinhood chain");
    }

    function _mineSalt(RobinhoodConfig.Params memory p) internal view returns (bytes32) {
        bytes32 initHash = keccak256(
            abi.encodePacked(
                type(LiquidToken).creationCode,
                abi.encode(
                    p.name,
                    p.symbol,
                    uint256(100_000_000_000e18),
                    p.tokenAdmin,
                    "",
                    "",
                    "",
                    uint256(4663)
                )
            )
        );
        for (uint256 i = 1; i < 5_000_000; i++) {
            bytes32 derived = keccak256(abi.encode(p.tokenAdmin, bytes32(i)));
            if (vm.computeCreate2Address(derived, initHash, FACTORY) < SPY) return bytes32(i);
        }
        revert("no salt");
    }

    function test_fork_endToEnd_ladderAndRewardPool() public {
        assertEq(IERC20Metadata(SPY).decimals(), 18, "SPY decimals drifted from assumption");

        RobinhoodConfig.Params memory p = RobinhoodConfig.Params({
            name: "robinhood template test",
            symbol: "RHTEST",
            salt: bytes32(0),
            tokenAdmin: deployer,
            hook: HOOK,
            pairedToken: SPY,
            locker: LOCKER_V2,
            mevModule: MEV,
            rewardRecipient: address(0),
            startMcUsdE8: 25_000e8,
            spyUsdE8: SPY_USD_E8,
            chainId: 4663
        });
        p.salt = _mineSalt(p);

        (, int24 migrationTick) = RobinhoodConfig.build(p);
        vm.startPrank(deployer);
        TopTraderRewardPool pool =
            new TopTraderRewardPool(SPY, deployer, TREASURY, keeper, migrationTick, STATE_VIEW);
        p.rewardRecipient = address(pool);
        (ILiquid.DeploymentConfig memory config,) = RobinhoodConfig.build(p);

        if (Liquid(FACTORY).deprecated()) {
            vm.stopPrank();
            vm.prank(Liquid(FACTORY).owner());
            Liquid(FACTORY).setDeprecated(false);
            vm.startPrank(deployer);
        }
        address token = Liquid(FACTORY).deployToken(config);
        assertTrue(token < SPY, "token must be currency0");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token),
            currency1: Currency.wrap(SPY),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });
        bytes32 poolId = keccak256(abi.encode(key));
        pool.setPool(poolId);
        vm.stopPrank();

        // pool live at the computed start tick
        (uint160 sqrtPrice, int24 tick,,) = IStateViewFork(STATE_VIEW).getSlot0(poolId);
        assertGt(sqrtPrice, 0, "pool not initialized at computed poolId - check PoolKey fee flag");
        assertEq(tick, config.poolConfig.tickIfToken0IsLiquid, "init tick mismatch");

        // migration latch: below threshold on the live fork
        vm.expectRevert(TopTraderRewardPool.BelowMigrationTick.selector);
        pool.migrate();

        // ladder geometry sanity: 7 rungs, ascending, bps sum 10_000
        uint256 bpsSum;
        for (uint256 i = 0; i < 7; i++) {
            assertLt(config.lockerConfig.tickLower[i], config.lockerConfig.tickUpper[i]);
            if (i > 0) {
                assertEq(config.lockerConfig.tickLower[i], config.lockerConfig.tickUpper[i - 1]);
            }
            bpsSum += config.lockerConfig.positionBps[i];
        }
        assertEq(bpsSum, 10_000);
        assertEq(config.lockerConfig.tickUpper[6], 887_220);

        // density declines monotonically above the wall (spec §2): bps/tickspan
        // rung 2 (index 1) is the wall; check indexes 1..6 strictly decreasing
        uint256 prevDensityE18 = type(uint256).max;
        for (uint256 i = 1; i < 7; i++) {
            uint256 span = uint256(
                int256(config.lockerConfig.tickUpper[i] - config.lockerConfig.tickLower[i])
            );
            uint256 d = uint256(config.lockerConfig.positionBps[i]) * 1e18 / span;
            assertLt(d, prevDensityE18, "density must decline above the wall");
            prevDensityE18 = d;
        }
    }
}
