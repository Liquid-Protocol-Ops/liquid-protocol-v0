// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {InferenceVault} from "../../src/vault/InferenceVault.sol";
import {MockDIEM} from "./mocks/MockDIEM.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, Vm} from "forge-std/Test.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests — MockDIEM (no fork required)
// ─────────────────────────────────────────────────────────────────────────────
contract InferenceVaultTest is Test {
    InferenceVault vault;
    MockDIEM diem;

    address treasury = makeAddr("treasury");
    address venueAdapter = makeAddr("venueAdapter");
    address veniceSigner = makeAddr("veniceSigner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        diem = new MockDIEM();
        vault = new InferenceVault(address(diem), treasury, veniceSigner, address(this));
        vault.setVenueAdapter(venueAdapter, true);

        diem.mint(alice, 1000e18);
        diem.mint(bob, 1000e18);
        diem.mint(venueAdapter, 10_000e18);

        vm.prank(alice);
        diem.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        diem.approve(address(vault), type(uint256).max);
        vm.prank(venueAdapter);
        diem.approve(address(vault), type(uint256).max);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    // Warp past minBatchOpenSecs so flush() is allowed on a non-full batch.
    function _warpBatchOpen() internal {
        vm.warp(block.timestamp + vault.minBatchOpenSecs() + 1);
    }

    // Full requestRedeem → flush → settle → claimRedeem lifecycle.
    // Returns DIEM delta for receiver. NOTE: captures shares BEFORE prank.
    function _redeem(address user, address receiver) internal returns (uint256 diem_) {
        uint256 shares = vault.balanceOf(user);
        vm.prank(user);
        uint256 reqId = vault.requestRedeem(shares, receiver);
        _warpBatchOpen();
        vault.flush();
        vm.warp(block.timestamp + diem.cooldownDuration() + 1);
        vault.settle();
        uint256 before = diem.balanceOf(receiver);
        vault.claimRedeem(reqId);
        diem_ = diem.balanceOf(receiver) - before;
    }

    // ── Staking mechanics ────────────────────────────────────────────────────

    function test_deposit_stakesAllDIEMInVenice() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        (uint256 staked,,) = diem.stakedInfos(address(vault));
        assertEq(staked, 100e18);
    }

    function test_deposit_vaultLiquidBalanceIsZero() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        assertEq(diem.balanceOf(address(vault)), 0);
    }

    function test_totalAssets_sumsStakedUnstakingAndIdle() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        diem.mint(address(vault), 5e18);
        assertEq(vault.totalAssets(), 105e18);
    }

    // pendingWithdrawalDiem is set at requestRedeem (not at flush).
    // totalAssets() must exclude it immediately — oracle always clean.
    function test_totalAssets_excludesPendingWithdrawal() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);
        uint256 assetsBefore = vault.totalAssets();

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares, alice);

        uint256 pending = vault.pendingWithdrawalDiem();
        assertGt(pending, 0);
        assertApproxEqAbs(vault.totalAssets(), assetsBefore - pending, 1);
    }

    // ── Deposit fee ──────────────────────────────────────────────────────────

    function test_deposit_fee_250bps() public {
        uint256 depositAmount = 1000e18;
        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        // treasury receives 2.5% of deposit as wstDIEM shares
        uint256 expectedFee = depositAmount * 250 / 10_000;
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(treasury)), expectedFee, 1e15);
    }

    function test_deposit_feeSharesAndUserSharesSumToTotalSupply() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        assertEq(vault.balanceOf(alice) + vault.balanceOf(treasury), vault.totalSupply());
    }

    function test_deposit_feeBps_isFlat250() public {
        assertEq(vault.currentDepositFeeBps(), 250);
    }

    function test_setDepositFeeBps_ownerCanUpdate() public {
        vault.setDepositFeeBps(100);
        assertEq(vault.currentDepositFeeBps(), 100);
    }

    function test_setDepositFeeBps_revertsAboveCap() public {
        vm.expectRevert("exceeds 10% cap");
        vault.setDepositFeeBps(1001);
    }

    function test_setYieldFeeBps_ownerCanUpdate() public {
        vault.setYieldFeeBps(1000);
        assertEq(vault.yieldFeeBps(), 1000);
    }

    function test_setYieldFeeBps_revertsAboveCap() public {
        vm.expectRevert("exceeds 20% cap");
        vault.setYieldFeeBps(2001);
    }

    function test_creditDIEM_yieldFeeMintsToTreasury() public {
        uint256 creditAmount = 100e18;
        diem.mint(venueAdapter, creditAmount);

        // Snapshot expected fee shares at pre-credit rate
        uint256 feeAmount = creditAmount * vault.yieldFeeBps() / 10_000;
        uint256 expectedFeeShares = vault.convertToShares(feeAmount);

        uint256 treasurySharesBefore = vault.balanceOf(treasury);
        vm.prank(venueAdapter);
        vault.creditDIEM(creditAmount);

        uint256 newTreasuryShares = vault.balanceOf(treasury) - treasurySharesBefore;
        assertApproxEqAbs(newTreasuryShares, expectedFeeShares, 1e12);
    }

    function test_creditDIEM_zeroYieldFee_noTreasuryMint() public {
        vault.setYieldFeeBps(0);
        uint256 creditAmount = 100e18;
        diem.mint(venueAdapter, creditAmount);

        uint256 supplyBefore = vault.totalSupply();
        vm.prank(venueAdapter);
        vault.creditDIEM(creditAmount);
        // No new shares minted (fee=0), rate rises purely
        assertEq(vault.totalSupply(), supplyBefore);
    }

    // ── maxTotalStake cap ────────────────────────────────────────────────────

    function test_deposit_revertsWhenCapExceeded() public {
        vault.setMaxTotalStake(50e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("MaxStakeExceeded()"));
        vault.deposit(100e18, alice);
    }

    function test_deposit_succeedsAtExactCap() public {
        vault.setMaxTotalStake(100e18);
        vm.prank(alice);
        vault.deposit(100e18, alice);
        assertGt(vault.balanceOf(alice), 0);
    }

    // ── creditDIEM — yield accrual ───────────────────────────────────────────

    function test_creditDIEM_stakesInVenice() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        (uint256 stakedBefore,,) = diem.stakedInfos(address(vault));
        vm.prank(venueAdapter);
        vault.creditDIEM(10e18);
        (uint256 stakedAfter,,) = diem.stakedInfos(address(vault));
        assertEq(stakedAfter, stakedBefore + 10e18);
    }

    function test_creditDIEM_mintsOnlyFeeShares() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 supplyBefore = vault.totalSupply();
        uint256 creditAmount = 10e18;
        uint256 expectedFeeShares =
            vault.convertToShares(creditAmount * vault.yieldFeeBps() / 10_000);
        vm.prank(venueAdapter);
        vault.creditDIEM(creditAmount);
        assertApproxEqAbs(vault.totalSupply() - supplyBefore, expectedFeeShares, 1e12);
    }

    function test_creditDIEM_increasesRate() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 rateBefore = vault.convertToAssets(1e18);
        vm.prank(venueAdapter);
        vault.creditDIEM(10e18);
        assertGt(vault.convertToAssets(1e18), rateBefore);
    }

    function test_creditDIEM_onlyVenueAdapter() public {
        vm.expectRevert(abi.encodeWithSignature("NotVenueAdapter()"));
        vault.creditDIEM(1e18);
    }

    // ── creditWstDIEM — inference source revenue reinvestment ─────────────────

    // An inference source routes their cut as wstDIEM so it compounds
    // rather than sitting idle. No entry fee — it's earned revenue.
    function test_creditWstDIEM_mintsSharesAtCurrentRate() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 rateBefore = vault.convertToAssets(1e18);

        address source = makeAddr("source");
        vault.setVenueAdapter(source, true);
        diem.mint(source, 20e18);
        vm.prank(source);
        diem.approve(address(vault), type(uint256).max);

        uint256 supplyBefore = vault.totalSupply();
        vm.prank(source);
        vault.creditWstDIEM(20e18, source);

        assertGt(vault.balanceOf(source), 0, "source must receive wstDIEM");
        // Rate must be unchanged — source paid for the shares with DIEM
        assertApproxEqAbs(
            vault.convertToAssets(1e18),
            rateBefore,
            1,
            "rate must not change when source deposits via creditWstDIEM"
        );
        assertGt(vault.totalSupply(), supplyBefore, "supply increased");
    }

    // creditWstDIEM has no entry fee — all DIEM becomes backing
    function test_creditWstDIEM_noFee_fullBacking() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        address source = makeAddr("source");
        vault.setVenueAdapter(source, true);
        diem.mint(source, 10e18);
        vm.prank(source);
        diem.approve(address(vault), type(uint256).max);

        uint256 shares = vault.previewDeposit(10e18); // shares WITH fee
        vm.prank(source);
        vault.creditWstDIEM(10e18, source);
        // Should have received MORE shares than previewDeposit since no fee applies
        assertGe(
            vault.balanceOf(source),
            shares,
            "creditWstDIEM must issue >= shares of a fee-bearing deposit"
        );
    }

    // Caller and recipient can differ — source credits wstDIEM to another address
    function test_creditWstDIEM_differentRecipient() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        address source = makeAddr("source");
        address operator = makeAddr("operator");
        vault.setVenueAdapter(source, true);
        diem.mint(source, 10e18);
        vm.prank(source);
        diem.approve(address(vault), type(uint256).max);

        vm.prank(source);
        vault.creditWstDIEM(10e18, operator);
        assertGt(vault.balanceOf(operator), 0);
        assertEq(vault.balanceOf(source), 0, "source gets nothing when operator is recipient");
    }

    function test_creditWstDIEM_onlyVenueAdapter() public {
        vm.expectRevert(abi.encodeWithSignature("NotVenueAdapter()"));
        vault.creditWstDIEM(1e18, alice);
    }

    // The intended split pattern: source earns 100 DIEM, routes 80 to holders
    // via creditDIEM and reinvests 20 as wstDIEM via creditWstDIEM.
    function test_creditWstDIEM_splitPattern() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);

        address source = makeAddr("source");
        vault.setVenueAdapter(source, true);
        diem.mint(source, 100e18);
        vm.prank(source);
        diem.approve(address(vault), type(uint256).max);

        uint256 rateBefore = vault.convertToAssets(1e18);

        // 80 DIEM to holders (rate rises), 20 DIEM to source (wstDIEM)
        vm.startPrank(source);
        vault.creditDIEM(80e18);
        vault.creditWstDIEM(20e18, source);
        vm.stopPrank();

        assertGt(vault.convertToAssets(1e18), rateBefore, "holders appreciated");
        assertGt(vault.balanceOf(source), 0, "source has wstDIEM position");
    }

    // ── InferenceToken registry ───────────────────────────────────────────────

    function test_addInferenceToken_registers() public {
        address token = makeAddr("inferenceToken");
        vault.addInferenceToken(token, true);
        assertTrue(vault.isInferenceToken(token));
        assertEq(vault.inferenceTokenList().length, 1);
        assertEq(vault.inferenceTokenList()[0], token);
    }

    function test_addInferenceToken_deregister() public {
        address token = makeAddr("inferenceToken");
        vault.addInferenceToken(token, true);
        vault.addInferenceToken(token, false);
        assertFalse(vault.isInferenceToken(token));
        // List still has the entry (deregister is soft — flag only)
        assertEq(vault.inferenceTokenList().length, 1);
    }

    function test_addInferenceToken_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.addInferenceToken(makeAddr("token"), true);
    }

    function test_venueAdapter_multipleAdapters() public {
        address adapter2 = makeAddr("adapter2");
        vault.setVenueAdapter(adapter2, true);
        diem.mint(adapter2, 100e18);
        vm.prank(adapter2);
        diem.approve(address(vault), type(uint256).max);

        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(venueAdapter);
        vault.creditDIEM(10e18);
        vm.prank(adapter2);
        vault.creditDIEM(10e18);

        (uint256 staked,,) = diem.stakedInfos(address(vault));
        assertEq(staked, 120e18);
    }

    function test_venueAdapter_revoked_reverts() public {
        vault.setVenueAdapter(venueAdapter, false);
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(venueAdapter);
        vm.expectRevert(abi.encodeWithSignature("NotVenueAdapter()"));
        vault.creditDIEM(10e18);
    }

    // ── Rate stability and oracle safety ─────────────────────────────────────
    //
    // Critical invariant: convertToAssets() must be stable from requestRedeem
    // through claimRedeem. Without pendingWithdrawalDiem, burning shares while
    // DIEM is still in Venice's unstakingAmount inflates the oracle — a Morpho
    // collateral position can be over-borrowed during the ~24h cooldown window.

    function test_rate_stableAfterRequestRedeem() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);
        vm.prank(venueAdapter);
        vault.creditDIEM(20e18);
        uint256 rateBefore = vault.convertToAssets(1e18);

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(aliceShares, alice);

        assertApproxEqAbs(
            vault.convertToAssets(1e18), rateBefore, 1, "rate must not change after requestRedeem"
        );
    }

    function test_rate_stableAfterFlush() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);
        vm.prank(venueAdapter);
        vault.creditDIEM(20e18);
        uint256 rateBefore = vault.convertToAssets(1e18);

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(aliceShares, alice);
        _warpBatchOpen();
        vault.flush();

        assertApproxEqAbs(
            vault.convertToAssets(1e18),
            rateBefore,
            1,
            "rate must not inflate during cooldown window"
        );
    }

    function test_rate_stableAfterSettle() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);
        vm.prank(venueAdapter);
        vault.creditDIEM(20e18);
        uint256 rateBefore = vault.convertToAssets(1e18);

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(aliceShares, alice);
        _warpBatchOpen();
        vault.flush();
        vm.warp(block.timestamp + diem.cooldownDuration() + 1);
        vault.settle();

        assertApproxEqAbs(
            vault.convertToAssets(1e18), rateBefore, 1, "rate must stay stable after settle"
        );
    }

    function test_rate_monotoneAfterMultipleDepositsAndCredits() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);
        uint256 r0 = vault.convertToAssets(1e18);
        vm.prank(venueAdapter);
        vault.creditDIEM(20e18);
        uint256 r1 = vault.convertToAssets(1e18);
        vm.prank(venueAdapter);
        vault.creditDIEM(20e18);
        uint256 r2 = vault.convertToAssets(1e18);
        assertGt(r1, r0);
        assertGt(r2, r1);
    }

    function test_rate_notDecreaseOnNewDeposit() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 rBefore = vault.convertToAssets(1e18);
        vm.prank(bob);
        vault.deposit(100e18, bob);
        assertGe(vault.convertToAssets(1e18), rBefore - 1);
    }

    // ── Instant withdrawal disabled ──────────────────────────────────────────

    function test_maxWithdraw_alwaysZero() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        assertEq(vault.maxWithdraw(alice), 0);
    }

    function test_maxRedeem_alwaysZero() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        assertEq(vault.maxRedeem(alice), 0);
    }

    // ── Step 1: requestRedeem ────────────────────────────────────────────────

    function test_requestRedeem_burnsSharesImmediately() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 shares = vault.balanceOf(alice);
        uint256 supplyBefore = vault.totalSupply();

        vm.prank(alice);
        vault.requestRedeem(shares, alice);

        assertEq(vault.balanceOf(alice), 0, "alice shares burned");
        assertEq(vault.totalSupply(), supplyBefore - shares, "totalSupply decreased");
        assertEq(vault.balanceOf(address(vault)), 0, "no escrow shares in new model");
    }

    function test_requestRedeem_locksExactDiemAtCurrentRate() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 shares = vault.balanceOf(alice);
        uint256 expected = vault.previewRedeem(shares);

        vm.prank(alice);
        uint256 reqId = vault.requestRedeem(shares, alice);

        (, uint256 locked,,,,) = vault.requestStatus(reqId);
        assertApproxEqAbs(locked, expected, 1);
    }

    function test_requestRedeem_rateUnchanged() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);
        uint256 rateBefore = vault.convertToAssets(1e18);

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(aliceShares, alice);

        assertEq(vault.convertToAssets(1e18), rateBefore);
    }

    function test_requestRedeem_differentReceiver() public {
        address charlie = makeAddr("charlie");
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        uint256 reqId = vault.requestRedeem(shares, charlie);

        (address receiver,,,,,) = vault.requestStatus(reqId);
        assertEq(receiver, charlie);
    }

    function test_requestRedeem_multipleUsers_sameOrdering() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);

        uint256 aliceShares = vault.balanceOf(alice);
        uint256 bobShares = vault.balanceOf(bob);

        vm.prank(alice);
        uint256 reqA = vault.requestRedeem(aliceShares, alice);
        vm.prank(bob);
        uint256 reqB = vault.requestRedeem(bobShares, bob);

        assertEq(reqB, reqA + 1, "sequential requestIds");
        (,, uint32 bA,,,) = vault.requestStatus(reqA);
        (,, uint32 bB,,,) = vault.requestStatus(reqB);
        assertEq(bA, bB, "same batch");
    }

    function test_requestRedeem_batchUserCountIncrements() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);

        uint256 aliceShares = vault.balanceOf(alice);
        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(alice);
        vault.requestRedeem(aliceShares, alice);
        vm.prank(bob);
        vault.requestRedeem(bobShares, bob);

        (,,, uint32 userCount,) = vault.unstakeBatches(1);
        assertEq(userCount, 2);
    }

    function test_requestRedeem_revertsZeroShares() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(alice);
        vm.expectRevert("below minRedeemShares");
        vault.requestRedeem(0, alice);
    }

    function test_requestRedeem_revertsBelowMinimum() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        // Raise the minimum above alice's balance (no prank — test contract is owner)
        vault.setMinRedeemShares(200e18);
        uint256 shares = vault.balanceOf(alice); // ~99.9e18 < 200e18 min
        vm.prank(alice);
        vm.expectRevert("below minRedeemShares");
        vault.requestRedeem(shares, alice);
    }

    function test_getRedeemRequests_returnsRequestIds() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);

        uint256 aShares = vault.balanceOf(alice);
        uint256 bShares = vault.balanceOf(bob);
        vm.prank(alice);
        uint256 reqA = vault.requestRedeem(aShares, alice);
        vm.prank(bob);
        uint256 reqB = vault.requestRedeem(bShares, bob);

        uint256[] memory aliceReqs = vault.getRedeemRequests(alice);
        uint256[] memory bobReqs = vault.getRedeemRequests(bob);

        assertEq(aliceReqs.length, 1);
        assertEq(aliceReqs[0], reqA);
        assertEq(bobReqs.length, 1);
        assertEq(bobReqs[0], reqB);
    }

    function test_getRedeemRequests_appendsOnMultipleRequests() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        // Need two separate deposits for two redemptions
        diem.mint(alice, 100e18);

        uint256 shares1 = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        uint256 req1 = vault.requestRedeem(shares1, alice);

        // Second deposit then second redemption
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 shares2 = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 req2 = vault.requestRedeem(shares2, alice);

        uint256[] memory reqs = vault.getRedeemRequests(alice);
        assertEq(reqs.length, 2);
        assertEq(reqs[0], req1);
        assertEq(reqs[1], req2);
    }

    function test_getRedeemRequests_differentReceiver() public {
        // requestRedeem tracks by receiver, not msg.sender
        address charlie = makeAddr("charlie");
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 reqId = vault.requestRedeem(shares, charlie);

        assertEq(vault.getRedeemRequests(charlie).length, 1);
        assertEq(vault.getRedeemRequests(charlie)[0], reqId);
        assertEq(vault.getRedeemRequests(alice).length, 0);
    }

    function test_requestRedeem_revertsZeroReceiver() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert("zero receiver");
        vault.requestRedeem(shares, address(0));
    }

    // ── Step 2: flush ────────────────────────────────────────────────────────

    function test_flush_initiatesVeniceUnstake() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares, alice);
        _warpBatchOpen();
        vault.flush();
        (,, uint256 coolDownAmount) = diem.stakedInfos(address(vault));
        assertGt(coolDownAmount, 0);
    }

    function test_flush_advancesCurrentBatch() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares, alice);
        assertEq(vault.currentBatch(), 1);
        _warpBatchOpen();
        vault.flush();
        assertEq(vault.currentBatch(), 2);
    }

    function test_flush_setsUnstakingBatch() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares, alice);
        _warpBatchOpen();
        vault.flush();
        assertEq(vault.unstakingBatch(), 1);
    }

    function test_flush_revertsWhenNothingQueued() public {
        vm.expectRevert(abi.encodeWithSignature("BatchNotOpen()"));
        vault.flush();
    }

    function test_flush_revertsWhenBatchTooNew() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares, alice);
        // do NOT warp — batch too new
        vm.expectRevert(abi.encodeWithSignature("BatchTooNew()"));
        vault.flush();
    }

    function test_flush_revertsWhenPriorBatchUnstaking() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(aliceShares, alice);
        _warpBatchOpen();
        vault.flush();

        // Start second batch while first is unstaking
        vm.prank(bob);
        vault.deposit(100e18, bob);
        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(bob);
        vault.requestRedeem(bobShares, bob);
        _warpBatchOpen();
        vm.expectRevert(abi.encodeWithSignature("PriorBatchUnstaking()"));
        vault.flush();
    }

    // ── Batch saturation (MAX_BATCH_SIZE = 50) ───────────────────────────────

    function test_requestRedeem_revertsWhenBatchFull() public {
        // Fill batch to the 50-user cap using distinct vm.toString(i) names
        for (uint256 i = 0; i < 50; i++) {
            address user = makeAddr(string.concat("batchFillUser", vm.toString(i)));
            diem.mint(user, 10e18);
            vm.startPrank(user);
            diem.approve(address(vault), type(uint256).max);
            vault.deposit(10e18, user);
            uint256 shares = vault.balanceOf(user);
            vault.requestRedeem(shares, user);
            vm.stopPrank();
        }
        // 51st request must revert with BatchFull
        address extra = makeAddr("batchExtra");
        diem.mint(extra, 10e18);
        vm.startPrank(extra);
        diem.approve(address(vault), type(uint256).max);
        vault.deposit(10e18, extra);
        uint256 extraShares = vault.balanceOf(extra);
        vm.expectRevert(abi.encodeWithSignature("BatchFull()"));
        vault.requestRedeem(extraShares, extra);
        vm.stopPrank();
    }

    function test_flush_immediatelyAllowedWhenBatchFull() public {
        // Fill batch to exactly 50 users — no time warp needed, userCount cap allows immediate flush
        for (uint256 i = 0; i < 50; i++) {
            address user = makeAddr(string.concat("flushFillUser", vm.toString(i)));
            diem.mint(user, 10e18);
            vm.startPrank(user);
            diem.approve(address(vault), type(uint256).max);
            vault.deposit(10e18, user);
            uint256 shares = vault.balanceOf(user);
            vault.requestRedeem(shares, user);
            vm.stopPrank();
        }
        // Should succeed without warping — batch is full
        vault.flush();
    }

    function test_setMinBatchOpenSecs_revertsAboveMax() public {
        vm.expectRevert("exceeds 7-day max");
        vault.setMinBatchOpenSecs(7 days + 1);
    }

    // ── Access control gaps ──────────────────────────────────────────────────

    function test_deregisteredAdapter_cannotCreditDIEM() public {
        // Register then immediately deregister
        vault.setVenueAdapter(venueAdapter, false);
        vm.prank(venueAdapter);
        vm.expectRevert(abi.encodeWithSignature("NotVenueAdapter()"));
        vault.creditDIEM(1e18);
    }

    function test_unpause_restoresDeposit() public {
        vault.pause();
        vm.expectRevert();
        vm.prank(alice);
        vault.deposit(1e18, alice);
        vault.unpause();
        // After unpause deposit should succeed
        vm.prank(alice);
        vault.deposit(1e18, alice);
        assertGt(vault.balanceOf(alice), 0);
    }

    function test_creditWstDIEM_revertsZeroRecipient() public {
        vm.prank(venueAdapter);
        vm.expectRevert("zero recipient");
        vault.creditWstDIEM(1e18, address(0));
    }

    // ── Step 3: settle ───────────────────────────────────────────────────────

    function test_settle_movesVeniceDIEMToBalance() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares, alice);
        _warpBatchOpen();
        vault.flush();
        vm.warp(block.timestamp + diem.cooldownDuration() + 1);
        vault.settle();
        assertGt(diem.balanceOf(address(vault)), 0);
    }

    function test_settle_marksBatchSettled() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares, alice);
        _warpBatchOpen();
        vault.flush();
        vm.warp(block.timestamp + diem.cooldownDuration() + 1);
        vault.settle();
        (,,,, bool settled) = vault.unstakeBatches(1);
        assertTrue(settled);
    }

    function test_settle_clearsUnstakingBatch() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares, alice);
        _warpBatchOpen();
        vault.flush();
        vm.warp(block.timestamp + diem.cooldownDuration() + 1);
        vault.settle();
        assertEq(vault.unstakingBatch(), 0);
    }

    function test_settle_revertsBeforeFlush() public {
        vm.expectRevert(abi.encodeWithSignature("BatchNotFlushed()"));
        vault.settle();
    }

    function test_settle_revertsBeforeCooldown() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares, alice);
        _warpBatchOpen();
        vault.flush();
        vm.expectRevert(abi.encodeWithSignature("BatchNotReady()"));
        vault.settle();
    }

    function test_settle_revertsOnDoubleSettle() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares, alice);
        _warpBatchOpen();
        vault.flush();
        vm.warp(block.timestamp + diem.cooldownDuration() + 1);
        vault.settle();
        // After settle(), unstakingBatch resets to 0, so next settle() sees no
        // batch to settle and reverts with BatchNotFlushed (not BatchAlreadySettled).
        vm.expectRevert(abi.encodeWithSignature("BatchNotFlushed()"));
        vault.settle();
    }

    // ── Step 4: claimRedeem ──────────────────────────────────────────────────

    function test_claimRedeem_transfersDIEM() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 shares = vault.balanceOf(alice);
        uint256 expectedDiem = vault.previewRedeem(shares);

        vm.prank(alice);
        uint256 reqId = vault.requestRedeem(shares, alice);
        _warpBatchOpen();
        vault.flush();
        vm.warp(block.timestamp + diem.cooldownDuration() + 1);
        vault.settle();

        uint256 before = diem.balanceOf(alice);
        vault.claimRedeem(reqId);
        assertApproxEqAbs(diem.balanceOf(alice) - before, expectedDiem, 1);
    }

    // Anyone can trigger claimRedeem — DIEM always goes to the recorded receiver.
    function test_claimRedeem_anyoneCanTriggerOnBehalfOfReceiver() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 reqId = vault.requestRedeem(shares, alice);
        _warpBatchOpen();
        vault.flush();
        vm.warp(block.timestamp + diem.cooldownDuration() + 1);
        vault.settle();

        uint256 before = diem.balanceOf(alice);
        vm.prank(bob); // bob triggers on alice's behalf
        vault.claimRedeem(reqId);
        assertGt(diem.balanceOf(alice) - before, 0);
    }

    function test_claimRedeem_revertsBeforeSettle() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 reqId = vault.requestRedeem(shares, alice);
        _warpBatchOpen();
        vault.flush();
        vm.expectRevert(abi.encodeWithSignature("BatchNotSettled()"));
        vault.claimRedeem(reqId);
    }

    function test_claimRedeem_revertsOnDoubleClaim() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 reqId = vault.requestRedeem(shares, alice);
        _warpBatchOpen();
        vault.flush();
        vm.warp(block.timestamp + diem.cooldownDuration() + 1);
        vault.settle();
        vault.claimRedeem(reqId);
        vm.expectRevert(abi.encodeWithSignature("AlreadyClaimed()"));
        vault.claimRedeem(reqId);
    }

    // ── Full lifecycle — multiple users ──────────────────────────────────────

    function test_fullLifecycle_multipleUsersProportional() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(200e18, bob);

        uint256 aliceShares = vault.balanceOf(alice);
        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(alice);
        uint256 reqA = vault.requestRedeem(aliceShares, alice);
        vm.prank(bob);
        uint256 reqB = vault.requestRedeem(bobShares, bob);

        _warpBatchOpen();
        vault.flush();
        vm.warp(block.timestamp + diem.cooldownDuration() + 1);
        vault.settle();

        uint256 aliceBefore = diem.balanceOf(alice);
        uint256 bobBefore = diem.balanceOf(bob);
        vault.claimRedeem(reqA);
        vault.claimRedeem(reqB);

        uint256 aliceDiem = diem.balanceOf(alice) - aliceBefore;
        uint256 bobDiem = diem.balanceOf(bob) - bobBefore;
        assertApproxEqRel(bobDiem, aliceDiem * 2, 0.001e18);
    }

    function test_fullLifecycle_pendingWithdrawalDiemClearsAfterAllClaims() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);

        uint256 aShares = vault.balanceOf(alice);
        uint256 bShares = vault.balanceOf(bob);
        vm.prank(alice);
        uint256 reqA = vault.requestRedeem(aShares, alice);
        vm.prank(bob);
        uint256 reqB = vault.requestRedeem(bShares, bob);

        assertGt(vault.pendingWithdrawalDiem(), 0);
        _warpBatchOpen();
        vault.flush();
        vm.warp(block.timestamp + diem.cooldownDuration() + 1);
        vault.settle();

        vault.claimRedeem(reqA);
        assertGt(vault.pendingWithdrawalDiem(), 0, "bob still pending");
        vault.claimRedeem(reqB);
        assertEq(vault.pendingWithdrawalDiem(), 0, "fully cleared");
    }

    function test_sequential_batches_work() public {
        // Batch 1
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 aShares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 req1 = vault.requestRedeem(aShares, alice);
        _warpBatchOpen();
        vault.flush();
        vm.warp(block.timestamp + diem.cooldownDuration() + 1);
        vault.settle();
        vault.claimRedeem(req1);

        // Batch 2 — only starts after batch 1 settled
        vm.prank(bob);
        vault.deposit(100e18, bob);
        uint256 bShares = vault.balanceOf(bob);
        vm.prank(bob);
        uint256 req2 = vault.requestRedeem(bShares, bob);
        _warpBatchOpen();
        vault.flush();
        vm.warp(block.timestamp + diem.cooldownDuration() + 1);
        vault.settle();

        uint256 bobBefore = diem.balanceOf(bob);
        vault.claimRedeem(req2);
        assertGt(diem.balanceOf(bob) - bobBefore, 0);
    }

    // ── View helpers ─────────────────────────────────────────────────────────

    function test_requestStatus_view() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 reqId = vault.requestRedeem(shares, alice);

        (
            address receiver,
            uint256 diem_,
            uint32 batchId,
            uint64 unlockAt,
            bool settled,
            bool claimed
        ) = vault.requestStatus(reqId);

        assertEq(receiver, alice);
        assertGt(diem_, 0);
        assertEq(batchId, 1);
        assertEq(unlockAt, 0, "unlockAt set at flush, not request");
        assertFalse(settled);
        assertFalse(claimed);
    }

    function test_currentBatchInfo_view() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares, alice);

        (uint32 batchId, uint128 diemTotal,, uint32 userCount, uint64 flushableAt) =
            vault.currentBatchInfo();

        assertEq(batchId, 1);
        assertGt(diemTotal, 0);
        assertEq(userCount, 1);
        assertGt(flushableAt, block.timestamp);
    }

    // ── Pause ────────────────────────────────────────────────────────────────

    function test_pause_blocksDeposit() public {
        vault.pause();
        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(100e18, alice);
    }

    function test_pause_blocksRequestRedeem() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vault.pause();
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        vault.requestRedeem(shares, alice);
    }

    function test_pause_blocksFlush() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares, alice);
        vault.pause();
        _warpBatchOpen();
        vm.expectRevert();
        vault.flush();
    }

    function test_pause_doesNotBlockSettle() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares, alice);
        _warpBatchOpen();
        vault.flush();
        vault.pause(); // paused AFTER flush
        vm.warp(block.timestamp + diem.cooldownDuration() + 1);
        vault.settle(); // must succeed despite pause
        (,,,, bool settled) = vault.unstakeBatches(1);
        assertTrue(settled);
    }

    function test_pause_doesNotBlockClaimRedeem() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 reqId = vault.requestRedeem(shares, alice);
        _warpBatchOpen();
        vault.flush();
        vm.warp(block.timestamp + diem.cooldownDuration() + 1);
        vault.settle();
        vault.pause(); // paused after settle
        uint256 before = diem.balanceOf(alice);
        vault.claimRedeem(reqId); // must succeed despite pause
        assertGt(diem.balanceOf(alice) - before, 0);
    }

    // ── ERC-1271 ─────────────────────────────────────────────────────────────

    function test_isValidSignature_veniceSignerAccepted() public {
        uint256 signerPk = uint256(keccak256("venice-signer-pk"));
        address signerAddr = vm.addr(signerPk);
        InferenceVault v2 = new InferenceVault(address(diem), treasury, signerAddr, address(this));

        bytes32 hash = keccak256("venice-api-challenge");
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(signerPk, hash);
        assertEq(v2.isValidSignature(hash, abi.encodePacked(r, s, vv)), bytes4(0x1626ba7e));
    }

    function test_isValidSignature_ownerWithoutVeniceSigner_rejected() public view {
        uint256 ownerPk = uint256(keccak256("owner-pk"));
        bytes32 hash = keccak256("venice-api-challenge");
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(ownerPk, hash);
        assertEq(vault.isValidSignature(hash, abi.encodePacked(r, s, vv)), bytes4(0xffffffff));
    }

    function test_isValidSignature_strangerRejected() public view {
        uint256 strangerPk = uint256(keccak256("stranger-pk"));
        bytes32 hash = keccak256("venice-api-challenge");
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(strangerPk, hash);
        assertEq(vault.isValidSignature(hash, abi.encodePacked(r, s, vv)), bytes4(0xffffffff));
    }

    function test_setVeniceSigner_rotatesKey() public {
        uint256 newPk = uint256(keccak256("new-venice-pk"));
        address newAddr = vm.addr(newPk);
        vault.setVeniceSigner(newAddr);
        assertEq(vault.veniceSigner(), newAddr);
        bytes32 hash = keccak256("challenge");
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(newPk, hash);
        assertEq(vault.isValidSignature(hash, abi.encodePacked(r, s, vv)), bytes4(0x1626ba7e));
    }

    // ── VOL accounting ────────────────────────────────────────────────────────

    function test_vaultOwnedShares_excludedFromEffectiveRate() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 rateBefore = vault.convertToAssets(1e18);
        uint256 half = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        vault.transfer(address(vault), half);
        assertEq(vault.convertToAssets(1e18), rateBefore);
    }

    function test_vaultOwnedShares_returnsVaultBalance() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 half = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        vault.transfer(address(vault), half);
        assertEq(vault.vaultOwnedShares(), half);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Fork tests — real DIEM on Base mainnet
// ─────────────────────────────────────────────────────────────────────────────
contract InferenceVaultForkTest is Test {
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;

    InferenceVault vault;
    address alice = makeAddr("alice");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        vault =
            new InferenceVault(DIEM, makeAddr("treasury"), makeAddr("veniceSigner"), address(this));
        vault.setVenueAdapter(makeAddr("venueAdapter"), true);
        deal(DIEM, alice, 1000e18);
        vm.prank(alice);
        IERC20(DIEM).approve(address(vault), type(uint256).max);
    }

    function test_fork_deposit_stakesInVenice() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        assertEq(IERC20(DIEM).balanceOf(address(vault)), 0);
        (bool ok, bytes memory data) =
            DIEM.staticcall(abi.encodeWithSignature("stakedInfos(address)", address(vault)));
        assertTrue(ok);
        (uint256 staked,,) = abi.decode(data, (uint256, uint256, uint256));
        assertEq(staked, 100e18);
    }

    function test_fork_totalAssets_matchesStakedInfos() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        assertEq(vault.totalAssets(), 100e18);
    }

    function test_fork_requestRedeem_fullLifecycle() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 reqId = vault.requestRedeem(shares, alice);

        vm.warp(block.timestamp + vault.minBatchOpenSecs() + 1);
        vault.flush();

        (, bytes memory cd) = DIEM.staticcall(abi.encodeWithSignature("cooldownDuration()"));
        uint256 cooldown = abi.decode(cd, (uint256));
        vm.warp(block.timestamp + cooldown + 1);
        vault.settle();

        uint256 before = IERC20(DIEM).balanceOf(alice);
        vault.claimRedeem(reqId);
        assertGt(IERC20(DIEM).balanceOf(alice) - before, 0);
    }

    function test_fork_multipleDepositors_rateConsistent() public {
        address bob = makeAddr("bob");
        deal(DIEM, bob, 1000e18);
        vm.prank(bob);
        IERC20(DIEM).approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);
        assertApproxEqRel(vault.balanceOf(alice), vault.balanceOf(bob), 0.01e18);
    }
}
