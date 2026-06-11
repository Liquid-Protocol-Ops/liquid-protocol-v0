// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DeployCurvePool} from "../../../script/vault/DeployCurvePool.s.sol";
import {AgentTGERegistry} from "../../../src/vault/AgentTGERegistry.sol";
import {FeeRouter} from "../../../src/vault/FeeRouter.sol";
import {InferenceVault} from "../../../src/vault/InferenceVault.sol";
import {IAgentTGERegistry} from "../../../src/vault/interfaces/IAgentTGERegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract PhaseEIntegrationTest is Test {
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;
    address constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant VVV_STAKING = 0x321b7ff75154472B18EDb199033fF4D116F340Ff;

    InferenceVault vault;
    FeeRouter feeRouter;
    AgentTGERegistry registry;
    address curvePool;

    address deployer = makeAddr("deployer");
    address treasury = makeAddr("treasury");
    address agent = makeAddr("agent");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));

        vault = new InferenceVault(DIEM, treasury, makeAddr("veniceSigner"), deployer);

        // Deploy Curve pool — two-arg prank satisfies the EOA guard on the factory
        DeployCurvePool d = new DeployCurvePool(address(vault));
        address seeder = makeAddr("seeder");
        vm.startPrank(seeder, seeder);
        curvePool = d.deployPool();
        vm.stopPrank();

        feeRouter = new FeeRouter(
            address(vault), WETH, VVV, VVV_STAKING, curvePool, address(0), address(this)
        );

        vm.prank(deployer);
        vault.setVenueAdapter(address(feeRouter), true);

        registry = new AgentTGERegistry(address(feeRouter), deployer);

        // Seed vault and Curve pool with initial liquidity so one-sided add_liquidity works
        deal(DIEM, seeder, 100_000e18);
        vm.startPrank(seeder);
        IERC20(DIEM).approve(address(vault), type(uint256).max);
        IERC20(DIEM).approve(curvePool, type(uint256).max);
        IERC20(address(vault)).approve(curvePool, type(uint256).max);
        uint256 seedShares = vault.deposit(50_000e18, seeder);
        uint256[] memory amt = new uint256[](2);
        amt[0] = 50_000e18;
        amt[1] = seedShares;
        (bool ok,) = curvePool.call(
            abi.encodeWithSignature("add_liquidity(uint256[],uint256)", amt, uint256(0))
        );
        require(ok, "seed liquidity");
        vm.stopPrank();
    }

    function test_fork_agentRegistrationAndFeeReceipt() public {
        // Register agent
        vm.prank(deployer);
        registry.register(agent, IAgentTGERegistry.Tier.Silver);
        assertTrue(registry.isEligible(agent));

        // Simulate fee receipt (only feeRouter is authorized)
        vm.warp(block.timestamp + 10 days);
        vm.prank(address(feeRouter));
        registry.recordFeeReceipt(agent);
        assertEq(registry.getCommitment(agent).lastFeeReceiptAt, block.timestamp);
    }

    function test_fork_wstDIEMFeeRouterRoundtrip() public {
        // Alice deposits DIEM → wstDIEM, then routes wstDIEM fees through FeeRouter
        address alice = makeAddr("alice");
        deal(DIEM, alice, 10_000e18);
        vm.startPrank(alice);
        IERC20(DIEM).approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(5000e18, alice);

        // Send wstDIEM fees to FeeRouter
        IERC20(address(vault)).approve(address(feeRouter), shares);
        feeRouter.receivewstDIEM(shares);
        vm.stopPrank();

        // Harvest flushes accumulated wstDIEM into Curve VOL
        feeRouter.harvest();
        assertEq(
            IERC20(address(vault)).balanceOf(address(feeRouter)),
            0,
            "wstDIEM not flushed from FeeRouter"
        );
    }

    function test_fork_vaultRateMonotone() public {
        uint256 rate0 = vault.convertToAssets(1e18);

        address alice = makeAddr("alice");
        deal(DIEM, alice, 10_000e18);
        vm.startPrank(alice);
        IERC20(DIEM).approve(address(vault), type(uint256).max);
        vault.deposit(5000e18, alice);
        vm.stopPrank();

        uint256 rate1 = vault.convertToAssets(1e18);
        assertGe(rate1, rate0, "rate must not decrease on deposit");

        // creditDIEM: deal DIEM to feeRouter, approve vault, prank as feeRouter to call creditDIEM
        // creditDIEM adds assets without minting shares → rate increases
        deal(DIEM, address(feeRouter), 1000e18);
        vm.startPrank(address(feeRouter));
        IERC20(DIEM).approve(address(vault), 1000e18);
        vault.creditDIEM(1000e18);
        vm.stopPrank();

        uint256 rate2 = vault.convertToAssets(1e18);
        assertGt(rate2, rate1, "creditDIEM must increase rate");
    }
}
