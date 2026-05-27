// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {InferenceVault} from "../../src/vault/InferenceVault.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

contract InferenceVaultTest is Test {
    InferenceVault vault;
    ERC20Mock diem;

    address treasury = makeAddr("treasury");
    address feeRouter = makeAddr("feeRouter");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        diem = new ERC20Mock();
        vault = new InferenceVault(address(diem), treasury, address(this));
        vault.setFeeRouter(feeRouter);

        diem.mint(alice, 1000e18);
        diem.mint(bob, 1000e18);
        diem.mint(feeRouter, 10_000e18);

        vm.prank(alice);
        diem.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        diem.approve(address(vault), type(uint256).max);
        vm.prank(feeRouter);
        diem.approve(address(vault), type(uint256).max);
    }

    // --- Core deposit ---

    function test_deposit_mintsShares() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(100e18, alice);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice) + vault.balanceOf(treasury), vault.totalSupply());
    }

    function test_depositFee_lowTier_10bps() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        // 0.1% fee = 1 DIEM worth of shares goes to treasury
        assertGt(vault.balanceOf(treasury), 0, "treasury receives fee shares");
    }

    // --- creditDIEM ---

    function test_creditDIEM_noNewShares() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 supplyBefore = vault.totalSupply();

        vm.prank(feeRouter);
        vault.creditDIEM(10e18);

        assertEq(vault.totalSupply(), supplyBefore, "no new shares on creditDIEM");
    }

    function test_creditDIEM_rateIncreases() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 rateBefore = vault.convertToAssets(1e18);

        vm.prank(feeRouter);
        vault.creditDIEM(10e18);

        assertGt(vault.convertToAssets(1e18), rateBefore, "rate must improve after creditDIEM");
    }

    function test_creditDIEM_onlyFeeRouter() public {
        vm.expectRevert(abi.encodeWithSignature("NotFeeRouter()"));
        vault.creditDIEM(1e18);
    }

    // --- Withdrawals disabled ---

    function test_maxWithdraw_zeroWhenDisabled() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        assertEq(vault.maxWithdraw(alice), 0, "withdrawals must be disabled at launch");
    }

    function test_maxRedeem_zeroWhenDisabled() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        assertEq(vault.maxRedeem(alice), 0);
    }

    // --- Withdrawal timelock ---

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

    function test_initiateWithdrawals_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.initiateEnableWithdrawals();
    }

    // --- Recursive accounting (VOL exclusion) ---

    function test_vaultOwnedShares_excludedFromRate() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 rateBefore = vault.convertToAssets(1e18);

        // Simulate vault-owned liquidity: alice transfers half her shares to vault
        uint256 half = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        vault.transfer(address(vault), half);

        // Rate must not change — VOL is excluded from effective supply
        assertEq(vault.convertToAssets(1e18), rateBefore, "VOL exclusion broken");
    }

    function test_vaultOwnedShares_returnsVaultBalance() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 half = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        vault.transfer(address(vault), half);
        assertEq(vault.vaultOwnedShares(), half);
    }

    // --- Rate monotonicity ---

    function test_rate_monotoneAfterMultipleCredits() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);

        uint256 rate0 = vault.convertToAssets(1e18);
        vm.prank(feeRouter);
        vault.creditDIEM(20e18);
        uint256 rate1 = vault.convertToAssets(1e18);
        vm.prank(feeRouter);
        vault.creditDIEM(20e18);
        uint256 rate2 = vault.convertToAssets(1e18);

        assertGt(rate1, rate0);
        assertGt(rate2, rate1);
    }
}
