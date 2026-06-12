// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, Vm} from "forge-std/Test.sol";

import {InferenceVault} from "../../../src/vault/InferenceVault.sol";
import {AntSeedAdapter} from "../../../src/vault/adapters/AntSeedAdapter.sol";
import {SurplusAdapter} from "../../../src/vault/adapters/SurplusAdapter.sol";
import {X402Adapter} from "../../../src/vault/adapters/X402Adapter.sol";
import {MockDIEM} from "../mocks/MockDIEM.sol";
import {MockSwapRouter} from "../mocks/MockSwapRouter.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

// DIEMCredited event signature from InferenceVault for vm.expectEmit
event DIEMCredited(address indexed adapter, uint256 amount);

contract AdaptersTest is Test {
    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address settler = makeAddr("settler");
    address alice = makeAddr("alice");
    address treasury = makeAddr("treasury");
    address veniceSigner = makeAddr("veniceSigner");

    MockDIEM diem;
    MockUSDC mockUsdc;
    MockSwapRouter router;
    InferenceVault vault;

    AntSeedAdapter antSeed;
    SurplusAdapter surplus;
    X402Adapter x402;

    // MockSwapRouter: 1 USDC (1e6) → 1e18 DIEM
    uint256 constant USDC_TO_DIEM = 1e12;

    function setUp() public {
        diem = new MockDIEM();
        mockUsdc = new MockUSDC();
        router = new MockSwapRouter(address(mockUsdc), address(diem));

        vault = new InferenceVault(address(diem), treasury, veniceSigner, address(this));

        antSeed = new AntSeedAdapter(address(vault), address(mockUsdc), address(router), owner);
        surplus = new SurplusAdapter(address(vault), address(mockUsdc), address(router), owner);
        x402 = new X402Adapter(address(vault), address(mockUsdc), address(router), owner);

        vault.setVenueAdapter(address(antSeed), true);
        vault.setVenueAdapter(address(surplus), true);
        vault.setVenueAdapter(address(x402), true);

        vm.startPrank(owner);
        antSeed.setAuthorizedSettler(settler);
        surplus.setAuthorizedSettler(settler);
        x402.setAuthorizedSettler(settler);
        antSeed.setKeeper(keeper);
        surplus.setKeeper(keeper);
        x402.setKeeper(keeper);
        vm.stopPrank();

        // Seed vault so the rate is defined
        diem.mint(alice, 1000e18);
        vm.prank(alice);
        diem.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Fund settler
        mockUsdc.mint(settler, 1_000_000e6);
        vm.prank(settler);
        mockUsdc.approve(address(antSeed), type(uint256).max);
        vm.prank(settler);
        mockUsdc.approve(address(surplus), type(uint256).max);
        vm.prank(settler);
        mockUsdc.approve(address(x402), type(uint256).max);
    }

    // Helper: put USDC directly in adapter (simulates accumulated balance)
    function _giveUsdc(address adapter, uint256 amount) internal {
        mockUsdc.mint(adapter, amount);
    }

    // ── receiveSettlement ─────────────────────────────────────────────────────

    function test_antSeed_receiveSettlement_recordsUSDC() public {
        vm.prank(settler);
        antSeed.receiveSettlement(100e6);
        assertEq(mockUsdc.balanceOf(address(antSeed)), 100e6);
    }

    function test_surplus_receiveSettlement_recordsUSDC() public {
        vm.prank(settler);
        surplus.receiveSettlement(200e6);
        assertEq(mockUsdc.balanceOf(address(surplus)), 200e6);
    }

    function test_x402_receiveSettlement_recordsUSDC() public {
        vm.prank(settler);
        x402.receiveSettlement(50e6);
        assertEq(mockUsdc.balanceOf(address(x402)), 50e6);
    }

    function test_x402_recordX402Settlement_permissionless() public {
        address payer = makeAddr("payer");
        mockUsdc.mint(payer, 10e6);
        vm.prank(payer);
        mockUsdc.approve(address(x402), type(uint256).max);
        vm.prank(payer);
        x402.recordX402Settlement(10e6);
        assertEq(mockUsdc.balanceOf(address(x402)), 10e6);
    }

    function test_receiveSettlement_revertsUnauthorized() public {
        mockUsdc.mint(alice, 100e6);
        vm.prank(alice);
        mockUsdc.approve(address(antSeed), 100e6);
        vm.prank(alice);
        vm.expectRevert("not authorized");
        antSeed.receiveSettlement(100e6);
    }

    // ── routeYield — fee split ────────────────────────────────────────────────

    function test_routeYield_raisesHolderRate() public {
        _giveUsdc(address(antSeed), 1000e6);
        uint256 rateBefore = vault.convertToAssets(1e18);
        vm.prank(keeper);
        antSeed.routeYield(0);
        assertGt(vault.convertToAssets(1e18), rateBefore, "holder rate must increase");
    }

    function test_routeYield_mintsWstDiemToAdapter() public {
        _giveUsdc(address(antSeed), 1000e6);
        vm.prank(keeper);
        antSeed.routeYield(0);
        assertGt(
            IERC20(address(vault)).balanceOf(address(antSeed)),
            0,
            "adapter must hold wstDIEM from operator cut"
        );
    }

    function test_routeYield_zeroOperatorFee_noWstDiem() public {
        vm.prank(owner);
        antSeed.setOperatorFeeBps(0);
        _giveUsdc(address(antSeed), 500e6);
        vm.prank(keeper);
        antSeed.routeYield(0);
        assertEq(IERC20(address(vault)).balanceOf(address(antSeed)), 0);
    }

    function test_routeYield_split_defaultFee() public {
        // 10% fee: 1000 USDC → 1000e18 DIEM, 900e18 to holders, 100e18 to adapter
        _giveUsdc(address(antSeed), 1000e6);
        uint256 supplyBefore = vault.totalSupply();
        vm.prank(keeper);
        antSeed.routeYield(0);
        // Total supply increased by operatorShares only (creditDIEM doesn't mint shares)
        assertGt(vault.totalSupply(), supplyBefore, "operator shares minted");
    }

    function test_routeYield_emitsYieldRouted() public {
        uint256 usdcIn = 100e6;
        _giveUsdc(address(antSeed), usdcIn);
        vm.prank(keeper);
        vm.recordLogs();
        antSeed.routeYield(0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("YieldRouted(uint256,uint256,uint256)");
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(antSeed) && logs[i].topics[0] == sig) {
                found = true;
                (uint256 usdcLogged, uint256 diemLogged,) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(usdcLogged, usdcIn);
                assertEq(diemLogged, usdcIn * USDC_TO_DIEM);
            }
        }
        assertTrue(found, "YieldRouted not emitted");
    }

    function test_surplus_routeYield_works() public {
        _giveUsdc(address(surplus), 200e6);
        uint256 rateBefore = vault.convertToAssets(1e18);
        vm.prank(keeper);
        surplus.routeYield(0);
        assertGt(vault.convertToAssets(1e18), rateBefore);
    }

    function test_x402_routeYield_works() public {
        _giveUsdc(address(x402), 150e6);
        uint256 rateBefore = vault.convertToAssets(1e18);
        vm.prank(keeper);
        x402.routeYield(0);
        assertGt(vault.convertToAssets(1e18), rateBefore);
    }

    // ── onlyOperator guard ────────────────────────────────────────────────────

    function test_routeYield_revertsNonOperator() public {
        _giveUsdc(address(antSeed), 100e6);
        vm.prank(alice);
        vm.expectRevert("not operator");
        antSeed.routeYield(0);
    }

    function test_routeYield_allowsOwner() public {
        _giveUsdc(address(antSeed), 100e6);
        vm.prank(owner);
        antSeed.routeYield(0);
    }

    function test_routeYield_allowsKeeper() public {
        _giveUsdc(address(antSeed), 100e6);
        vm.prank(keeper);
        antSeed.routeYield(0);
    }

    // ── setOperatorFeeBps ─────────────────────────────────────────────────────

    function test_setOperatorFeeBps_revertsAboveMax() public {
        vm.prank(owner);
        vm.expectRevert("exceeds max fee");
        antSeed.setOperatorFeeBps(2001);
    }

    function test_setOperatorFeeBps_succeedsAtMax() public {
        vm.prank(owner);
        antSeed.setOperatorFeeBps(2000);
        assertEq(antSeed.operatorFeeBps(), 2000);
    }

    function test_setOperatorFeeBps_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        antSeed.setOperatorFeeBps(500);
    }

    // ── routeYield no USDC ────────────────────────────────────────────────────

    function test_routeYield_revertsWhenNoUsdc() public {
        vm.prank(keeper);
        vm.expectRevert("no USDC to route");
        antSeed.routeYield(0);
    }

    // ── routeYield slippage floor (MOG-541) ───────────────────────────────────

    function test_routeYield_revertsWhenBelowMinDiemOut() public {
        // 100 USDC → 100e18 DIEM at the mock rate. Demanding more must revert,
        // proving a sandwiched/under-delivering swap fails instead of crediting.
        uint256 usdcIn = 100e6;
        _giveUsdc(address(antSeed), usdcIn);
        uint256 expectedOut = usdcIn * USDC_TO_DIEM;
        vm.prank(keeper);
        vm.expectRevert("Too little received");
        antSeed.routeYield(expectedOut + 1);
    }

    function test_routeYield_succeedsAtExactMinDiemOut() public {
        // minDiemOut == exact output is satisfied (>=), so the swap goes through.
        uint256 usdcIn = 100e6;
        _giveUsdc(address(antSeed), usdcIn);
        uint256 expectedOut = usdcIn * USDC_TO_DIEM;
        uint256 rateBefore = vault.convertToAssets(1e18);
        vm.prank(keeper);
        antSeed.routeYield(expectedOut);
        assertGt(vault.convertToAssets(1e18), rateBefore, "holder rate must increase");
    }

    // ── IInferenceToken views ─────────────────────────────────────────────────

    function test_inferenceName_antSeed() public view {
        assertEq(antSeed.inferenceName(), "AntSeed");
    }

    function test_inferenceName_surplus() public view {
        assertEq(surplus.inferenceName(), "Surplus Intelligence");
    }

    function test_inferenceName_x402() public view {
        assertEq(x402.inferenceName(), "X402");
    }

    function test_inferenceAsset_returnsDiemMainnet() public view {
        assertEq(antSeed.inferenceAsset(), 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024);
    }

    function test_inferenceStaked_doesNotRevert() public view {
        antSeed.inferenceStaked(); // just verify no revert
    }

    function test_pendingYieldInDIEM_isZero() public view {
        assertEq(antSeed.pendingYieldInDIEM(), 0);
    }
}
