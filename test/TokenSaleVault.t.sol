// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TokenSaleVault} from "../src/extensions/TokenSaleVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

// ── Minimal mocks ─────────────────────────────────────────────────────────────

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ── Base setup ────────────────────────────────────────────────────────────────

abstract contract BaseTest is Test {
    MockERC20 diem;
    MockERC20 saleToken;

    address seller = makeAddr("seller");
    address buyer1 = makeAddr("buyer1");
    address buyer2 = makeAddr("buyer2");
    address buyer3 = makeAddr("buyer3");
    address anyone = makeAddr("anyone");

    uint256 constant LOCK_DURATION = 30 days;
    uint256 constant DEPOSIT_WINDOW = 7 days;
    uint256 constant TOKEN_SUPPLY = 1_000_000e18; // 1M sale tokens
    uint256 constant TARGET_DIEM = 100_000e18; // 100k DIEM reference
    uint256 constant MAX_DEPOSIT_CAP = 10_000e18; // 10k DIEM per address
    uint256 constant USD_VALUE_E6 = 1_000_000; // $1.00 per token

    TokenSaleVault vault;

    function setUp() public virtual {
        diem = new MockERC20("DIEM", "DIEM");
        saleToken = new MockERC20("SaleToken", "SALE");

        vault = new TokenSaleVault(
            address(diem),
            seller,
            LOCK_DURATION,
            DEPOSIT_WINDOW,
            TARGET_DIEM,
            MAX_DEPOSIT_CAP,
            USD_VALUE_E6
        );

        // Fund seller with sale tokens
        saleToken.mint(seller, TOKEN_SUPPLY);
        // Fund buyers with DIEM
        diem.mint(buyer1, 100_000e18);
        diem.mint(buyer2, 100_000e18);
        diem.mint(buyer3, 100_000e18);
    }

    function _initialize() internal {
        vm.startPrank(seller);
        saleToken.approve(address(vault), TOKEN_SUPPLY);
        vault.initialize(address(saleToken), TOKEN_SUPPLY);
        vm.stopPrank();
    }

    function _deposit(address who, uint256 amount) internal {
        vm.startPrank(who);
        diem.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }
}

// ── Constructor ───────────────────────────────────────────────────────────────

contract ConstructorTest is BaseTest {
    function test_immutables() public view {
        assertEq(address(vault.diem()), address(diem));
        assertEq(vault.seller(), seller);
        assertEq(vault.lockDuration(), LOCK_DURATION);
        assertEq(vault.depositWindow(), DEPOSIT_WINDOW);
        assertEq(vault.targetDiemWei(), TARGET_DIEM);
        assertEq(vault.maxDeposit(), MAX_DEPOSIT_CAP);
        assertEq(vault.usdValueE6(), USD_VALUE_E6);
    }

    function test_revert_invalidLock_tooShort() public {
        vm.expectRevert(TokenSaleVault.InvalidLock.selector);
        new TokenSaleVault(address(diem), seller, 0, DEPOSIT_WINDOW, 0, 0, 0);
    }

    function test_revert_invalidLock_tooLong() public {
        vm.expectRevert(TokenSaleVault.InvalidLock.selector);
        new TokenSaleVault(address(diem), seller, 366 days, DEPOSIT_WINDOW, 0, 0, 0);
    }

    function test_revert_invalidWindow_tooShort() public {
        vm.expectRevert(TokenSaleVault.InvalidWindow.selector);
        new TokenSaleVault(address(diem), seller, LOCK_DURATION, 1 hours, 0, 0, 0);
    }

    function test_revert_invalidWindow_tooLong() public {
        vm.expectRevert(TokenSaleVault.InvalidWindow.selector);
        new TokenSaleVault(address(diem), seller, LOCK_DURATION, 31 days, 0, 0, 0);
    }

    function test_noTargetDiem_zero() public {
        // targetDiemWei = 0 is valid (no reference)
        TokenSaleVault v =
            new TokenSaleVault(address(diem), seller, LOCK_DURATION, DEPOSIT_WINDOW, 0, 0, 0);
        assertEq(v.targetDiemWei(), 0);
    }

    function test_noMaxDeposit_zero() public {
        // maxDeposit = 0 means uncapped
        TokenSaleVault v =
            new TokenSaleVault(address(diem), seller, LOCK_DURATION, DEPOSIT_WINDOW, 0, 0, 0);
        assertEq(v.maxDeposit(), 0);
    }

    function test_boundaryLock_minValid() public {
        TokenSaleVault v =
            new TokenSaleVault(address(diem), seller, 1 days, DEPOSIT_WINDOW, 0, 0, 0);
        assertEq(v.lockDuration(), 1 days);
    }

    function test_boundaryLock_maxValid() public {
        TokenSaleVault v =
            new TokenSaleVault(address(diem), seller, 365 days, DEPOSIT_WINDOW, 0, 0, 0);
        assertEq(v.lockDuration(), 365 days);
    }

    function test_boundaryWindow_minValid() public {
        TokenSaleVault v =
            new TokenSaleVault(address(diem), seller, LOCK_DURATION, 2 hours, 0, 0, 0);
        assertEq(v.depositWindow(), 2 hours);
    }

    function test_boundaryWindow_maxValid() public {
        TokenSaleVault v =
            new TokenSaleVault(address(diem), seller, LOCK_DURATION, 30 days, 0, 0, 0);
        assertEq(v.depositWindow(), 30 days);
    }
}

// ── Initialize ────────────────────────────────────────────────────────────────

contract InitializeTest is BaseTest {
    function test_initialize() public {
        uint256 ts = block.timestamp;
        _initialize();

        assertEq(address(vault.saleToken()), address(saleToken));
        assertEq(vault.totalTokenSupply(), TOKEN_SUPPLY);
        assertEq(vault.depositDeadline(), ts + DEPOSIT_WINDOW);
        assertTrue(vault.initialized());
        // tokens transferred from seller to vault
        assertEq(saleToken.balanceOf(address(vault)), TOKEN_SUPPLY);
        assertEq(saleToken.balanceOf(seller), 0);
    }

    function test_initialize_emitsEvent() public {
        vm.startPrank(seller);
        saleToken.approve(address(vault), TOKEN_SUPPLY);
        vm.expectEmit(true, false, false, true);
        emit TokenSaleVault.VaultInitialized(
            address(saleToken), TOKEN_SUPPLY, block.timestamp + DEPOSIT_WINDOW
        );
        vault.initialize(address(saleToken), TOKEN_SUPPLY);
        vm.stopPrank();
    }

    function test_revert_notSeller() public {
        vm.startPrank(buyer1);
        saleToken.approve(address(vault), TOKEN_SUPPLY);
        vm.expectRevert(TokenSaleVault.NotSeller.selector);
        vault.initialize(address(saleToken), TOKEN_SUPPLY);
        vm.stopPrank();
    }

    function test_revert_alreadyInitialized() public {
        _initialize();
        vm.startPrank(seller);
        vm.expectRevert(TokenSaleVault.AlreadyInitialized.selector);
        vault.initialize(address(saleToken), TOKEN_SUPPLY);
        vm.stopPrank();
    }

    function test_revert_zeroAmount() public {
        vm.startPrank(seller);
        saleToken.approve(address(vault), TOKEN_SUPPLY);
        vm.expectRevert(TokenSaleVault.ZeroAmount.selector);
        vault.initialize(address(saleToken), 0);
        vm.stopPrank();
    }

    function test_lockExpiry_zeroBeforeInit() public view {
        assertEq(vault.lockExpiry(), 0);
    }

    function test_lockExpiry_afterInit() public {
        uint256 ts = block.timestamp;
        _initialize();
        assertEq(vault.lockExpiry(), ts + DEPOSIT_WINDOW + LOCK_DURATION);
    }
}

// ── Deposit ───────────────────────────────────────────────────────────────────

contract DepositTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _initialize();
    }

    function test_deposit() public {
        uint256 amount = 1000e18;
        _deposit(buyer1, amount);

        assertEq(vault.deposited(buyer1), amount);
        assertEq(vault.totalDeposited(), amount);
        assertEq(diem.balanceOf(address(vault)), amount);
    }

    function test_deposit_emitsEvent() public {
        uint256 amount = 1000e18;
        vm.startPrank(buyer1);
        diem.approve(address(vault), amount);
        vm.expectEmit(true, false, false, true);
        emit TokenSaleVault.Deposited(buyer1, amount);
        vault.deposit(amount);
        vm.stopPrank();
    }

    function test_deposit_multipleTopUps() public {
        _deposit(buyer1, 3000e18);
        _deposit(buyer1, 4000e18);
        assertEq(vault.deposited(buyer1), 7000e18);
        assertEq(vault.totalDeposited(), 7000e18);
    }

    function test_deposit_multipleBuyers() public {
        _deposit(buyer1, 1000e18);
        _deposit(buyer2, 2000e18);
        _deposit(buyer3, 3000e18);
        assertEq(vault.totalDeposited(), 6000e18);
    }

    function test_deposit_upToCapExact() public {
        _deposit(buyer1, MAX_DEPOSIT_CAP);
        assertEq(vault.deposited(buyer1), MAX_DEPOSIT_CAP);
    }

    function test_revert_notInitialized() public {
        TokenSaleVault uninit =
            new TokenSaleVault(address(diem), seller, LOCK_DURATION, DEPOSIT_WINDOW, 0, 0, 0);
        vm.startPrank(buyer1);
        diem.approve(address(uninit), 1e18);
        vm.expectRevert(TokenSaleVault.NotInitialized.selector);
        uninit.deposit(1e18);
        vm.stopPrank();
    }

    function test_revert_windowClosed() public {
        vm.warp(vault.depositDeadline());
        vm.startPrank(buyer1);
        diem.approve(address(vault), 1e18);
        vm.expectRevert(TokenSaleVault.DepositWindowClosed.selector);
        vault.deposit(1e18);
        vm.stopPrank();
    }

    function test_revert_zeroDeposit() public {
        vm.startPrank(buyer1);
        diem.approve(address(vault), 1e18);
        vm.expectRevert(TokenSaleVault.ZeroDeposit.selector);
        vault.deposit(0);
        vm.stopPrank();
    }

    function test_revert_capExceeded() public {
        vm.startPrank(buyer1);
        diem.approve(address(vault), MAX_DEPOSIT_CAP + 1);
        vm.expectRevert(TokenSaleVault.DepositCapExceeded.selector);
        vault.deposit(MAX_DEPOSIT_CAP + 1);
        vm.stopPrank();
    }

    function test_revert_capExceeded_topUp() public {
        _deposit(buyer1, 6000e18);
        vm.startPrank(buyer1);
        diem.approve(address(vault), MAX_DEPOSIT_CAP);
        vm.expectRevert(TokenSaleVault.DepositCapExceeded.selector);
        vault.deposit(MAX_DEPOSIT_CAP); // 6k + 10k > 10k cap
        vm.stopPrank();
    }

    function test_uncapped_vault() public {
        // maxDeposit = 0 → no cap
        saleToken.mint(seller, TOKEN_SUPPLY);
        TokenSaleVault uncapped =
            new TokenSaleVault(address(diem), seller, LOCK_DURATION, DEPOSIT_WINDOW, 0, 0, 0);
        vm.startPrank(seller);
        saleToken.approve(address(uncapped), TOKEN_SUPPLY);
        uncapped.initialize(address(saleToken), TOKEN_SUPPLY);
        vm.stopPrank();

        uint256 bigDeposit = 1_000_000e18;
        diem.mint(buyer1, bigDeposit);
        vm.startPrank(buyer1);
        diem.approve(address(uncapped), bigDeposit);
        uncapped.deposit(bigDeposit);
        vm.stopPrank();
        assertEq(uncapped.deposited(buyer1), bigDeposit);
    }
}

// ── Claim tokens ──────────────────────────────────────────────────────────────

contract ClaimTokensTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _initialize();
    }

    function test_claimTokens_singleBuyer() public {
        _deposit(buyer1, 1000e18);
        vm.warp(vault.depositDeadline() + 1);

        vm.prank(buyer1);
        vault.claimTokens();

        assertEq(saleToken.balanceOf(buyer1), TOKEN_SUPPLY);
        assertTrue(vault.tokensClaimed(buyer1));
    }

    function test_claimTokens_emitsEvent() public {
        _deposit(buyer1, 1000e18);
        vm.warp(vault.depositDeadline() + 1);

        vm.expectEmit(true, false, false, true);
        emit TokenSaleVault.TokensClaimed(buyer1, TOKEN_SUPPLY);
        vm.prank(buyer1);
        vault.claimTokens();
    }

    function test_claimTokens_proRataEqual() public {
        _deposit(buyer1, 1000e18);
        _deposit(buyer2, 1000e18);
        _deposit(buyer3, 2000e18);
        vm.warp(vault.depositDeadline() + 1);

        vm.prank(buyer1);
        vault.claimTokens();
        vm.prank(buyer2);
        vault.claimTokens();
        vm.prank(buyer3);
        vault.claimTokens();

        uint256 total =
            saleToken.balanceOf(buyer1) + saleToken.balanceOf(buyer2) + saleToken.balanceOf(buyer3);

        // buyer1 and buyer2 each get 25%, buyer3 gets 50%
        assertEq(saleToken.balanceOf(buyer1), TOKEN_SUPPLY / 4);
        assertEq(saleToken.balanceOf(buyer2), TOKEN_SUPPLY / 4);
        assertEq(saleToken.balanceOf(buyer3), TOKEN_SUPPLY / 2);
        // dust (from integer division) stays in vault
        assertLe(total, TOKEN_SUPPLY);
    }

    function test_claimTokens_proRataUnequal() public {
        _deposit(buyer1, 1000e18); // 1/6
        _deposit(buyer2, 2000e18); // 2/6
        _deposit(buyer3, 3000e18); // 3/6
        vm.warp(vault.depositDeadline() + 1);

        vm.prank(buyer1);
        vault.claimTokens();
        vm.prank(buyer2);
        vault.claimTokens();
        vm.prank(buyer3);
        vault.claimTokens();

        uint256 expected1 = TOKEN_SUPPLY / 6;
        uint256 expected2 = TOKEN_SUPPLY * 2 / 6;
        uint256 expected3 = TOKEN_SUPPLY / 2;

        assertEq(saleToken.balanceOf(buyer1), expected1);
        assertEq(saleToken.balanceOf(buyer2), expected2);
        assertEq(saleToken.balanceOf(buyer3), expected3);
    }

    function test_revert_windowOpen() public {
        _deposit(buyer1, 1000e18);
        vm.expectRevert(TokenSaleVault.DepositWindowOpen.selector);
        vm.prank(buyer1);
        vault.claimTokens();
    }

    function test_revert_alreadyClaimed() public {
        _deposit(buyer1, 1000e18);
        vm.warp(vault.depositDeadline() + 1);
        vm.prank(buyer1);
        vault.claimTokens();
        vm.expectRevert(TokenSaleVault.AlreadyClaimed.selector);
        vm.prank(buyer1);
        vault.claimTokens();
    }

    function test_revert_nothingDeposited() public {
        vm.warp(vault.depositDeadline() + 1);
        vm.expectRevert(TokenSaleVault.NothingDeposited.selector);
        vm.prank(buyer1);
        vault.claimTokens();
    }

    function test_revert_noDeposits() public {
        // buyer1 has zero deposited, totalDeposited == 0
        // First check is deposited[msg.sender] == 0 → NothingDeposited
        // To hit NoDeposits we'd need deposited > 0 but totalDeposited == 0, which is impossible.
        // Verify the guard order: NothingDeposited fires first.
        vm.warp(vault.depositDeadline() + 1);
        vm.expectRevert(TokenSaleVault.NothingDeposited.selector);
        vm.prank(buyer1);
        vault.claimTokens();
    }

    function test_revert_notInitialized() public {
        TokenSaleVault uninit =
            new TokenSaleVault(address(diem), seller, LOCK_DURATION, DEPOSIT_WINDOW, 0, 0, 0);
        vm.expectRevert(TokenSaleVault.NotInitialized.selector);
        vm.prank(buyer1);
        uninit.claimTokens();
    }
}

// ── Withdraw DIEM ─────────────────────────────────────────────────────────────

contract WithdrawDiemTest is BaseTest {
    uint256 depositAmount = 1000e18;

    function setUp() public override {
        super.setUp();
        _initialize();
        _deposit(buyer1, depositAmount);
        _deposit(buyer2, 2000e18);
    }

    function test_withdrawDiem() public {
        uint256 balBefore = diem.balanceOf(buyer1);
        vm.warp(vault.lockExpiry() + 1);

        vm.prank(buyer1);
        vault.withdrawDiem();

        assertEq(diem.balanceOf(buyer1), balBefore + depositAmount);
        assertTrue(vault.diemWithdrawn(buyer1));
    }

    function test_withdrawDiem_emitsEvent() public {
        vm.warp(vault.lockExpiry() + 1);
        vm.expectEmit(true, false, false, true);
        emit TokenSaleVault.DiemWithdrawn(buyer1, depositAmount);
        vm.prank(buyer1);
        vault.withdrawDiem();
    }

    function test_withdrawDiem_atExactExpiry() public {
        // exactly at lockExpiry should succeed (block.timestamp < lockExpiry fails at equality)
        vm.warp(vault.lockExpiry());
        vm.prank(buyer1);
        vault.withdrawDiem();
        // buyer1 started with 100k, deposited 1k, withdrew 1k → 100k again
        assertEq(diem.balanceOf(buyer1), 100_000e18);
        assertTrue(vault.diemWithdrawn(buyer1));
    }

    function test_withdrawDiem_multipleBuyers() public {
        vm.warp(vault.lockExpiry() + 1);
        vm.prank(buyer1);
        vault.withdrawDiem();
        vm.prank(buyer2);
        vault.withdrawDiem();
        assertEq(diem.balanceOf(buyer1), 100_000e18); // all DIEM back
        assertEq(diem.balanceOf(buyer2), 100_000e18);
    }

    function test_revert_lockNotExpired() public {
        vm.warp(vault.lockExpiry() - 1);
        vm.expectRevert(TokenSaleVault.LockNotExpired.selector);
        vm.prank(buyer1);
        vault.withdrawDiem();
    }

    function test_revert_alreadyWithdrawn() public {
        vm.warp(vault.lockExpiry() + 1);
        vm.prank(buyer1);
        vault.withdrawDiem();
        vm.expectRevert(TokenSaleVault.AlreadyWithdrawn.selector);
        vm.prank(buyer1);
        vault.withdrawDiem();
    }

    function test_revert_nothingDeposited() public {
        vm.warp(vault.lockExpiry() + 1);
        vm.expectRevert(TokenSaleVault.NothingDeposited.selector);
        vm.prank(buyer3); // buyer3 never deposited
        vault.withdrawDiem();
    }

    function test_revert_notInitialized() public {
        TokenSaleVault uninit =
            new TokenSaleVault(address(diem), seller, LOCK_DURATION, DEPOSIT_WINDOW, 0, 0, 0);
        vm.expectRevert(TokenSaleVault.NotInitialized.selector);
        vm.prank(buyer1);
        uninit.withdrawDiem();
    }
}

// ── Sweep unsold ──────────────────────────────────────────────────────────────

contract SweepUnsoldTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _initialize();
    }

    function _sweepTime() internal view returns (uint256) {
        return vault.lockExpiry() + vault.SWEEP_GRACE();
    }

    function test_sweepUnsold_noDeposits_fullSupply() public {
        vm.warp(_sweepTime() + 1);
        vm.prank(anyone);
        vault.sweepUnsold();
        assertEq(saleToken.balanceOf(seller), TOKEN_SUPPLY);
        assertEq(saleToken.balanceOf(address(vault)), 0);
    }

    function test_sweepUnsold_dust() public {
        // 3 buyers divide a supply that won't divide evenly
        // Use a supply that guarantees dust
        MockERC20 dustSale = new MockERC20("Dust", "DUST");
        dustSale.mint(seller, 7); // 7 tokens
        TokenSaleVault dustVault =
            new TokenSaleVault(address(diem), seller, LOCK_DURATION, DEPOSIT_WINDOW, 0, 0, 0);
        vm.startPrank(seller);
        dustSale.approve(address(dustVault), 7);
        dustVault.initialize(address(dustSale), 7);
        vm.stopPrank();

        // 3 equal buyers → 7/3 = 2 each + 1 dust
        vm.startPrank(buyer1);
        diem.approve(address(dustVault), 1e18);
        dustVault.deposit(1e18);
        vm.stopPrank();
        vm.startPrank(buyer2);
        diem.approve(address(dustVault), 1e18);
        dustVault.deposit(1e18);
        vm.stopPrank();
        vm.startPrank(buyer3);
        diem.approve(address(dustVault), 1e18);
        dustVault.deposit(1e18);
        vm.stopPrank();

        uint256 deadline = dustVault.depositDeadline();
        vm.warp(deadline + 1);
        vm.prank(buyer1);
        dustVault.claimTokens();
        vm.prank(buyer2);
        dustVault.claimTokens();
        vm.prank(buyer3);
        dustVault.claimTokens();

        // 1 token of dust remains
        assertEq(dustSale.balanceOf(address(dustVault)), 1);

        vm.warp(deadline + LOCK_DURATION + dustVault.SWEEP_GRACE() + 1);
        vm.prank(anyone);
        dustVault.sweepUnsold();
        assertEq(dustSale.balanceOf(seller), 1);
    }

    function test_sweepUnsold_emitsEvent() public {
        vm.warp(_sweepTime() + 1);
        vm.expectEmit(false, false, false, true);
        emit TokenSaleVault.UnsoldSwept(TOKEN_SUPPLY);
        vm.prank(anyone);
        vault.sweepUnsold();
    }

    function test_sweepUnsold_calledByAnyone() public {
        vm.warp(_sweepTime() + 1);
        vm.prank(anyone); // not seller
        vault.sweepUnsold();
        assertEq(saleToken.balanceOf(seller), TOKEN_SUPPLY);
    }

    function test_sweepUnsold_zeroBalance_noRevert() public {
        // all tokens claimed, vault empty
        _deposit(buyer1, 1000e18);
        vm.warp(vault.depositDeadline() + 1);
        vm.prank(buyer1); // gets full supply (only buyer)
        vault.claimTokens();

        vm.warp(_sweepTime() + 1);
        vm.prank(anyone);
        vault.sweepUnsold(); // should not revert even though balance == 0
        assertEq(saleToken.balanceOf(seller), 0); // seller got nothing (no dust)
    }

    function test_revert_sweepTooEarly_beforeLockExpiry() public {
        vm.warp(vault.lockExpiry() - 1);
        vm.expectRevert(TokenSaleVault.SweepTooEarly.selector);
        vault.sweepUnsold();
    }

    function test_revert_sweepTooEarly_duringGrace() public {
        vm.warp(_sweepTime() - 1);
        vm.expectRevert(TokenSaleVault.SweepTooEarly.selector);
        vault.sweepUnsold();
    }

    function test_revert_notInitialized() public {
        TokenSaleVault uninit =
            new TokenSaleVault(address(diem), seller, LOCK_DURATION, DEPOSIT_WINDOW, 0, 0, 0);
        vm.warp(block.timestamp + 365 days + 14 days + 1);
        vm.expectRevert(TokenSaleVault.NotInitialized.selector);
        uninit.sweepUnsold();
    }
}

// ── Views ─────────────────────────────────────────────────────────────────────

contract ViewsTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _initialize();
    }

    function test_getShare_beforeDeposit() public view {
        assertEq(vault.getShare(buyer1), 0);
    }

    function test_getShare_singleDeposit() public {
        _deposit(buyer1, 1000e18);
        // buyer1 is only depositor → 100% share
        assertEq(vault.getShare(buyer1), TOKEN_SUPPLY);
    }

    function test_getShare_multipleDepositors() public {
        _deposit(buyer1, 1000e18);
        _deposit(buyer2, 3000e18);
        // buyer1: 1k/4k = 25%
        assertEq(vault.getShare(buyer1), TOKEN_SUPPLY / 4);
        // buyer2: 3k/4k = 75%
        assertEq(vault.getShare(buyer2), TOKEN_SUPPLY * 3 / 4);
    }

    function test_getShare_zeroTotalDeposited() public view {
        // no deposits → 0
        assertEq(vault.getShare(buyer1), 0);
    }

    function test_effectivePriceWei_noDeposits() public view {
        assertEq(vault.effectivePriceWei(), 0);
    }

    function test_effectivePriceWei_withDeposits() public {
        uint256 amount = MAX_DEPOSIT_CAP; // 10k DIEM — within cap
        _deposit(buyer1, amount);
        uint256 expected = amount * 1e18 / TOKEN_SUPPLY;
        assertEq(vault.effectivePriceWei(), expected);
    }

    function test_effectivePriceWei_oversubscribed() public {
        // 3 buyers × 10k = 30k DIEM, well above TARGET_DIEM (100k would need uncapped)
        // demonstrates formula works regardless of relative size to target
        _deposit(buyer1, MAX_DEPOSIT_CAP);
        _deposit(buyer2, MAX_DEPOSIT_CAP);
        _deposit(buyer3, MAX_DEPOSIT_CAP);
        uint256 totalDep = MAX_DEPOSIT_CAP * 3;
        uint256 expected = totalDep * 1e18 / TOKEN_SUPPLY;
        assertEq(vault.effectivePriceWei(), expected);
    }

    function test_lockExpiry_beforeInit() public {
        TokenSaleVault uninit =
            new TokenSaleVault(address(diem), seller, LOCK_DURATION, DEPOSIT_WINDOW, 0, 0, 0);
        assertEq(uninit.lockExpiry(), 0);
    }

    function test_lockExpiry_afterInit() public view {
        // Set in BaseTest setup via _initialize in subclass; here setUp calls _initialize
        // depositDeadline = ts + DEPOSIT_WINDOW; lockExpiry = depositDeadline + lockDuration
        uint256 expected = vault.depositDeadline() + LOCK_DURATION;
        assertEq(vault.lockExpiry(), expected);
    }
}

// ── Full lifecycle ────────────────────────────────────────────────────────────

contract LifecycleTest is BaseTest {
    function test_fullLifecycle() public {
        // 1. Initialize
        _initialize();

        // 2. Three buyers deposit during window
        _deposit(buyer1, 1000e18);
        _deposit(buyer2, 2000e18);
        _deposit(buyer3, 1000e18);
        // total = 4_000e18

        // 3. Window closes
        vm.warp(vault.depositDeadline() + 1);

        // 4. All claim tokens
        vm.prank(buyer1);
        vault.claimTokens();
        vm.prank(buyer2);
        vault.claimTokens();
        vm.prank(buyer3);
        vault.claimTokens();

        assertEq(saleToken.balanceOf(buyer1), TOKEN_SUPPLY / 4);
        assertEq(saleToken.balanceOf(buyer2), TOKEN_SUPPLY / 2);
        assertEq(saleToken.balanceOf(buyer3), TOKEN_SUPPLY / 4);

        // 5. Lock expires — all withdraw DIEM
        vm.warp(vault.lockExpiry() + 1);
        vm.prank(buyer1);
        vault.withdrawDiem();
        vm.prank(buyer2);
        vault.withdrawDiem();
        vm.prank(buyer3);
        vault.withdrawDiem();

        assertEq(diem.balanceOf(buyer1), 100_000e18);
        assertEq(diem.balanceOf(buyer2), 100_000e18);
        assertEq(diem.balanceOf(buyer3), 100_000e18);

        // 6. Sweep any remaining dust
        vm.warp(vault.lockExpiry() + vault.SWEEP_GRACE() + 1);
        uint256 dustBefore = saleToken.balanceOf(address(vault));
        vm.prank(anyone);
        vault.sweepUnsold();
        assertEq(saleToken.balanceOf(seller), dustBefore); // seller gets dust
    }

    function test_lifecycle_partialParticipation() public {
        // Only buyer1 claims; buyer2 and buyer3 never do
        _initialize();
        _deposit(buyer1, 1000e18);
        _deposit(buyer2, 3000e18);

        vm.warp(vault.depositDeadline() + 1);
        vm.prank(buyer1);
        vault.claimTokens();
        // buyer2 never claims

        vm.warp(vault.lockExpiry() + vault.SWEEP_GRACE() + 1);
        uint256 unclaimed = saleToken.balanceOf(address(vault)); // buyer2's 75% share
        vm.prank(seller);
        vault.sweepUnsold();
        assertEq(saleToken.balanceOf(seller), unclaimed);
    }
}
