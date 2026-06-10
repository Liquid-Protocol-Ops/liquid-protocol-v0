// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {InferenceVault} from "../../src/vault/InferenceVault.sol";
import {SurplusStakingWrapper} from "../../src/vault/SurplusStakingWrapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract SurplusStakingWrapperTest is Test {
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;

    InferenceVault vault;
    SurplusStakingWrapper wrapper;
    address user = makeAddr("user");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        vault =
            new InferenceVault(DIEM, makeAddr("treasury"), makeAddr("veniceSigner"), address(this));
        wrapper = new SurplusStakingWrapper(address(vault), address(0), address(this));

        deal(DIEM, user, 1000e18);
        vm.prank(user);
        IERC20(DIEM).approve(address(wrapper), type(uint256).max);
    }

    // ── stakeForUser ──────────────────────────────────────────────────────

    function test_stakeForUser_mintsWstDIEM() public {
        vm.prank(user);
        uint256 shares = wrapper.stakeForUser(user, 100e18);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(user), shares);
    }

    function test_stakeForUser_vaultStakesDIEM() public {
        vm.prank(user);
        wrapper.stakeForUser(user, 100e18);
        assertEq(IERC20(DIEM).balanceOf(address(vault)), 0, "vault must stake DIEM, not hold idle");
        assertEq(vault.totalAssets(), 100e18);
    }

    // ── referralDeposit ───────────────────────────────────────────────────

    function test_referralDeposit_mintsShares() public {
        vm.prank(user);
        uint256 shares = wrapper.referralDeposit(user, 100e18, keccak256("ref-abc"));
        assertGt(shares, 0);
        assertEq(vault.balanceOf(user), shares);
    }

    function test_referralDeposit_emitsEvent() public {
        vm.prank(user);
        vm.expectEmit(true, false, false, false);
        emit SurplusStakingWrapper.Staked(user, 100e18, 0, keccak256("ref-abc"));
        wrapper.referralDeposit(user, 100e18, keccak256("ref-abc"));
    }

    // ── getBalance / getYield ─────────────────────────────────────────────

    function test_getBalance_returnsVaultBalance() public {
        vm.prank(user);
        wrapper.stakeForUser(user, 100e18);
        assertEq(wrapper.getBalance(user), vault.balanceOf(user));
    }

    function test_getYield_returnsConvertedAssets() public {
        vm.prank(user);
        wrapper.stakeForUser(user, 100e18);
        uint256 shares = vault.balanceOf(user);
        assertEq(wrapper.getYield(user), vault.convertToAssets(shares));
    }

    // ── unstakeForUser ────────────────────────────────────────────────────

    function test_unstakeForUser_revertWithoutCurvePool() public {
        vm.prank(user);
        wrapper.stakeForUser(user, 100e18);
        uint256 shares = vault.balanceOf(user);
        vm.prank(user);
        IERC20(address(vault)).approve(address(wrapper), shares);
        vm.expectRevert(abi.encodeWithSignature("CurvePoolNotSet()"));
        wrapper.unstakeForUser(user, shares, 0);
    }

    // ── Admin ─────────────────────────────────────────────────────────────

    function test_setCurvePool_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert();
        wrapper.setCurvePool(makeAddr("pool"));
    }

    function test_setCurvePool_updates() public {
        address pool = makeAddr("pool");
        wrapper.setCurvePool(pool);
        assertEq(wrapper.curvePool(), pool);
    }
}
