// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {InferenceVault} from "../../src/vault/InferenceVault.sol";
import {Router} from "../../src/vault/Router.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Test} from "forge-std/Test.sol";

contract RouterTest is Test {
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;
    address constant VVV_STAKING = 0x321b7ff75154472B18EDb199033fF4D116F340Ff;
    // Uniswap V3 SwapRouter02 on Base
    address constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;

    InferenceVault vault;
    Router router;
    address alice = makeAddr("alice");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        vault =
            new InferenceVault(DIEM, makeAddr("treasury"), makeAddr("veniceSigner"), address(this));
        router = new Router(address(vault), WETH, VVV, VVV_STAKING, address(0), address(this));

        deal(DIEM, alice, 1000e18);
        deal(WETH, alice, 10e18);
        deal(VVV, alice, 100e18);

        vm.startPrank(alice);
        IERC20(DIEM).approve(address(vault), type(uint256).max);
        IERC20(DIEM).approve(address(router), type(uint256).max);
        IERC20(WETH).approve(address(router), type(uint256).max);
        IERC20(VVV).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    // ── Direct vault deposit ──────────────────────────────────────────────

    function test_depositDIEM_direct_mintsShares() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(100e18, alice);
        assertGt(shares, 0);
    }

    function test_depositDIEM_direct_stakesInVenice() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        assertEq(IERC20(DIEM).balanceOf(address(vault)), 0, "vault should hold no idle DIEM");
        assertEq(vault.totalAssets(), 100e18);
    }

    // ── depositWETH stub ──────────────────────────────────────────────────

    // depositWETH uses V3 only — no v4Pool required, guard was intentionally removed.

    // ── exitToWETH stub ───────────────────────────────────────────────────

    function test_exitToWETH_revertWithPoolNotSet() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        IERC20(address(vault)).approve(address(router), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("PoolNotSet()"));
        router.exitToWETH(shares, 0, alice);
    }

    // ── depositVVV ────────────────────────────────────────────────────────
    // VVV → (stake) → sVVV → (mintDiem) → DIEM → (vault.deposit) → wstDIEM

    function test_depositVVV_mintsWstDIEM() public {
        uint256 vvvAmount = 1e18;
        vm.prank(alice);
        uint256 shares = router.depositVVV(vvvAmount, 0, alice);
        assertGt(shares, 0, "depositVVV must mint wstDIEM");
        assertGt(vault.balanceOf(alice), 0, "alice must receive wstDIEM");
    }

    function test_depositVVV_vaultStakesDIEMInVenice() public {
        vm.prank(alice);
        router.depositVVV(1e18, 0, alice);

        // All DIEM that entered the vault must be staked
        assertEq(IERC20(DIEM).balanceOf(address(vault)), 0);
        assertGt(vault.totalAssets(), 0, "vault must have staked assets");
    }

    function test_depositVVV_zeroAmount_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        router.depositVVV(0, 0, alice);
    }

    function test_depositVVV_slippageProtection() public {
        // Set an impossibly high minWstDIEM to trigger SlippageExceeded
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("SlippageExceeded()"));
        router.depositVVV(1e18, type(uint256).max, alice);
    }

    // ── Immutables ────────────────────────────────────────────────────────

    function test_router_immutables() public view {
        assertEq(address(router.vault()), address(vault));
        assertEq(router.weth(), WETH);
        assertEq(router.vvv(), VVV);
        assertEq(router.vvvStaking(), VVV_STAKING);
    }

    // ── Admin ─────────────────────────────────────────────────────────────

    function test_setV4Pool_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        router.setV4Pool(makeAddr("pool"));
    }

    // ── setSwapFees / wstDiemV4Hooks ─────────────────────────────────────

    function test_setSwapFees_allowsDynamicFlagAndHooks() public {
        address hookAddr = makeAddr("hook");
        vm.prank(router.owner());
        router.setSwapFees(10_000, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, hookAddr);
        assertEq(router.wstDiemV4Fee(), LPFeeLibrary.DYNAMIC_FEE_FLAG);
        assertEq(router.wstDiemV4Hooks(), hookAddr);
        assertEq(router.wstDiemV4TickSpacing(), int24(60));
    }

    function test_setSwapFees_rejectsZeroV4Fee() public {
        vm.prank(router.owner());
        vm.expectRevert(bytes("invalid V4 fee"));
        router.setSwapFees(10_000, 0, 60, address(0));
    }

    function test_wstDiemV4Hooks_defaultsToZero() public view {
        assertEq(router.wstDiemV4Hooks(), address(0));
    }
}
