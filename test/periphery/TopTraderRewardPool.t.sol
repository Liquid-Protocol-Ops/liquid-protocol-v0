// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TopTraderRewardPool} from "../../src/periphery/TopTraderRewardPool.sol";
import {Test} from "forge-std/Test.sol";

contract MockSpy {
    string public constant name = "SPY";
    uint8 public constant decimals = 18;
    bool public blocked;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function setBlocked(bool b) external {
        blocked = b;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(!blocked, "SPY: blocked");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract MockStateView {
    int24 public tick;

    function setTick(int24 t) external {
        tick = t;
    }

    function getSlot0(bytes32) external view returns (uint160, int24, uint24, uint24) {
        return (0, tick, 0, 0);
    }
}

contract TopTraderRewardPoolTest is Test {
    MockSpy spy;
    MockStateView sv;
    TopTraderRewardPool pool;

    address creator = address(0xC0FFEE);
    address treasury = address(0x7EA);
    address keeper;
    int24 constant MIGRATION_TICK = -172_980;
    bytes32 constant POOL_ID = keccak256("pool");

    address w1 = address(0x111);
    address w2 = address(0x222);
    address w3 = address(0x333);

    function setUp() public {
        spy = new MockSpy();
        sv = new MockStateView();
        sv.setTick(-216_840); // below migration threshold
        keeper = address(0xBEEF);
        pool = new TopTraderRewardPool(
            address(spy), creator, treasury, keeper, MIGRATION_TICK, address(sv)
        );
        pool.setPool(POOL_ID);
    }

    // ── awardMonth ──
    function test_award_splits_60_30_10_remainderToFirst() public {
        spy.mint(address(pool), 1001); // forces a remainder
        vm.prank(keeper);
        pool.awardMonth([w1, w2, w3]);
        assertEq(spy.balanceOf(w2), 300);
        assertEq(spy.balanceOf(w3), 100);
        assertEq(spy.balanceOf(w1), 601); // 600 + remainder 1
        assertEq(spy.balanceOf(address(pool)), 0);
    }

    function test_award_onlyKeeper() public {
        spy.mint(address(pool), 100);
        vm.expectRevert(TopTraderRewardPool.NotKeeper.selector);
        pool.awardMonth([w1, w2, w3]);
    }

    function test_award_cooldown() public {
        spy.mint(address(pool), 100);
        vm.startPrank(keeper);
        pool.awardMonth([w1, w2, w3]);
        spy.mint(address(pool), 100);
        vm.expectRevert(TopTraderRewardPool.AwardTooSoon.selector);
        pool.awardMonth([w1, w2, w3]);
        vm.warp(block.timestamp + 25 days);
        pool.awardMonth([w1, w2, w3]); // succeeds after cooldown
        vm.stopPrank();
    }

    function test_award_rejectsZeroAndDuplicateWinners() public {
        spy.mint(address(pool), 100);
        vm.startPrank(keeper);
        vm.expectRevert(TopTraderRewardPool.BadWinners.selector);
        pool.awardMonth([address(0), w2, w3]);
        vm.expectRevert(TopTraderRewardPool.BadWinners.selector);
        pool.awardMonth([w1, w1, w3]);
        vm.stopPrank();
    }

    function test_award_revertsWhenEmptyPot() public {
        vm.prank(keeper);
        vm.expectRevert(TopTraderRewardPool.EmptyPot.selector);
        pool.awardMonth([w1, w2, w3]);
    }

    // ── migrate ──
    function test_migrate_revertsBelowThreshold() public {
        vm.expectRevert(TopTraderRewardPool.BelowMigrationTick.selector);
        pool.migrate();
    }

    function test_migrate_latchesAndRecordsPot_settlePaysTreasury() public {
        spy.mint(address(pool), 500);
        sv.setTick(MIGRATION_TICK); // exactly at threshold: succeeds (>=)
        pool.migrate();
        assertTrue(pool.migrated());
        assertEq(pool.treasuryPot(), 500);
        assertEq(spy.balanceOf(treasury), 0); // latch never transfers
        pool.settleTreasury();
        assertEq(spy.balanceOf(treasury), 500);
        assertEq(pool.treasuryPot(), 0);
        pool.settleTreasury(); // no-op once settled
        assertEq(spy.balanceOf(treasury), 500);
        vm.expectRevert(TopTraderRewardPool.AlreadyMigrated.selector);
        pool.migrate();
    }

    function test_migrate_latchSurvivesBlockedTransfer() public {
        spy.mint(address(pool), 500);
        sv.setTick(MIGRATION_TICK);
        spy.setBlocked(true);
        pool.migrate(); // latch engages even though transfers revert
        assertTrue(pool.migrated());
        vm.expectRevert(bytes("SPY: blocked"));
        pool.settleTreasury();
        spy.setBlocked(false);
        pool.settleTreasury(); // retryable
        assertEq(spy.balanceOf(treasury), 500);
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(TopTraderRewardPool.ZeroAddress.selector);
        new TopTraderRewardPool(address(0), creator, treasury, keeper, MIGRATION_TICK, address(sv));
        vm.expectRevert(TopTraderRewardPool.ZeroAddress.selector);
        new TopTraderRewardPool(
            address(spy), creator, address(0), keeper, MIGRATION_TICK, address(sv)
        );
    }

    function test_award_blockedAfterMigration() public {
        sv.setTick(MIGRATION_TICK + 60);
        pool.migrate();
        spy.mint(address(pool), 100);
        vm.prank(keeper);
        vm.expectRevert(TopTraderRewardPool.AlreadyMigrated.selector);
        pool.awardMonth([w1, w2, w3]);
    }

    // ── sweep ──
    function test_sweep_onlyAfterMigration_excludesUnsettledPot() public {
        spy.mint(address(pool), 250);
        vm.expectRevert(TopTraderRewardPool.NotMigrated.selector);
        pool.sweep(address(spy));
        sv.setTick(MIGRATION_TICK);
        pool.migrate(); // records 250 owed to treasury, transfers nothing
        spy.mint(address(pool), 77); // post-migration fee arrival
        pool.sweep(address(spy)); // creator gets only the non-reserved 77
        assertEq(spy.balanceOf(creator), 77);
        assertEq(spy.balanceOf(address(pool)), 250);
        pool.settleTreasury();
        assertEq(spy.balanceOf(treasury), 250);
    }

    // ── admin ──
    function test_setPool_onceAndDeployerOnly() public {
        vm.expectRevert(TopTraderRewardPool.PoolAlreadySet.selector);
        pool.setPool(keccak256("other"));
        TopTraderRewardPool fresh = new TopTraderRewardPool(
            address(spy), creator, treasury, keeper, MIGRATION_TICK, address(sv)
        );
        vm.prank(address(0xDEAD));
        vm.expectRevert(TopTraderRewardPool.NotDeployer.selector);
        fresh.setPool(POOL_ID);
    }

    function test_setKeeper_creatorOnly() public {
        vm.prank(creator);
        pool.setKeeper(address(0xABCD));
        assertEq(pool.keeper(), address(0xABCD));
        vm.expectRevert(TopTraderRewardPool.NotCreator.selector);
        pool.setKeeper(address(0x1));
    }

    function test_migrate_requiresPoolSet() public {
        TopTraderRewardPool fresh = new TopTraderRewardPool(
            address(spy), creator, treasury, keeper, MIGRATION_TICK, address(sv)
        );
        sv.setTick(MIGRATION_TICK);
        vm.expectRevert(TopTraderRewardPool.PoolNotSet.selector);
        fresh.migrate();
    }
}
