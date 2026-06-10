// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AgentTGERegistry} from "../../../src/vault/AgentTGERegistry.sol";
import {FeeRouter} from "../../../src/vault/FeeRouter.sol";
import {InferenceVault} from "../../../src/vault/InferenceVault.sol";
import {Router} from "../../../src/vault/Router.sol";
import {SurplusStakingWrapper} from "../../../src/vault/SurplusStakingWrapper.sol";
import {IAgentTGERegistry} from "../../../src/vault/interfaces/IAgentTGERegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/// End-to-end fork tests exercising the full wstDIEM vault stack on Base mainnet.
contract VaultStackIntegrationTest is Test {
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;
    address constant VVV_STAKING = 0x321b7ff75154472B18EDb199033fF4D116F340Ff;

    InferenceVault vault;
    Router router;
    FeeRouter feeRouter;
    AgentTGERegistry registry;
    SurplusStakingWrapper wrapper;

    address safe = makeAddr("safe");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address agent = makeAddr("agent");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));

        vault = new InferenceVault(DIEM, treasury, makeAddr("veniceSigner"), address(this));
        feeRouter = new FeeRouter(
            address(vault), WETH, VVV, VVV_STAKING, address(0), address(0), address(this)
        );
        router = new Router(address(vault), WETH, VVV, VVV_STAKING, address(0), address(this));
        registry = new AgentTGERegistry(address(feeRouter), address(this));
        wrapper = new SurplusStakingWrapper(address(vault), address(0), address(this));

        vault.setVenueAdapter(address(feeRouter), true);

        deal(DIEM, alice, 10_000e18);
        deal(DIEM, bob, 10_000e18);
        deal(VVV, alice, 1000e18);

        vm.prank(alice);
        IERC20(DIEM).approve(address(vault), type(uint256).max);
        vm.prank(bob);
        IERC20(DIEM).approve(address(vault), type(uint256).max);
        vm.prank(alice);
        IERC20(VVV).approve(address(router), type(uint256).max);
        vm.prank(alice);
        IERC20(DIEM).approve(address(wrapper), type(uint256).max);
    }

    // ── Core deposit → staking → rate ─────────────────────────────────────

    function test_e2e_deposit_stakesAndMintsShares() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000e18, alice);

        assertGt(shares, 0);
        assertEq(IERC20(DIEM).balanceOf(address(vault)), 0, "no idle DIEM in vault");
        assertEq(vault.totalAssets(), 1000e18);
    }

    function test_e2e_creditDIEM_raisesRateForAllHolders() public {
        vm.prank(alice);
        vault.deposit(500e18, alice);
        vm.prank(bob);
        vault.deposit(500e18, bob);

        uint256 aliceAssetsBefore = vault.convertToAssets(vault.balanceOf(alice));

        // Simulate fee income: feeRouter credits 100 DIEM to vault
        deal(DIEM, address(feeRouter), 100e18);
        vm.prank(address(feeRouter));
        IERC20(DIEM).approve(address(vault), 100e18);
        vm.prank(address(feeRouter));
        vault.creditDIEM(100e18);

        uint256 aliceAssetsAfter = vault.convertToAssets(vault.balanceOf(alice));
        assertGt(aliceAssetsAfter, aliceAssetsBefore, "alice's position must grow after fee credit");
    }

    function test_e2e_multiDepositor_rateEquitable() public {
        // Alice deposits first, bob deposits second — rate should be stable
        vm.prank(alice);
        vault.deposit(1000e18, alice);
        uint256 rateMid = vault.convertToAssets(1e18);
        vm.prank(bob);
        vault.deposit(1000e18, bob);
        uint256 rateEnd = vault.convertToAssets(1e18);

        // Rate after bob's deposit must not be lower (fee goes to treasury, no dilution)
        assertGe(rateEnd, rateMid - 1);
    }

    function test_e2e_vvvToWstDIEM_viaRouter() public {
        vm.prank(alice);
        uint256 shares = router.depositVVV(10e18, 0, alice);

        assertGt(shares, 0, "VVV deposit must produce wstDIEM");
        assertEq(vault.balanceOf(alice), shares);
        assertEq(IERC20(DIEM).balanceOf(address(vault)), 0, "vault must stake all DIEM");
    }

    function test_e2e_wrapper_stakeAndBalance() public {
        vm.prank(alice);
        uint256 shares = wrapper.stakeForUser(alice, 500e18);

        assertGt(shares, 0);
        assertEq(wrapper.getBalance(alice), vault.balanceOf(alice));
        assertGt(wrapper.getYield(alice), 0);
    }

    // ── AgentTGERegistry integration ──────────────────────────────────────

    function test_e2e_agentRegistry_lifecycle() public {
        registry.register(agent, IAgentTGERegistry.Tier.Gold);
        assertTrue(registry.isEligible(agent), "newly registered agent must be eligible");

        // FeeRouter records a receipt — resets dormancy clock
        vm.prank(address(feeRouter));
        registry.recordFeeReceipt(agent);

        // 29 days: still eligible
        vm.warp(block.timestamp + 29 days);
        assertTrue(registry.isEligible(agent));

        // 31 days without further receipt: dormant
        vm.warp(block.timestamp + 2 days);
        registry.markDormant(agent);
        assertFalse(registry.isEligible(agent));
    }

    // ── Withdrawal gate ───────────────────────────────────────────────────

    function test_e2e_withdrawalsDisabledAtLaunch() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);
    }

    function test_e2e_fullWithdrawalFlow() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Step 1: alice queues withdrawal — shares burned, DIEM amount locked
        uint256 shares = vault.balanceOf(alice);
        uint256 expectedDiem = vault.previewRedeem(shares);
        uint256 aliceBalBefore = IERC20(DIEM).balanceOf(alice);
        vm.prank(alice);
        uint256 reqId = vault.requestRedeem(shares, alice);

        // Step 2: flush after minBatchOpenSecs → initiates Venice unstake (~24h)
        vm.warp(block.timestamp + vault.minBatchOpenSecs() + 1);
        vault.flush();

        // Step 3: settle after Venice cooldown
        (,, uint64 unlockAt,,) = vault.unstakeBatches(1);
        vm.warp(unlockAt + 1);
        vault.settle();

        // Step 4: alice claims; anyone can trigger but DIEM always goes to receiver
        vault.claimRedeem(reqId);
        assertApproxEqAbs(IERC20(DIEM).balanceOf(alice) - aliceBalBefore, expectedDiem, 1);
    }

    // ── feeRouter.receiveVVV accumulation ────────────────────────────────

    function test_e2e_feeRouter_accumulates() public {
        deal(WETH, address(this), 5e18);
        deal(VVV, address(this), 200e18);
        IERC20(WETH).approve(address(feeRouter), type(uint256).max);
        IERC20(VVV).approve(address(feeRouter), type(uint256).max);

        feeRouter.receiveWETH(1e18);
        feeRouter.receiveVVV(100e18);

        assertEq(feeRouter.pendingWETH(), 1e18);
        assertEq(feeRouter.pendingVVV(), 100e18);
    }
}
