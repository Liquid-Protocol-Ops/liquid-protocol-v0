// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {InferenceVault} from "../../src/vault/InferenceVault.sol";
import {MockDIEM} from "./mocks/MockDIEM.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests — MockDIEM (no fork required)
// ─────────────────────────────────────────────────────────────────────────────
contract InferenceVaultTest is Test {
    InferenceVault vault;
    MockDIEM diem;

    address treasury  = makeAddr("treasury");
    address feeRouter = makeAddr("feeRouter");
    address alice     = makeAddr("alice");
    address bob       = makeAddr("bob");

    function setUp() public {
        diem = new MockDIEM();
        vault = new InferenceVault(address(diem), treasury, address(this));
        vault.setFeeRouter(feeRouter);

        diem.mint(alice,     1_000e18);
        diem.mint(bob,       1_000e18);
        diem.mint(feeRouter, 10_000e18);

        vm.prank(alice);     diem.approve(address(vault), type(uint256).max);
        vm.prank(bob);       diem.approve(address(vault), type(uint256).max);
        vm.prank(feeRouter); diem.approve(address(vault), type(uint256).max);
    }

    // ── Staking mechanics ─────────────────────────────────────────────────

    function test_deposit_stakesAllDIEMInVenice() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        (uint256 staked,,) = diem.stakedInfos(address(vault));
        assertEq(staked, 100e18, "all deposited DIEM must be staked");
    }

    function test_deposit_vaultLiquidBalanceIsZero() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        assertEq(diem.balanceOf(address(vault)), 0, "vault holds no idle DIEM after deposit");
    }

    function test_totalAssets_sumsStalkedUnstakingAndIdle() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Manually credit some idle DIEM to the vault to simulate pre-stake idle
        diem.mint(address(vault), 5e18);

        // totalAssets = staked(100) + idle(5) + unstaking(0)
        assertEq(vault.totalAssets(), 105e18);
    }

    function test_totalAssets_includesUnstakingBucket() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Owner initiates unstake of 30 DIEM
        vault.initiateUnstake(30e18);

        // staked=70, unstaking=30, idle=0 → totalAssets=100
        assertEq(vault.totalAssets(), 100e18);
    }

    function test_completeUnstake_movesFromUnstakingToIdle() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vault.initiateUnstake(100e18);

        // Fast-forward past 24h cooldown
        vm.warp(block.timestamp + 86_401);
        vault.completeUnstake();

        assertEq(diem.balanceOf(address(vault)), 100e18, "DIEM must be liquid after unstake");
        (uint256 staked, uint256 unstaking,) = diem.stakedInfos(address(vault));
        assertEq(staked, 0);
        assertEq(unstaking, 0);
    }

    // ── Deposit fee ───────────────────────────────────────────────────────

    function test_deposit_lowTierFee_10bps() public {
        vm.prank(alice);
        vault.deposit(1_000e18, alice);
        assertGt(vault.balanceOf(treasury), 0, "treasury must receive fee shares");
    }

    function test_deposit_feeSharesAndUserSharesSumToTotalSupply() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        assertEq(vault.balanceOf(alice) + vault.balanceOf(treasury), vault.totalSupply());
    }

    function test_deposit_highTierFee_50bps_aboveThreshold() public {
        // Fund alice above TVL_FEE_THRESHOLD
        diem.mint(alice, 5_000_001e18);
        vm.startPrank(alice);
        diem.approve(address(vault), type(uint256).max);
        vault.deposit(5_000_001e18, alice);
        vm.stopPrank();

        assertEq(vault.currentDepositFeeBps(), 50);
    }

    // ── creditDIEM ────────────────────────────────────────────────────────

    function test_creditDIEM_stakesInVenice() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        (uint256 stakedBefore,,) = diem.stakedInfos(address(vault));

        vm.prank(feeRouter);
        vault.creditDIEM(10e18);

        (uint256 stakedAfter,,) = diem.stakedInfos(address(vault));
        assertEq(stakedAfter, stakedBefore + 10e18, "credited DIEM must be staked");
    }

    function test_creditDIEM_noNewShares() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 supplyBefore = vault.totalSupply();

        vm.prank(feeRouter);
        vault.creditDIEM(10e18);

        assertEq(vault.totalSupply(), supplyBefore, "creditDIEM must not mint shares");
    }

    function test_creditDIEM_increasesRate() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 rateBefore = vault.convertToAssets(1e18);

        vm.prank(feeRouter);
        vault.creditDIEM(10e18);

        assertGt(vault.convertToAssets(1e18), rateBefore, "rate must rise after creditDIEM");
    }

    function test_creditDIEM_onlyFeeRouter() public {
        vm.expectRevert(abi.encodeWithSignature("NotFeeRouter()"));
        vault.creditDIEM(1e18);
    }

    // ── Withdrawal gate ───────────────────────────────────────────────────

    function test_maxWithdraw_zeroWhenDisabled() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        assertEq(vault.maxWithdraw(alice), 0);
    }

    function test_maxRedeem_zeroWhenDisabled() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        assertEq(vault.maxRedeem(alice), 0);
    }

    function test_enableWithdrawals_requiresInitiation() public {
        vm.expectRevert(abi.encodeWithSignature("WithdrawalNotInitiated()"));
        vault.enableWithdrawals();
    }

    function test_enableWithdrawals_timelockBlocks() public {
        vault.initiateEnableWithdrawals();
        vm.expectRevert(abi.encodeWithSignature("TimelockActive()"));
        vault.enableWithdrawals();
    }

    function test_enableWithdrawals_succeedsAfter14Days() public {
        vault.initiateEnableWithdrawals();
        vm.warp(block.timestamp + 14 days + 1);
        vault.enableWithdrawals();
        assertTrue(vault.withdrawalsEnabled());
    }

    function test_initiateEnableWithdrawals_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.initiateEnableWithdrawals();
    }

    function test_initiateEnableWithdrawals_cannotDoubleTrigger() public {
        vault.initiateEnableWithdrawals();
        vm.expectRevert(abi.encodeWithSignature("AlreadyInitiated()"));
        vault.initiateEnableWithdrawals();
    }

    // ── Admin gating ──────────────────────────────────────────────────────

    function test_initiateUnstake_onlyOwner() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(alice);
        vm.expectRevert();
        vault.initiateUnstake(50e18);
    }

    // ── Rate monotonicity ─────────────────────────────────────────────────

    function test_rate_monotoneAfterMultipleDepositsAndCredits() public {
        vm.prank(alice); vault.deposit(100e18, alice);
        vm.prank(bob);   vault.deposit(100e18, bob);

        uint256 r0 = vault.convertToAssets(1e18);
        vm.prank(feeRouter); vault.creditDIEM(20e18);
        uint256 r1 = vault.convertToAssets(1e18);
        vm.prank(feeRouter); vault.creditDIEM(20e18);
        uint256 r2 = vault.convertToAssets(1e18);

        assertGt(r1, r0);
        assertGt(r2, r1);
    }

    function test_rate_notDecreaseOnNewDeposit() public {
        vm.prank(alice); vault.deposit(100e18, alice);
        uint256 rBefore = vault.convertToAssets(1e18);

        vm.prank(bob); vault.deposit(100e18, bob);
        uint256 rAfter = vault.convertToAssets(1e18);

        // Due to rounding/fee, rate may stay flat or increase slightly (fee to treasury)
        // but must never decrease
        assertGe(rAfter, rBefore - 1, "rate must not decrease on deposit");
    }

    // ── VOL accounting ────────────────────────────────────────────────────

    function test_vaultOwnedShares_excludedFromEffectiveRate() public {
        vm.prank(alice); vault.deposit(100e18, alice);
        uint256 rateBefore = vault.convertToAssets(1e18);

        uint256 half = vault.balanceOf(alice) / 2;
        vm.prank(alice); vault.transfer(address(vault), half);

        assertEq(vault.convertToAssets(1e18), rateBefore, "VOL must not distort rate");
    }

    function test_vaultOwnedShares_returnsVaultBalance() public {
        vm.prank(alice); vault.deposit(100e18, alice);
        uint256 half = vault.balanceOf(alice) / 2;
        vm.prank(alice); vault.transfer(address(vault), half);
        assertEq(vault.vaultOwnedShares(), half);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Fork tests — real DIEM on Base mainnet
// ─────────────────────────────────────────────────────────────────────────────
contract InferenceVaultForkTest is Test {
    address constant DIEM  = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;

    InferenceVault vault;
    address alice = makeAddr("alice");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        vault = new InferenceVault(DIEM, makeAddr("treasury"), address(this));
        vault.setFeeRouter(makeAddr("feeRouter"));

        deal(DIEM, alice, 1_000e18);
        vm.prank(alice);
        IERC20(DIEM).approve(address(vault), type(uint256).max);
    }

    function test_fork_deposit_stakesInVenice() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // balanceOf must be 0 — staked, not idle
        assertEq(IERC20(DIEM).balanceOf(address(vault)), 0);

        // stakedInfos.stakedAmount must match deposit
        (bool success, bytes memory data) = DIEM.staticcall(
            abi.encodeWithSignature("stakedInfos(address)", address(vault))
        );
        assertTrue(success);
        (uint256 staked,,) = abi.decode(data, (uint256, uint256, uint256));
        assertEq(staked, 100e18, "staked amount must equal deposit");
    }

    function test_fork_totalAssets_matchesStakedInfos() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        assertEq(vault.totalAssets(), 100e18);
    }

    function test_fork_multipleDepositors_rateConsistent() public {
        address bob = makeAddr("bob");
        deal(DIEM, bob, 1_000e18);
        vm.prank(bob);
        IERC20(DIEM).approve(address(vault), type(uint256).max);

        vm.prank(alice); vault.deposit(100e18, alice);
        vm.prank(bob);   vault.deposit(100e18, bob);

        // Each depositor should get approximately equal shares (minus fee)
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 bobShares   = vault.balanceOf(bob);
        // Bob gets same or fewer shares due to fee-tier progression — at most 1% diff
        assertApproxEqRel(aliceShares, bobShares, 0.01e18);
    }
}
