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
    address siUser = makeAddr("siUser");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        vault = new InferenceVault(DIEM, makeAddr("treasury"), address(this));
        wrapper = new SurplusStakingWrapper(address(vault), address(0)); // no curvePool yet

        deal(DIEM, siUser, 1000e18);
        vm.prank(siUser);
        IERC20(DIEM).approve(address(wrapper), type(uint256).max);
    }

    function test_stakeForUser_mintsWstDIEM() public {
        vm.prank(siUser);
        uint256 shares = wrapper.stakeForUser(siUser, 100e18);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(siUser), shares);
    }

    function test_getBalance_returnsVaultBalance() public {
        vm.prank(siUser);
        wrapper.stakeForUser(siUser, 100e18);
        assertEq(wrapper.getBalance(siUser), vault.balanceOf(siUser));
    }

    function test_referralDeposit_mintsShares() public {
        vm.prank(siUser);
        uint256 shares = wrapper.referralDeposit(siUser, 100e18, keccak256("ref123"));
        assertGt(shares, 0);
    }

    function test_unstakeForUser_revertWithoutCurvePool() public {
        vm.prank(siUser);
        wrapper.stakeForUser(siUser, 100e18);
        uint256 shares = vault.balanceOf(siUser);
        vm.prank(siUser);
        IERC20(address(vault)).approve(address(wrapper), shares);
        vm.expectRevert();
        wrapper.unstakeForUser(siUser, shares);
    }
}
