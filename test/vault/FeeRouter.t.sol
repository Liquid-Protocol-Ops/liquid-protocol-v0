// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FeeRouter} from "../../src/vault/FeeRouter.sol";
import {InferenceVault} from "../../src/vault/InferenceVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract FeeRouterTest is Test {
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;
    address constant VVV_STAKING = 0x321b7ff75154472B18EDb199033fF4D116F340Ff;

    InferenceVault vault;
    FeeRouter router;
    address curvePool = makeAddr("curvePool"); // mocked — no real code
    address v4Pool = makeAddr("v4Pool"); // mocked

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        vault = new InferenceVault(DIEM, makeAddr("treasury"), address(this));
        router = new FeeRouter(address(vault), WETH, VVV, VVV_STAKING, curvePool, v4Pool);
        vault.setFeeRouter(address(router));
    }

    function test_receiveWETH_accumulatesBalance() public {
        deal(WETH, address(this), 1e18);
        IERC20(WETH).approve(address(router), 1e18);
        router.receiveWETH(1e18);
        assertEq(router.pendingWETH(), 1e18);
    }

    function test_receivewstDIEM_accumulatesBalance() public {
        deal(DIEM, address(this), 100e18);
        IERC20(DIEM).approve(address(vault), 100e18);
        uint256 shares = vault.deposit(100e18, address(this));
        IERC20(address(vault)).approve(address(router), shares);
        router.receivewstDIEM(shares);
        assertGt(IERC20(address(vault)).balanceOf(address(router)), 0);
    }

    function test_receiveVVV_accumulatesBalance() public {
        deal(VVV, address(this), 100e18);
        IERC20(VVV).approve(address(router), 100e18);
        router.receiveVVV(100e18);
        assertEq(router.pendingVVV(), 100e18);
    }

    function test_pendingVVV_belowThreshold_harvestVVV_noops() public {
        deal(VVV, address(this), 1e18);
        IERC20(VVV).approve(address(router), 1e18);
        router.receiveVVV(1e18); // below default threshold (100e18)
        uint256 assetsBefore = vault.totalAssets();
        router.harvestVVV();
        assertEq(vault.totalAssets(), assetsBefore, "below threshold: no-op");
    }

    function test_setMaxSlippageBps_onlyOwner() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        router.setMaxSlippageBps(100);
    }
}
