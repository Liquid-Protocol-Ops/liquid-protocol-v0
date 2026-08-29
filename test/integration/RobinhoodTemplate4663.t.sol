// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RobinhoodConfig} from "../../script/lib/RobinhoodConfig.sol";
import {Liquid} from "../../src/Liquid.sol";
import {LiquidToken} from "../../src/LiquidToken.sol";
import {ILiquid} from "../../src/interfaces/ILiquid.sol";
import {ILiquidFeeLocker} from "../../src/interfaces/ILiquidFeeLocker.sol";
import {ILiquidLpLocker} from "../../src/interfaces/ILiquidLpLocker.sol";
import {TopTraderRewardPool} from "../../src/periphery/TopTraderRewardPool.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
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
    address constant FEE_LOCKER = 0xBd81F5d3a761929e3e93D5d3Ab6aB83960B7dE62;
    // singleton V4 balance sheet backing every pool on-chain (incl. the live
    // SPYING/SPY pool) — fallback SPY funding source if deal() can't find the
    // beacon proxy's balance slot.
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

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

        // --- H1: fee path + migration sweep, end to end on the real fork ---

        // wiring: the locker must actually be pointed at the reward pool.
        ILiquidLpLocker.TokenRewardInfo memory rewardInfo =
            ILiquidLpLocker(LOCKER_V2).tokenRewards(token);
        assertEq(rewardInfo.rewardRecipients[0], address(pool), "locker not wired to reward pool");

        // fund a trader with SPY: deal() first; SPY is a beacon proxy, so if
        // stdStorage can't find the balance slot fall back to pulling real
        // SPY out of the PoolManager (the singleton V4 balance sheet that
        // custodies every SPY-paired pool's reserves on-chain).
        address trader = makeAddr("trader");
        uint256 spyFund = 3500e18;
        _fundSpy(trader, spyFund);
        assertEq(IERC20Metadata(SPY).balanceOf(trader), spyFund, "trader SPY funding failed");

        PoolSwapTest swapRouter =
            new PoolSwapTest(IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951));
        vm.prank(trader);
        IERC20Metadata(SPY).approve(address(swapRouter), type(uint256).max);

        // the MEV module operates for MAX_MEV_MODULE_DELAY (2 min) after pool
        // init and _collectRewards silently no-ops (no revert, no event)
        // while it's active — warp past it BEFORE swapping, or fee collection
        // below passes vacuously.
        vm.warp(block.timestamp + 121);

        // small SPY->token swap (buying token with SPY, the same direction
        // that pushes price up through the ladder): generates the first
        // round of LP fees. The hook auto-collects them into the FeeLocker
        // escrow per swap (collectRewardsWithoutUnlock -> storeFees).
        _swapSpyForToken(swapRouter, key, trader, 10e18);

        // collectRewards(token) is a manual fallback (idempotent - no-ops if
        // the hook's auto-collect already ran); claim moves the FeeLocker
        // escrow into the pool's own balance. Assert it strictly increases.
        uint256 poolSpyBefore = IERC20Metadata(SPY).balanceOf(address(pool));
        ILiquidLpLocker(LOCKER_V2).collectRewards(token);
        ILiquidFeeLocker(FEE_LOCKER).claim(address(pool), SPY);
        uint256 poolSpyAfterFirstClaim = IERC20Metadata(SPY).balanceOf(address(pool));
        assertGt(
            poolSpyAfterFirstClaim,
            poolSpyBefore,
            "reward pool SPY balance did not increase across collect -> claim"
        );

        // awardMonth: 60/30/10 split of the pot, remainder to first.
        address w1 = makeAddr("winner1");
        address w2 = makeAddr("winner2");
        address w3 = makeAddr("winner3");
        uint256 pot = IERC20Metadata(SPY).balanceOf(address(pool));
        uint256 expectedThird = pot * 1000 / 10_000;
        uint256 expectedSecond = pot * 3000 / 10_000;
        uint256 expectedFirst = pot - expectedSecond - expectedThird;
        vm.prank(keeper);
        pool.awardMonth([w1, w2, w3]);
        assertEq(IERC20Metadata(SPY).balanceOf(w1), expectedFirst, "1st-place 60% mismatch");
        assertEq(IERC20Metadata(SPY).balanceOf(w2), expectedSecond, "2nd-place 30% mismatch");
        assertEq(IERC20Metadata(SPY).balanceOf(w3), expectedThird, "3rd-place 10% mismatch");
        assertEq(IERC20Metadata(SPY).balanceOf(address(pool)), 0, "pot not fully distributed");

        // migration sweep: push the spot tick above migrationTick with a
        // large SPY buy. Rung 1 ($25k -> $2M MC, 600 bps / 6% of supply) is
        // "tens of SPY" per the density calc above; sized generously here.
        _swapSpyForToken(swapRouter, key, trader, 3000e18);
        (, int24 tickAfterBigSwap,,) = IStateViewFork(STATE_VIEW).getSlot0(poolId);
        assertGe(tickAfterBigSwap, migrationTick, "swap did not push spot tick to migrationTick");

        // claim the fresh fees the migration-crossing swap generated so
        // migrate() has a real, non-zero pot to sweep.
        ILiquidLpLocker(LOCKER_V2).collectRewards(token);
        ILiquidFeeLocker(FEE_LOCKER).claim(address(pool), SPY);
        uint256 potBeforeMigrate = IERC20Metadata(SPY).balanceOf(address(pool));
        assertGt(potBeforeMigrate, 0, "no fresh pot to exercise the migration sweep");

        uint256 treasurySpyBefore = IERC20Metadata(SPY).balanceOf(TREASURY);
        vm.prank(makeAddr("rando")); // migrate() is permissionless
        pool.migrate();
        assertTrue(pool.migrated(), "migrate() did not flip the latch");
        assertEq(IERC20Metadata(SPY).balanceOf(address(pool)), 0, "pot not swept out of the pool");
        assertEq(
            IERC20Metadata(SPY).balanceOf(TREASURY),
            treasurySpyBefore + potBeforeMigrate,
            "pot not swept to treasury"
        );

        // post-migration: a fresh fee arrival, then sweep(SPY) forwards the
        // full balance to the creator.
        _swapSpyForToken(swapRouter, key, trader, 10e18);
        ILiquidLpLocker(LOCKER_V2).collectRewards(token);
        ILiquidFeeLocker(FEE_LOCKER).claim(address(pool), SPY);
        uint256 poolSpyPostMigration = IERC20Metadata(SPY).balanceOf(address(pool));
        assertGt(poolSpyPostMigration, 0, "no post-migration fees arrived to sweep");
        uint256 creatorSpyBefore = IERC20Metadata(SPY).balanceOf(deployer);
        pool.sweep(SPY);
        assertEq(
            IERC20Metadata(SPY).balanceOf(deployer),
            creatorSpyBefore + poolSpyPostMigration,
            "sweep(SPY) did not forward the full balance to the creator"
        );
    }

    /// Fund `to` with `amount` SPY. deal() first (works when stdStorage can
    /// find SPY's balance-mapping slot through the beacon proxy); otherwise
    /// fall back to pulling real SPY custodied by the PoolManager.
    function _fundSpy(address to, uint256 amount) internal {
        try this._dealSpyExternal(to, amount) {
            emit log_string("SPY funding: deal() found the balance slot");
        } catch {
            emit log_string("SPY funding: deal() failed (beacon proxy) - falling back to PoolManager transfer");
            vm.prank(POOL_MANAGER);
            IERC20Metadata(SPY).transfer(to, amount);
        }
    }

    /// External wrapper so _fundSpy can try/catch deal()'s stdStorage revert
    /// (Solidity try/catch only wraps external calls).
    function _dealSpyExternal(address to, uint256 amount) external {
        require(msg.sender == address(this), "internal only");
        deal(SPY, to, amount);
    }

    /// Exact-input SPY -> token swap (zeroForOne=false: currency1/SPY in,
    /// currency0/token out). This is the direction that both generates LP
    /// fees and pushes the spot tick up through the ladder.
    function _swapSpyForToken(
        PoolSwapTest router,
        PoolKey memory key_,
        address trader,
        uint256 spyIn
    ) internal {
        vm.prank(trader);
        router.swap(
            key_,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(spyIn),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
