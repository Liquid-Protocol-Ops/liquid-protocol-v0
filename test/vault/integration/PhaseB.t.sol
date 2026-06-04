// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DeployCurvePool} from "../../../script/vault/DeployCurvePool.s.sol";
import {InferenceVault} from "../../../src/vault/InferenceVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

interface ICurvePool {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function add_liquidity(uint256[] calldata amounts, uint256 min_mint_amount)
        external
        returns (uint256);
}

contract PhaseBIntegrationTest is Test {
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;

    InferenceVault vault;
    ICurvePool curvePool;
    address alice = makeAddr("alice");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        vault =
            new InferenceVault(DIEM, makeAddr("treasury"), makeAddr("veniceSigner"), address(this));

        DeployCurvePool d = new DeployCurvePool(address(vault));
        vm.startPrank(alice, alice); // two-arg: satisfies factory EOA guard
        address pool = d.deployPool();
        vm.stopPrank();
        curvePool = ICurvePool(pool);

        // 250k gives headroom for both tests (max use: ~210k)
        deal(DIEM, alice, 250_000e18);
        vm.startPrank(alice);
        IERC20(DIEM).approve(address(vault), type(uint256).max);
        IERC20(DIEM).approve(address(curvePool), type(uint256).max);
        IERC20(address(vault)).approve(address(curvePool), type(uint256).max);
        vm.stopPrank();
    }

    // ─── test 1: deposit → Curve exit ────────────────────────────────────────

    function test_fork_depositThenCurveExit() public {
        // 1. Alice deposits 50,000 DIEM → wstDIEM shares
        vm.startPrank(alice);
        uint256 shares = vault.deposit(50_000e18, alice);
        assertGt(shares, 0, "no shares received");

        // 2. Seed pool with 50,000 DIEM + all wstDIEM shares (both sides)
        uint256[] memory seedAmounts = new uint256[](2);
        seedAmounts[0] = 50_000e18; // DIEM  (coins[0])
        seedAmounts[1] = shares; //     wstDIEM (coins[1])
        curvePool.add_liquidity(seedAmounts, 0);

        // 3. Deposit a fresh 5,000 DIEM to get wstDIEM to swap
        uint256 swapShares = vault.deposit(5000e18, alice);
        assertGt(swapShares, 0, "no shares for swap");

        // 4. Swap wstDIEM → DIEM via Curve exchange(1→0)
        uint256 diemOut = curvePool.exchange(1, 0, swapShares, 0);
        vm.stopPrank();

        assertGt(diemOut, 0, "Curve exit returned zero DIEM");
    }

    // ─── test 2: exit within 1% of vault NAV ─────────────────────────────────

    function test_fork_exitApproxParity() public {
        vm.startPrank(alice);

        // 1. Deposit 100,000 DIEM → wstDIEM shares
        uint256 seedShares = vault.deposit(100_000e18, alice);
        assertGt(seedShares, 0, "no seed shares");

        // 2. Seed pool with 100,000 DIEM + those shares
        uint256[] memory seedAmounts = new uint256[](2);
        seedAmounts[0] = 100_000e18;
        seedAmounts[1] = seedShares;
        curvePool.add_liquidity(seedAmounts, 0);

        // 3. Deposit fresh 10,000 DIEM → separate swap batch
        uint256 swapShares = vault.deposit(10_000e18, alice);
        assertGt(swapShares, 0, "no swap shares");

        // 4. Swap those shares wstDIEM → DIEM via Curve exchange(1→0)
        uint256 diemOut = curvePool.exchange(1, 0, swapShares, 0);
        vm.stopPrank();

        // 5. Expected: vault NAV of swapShares (floor rounding)
        uint256 expected = vault.convertToAssets(swapShares);

        // Assert within 1% of vault NAV (Curve pool slippage + fee should be negligible at this size)
        assertApproxEqRel(diemOut, expected, 0.01e18, "Curve exit diverged >1% from vault NAV");
    }
}
