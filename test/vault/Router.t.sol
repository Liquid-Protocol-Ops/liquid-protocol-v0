// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {InferenceVault} from "../../src/vault/InferenceVault.sol";
import {Router} from "../../src/vault/Router.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract RouterTest is Test {
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant VVV_STAKING = 0x321b7ff75154472B18EDb199033fF4D116F340Ff;

    InferenceVault vault;
    Router router;
    address alice = makeAddr("alice");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        vault = new InferenceVault(DIEM, makeAddr("treasury"), address(this));
        router = new Router(address(vault), WETH, VVV_STAKING);

        deal(DIEM, alice, 1000e18);
        deal(WETH, alice, 10e18);

        vm.startPrank(alice);
        IERC20(DIEM).approve(address(vault), type(uint256).max);
        IERC20(DIEM).approve(address(router), type(uint256).max);
        IERC20(WETH).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function test_depositDIEM_direct() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(100e18, alice);
        assertGt(shares, 0);
    }

    function test_router_exitToWETH_revertWithoutPool() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        IERC20(address(vault)).approve(address(router), type(uint256).max);
        // Should revert — no pool set yet
        vm.expectRevert();
        router.exitToWETH(shares, 0, alice);
    }
}
