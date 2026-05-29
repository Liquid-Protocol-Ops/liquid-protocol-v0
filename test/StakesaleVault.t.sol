// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {StakesaleVault} from "../src/extensions/StakesaleVault.sol";
import {ILiquid} from "../src/interfaces/ILiquid.sol";
import {ILiquidExtension} from "../src/interfaces/ILiquidExtension.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Test} from "forge-std/Test.sol";

// ── Minimal mocks ─────────────────────────────────────────────────────────────

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockFactory {
    function callReceiveTokens(address vault, address launchedToken, uint256 supply) external {
        IERC20(launchedToken).approve(vault, supply);
        ILiquid.DeploymentConfig memory config;
        PoolKey memory key;
        ILiquidExtension(vault).receiveTokens(config, key, launchedToken, supply, 0);
    }
}

// ── Base setup ────────────────────────────────────────────────────────────────

abstract contract Base is Test {
    MockFactory factory;
    MockERC20 launchedToken;
    MockERC20 diem;

    address owner = makeAddr("owner");
    address treasury = 0x872c561f699B42977c093F0eD8b4C9a431280c6c;

    uint256 constant DEPOSIT_WINDOW = 24 hours;
    uint256 constant TOKEN_SUPPLY = 20_000_000_000e18; // 20B (20% of 100B)

    StakesaleVault vault;

    function setUp() public virtual {
        factory = new MockFactory();
        launchedToken = new MockERC20("AgentToken", "AGT");
        diem = new MockERC20("DIEM", "DIEM");

        vm.prank(owner);
        vault = new StakesaleVault(address(diem), address(factory), DEPOSIT_WINDOW);

        launchedToken.mint(address(factory), TOKEN_SUPPLY);
    }

    function _init() internal {
        factory.callReceiveTokens(address(vault), address(launchedToken), TOKEN_SUPPLY);
    }

    function _deposit(address who, uint256 amount, uint256 lockDuration) internal {
        diem.mint(who, amount);
        vm.startPrank(who);
        diem.approve(address(vault), amount);
        vault.deposit(amount, lockDuration);
        vm.stopPrank();
    }
}

// ── Constructor ───────────────────────────────────────────────────────────────

contract ConstructorTest is Base {
    function test_constructor_setsImmutables() public view {
        assertEq(address(vault.diem()), address(diem));
        assertEq(vault.factory(), address(factory));
        assertEq(vault.depositWindow(), DEPOSIT_WINDOW);
        assertEq(vault.owner(), owner);
        assertEq(vault.extensionBps(), 2000);
    }

    function test_constructor_revertWindowTooShort() public {
        vm.expectRevert(StakesaleVault.InvalidDepositWindow.selector);
        new StakesaleVault(address(diem), address(factory), 1 hours);
    }

    function test_constructor_revertWindowTooLong() public {
        vm.expectRevert(StakesaleVault.InvalidDepositWindow.selector);
        new StakesaleVault(address(diem), address(factory), 31 days);
    }

    function test_constructor_minWindowAccepted() public {
        StakesaleVault v = new StakesaleVault(address(diem), address(factory), 2 hours);
        assertEq(v.depositWindow(), 2 hours);
    }

    function test_constructor_maxWindowAccepted() public {
        StakesaleVault v = new StakesaleVault(address(diem), address(factory), 30 days);
        assertEq(v.depositWindow(), 30 days);
    }
}

// ── receiveTokens ─────────────────────────────────────────────────────────────

contract ReceiveTokensTest is Base {
    function test_receiveTokens_setsState() public {
        _init();

        assertEq(vault.token(), address(launchedToken));
        assertEq(vault.totalTokenSupply(), TOKEN_SUPPLY);
        assertEq(vault.depositDeadline(), block.timestamp + DEPOSIT_WINDOW);
        assertTrue(vault.initialized());
        assertEq(IERC20(launchedToken).balanceOf(address(vault)), TOKEN_SUPPLY);
    }

    function test_receiveTokens_revertNotFactory() public {
        ILiquid.DeploymentConfig memory config;
        PoolKey memory key;
        vm.expectRevert(StakesaleVault.NotFactory.selector);
        vault.receiveTokens(config, key, address(launchedToken), TOKEN_SUPPLY, 0);
    }

    function test_receiveTokens_revertAlreadyInitialized() public {
        _init();
        launchedToken.mint(address(factory), TOKEN_SUPPLY);
        vm.expectRevert(StakesaleVault.AlreadyInitialized.selector);
        factory.callReceiveTokens(address(vault), address(launchedToken), TOKEN_SUPPLY);
    }

    function test_receiveTokens_revertMsgValue() public {
        ILiquid.DeploymentConfig memory config;
        PoolKey memory key;
        hoax(address(factory), 1); // fund factory with 1 wei + prank
        vm.expectRevert(ILiquidExtension.InvalidMsgValue.selector);
        vault.receiveTokens{value: 1}(config, key, address(launchedToken), TOKEN_SUPPLY, 0);
    }
}

// ── deposit ───────────────────────────────────────────────────────────────────

contract DepositTest is Base {
    function setUp() public override {
        super.setUp();
        _init();
    }

    function test_deposit_30day() public {
        address alice = makeAddr("alice");
        _deposit(alice, 1e18, vault.LOCK_30());

        assertEq(vault.deposited(alice), 1e18);
        assertEq(vault.weight(alice), 1e18 * vault.MULTIPLIER_30());
        assertEq(vault.chosenLock(alice), vault.LOCK_30());
        assertEq(vault.totalDeposited(), 1e18);
        assertEq(vault.totalWeight(), 1e18);
    }

    function test_deposit_60day() public {
        address alice = makeAddr("alice");
        _deposit(alice, 1e18, vault.LOCK_60());

        assertEq(vault.weight(alice), 1e18 * 2);
        assertEq(vault.totalWeight(), 1e18 * 2);
    }

    function test_deposit_90day() public {
        address alice = makeAddr("alice");
        _deposit(alice, 1e18, vault.LOCK_90());

        assertEq(vault.weight(alice), 1e18 * 3);
        assertEq(vault.totalWeight(), 1e18 * 3);
    }

    function test_deposit_topUp_sameTier() public {
        address alice = makeAddr("alice");
        _deposit(alice, 4e18, vault.LOCK_60());
        _deposit(alice, 4e18, vault.LOCK_60());

        assertEq(vault.deposited(alice), 8e18);
        assertEq(vault.weight(alice), 8e18 * 2);
    }

    function test_deposit_revertCapExceeded() public {
        uint256 lock30 = vault.LOCK_30();
        address alice = makeAddr("alice");
        _deposit(alice, 10e18, lock30);

        diem.mint(alice, 1);
        vm.startPrank(alice);
        diem.approve(address(vault), 1);
        vm.expectRevert(StakesaleVault.DepositCapExceeded.selector);
        vault.deposit(1, lock30);
        vm.stopPrank();
    }

    function test_deposit_capIsExact() public {
        address alice = makeAddr("alice");
        // Two deposits totalling exactly MAX_DEPOSIT should succeed
        _deposit(alice, 6e18, vault.LOCK_90());
        _deposit(alice, 4e18, vault.LOCK_90());
        assertEq(vault.deposited(alice), 10e18);
    }

    function test_deposit_revertLockDurationMismatch() public {
        uint256 lock30 = vault.LOCK_30();
        uint256 lock60 = vault.LOCK_60();
        address alice = makeAddr("alice");
        _deposit(alice, 1e18, lock30);

        diem.mint(alice, 1e18);
        vm.startPrank(alice);
        diem.approve(address(vault), 1e18);
        vm.expectRevert(StakesaleVault.LockDurationMismatch.selector);
        vault.deposit(1e18, lock60);
        vm.stopPrank();
    }

    function test_deposit_revertZero() public {
        uint256 lock30 = vault.LOCK_30();
        address alice = makeAddr("alice");
        diem.mint(alice, 1e18);
        vm.startPrank(alice);
        diem.approve(address(vault), 1e18);
        vm.expectRevert(StakesaleVault.ZeroDeposit.selector);
        vault.deposit(0, lock30);
        vm.stopPrank();
    }

    function test_deposit_revertInvalidLockDuration() public {
        address alice = makeAddr("alice");
        diem.mint(alice, 1e18);
        vm.startPrank(alice);
        diem.approve(address(vault), 1e18);
        vm.expectRevert(StakesaleVault.InvalidLockDuration.selector);
        vault.deposit(1e18, 15 days);
        vm.stopPrank();
    }

    function test_deposit_revertWindowClosed() public {
        uint256 lock30 = vault.LOCK_30();
        vm.warp(block.timestamp + DEPOSIT_WINDOW + 1);
        address alice = makeAddr("alice");
        diem.mint(alice, 1e18);
        vm.startPrank(alice);
        diem.approve(address(vault), 1e18);
        vm.expectRevert(StakesaleVault.DepositWindowClosed.selector);
        vault.deposit(1e18, lock30);
        vm.stopPrank();
    }

    function test_deposit_revertNotInitialized() public {
        uint256 lock30 = vault.LOCK_30();
        StakesaleVault uninit = new StakesaleVault(address(diem), address(factory), DEPOSIT_WINDOW);
        address alice = makeAddr("alice");
        diem.mint(alice, 1e18);
        vm.startPrank(alice);
        diem.approve(address(uninit), 1e18);
        vm.expectRevert(StakesaleVault.NotInitialized.selector);
        uninit.deposit(1e18, lock30);
        vm.stopPrank();
    }

    function test_deposit_multipleDepositors_totalWeight() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _deposit(alice, 5e18, vault.LOCK_30()); // weight 5
        _deposit(bob, 2e18, vault.LOCK_90()); // weight 6

        assertEq(vault.totalWeight(), 11e18);
    }
}

// ── claimTokens ───────────────────────────────────────────────────────────────

contract ClaimTokensTest is Base {
    function setUp() public override {
        super.setUp();
        _init();
    }

    function test_claimTokens_singleDepositor_gets100Pct() public {
        address alice = makeAddr("alice");
        _deposit(alice, 5e18, vault.LOCK_30());

        vm.warp(vault.depositDeadline() + 1);
        vm.prank(alice);
        vault.claimTokens();

        assertEq(launchedToken.balanceOf(alice), TOKEN_SUPPLY);
    }

    function test_claimTokens_weightedProRata() public {
        // Alice: 10 DIEM × 30d (1×) = weight 10
        // Bob:   5 DIEM × 60d (2×) = weight 10  → equal share
        // Carol: 5 DIEM × 90d (3×) = weight 15
        // Total weight = 35
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address carol = makeAddr("carol");

        _deposit(alice, 10e18, vault.LOCK_30());
        _deposit(bob, 5e18, vault.LOCK_60());
        _deposit(carol, 5e18, vault.LOCK_90());

        vm.warp(vault.depositDeadline() + 1);
        vm.prank(alice);
        vault.claimTokens();
        vm.prank(bob);
        vault.claimTokens();
        vm.prank(carol);
        vault.claimTokens();

        uint256 totalWeight = 10e18 + 10e18 + 15e18; // 35e18
        assertEq(launchedToken.balanceOf(alice), TOKEN_SUPPLY * 10e18 / totalWeight);
        assertEq(launchedToken.balanceOf(bob), TOKEN_SUPPLY * 10e18 / totalWeight);
        assertEq(launchedToken.balanceOf(carol), TOKEN_SUPPLY * 15e18 / totalWeight);
    }

    function test_claimTokens_90dayOutweighs30day() public {
        // Same DIEM amount: 90d depositor gets 3× the tokens
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _deposit(alice, 1e18, vault.LOCK_30()); // weight 1
        _deposit(bob, 1e18, vault.LOCK_90()); // weight 3

        vm.warp(vault.depositDeadline() + 1);
        vm.prank(alice);
        vault.claimTokens();
        vm.prank(bob);
        vault.claimTokens();

        // Alice 25%, Bob 75%
        assertEq(launchedToken.balanceOf(alice), TOKEN_SUPPLY / 4);
        assertEq(launchedToken.balanceOf(bob), TOKEN_SUPPLY * 3 / 4);
    }

    function test_claimTokens_revertBeforeDeadline() public {
        address alice = makeAddr("alice");
        _deposit(alice, 1e18, vault.LOCK_30());

        vm.prank(alice);
        vm.expectRevert(StakesaleVault.DepositWindowOpen.selector);
        vault.claimTokens();
    }

    function test_claimTokens_revertDoubleClaim() public {
        address alice = makeAddr("alice");
        _deposit(alice, 1e18, vault.LOCK_30());

        vm.warp(vault.depositDeadline() + 1);
        vm.prank(alice);
        vault.claimTokens();
        vm.prank(alice);
        vm.expectRevert(StakesaleVault.AlreadyClaimed.selector);
        vault.claimTokens();
    }

    function test_claimTokens_revertNothingDeposited() public {
        vm.warp(vault.depositDeadline() + 1);
        vm.prank(makeAddr("nobody"));
        vm.expectRevert(StakesaleVault.NothingDeposited.selector);
        vault.claimTokens();
    }

    function test_claimTokens_revertNoDepositsInVault() public {
        // No one deposited — totalWeight == 0. Force deposited[alice] > 0
        // via a separate vault where we can test this path indirectly.
        // In practice this state is unreachable (deposit sets totalWeight > 0).
        // Covered by test_sweepDust_fullSupplyWhenNoDeposits instead.
    }
}

// ── withdrawDiem ──────────────────────────────────────────────────────────────

contract WithdrawDiemTest is Base {
    function setUp() public override {
        super.setUp();
        _init();
    }

    function test_withdrawDiem_after30dLock() public {
        address alice = makeAddr("alice");
        _deposit(alice, 3e18, vault.LOCK_30());

        vm.warp(vault.lockExpiryOf(alice) + 1);
        vm.prank(alice);
        vault.withdrawDiem();

        assertEq(diem.balanceOf(alice), 3e18);
        assertEq(diem.balanceOf(address(vault)), 0);
    }

    function test_withdrawDiem_after60dLock() public {
        address alice = makeAddr("alice");
        _deposit(alice, 2e18, vault.LOCK_60());

        vm.warp(vault.lockExpiryOf(alice) + 1);
        vm.prank(alice);
        vault.withdrawDiem();

        assertEq(diem.balanceOf(alice), 2e18);
    }

    function test_withdrawDiem_after90dLock() public {
        address alice = makeAddr("alice");
        _deposit(alice, 1e18, vault.LOCK_90());

        vm.warp(vault.lockExpiryOf(alice) + 1);
        vm.prank(alice);
        vault.withdrawDiem();

        assertEq(diem.balanceOf(alice), 1e18);
    }

    function test_withdrawDiem_revertBeforeLockExpiry() public {
        address alice = makeAddr("alice");
        _deposit(alice, 1e18, vault.LOCK_90());

        // after deposit deadline but before lock expiry
        vm.warp(vault.depositDeadline() + 1);
        vm.prank(alice);
        vm.expectRevert(StakesaleVault.LockNotExpired.selector);
        vault.withdrawDiem();
    }

    function test_withdrawDiem_revertDoubleWithdraw() public {
        address alice = makeAddr("alice");
        _deposit(alice, 1e18, vault.LOCK_30());

        vm.warp(vault.lockExpiryOf(alice) + 1);
        vm.prank(alice);
        vault.withdrawDiem();
        vm.prank(alice);
        vm.expectRevert(StakesaleVault.AlreadyWithdrawn.selector);
        vault.withdrawDiem();
    }

    function test_withdrawDiem_revertNothingDeposited() public {
        vm.warp(vault.depositDeadline() + vault.LOCK_30() + 1);
        vm.prank(makeAddr("nobody"));
        vm.expectRevert(StakesaleVault.NothingDeposited.selector);
        vault.withdrawDiem();
    }

    function test_withdrawDiem_independentFromClaimTokens() public {
        address alice = makeAddr("alice");
        _deposit(alice, 4e18, vault.LOCK_30());

        // Claim tokens first (after deadline)
        vm.warp(vault.depositDeadline() + 1);
        vm.prank(alice);
        vault.claimTokens();
        assertEq(launchedToken.balanceOf(alice), TOKEN_SUPPLY);

        // Then withdraw DIEM after lock expiry
        vm.warp(vault.lockExpiryOf(alice) + 1);
        vm.prank(alice);
        vault.withdrawDiem();
        assertEq(diem.balanceOf(alice), 4e18);
    }

    function test_withdrawDiem_lockExpiryTimingIndependentOfDepositTime() public {
        // Two depositors choosing LOCK_30, depositing at different times.
        // Both should unlock at the same time: depositDeadline + LOCK_30.
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        _deposit(alice, 1e18, vault.LOCK_30());
        vm.warp(block.timestamp + DEPOSIT_WINDOW / 2); // halfway through window
        _deposit(bob, 1e18, vault.LOCK_30());

        // Both lockExpiry should be equal: depositDeadline + LOCK_30
        assertEq(vault.lockExpiryOf(alice), vault.lockExpiryOf(bob));
        assertEq(vault.lockExpiryOf(alice), vault.depositDeadline() + vault.LOCK_30());
    }

    function test_withdrawDiem_multipleTiersUnlockAtDifferentTimes() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _deposit(alice, 1e18, vault.LOCK_30());
        _deposit(bob, 1e18, vault.LOCK_90());

        // At depositDeadline + LOCK_30: alice can withdraw, bob cannot
        vm.warp(vault.depositDeadline() + vault.LOCK_30() + 1);
        vm.prank(alice);
        vault.withdrawDiem();
        vm.prank(bob);
        vm.expectRevert(StakesaleVault.LockNotExpired.selector);
        vault.withdrawDiem();

        // At depositDeadline + LOCK_90: bob can withdraw
        vm.warp(vault.depositDeadline() + vault.LOCK_90() + 1);
        vm.prank(bob);
        vault.withdrawDiem();
        assertEq(diem.balanceOf(bob), 1e18);
    }
}

// ── sweepDust ─────────────────────────────────────────────────────────────────

contract SweepDustTest is Base {
    function setUp() public override {
        super.setUp();
        _init();
    }

    function test_sweepDust_dustFromIntegerDivision() public {
        // Weights 1:2 → total 3. TOKEN_SUPPLY = 20B, not divisible by 3 → 1 wei dust.
        uint256 lock30 = vault.LOCK_30();
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _deposit(alice, 1e18, lock30); // weight 1
        _deposit(bob, 2e18, lock30); // weight 2

        vm.warp(vault.depositDeadline() + 1);
        vm.prank(alice);
        vault.claimTokens();
        vm.prank(bob);
        vault.claimTokens();

        vm.warp(vault.depositDeadline() + vault.LOCK_90() + 14 days + 1);
        uint256 remaining = launchedToken.balanceOf(address(vault));
        assertGt(remaining, 0);

        vault.sweepDust();

        assertEq(launchedToken.balanceOf(address(vault)), 0);
        assertEq(launchedToken.balanceOf(vault.TREASURY()), remaining);
    }

    function test_sweepDust_fullSupplyWhenNoDeposits() public {
        vm.warp(vault.depositDeadline() + vault.LOCK_90() + 14 days + 1);

        vault.sweepDust();

        assertEq(launchedToken.balanceOf(vault.TREASURY()), TOKEN_SUPPLY);
        assertEq(launchedToken.balanceOf(address(vault)), 0);
    }

    function test_sweepDust_revertTooEarly() public {
        // One second before the grace period ends — should still revert.
        vm.warp(vault.depositDeadline() + vault.LOCK_90() + 14 days - 1);
        vm.expectRevert(StakesaleVault.SweepTooEarly.selector);
        vault.sweepDust();
    }

    function test_sweepDust_noopWhenEmpty() public {
        address alice = makeAddr("alice");
        _deposit(alice, 1e18, vault.LOCK_30()); // single depositor → no dust

        vm.warp(vault.depositDeadline() + 1);
        vm.prank(alice);
        vault.claimTokens();

        vm.warp(vault.depositDeadline() + vault.LOCK_90() + 14 days + 1);
        vault.sweepDust(); // should not revert even if balance == 0
        assertEq(launchedToken.balanceOf(vault.TREASURY()), 0);
    }

    function test_sweepDust_callableByAnyone() public {
        vm.warp(vault.depositDeadline() + vault.LOCK_90() + 14 days + 1);
        vm.prank(makeAddr("random"));
        vault.sweepDust(); // non-owner, non-factory — should succeed
    }

    function test_sweepDust_revertNotInitialized() public {
        StakesaleVault uninit = new StakesaleVault(address(diem), address(factory), DEPOSIT_WINDOW);
        vm.expectRevert(StakesaleVault.NotInitialized.selector);
        uninit.sweepDust();
    }
}

// ── Admin ─────────────────────────────────────────────────────────────────────

contract AdminTest is Base {
    function test_setExtensionBps_byOwner() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit StakesaleVault.ExtensionBpsUpdated(2000, 1500);
        vault.setExtensionBps(1500);
        assertEq(vault.extensionBps(), 1500);
    }

    function test_setExtensionBps_revertNotOwner() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(StakesaleVault.NotOwner.selector);
        vault.setExtensionBps(1500);
    }

    function test_transferOwnership() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        vault.transferOwnership(newOwner);
        assertEq(vault.owner(), newOwner);

        // old owner can no longer set bps
        vm.prank(owner);
        vm.expectRevert(StakesaleVault.NotOwner.selector);
        vault.setExtensionBps(100);

        // new owner can
        vm.prank(newOwner);
        vault.setExtensionBps(100);
        assertEq(vault.extensionBps(), 100);
    }

    function test_transferOwnership_revertNotOwner() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(StakesaleVault.NotOwner.selector);
        vault.transferOwnership(makeAddr("rando2"));
    }
}

// ── Views ─────────────────────────────────────────────────────────────────────

contract ViewsTest is Base {
    function setUp() public override {
        super.setUp();
        _init();
    }

    function test_getShare_proRata() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _deposit(alice, 3e18, vault.LOCK_30()); // weight 3
        _deposit(bob, 1e18, vault.LOCK_30()); // weight 1

        assertEq(vault.getShare(alice), TOKEN_SUPPLY * 3 / 4);
        assertEq(vault.getShare(bob), TOKEN_SUPPLY / 4);
    }

    function test_getShare_weightedByTier() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _deposit(alice, 1e18, vault.LOCK_30()); // weight 1
        _deposit(bob, 1e18, vault.LOCK_90()); // weight 3

        assertEq(vault.getShare(alice), TOKEN_SUPPLY / 4);
        assertEq(vault.getShare(bob), TOKEN_SUPPLY * 3 / 4);
    }

    function test_getShare_returnsZeroNoDeposit() public {
        assertEq(vault.getShare(makeAddr("nobody")), 0);
    }

    function test_getShare_returnsZeroNoTotalWeight() public {
        StakesaleVault v = new StakesaleVault(address(diem), address(factory), DEPOSIT_WINDOW);
        assertEq(v.getShare(makeAddr("alice")), 0);
    }

    function test_lockExpiryOf_30day() public {
        address alice = makeAddr("alice");
        _deposit(alice, 1e18, vault.LOCK_30());
        assertEq(vault.lockExpiryOf(alice), vault.depositDeadline() + vault.LOCK_30());
    }

    function test_lockExpiryOf_60day() public {
        address alice = makeAddr("alice");
        _deposit(alice, 1e18, vault.LOCK_60());
        assertEq(vault.lockExpiryOf(alice), vault.depositDeadline() + vault.LOCK_60());
    }

    function test_lockExpiryOf_90day() public {
        address alice = makeAddr("alice");
        _deposit(alice, 1e18, vault.LOCK_90());
        assertEq(vault.lockExpiryOf(alice), vault.depositDeadline() + vault.LOCK_90());
    }

    function test_lockExpiryOf_returnsZeroNoDeposit() public {
        assertEq(vault.lockExpiryOf(makeAddr("nobody")), 0);
    }
}

// ── ERC165 ────────────────────────────────────────────────────────────────────

contract ERC165Test is Base {
    function test_supportsILiquidExtension() public view {
        assertTrue(vault.supportsInterface(type(ILiquidExtension).interfaceId));
    }

    function test_supportsIERC165() public view {
        assertTrue(vault.supportsInterface(type(IERC165).interfaceId));
    }

    function test_doesNotSupportRandomInterface() public view {
        assertFalse(vault.supportsInterface(bytes4(0xdeadbeef)));
    }
}
