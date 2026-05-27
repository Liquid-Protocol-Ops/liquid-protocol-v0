// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {InferenceVault} from "../../../src/vault/InferenceVault.sol";

// Fork test against Base mainnet DIEM token
contract PhaseAIntegrationTest is Test {
    address constant DIEM     = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;

    InferenceVault vault;
    address treasury  = makeAddr("treasury");
    address feeRouter = makeAddr("feeRouter");
    address alice     = makeAddr("alice");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));

        vault = new InferenceVault(DIEM, treasury, address(this));
        vault.setFeeRouter(feeRouter);

        // Fund alice with DIEM via deal
        deal(DIEM, alice, 1_000e18);
        deal(DIEM, feeRouter, 10_000e18);

        vm.prank(alice);     IERC20(DIEM).approve(address(vault), type(uint256).max);
        vm.prank(feeRouter); IERC20(DIEM).approve(address(vault), type(uint256).max);
    }

    function test_fork_depositAndCredit() public {
        // Alice deposits 100 DIEM
        vm.prank(alice);
        uint256 shares = vault.deposit(100e18, alice);
        assertGt(shares, 0);
        assertEq(vault.maxWithdraw(alice), 0, "withdrawals disabled at launch");

        // FeeRouter credits 10 DIEM (non-dilutive)
        uint256 supplyBefore = vault.totalSupply();
        uint256 rateBefore   = vault.convertToAssets(1e18);
        vm.prank(feeRouter);
        vault.creditDIEM(10e18);

        assertEq(vault.totalSupply(), supplyBefore, "no new shares on creditDIEM");
        assertGt(vault.convertToAssets(1e18), rateBefore, "rate improved");
    }

    function test_fork_withdrawalTimelock() public {
        vault.initiateEnableWithdrawals();
        vm.expectRevert(abi.encodeWithSignature("TimelockActive()"));
        vault.enableWithdrawals();

        vm.warp(block.timestamp + 14 days + 1);
        vault.enableWithdrawals();
        assertTrue(vault.withdrawalsEnabled());
    }

    function test_fork_volExclusionOnChain() public {
        vm.prank(alice);
        vault.deposit(200e18, alice);
        uint256 rateBefore = vault.convertToAssets(1e18);

        // Simulate VOL: vault acquires its own shares
        uint256 vol = vault.balanceOf(alice) / 4;
        vm.prank(alice);
        vault.transfer(address(vault), vol);

        assertEq(vault.convertToAssets(1e18), rateBefore, "VOL must not dilute rate");
    }
}
