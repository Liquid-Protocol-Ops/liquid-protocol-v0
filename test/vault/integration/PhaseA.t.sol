// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {InferenceVault} from "../../../src/vault/InferenceVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

// Fork test against Base mainnet DIEM token
contract PhaseAIntegrationTest is Test {
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;

    InferenceVault vault;
    address treasury = makeAddr("treasury");
    address venueAdapter = makeAddr("venueAdapter");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));

        vault = new InferenceVault(DIEM, treasury, makeAddr("veniceSigner"), address(this));
        vault.setVenueAdapter(venueAdapter, true);

        deal(DIEM, alice, 1000e18);
        deal(DIEM, venueAdapter, 10_000e18);

        vm.prank(alice);
        IERC20(DIEM).approve(address(vault), type(uint256).max);
        vm.prank(venueAdapter);
        IERC20(DIEM).approve(address(vault), type(uint256).max);
    }

    function test_fork_depositAndCredit() public {
        // Alice deposits 100 DIEM
        vm.prank(alice);
        uint256 shares = vault.deposit(100e18, alice);
        assertGt(shares, 0);
        assertEq(vault.maxWithdraw(alice), 0, "withdrawals disabled at launch");

        // FeeRouter credits 10 DIEM. creditDIEM is non-dilutive to depositors:
        // existing holders' share balances are untouched and the rate rises.
        // (The yieldFeeBps cut is minted as fee shares to the treasury, not to depositors.)
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 rateBefore = vault.convertToAssets(1e18);
        vm.prank(venueAdapter);
        vault.creditDIEM(10e18);

        assertEq(vault.balanceOf(alice), aliceShares, "depositor shares unchanged by creditDIEM");
        assertGt(vault.convertToAssets(1e18), rateBefore, "rate improved");
    }

    function test_fork_withdrawalQueue() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 reqId = vault.requestRedeem(shares, alice);

        // Warp past minBatchOpenSecs (1 day) then flush
        vm.warp(block.timestamp + vault.minBatchOpenSecs() + 1);
        vault.flush();

        (,, uint64 batchUnlockAt,,) = vault.unstakeBatches(1);
        assertGt(batchUnlockAt, 0, "batch must have a cooldown set");

        vm.warp(batchUnlockAt + 1);
        vault.settle();
        vault.claimRedeem(reqId);

        assertGt(IERC20(DIEM).balanceOf(alice), 0, "alice must receive DIEM");
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
