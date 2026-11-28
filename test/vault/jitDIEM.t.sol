// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LiquidFeeLocker} from "../../src/LiquidFeeLocker.sol";
import {InferenceVault} from "../../src/vault/InferenceVault.sol";
import {IInferenceVaultQueue} from "../../src/vault/interfaces/IInferenceVaultQueue.sol";
import {jitDIEM} from "../../src/vault/jitDIEM.sol";
import {IFeeLockerClaim, jitDIEMFeeConverter} from "../../src/vault/jitDIEMFeeConverter.sol";
import {MockDIEM} from "./mocks/MockDIEM.sol";

import {DeployJitDiem} from "../../script/vault/DeployJitDiem.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Test, Vm} from "forge-std/Test.sol";

/// Tests for jitDIEM on a Base fork (live v4 PoolManager) against a fresh InferenceVault built
/// from this repo's source (MockDIEM for Venice staking) and the real LiquidFeeLocker.
/// Requires BASE_RPC_URL. `jitDIEMLiveVaultTest` below runs against the live wstDIEM vault.
contract jitDIEMTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant BPS = 10_000;
    uint160 constant FLAGS = (1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3); // 0x28C8

    MockDIEM diem;
    InferenceVault wst;
    IPoolManager constant pm = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    PoolSwapTest router;
    PoolModifyLiquidityTest lpRouter;
    jitDIEM jit;
    PoolKey key;
    bool diemIs0;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address adapter = makeAddr("adapter");
    address lp = makeAddr("lp");
    address trader = makeAddr("trader");
    address buyer = makeAddr("buyer");
    address keeper = makeAddr("keeper");

    function _params() internal pure returns (jitDIEM.Params memory) {
        return jitDIEM.Params({
            minSellFeeBps: 100,
            maxSellFeeBps: 500,
            buyInventoryFeeBps: 5,
            targetIdleBps: 5000,
            floorIdleBps: 500,
            rebalanceBandBps: 1000,
            exitFeeBps: 10,
            maxNavDropBps: 100,
            maxNavGrowthBpsPerYear: 5000,
            rewardVestingPeriod: 3 days,
            maintainInterval: 1 hours,
            navGrowthWindow: 1 days,
            autoMaintain: true
        });
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        diem = new MockDIEM();
        wst = new InferenceVault(address(diem), treasury, makeAddr("signer"), address(this));
        wst.setVenueAdapter(adapter, true);

        // Seed wstDIEM and push NAV to ~1.0334 like mainnet.
        diem.mint(address(this), 1000e18);
        diem.approve(address(wst), type(uint256).max);
        wst.deposit(1000e18, address(this));
        _credit(34e18);

        router = new PoolSwapTest(pm);
        lpRouter = new PoolModifyLiquidityTest(pm);

        address hookAddr = address(uint160(0x4444 << 144) | FLAGS);
        deployCodeTo(
            "jitDIEM.sol:jitDIEM",
            abi.encode(pm, IInferenceVaultQueue(address(wst)), owner, _params()),
            hookAddr
        );
        jit = jitDIEM(hookAddr);

        diemIs0 = address(diem) < address(wst);
        (address c0, address c1) =
            diemIs0 ? (address(diem), address(wst)) : (address(wst), address(diem));
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 0, 1, IHooks(hookAddr));
        vm.prank(owner);
        pm.initialize(key, 2 ** 96);

        address[4] memory users = [lp, trader, buyer, owner];
        for (uint256 i; i < users.length; ++i) {
            diem.mint(users[i], 100_000e18);
            vm.startPrank(users[i]);
            diem.approve(address(jit), type(uint256).max);
            diem.approve(address(router), type(uint256).max);
            diem.approve(address(wst), type(uint256).max);
            wst.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(owner);
        jit.deposit(1e18, address(0xdead)); // dead shares
        vm.prank(lp);
        jit.deposit(1000e18, lp);
        vm.prank(trader);
        wst.deposit(5000e18, trader);
    }

    // ------------------------------------------------------------------ helpers

    function _credit(uint256 amount) internal {
        diem.mint(adapter, amount);
        vm.startPrank(adapter);
        diem.approve(address(wst), amount);
        wst.creditDIEM(amount);
        vm.stopPrank();
    }

    function _swap(address who, bool diemIn, bool exactIn, uint256 amount)
        internal
        returns (Vm.Log[] memory)
    {
        bool zeroForOne = diemIn == diemIs0;
        vm.recordLogs();
        vm.prank(who);
        router.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: exactIn ? -int256(amount) : int256(amount),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        return vm.getRecordedLogs();
    }

    function _sold(Vm.Log[] memory logs)
        internal
        pure
        returns (uint256 wstIn, uint256 diemOut, uint256 fee, uint256 nav)
    {
        bytes32 sig = keccak256("Sold(address,uint256,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                return abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            }
        }
        revert("no Sold");
    }

    function _expectSwapRevert(address who, bool diemIn, bool exactIn, uint256 amount, bytes4 err)
        internal
    {
        try this.swapExternal(who, diemIn, exactIn, amount) {
            revert("expected revert");
        } catch (bytes memory data) {
            assertTrue(_contains(data, abi.encodePacked(err)), "wrong revert");
        }
    }

    function swapExternal(address who, bool diemIn, bool exactIn, uint256 amount) external {
        _swap(who, diemIn, exactIn, amount);
    }

    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length > hay.length) return false;
        for (uint256 i; i <= hay.length - needle.length; ++i) {
            bool ok = true;
            for (uint256 j; j < needle.length; ++j) {
                if (hay[i + j] != needle[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    // via-IR can cache block.timestamp within a call, so warp to absolute times.
    function _flushSettle() internal {
        uint256 t = vm.getBlockTimestamp();
        vm.warp(t + 1 days + 1);
        wst.flush();
        vm.warp(t + 2 days + 2);
        wst.settle();
    }

    // ------------------------------------------------------------------ setup / pool guards

    function test_hookAddressAndSinglePool() public {
        assertEq(uint160(address(jit)) & 0x3FFF, FLAGS);
        assertTrue(jit.poolInitialized());
        PoolKey memory k2 = key;
        k2.tickSpacing = 10;
        vm.prank(owner);
        vm.expectRevert();
        pm.initialize(k2, 2 ** 96);
    }

    function test_directLiquidityBlocked() public {
        vm.expectRevert();
        lpRouter.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(-10, 10, 1e18, 0), "");
    }

    // ------------------------------------------------------------------ sells

    function test_sellExactIn_pricedAtNavMinusMinFee() public {
        uint256 before = diem.balanceOf(trader);
        (, uint256 out, uint256 fee, uint256 nav) = _sold(_swap(trader, false, true, 10e18));
        assertEq(diem.balanceOf(trader) - before, out);
        assertEq(fee, 100);
        assertEq(out, 10e18 * nav * (BPS - 100) / (WAD * BPS));
        assertLe(nav, wst.convertToAssets(WAD));
        assertEq(jit.trackedwstDIEM(), 10e18);
    }

    function test_sellFeeRisesThenFloorReverts() public {
        uint256 last;
        uint256 first;
        for (uint256 i; i < 14; ++i) {
            (,, uint256 fee,) = _sold(_swap(trader, false, true, 50e18));
            if (i == 0) first = fee;
            assertGe(fee, last);
            last = fee;
        }
        assertEq(first, 100);
        assertGt(last, 100);
        assertLe(last, 500);
        _expectSwapRevert(trader, false, true, 2000e18, jitDIEM.InsufficientLiquidity.selector);
    }

    function test_sellExactOut_neverUndercharges() public {
        uint256 before = wst.balanceOf(trader);
        (,,, uint256 nav) = _sold(_swap(trader, false, false, 20e18));
        uint256 spent = before - wst.balanceOf(trader);
        assertGe(spent * nav * (BPS - 100) / (WAD * BPS), 20e18);
    }

    // ------------------------------------------------------------------ buys

    function test_buyAboveTarget_stakesAtVaultPrice() public {
        uint256 preview = wst.previewDeposit(100e18);
        uint256 supply = wst.totalSupply();
        uint256 before = wst.balanceOf(buyer);
        _swap(buyer, true, true, 100e18);
        assertEq(wst.balanceOf(buyer) - before, preview);
        assertGt(wst.totalSupply(), supply);
        assertEq(jit.trackedwstDIEM(), 0);
    }

    function test_buyBelowTarget_recyclesInventory() public {
        _swap(trader, false, true, 700e18);
        uint256 idle = jit.trackedDIEM();
        uint256 inv = jit.trackedwstDIEM();
        uint256 spot = wst.convertToAssets(WAD);
        uint256 supply = wst.totalSupply();
        uint256 before = wst.balanceOf(buyer);
        _swap(buyer, true, true, 100e18);
        uint256 got = wst.balanceOf(buyer) - before;
        assertEq(got, 100e18 * WAD * BPS / (spot * (BPS + 5)));
        assertEq(jit.trackedDIEM(), idle + 100e18);
        assertEq(jit.trackedwstDIEM(), inv - got);
        assertEq(wst.totalSupply(), supply);
    }

    function test_buyExactOut_splitsInventoryAndStake() public {
        _swap(trader, false, true, 600e18);
        uint256 want = jit.trackedwstDIEM() + 50e18;
        uint256 before = wst.balanceOf(buyer);
        _swap(buyer, true, false, want);
        assertEq(wst.balanceOf(buyer) - before, want);
        assertEq(jit.trackedwstDIEM(), 0);
    }

    // ------------------------------------------------------------------ NAV safety

    function test_navJumpCannotBeCashedOut() public {
        _swap(trader, false, true, 1e18);
        uint256 last = jit.lastNav();
        _credit(1000e18); // ~+16% NAV in one block
        assertGt(wst.convertToAssets(WAD), last * 11 / 10);
        (,,, uint256 nav) = _sold(_swap(trader, false, true, 10e18));
        assertEq(nav, last); // same block: no headroom at all
    }

    function test_navHeadroomDoesNotBuildUpWhenQuiet() public {
        _swap(trader, false, true, 1e18);
        uint256 last = jit.lastNav();
        vm.warp(vm.getBlockTimestamp() + 30 days);
        _credit(300e18);
        (,,, uint256 nav) = _sold(_swap(trader, false, true, 10e18));
        assertLe(nav, last + last * 5000 * 1 days / (BPS * 365 days));
        assertGt(nav, last);
    }

    function test_navDropTripsStickyBreaker() public {
        _swap(trader, false, true, 1e18);
        uint256 low = jit.lastNav() * 95 / 100;
        vm.mockCall(
            address(wst), abi.encodeWithSignature("convertToAssets(uint256)", WAD), abi.encode(low)
        );
        _expectSwapRevert(trader, false, true, 1e18, jitDIEM.NavCircuitBreaker.selector);
        _swap(buyer, true, true, 10e18); // buys still stake
        _expectSwapRevert(trader, false, true, 1e18, jitDIEM.NavCircuitBreaker.selector);
        vm.prank(owner);
        jit.resetNav();
        _swap(trader, false, true, 1e18);
        vm.clearMockedCalls();
    }

    // ------------------------------------------------------------------ settlement paths

    function test_firstHopUsesClaimsThenConverts() public {
        _swap(trader, false, true, 10e18);
        uint256 id = uint256(uint160(address(wst)));
        assertEq(pm.balanceOf(address(jit), id), 10e18);
        jit.rebalance();
        assertEq(pm.balanceOf(address(jit), id), 0);
        assertEq(jit.trackedwstDIEM(), wst.balanceOf(address(jit)));
    }

    function test_multiHopTakesRealTokens() public {
        vm.prank(trader);
        wst.transfer(address(pm), 500e18);
        vm.prank(buyer);
        diem.transfer(address(pm), 500e18);
        _swap(trader, false, true, 25e18);
        _swap(buyer, true, true, 25e18);
        assertEq(pm.balanceOf(address(jit), uint256(uint160(address(wst)))), 0);
        assertEq(pm.balanceOf(address(jit), uint256(uint160(address(diem)))), 0);
        assertEq(wst.balanceOf(address(pm)), 500e18);
        assertEq(diem.balanceOf(address(pm)), 500e18);
    }

    // ------------------------------------------------------------------ maintenance

    function test_redeemRequestedAndClaimedWithoutKeeper() public {
        _swap(trader, false, true, 700e18);
        jit.rebalance();
        assertEq(jit.pendingCount(), 1);
        uint256 pending = jit.pendingRedeemDIEM();
        uint256 idle = jit.trackedDIEM();
        assertGt(pending, 0);
        _flushSettle();
        _swap(buyer, true, true, 1e18); // afterSwap claims
        assertEq(jit.pendingCount(), 0);
        assertGe(jit.trackedDIEM(), idle + pending);
    }

    function test_oneRequestPerOpenBatch() public {
        _swap(trader, false, true, 700e18);
        jit.rebalance();
        assertEq(jit.pendingCount(), 1);
        _swap(trader, false, true, 150e18);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        jit.rebalance();
        _swap(buyer, true, true, 1e18);
        assertEq(jit.pendingCount(), 1); // batch still open
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        wst.flush();
        jit.rebalance();
        assertEq(jit.pendingCount(), 2);
    }

    // ------------------------------------------------------------------ LP side

    function test_rewardsVest_sandwichUnprofitable() public {
        uint256 ta0 = jit.totalAssets();
        vm.prank(buyer);
        jit.deposit(1000e18, buyer);
        diem.mint(address(jit), 30e18);
        jit.sync();
        assertEq(jit.lockedProfit(), 30e18);
        uint256 sh = jit.balanceOf(buyer);
        uint256 b0 = diem.balanceOf(buyer);
        vm.prank(buyer);
        jit.redeem(sh, buyer, buyer);
        assertLt(diem.balanceOf(buyer) - b0, 1000e18);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        assertGe(jit.totalAssets(), ta0 + 30e18);
    }

    function test_redeemInKind() public {
        _swap(trader, false, true, 700e18);
        jit.rebalance();
        uint256 sh = jit.balanceOf(lp) * 3 / 10;
        uint256 val = jit.previewRedeem(sh);
        uint256 d0 = diem.balanceOf(lp);
        uint256 w0 = wst.balanceOf(lp);
        vm.prank(lp);
        jit.redeemInKind(sh, lp, lp);
        uint256 value =
            (diem.balanceOf(lp) - d0) + (wst.balanceOf(lp) - w0) * wst.convertToAssets(WAD) / WAD;
        assertApproxEqAbs(value, val, 1e12);
    }

    function test_noPhantomRewardsAfterMixedFlow() public {
        uint256 seed = 7;
        for (uint256 i; i < 40; ++i) {
            seed = uint256(keccak256(abi.encode(seed)));
            uint256 amt = (1 + seed % 60) * 1e18;
            bool sell = (seed >> 8) % 100 < 55;
            bool exactIn = (seed >> 16) % 2 == 0;
            try this.swapExternal(sell ? trader : buyer, !sell, exactIn, amt) {} catch {}
            if (i % 10 == 9) {
                vm.warp(vm.getBlockTimestamp() + 1 days + 1);
                try wst.flush() {} catch {}
                vm.warp(vm.getBlockTimestamp() + 1 days + 1);
                try wst.settle() {} catch {}
            }
        }
        jit.rebalance();
        uint256 locked = jit.lockedProfit();
        jit.sync();
        assertEq(jit.lockedProfit(), locked);
        assertGt(jit.previewRedeem(jit.balanceOf(lp)), 1000e18 * 9990 / 10_000);
    }

    // ------------------------------------------------------------------ fee converter

    function test_feeConverter_paysLaunchFeesToJitAsDIEM() public {
        LiquidFeeLocker locker = new LiquidFeeLocker(address(this));
        jitDIEMFeeConverter conv = new jitDIEMFeeConverter(
            IInferenceVaultQueue(address(wst)), address(jit), IFeeLockerClaim(address(locker))
        );
        locker.addDepositor(address(this));
        // the LP locker stores the converter's share in wstDIEM (FeeIn.Paired)
        vm.prank(trader);
        wst.transfer(address(this), 5e18);
        wst.approve(address(locker), 5e18);
        locker.storeFees(address(conv), address(wst), 5e18);

        assertEq(conv.convert(), 5e18);
        assertEq(conv.pendingCount(), 1);
        // a second call before the batch flushes does not take another batch slot
        locker.storeFees(address(conv), address(wst), 0);
        assertEq(conv.convert(), 0);

        uint256 owed = 5e18 * wst.convertToAssets(WAD) / WAD;
        uint256 jitBefore = diem.balanceOf(address(jit));
        _flushSettle();
        conv.convert(); // claims to jitDIEM
        assertApproxEqAbs(diem.balanceOf(address(jit)) - jitBefore, owed, 1e3);
        assertEq(conv.pendingCount(), 0);

        uint256 lockedBefore = jit.lockedProfit();
        jit.sync();
        assertApproxEqAbs(jit.lockedProfit() - lockedBefore, owed, 1e3);
    }
}

/// Fork test against the LIVE wstDIEM InferenceVault and live DIEM on Base. Requires BASE_RPC_URL.
contract jitDIEMLiveVaultTest is Test {
    uint256 constant WAD = 1e18;
    uint160 constant FLAGS = (1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3);
    IPoolManager constant pm = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    IERC20 constant DIEM = IERC20(0xF4d97F2da56e8c3098f3a8D538DB630A2606a024);
    InferenceVault constant WST = InferenceVault(0xe49FA849cB37b0e7A42B2335e333fb99474167ba);

    jitDIEM jit;
    PoolSwapTest router;
    PoolKey key;
    bool diemIs0;
    address owner = makeAddr("owner");
    address lp = makeAddr("lp");
    address trader = makeAddr("trader");
    address buyer = makeAddr("buyer");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        router = new PoolSwapTest(pm);
        address hookAddr = address(uint160(0x5555 << 144) | FLAGS);
        jitDIEM.Params memory p = jitDIEM.Params(
            100, 500, 5, 5000, 500, 1000, 10, 100, 5000, 3 days, 1 hours, 1 days, true
        );
        deployCodeTo(
            "jitDIEM.sol:jitDIEM",
            abi.encode(pm, IInferenceVaultQueue(address(WST)), owner, p),
            hookAddr
        );
        jit = jitDIEM(hookAddr);
        diemIs0 = address(DIEM) < address(WST);
        (address c0, address c1) =
            diemIs0 ? (address(DIEM), address(WST)) : (address(WST), address(DIEM));
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 0, 1, IHooks(hookAddr));
        vm.prank(owner);
        pm.initialize(key, 2 ** 96);

        address[3] memory users = [lp, trader, buyer];
        for (uint256 i; i < users.length; ++i) {
            deal(address(DIEM), users[i], 100e18);
            vm.startPrank(users[i]);
            DIEM.approve(address(jit), type(uint256).max);
            DIEM.approve(address(router), type(uint256).max);
            DIEM.approve(address(WST), type(uint256).max);
            IERC20(address(WST)).approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(lp);
        jit.deposit(20e18, lp);
        vm.prank(trader);
        WST.deposit(50e18, trader);
    }

    function _swap(address who, bool diemIn, bool exactIn, uint256 amount) internal {
        bool zeroForOne = diemIn == diemIs0;
        vm.prank(who);
        router.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: exactIn ? -int256(amount) : int256(amount),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_live_sellBuyAndQueueRoundTrip() public {
        uint256 nav = WST.convertToAssets(WAD);
        uint256 d0 = DIEM.balanceOf(trader);
        _swap(trader, false, true, 2e18);
        assertApproxEqRel(DIEM.balanceOf(trader) - d0, 2e18 * nav / WAD * 99 / 100, 1e14);

        uint256 preview = WST.previewDeposit(1e18);
        uint256 w0 = WST.balanceOf(buyer);
        _swap(buyer, true, true, 1e18);
        assertEq(WST.balanceOf(buyer) - w0, preview); // staked into the live vault

        _swap(trader, false, true, 10e18); // below target
        jit.rebalance();
        assertEq(jit.pendingCount(), 1);
        (address receiver,,,,,) = WST.requestStatus(jit.pendingIds(0));
        assertEq(receiver, address(jit));
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        jit.rebalance();
        assertEq(jit.pendingCount(), 1); // one request per open batch on the live vault

        uint256 pending = jit.pendingRedeemDIEM();
        uint256 idle = jit.trackedDIEM();
        uint256 t = vm.getBlockTimestamp();
        vm.warp(t + 1 days + 1);
        WST.flush();
        vm.warp(t + 2 days + 2);
        WST.settle();
        jit.rebalance();
        assertEq(jit.pendingCount(), 0);
        assertEq(jit.trackedDIEM(), idle + pending);
    }
}

/// Runs the deploy script end to end on a Base fork. Requires BASE_RPC_URL.
contract DeployJitDiemScriptTest is Test {
    function test_deployScript() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        uint256 pk = 0xA11CE;
        address deployer = vm.addr(pk);
        vm.setEnv("DEPLOYER_PK", vm.toString(pk));
        deal(0xF4d97F2da56e8c3098f3a8D538DB630A2606a024, deployer, 1e17);

        vm.recordLogs();
        new DeployJitDiem().run();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // find the deployed jitDIEM from its OwnershipTransferStarted event
        bytes32 sig = keccak256("OwnershipTransferStarted(address,address)");
        address jitAddr;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) jitAddr = logs[i].emitter;
        }
        jitDIEM jit = jitDIEM(jitAddr);
        assertEq(uint160(jitAddr) & 0x3FFF, 0x28C8);
        assertTrue(jit.poolInitialized());
        assertEq(jit.balanceOf(0x000000000000000000000000000000000000dEaD), 1e16);
        assertEq(jit.pendingOwner(), 0x872c561f699B42977c093F0eD8b4C9a431280c6c);
        assertLe(jitAddr.code.length, 24_576);
    }
}
