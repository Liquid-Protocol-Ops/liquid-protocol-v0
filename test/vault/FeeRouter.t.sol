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
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    InferenceVault vault;
    FeeRouter router;
    address curvePool = makeAddr("curvePool");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        vault =
            new InferenceVault(DIEM, makeAddr("treasury"), makeAddr("veniceSigner"), address(this));
        router = new FeeRouter(
            address(vault), WETH, VVV, VVV_STAKING, curvePool, address(0), address(this)
        );
        vault.setVenueAdapter(address(router), true);
    }

    function test_receiveWETH_accumulatesBalance() public {
        deal(WETH, address(this), 1e18);
        IERC20(WETH).approve(address(router), 1e18);
        router.receiveWETH(1e18);
        assertEq(router.pendingWETH(), 1e18);
    }

    function test_receiveUSDC_accumulatesBalance() public {
        deal(USDC, address(this), 100e6);
        IERC20(USDC).approve(address(router), 100e6);
        router.receiveUSDC(100e6);
        assertEq(router.pendingUSDC(), 100e6);
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
        router.receiveVVV(1e18);
        uint256 assetsBefore = vault.totalAssets();
        router.harvestVVV();
        assertEq(vault.totalAssets(), assetsBefore, "below threshold: no-op");
    }

    function test_harvest_weth_creditsVault() public {
        deal(WETH, address(this), 1e18);
        IERC20(WETH).approve(address(router), 1e18);
        router.receiveWETH(1e18);

        // Seed vault so creditDIEM has non-zero totalAssets
        deal(DIEM, address(this), 100e18);
        IERC20(DIEM).approve(address(vault), 100e18);
        vault.deposit(100e18, address(this));

        uint256 rateBefore = vault.convertToAssets(1e18);
        router.harvest();
        uint256 rateAfter = vault.convertToAssets(1e18);

        assertGt(rateAfter, rateBefore, "harvest WETH must increase wstDIEM rate");
    }

    function test_harvest_usdc_creditsVault() public {
        deal(USDC, address(this), 100e6);
        IERC20(USDC).approve(address(router), 100e6);
        router.receiveUSDC(100e6);

        deal(DIEM, address(this), 100e18);
        IERC20(DIEM).approve(address(vault), 100e18);
        vault.deposit(100e18, address(this));

        uint256 rateBefore = vault.convertToAssets(1e18);
        router.harvest();
        uint256 rateAfter = vault.convertToAssets(1e18);

        assertGt(rateAfter, rateBefore, "harvest USDC must increase wstDIEM rate");
    }

    function test_setVVVBatchThreshold_onlyOwner() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        router.setVVVBatchThreshold(1e18);
    }

    // ── Channel registry ─────────────────────────────────────────────────────

    function test_addChannel_registersChannel() public {
        address payoutWallet = makeAddr("surplusKeeper");
        uint256 id = router.addChannel("SurplusIntelligence", payoutWallet, 500);
        assertEq(id, 0);
        FeeRouter.Channel memory c = router.getChannel(0);
        assertEq(c.name, "SurplusIntelligence");
        assertEq(c.payoutWallet, payoutWallet);
        assertEq(c.platformFeeBps, 500);
        assertTrue(c.active);
        assertEq(c.totalRevenue, 0);
    }

    function test_addChannel_incrementsId() public {
        router.addChannel("SurplusIntelligence", makeAddr("s"), 500);
        uint256 id2 = router.addChannel("AntSeed", makeAddr("a"), 0);
        assertEq(id2, 1);
        assertEq(router.nextChannelId(), 2);
    }

    function test_addChannel_onlyOwner() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        router.addChannel("Rogue", makeAddr("x"), 0);
    }

    function test_addChannel_rejectsExcessiveFee() public {
        vm.expectRevert("fee > 50%");
        router.addChannel("Greedy", makeAddr("x"), 5001);
    }

    function test_receiveFromChannel_accumulatesPendingUSDC() public {
        uint256 id = router.addChannel("SurplusIntelligence", makeAddr("keeper"), 500);
        deal(USDC, address(this), 200e6);
        IERC20(USDC).approve(address(router), 200e6);
        router.receiveFromChannel(id, 200e6);
        assertEq(router.pendingUSDC(), 200e6);
        assertEq(router.getChannel(id).totalRevenue, 200e6);
    }

    function test_receiveFromChannel_inactiveReverts() public {
        uint256 id = router.addChannel("SurplusIntelligence", makeAddr("keeper"), 500);
        router.setChannelActive(id, false);
        deal(USDC, address(this), 100e6);
        IERC20(USDC).approve(address(router), 100e6);
        vm.expectRevert("channel inactive");
        router.receiveFromChannel(id, 100e6);
    }

    function test_receiveFromChannel_creditsVaultOnHarvest() public {
        uint256 id = router.addChannel("AntSeed", makeAddr("keeper"), 0);

        deal(DIEM, address(this), 100e18);
        IERC20(DIEM).approve(address(vault), 100e18);
        vault.deposit(100e18, address(this));

        deal(USDC, address(this), 100e6);
        IERC20(USDC).approve(address(router), 100e6);
        router.receiveFromChannel(id, 100e6);

        uint256 rateBefore = vault.convertToAssets(1e18);
        router.harvest();
        assertGt(vault.convertToAssets(1e18), rateBefore, "channel USDC must increase wstDIEM rate");
    }

    function test_setChannelPayoutWallet_updatesKeeper() public {
        uint256 id = router.addChannel("SurplusIntelligence", makeAddr("old"), 500);
        address newKeeper = makeAddr("new");
        router.setChannelPayoutWallet(id, newKeeper);
        assertEq(router.getChannel(id).payoutWallet, newKeeper);
    }

    function test_setChannelFee_updatesRate() public {
        uint256 id = router.addChannel("SurplusIntelligence", makeAddr("k"), 500);
        router.setChannelFee(id, 300);
        assertEq(router.getChannel(id).platformFeeBps, 300);
    }
}
