// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {InferenceVault} from "../../../src/vault/InferenceVault.sol";
import {WstDiemVvvOracle} from "../../../src/vault/oracles/WstDiemVvvOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Minimal Aerodrome volatile-pool surface used by the test (swap + views).
interface IAeroPool {
    function quote(address tokenIn, uint256 amountIn, uint256 granularity)
        external
        view
        returns (uint256);
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);
    function getReserves() external view returns (uint256, uint256, uint256);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/// @notice Fork tests for WstDiemVvvOracle (MOG-544).
///         Validates the on-chain price formula (vault rate × Aerodrome DIEM→VVV TWAP),
///         the token-ordering constructor guard (the liquid-VVV vs sVVV footgun), and
///         — the keystone — that the TWAP resists single-block spot manipulation.
///
/// Run: BASE_RPC_URL=<url> forge test --match-path "test/vault/oracles/**" -vv
contract WstDiemVvvOracleForkTest is Test {
    // Base mainnet
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;
    address constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf; // liquid VVV — the pool's token0
    address constant SVVV = 0x321b7ff75154472B18EDb199033fF4D116F340Ff; // sVVV staking — NOT in the pool
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant AERO_POOL = 0xbB345D35450BF9Ee76F3D2cE214E8e7AC5e1071d; // Aerodrome volatile VVV/DIEM
    uint256 constant GRANULARITY = 24; // ~24 observations ≈ ~12h TWAP window (MOG-548 review)
    uint256 constant MAX_AGE = 7200; // 2h staleness bound on the newest committed observation

    InferenceVault vault;
    WstDiemVvvOracle oracle;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address adapter = makeAddr("adapter"); // registered venue adapter (can call creditDIEM)

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        vault = new InferenceVault(DIEM, treasury, makeAddr("veniceSigner"), owner);
        oracle = new WstDiemVvvOracle(address(vault), AERO_POOL, VVV, GRANULARITY, MAX_AGE);
    }

    // ─── constructor ──────────────────────────────────────────────────────────

    function test_constructor_setsImmutables() public view {
        assertEq(address(oracle.vault()), address(vault));
        assertEq(address(oracle.pool()), AERO_POOL);
        assertEq(oracle.diem(), DIEM); // derived from vault.asset()
        assertEq(oracle.vvv(), VVV);
        assertEq(oracle.twapGranularity(), GRANULARITY);
        assertEq(oracle.maxObservationAge(), MAX_AGE);
    }

    /// The MOG-544 footgun: the pool pairs DIEM with *liquid VVV* (0xacfE…), not the
    /// sVVV staking contract (0x321b…) that our docs labelled "VVV". Passing sVVV — or
    /// any token not in the pool — must revert, not deploy a silently-wrong oracle.
    function test_constructor_revertsWhenVvvNotInPool() public {
        vm.expectRevert(WstDiemVvvOracle.TokenNotInPool.selector);
        new WstDiemVvvOracle(address(vault), AERO_POOL, SVVV, GRANULARITY, MAX_AGE);

        vm.expectRevert(WstDiemVvvOracle.TokenNotInPool.selector);
        new WstDiemVvvOracle(address(vault), AERO_POOL, WETH, GRANULARITY, MAX_AGE);
    }

    function test_constructor_revertsOnZeroArgs() public {
        vm.expectRevert(bytes("zero address"));
        new WstDiemVvvOracle(address(0), AERO_POOL, VVV, GRANULARITY, MAX_AGE);

        vm.expectRevert(bytes("zero address"));
        new WstDiemVvvOracle(address(vault), address(0), VVV, GRANULARITY, MAX_AGE);

        vm.expectRevert(bytes("zero address"));
        new WstDiemVvvOracle(address(vault), AERO_POOL, address(0), GRANULARITY, MAX_AGE);
    }

    function test_constructor_revertsOnZeroGranularity() public {
        vm.expectRevert(bytes("granularity=0"));
        new WstDiemVvvOracle(address(vault), AERO_POOL, VVV, 0, MAX_AGE);
    }

    function test_constructor_revertsOnZeroMaxAge() public {
        vm.expectRevert(bytes("maxAge=0"));
        new WstDiemVvvOracle(address(vault), AERO_POOL, VVV, GRANULARITY, 0);
    }

    // ─── price() formula ──────────────────────────────────────────────────────

    /// price() must be exactly convertToAssets(1e18) × quote(DIEM,1e18,n) — pure multiply.
    function test_price_equalsRateTimesTwap() public view {
        uint256 a = vault.convertToAssets(1e18);
        uint256 q = IAeroPool(AERO_POOL).quote(DIEM, 1e18, GRANULARITY);
        assertEq(oracle.price(), a * q, "price != convertToAssets(1e18) * quote(DIEM,1e18,n)");
    }

    /// At a fresh ~1.0 rate, price/1e36 ≈ VVV per wstDIEM ≈ ~89 (DIEM ≈ 89 VVV). Sanity band.
    function test_price_sanityMagnitude() public view {
        uint256 vvvPerWstWhole = oracle.price() / 1e36;
        assertGe(vvvPerWstWhole, 50, "implied VVV/wstDIEM unexpectedly low");
        assertLe(vvvPerWstWhole, 150, "implied VVV/wstDIEM unexpectedly high");
    }

    // ─── rate sensitivity ─────────────────────────────────────────────────────

    /// As the vault rate ratchets up (creditDIEM), price scales linearly with it.
    /// Same block ⇒ TWAP constant ⇒ p1/p0 == a1/a0 exactly.
    function test_price_scalesWithVaultRate() public {
        vm.prank(owner);
        vault.setVenueAdapter(adapter, true);

        // establish share supply
        address dep = makeAddr("dep");
        deal(DIEM, dep, 1000e18);
        vm.startPrank(dep);
        IERC20(DIEM).approve(address(vault), type(uint256).max);
        vault.deposit(1000e18, dep);
        vm.stopPrank();

        uint256 a0 = vault.convertToAssets(1e18);
        uint256 p0 = oracle.price();

        // adapter credits inference yield → non-dilutive rate increase
        deal(DIEM, adapter, 200e18);
        vm.startPrank(adapter);
        IERC20(DIEM).approve(address(vault), type(uint256).max);
        vault.creditDIEM(200e18);
        vm.stopPrank();

        uint256 a1 = vault.convertToAssets(1e18);
        uint256 p1 = oracle.price();

        assertGt(a1, a0, "rate should rise after creditDIEM");
        assertGt(p1, p0, "price should rise with rate");
        // p = A*Q with Q identical in-block ⇒ p1*a0 == p0*a1
        assertEq(p1 * a0, p0 * a1, "price must scale linearly with vault rate");
    }

    // ─── manipulation resistance (keystone) ───────────────────────────────────

    /// Dump ~50% of the DIEM reserve into the pool in a single block: spot DIEM→VVV
    /// craters, but the TWAP — and therefore the oracle — barely moves. This is the
    /// whole premise of an on-chain TWAP oracle; the test executes a real swap.
    function test_twap_resistsSingleBlockManipulation() public {
        IAeroPool pool = IAeroPool(AERO_POOL);
        (, uint256 rDiem,) = pool.getReserves(); // (VVV, DIEM, ts)

        uint256 spot0 = pool.getAmountOut(1e18, DIEM); // VVV out for 1 DIEM (live reserves)
        uint256 q0 = pool.quote(DIEM, 1e18, GRANULARITY); // TWAP
        uint256 p0 = oracle.price();

        // single-block manipulation: push a large DIEM amount in, take VVV out
        uint256 diemIn = rDiem / 2;
        uint256 vvvOut = pool.getAmountOut(diemIn, DIEM);
        deal(DIEM, address(this), diemIn);
        IERC20(DIEM).transfer(AERO_POOL, diemIn);
        pool.swap(vvvOut, 0, address(this), ""); // amount0Out = VVV

        uint256 spot1 = pool.getAmountOut(1e18, DIEM);
        uint256 q1 = pool.quote(DIEM, 1e18, GRANULARITY);
        uint256 p1 = oracle.price();

        // the attack was real and large: spot collapsed by >20%
        assertLt(spot1, (spot0 * 80) / 100, "spot VVV/DIEM should crater after dumping DIEM");

        // the TWAP (and oracle) shrugged it off: <2% in the same block
        assertApproxEqRel(q1, q0, 0.02e18, "TWAP moved too much under single-block manipulation");
        assertApproxEqRel(p1, p0, 0.02e18, "oracle price moved too much under manipulation");
    }

    // ─── staleness guard (MOG-548 review) ──────────────────────────────────────

    /// price() must fail CLOSED when the newest committed Aerodrome observation is older than
    /// maxObservationAge — a quiet pool cannot serve a long-stale TWAP that would delay liquidations.
    function test_price_revertsWhenObservationStale() public {
        oracle.price(); // fresh: newest observation is recent on the fork

        // No new observation is committed; advance time past the staleness bound.
        vm.warp(block.timestamp + MAX_AGE + 1);
        vm.expectRevert(WstDiemVvvOracle.StaleObservation.selector);
        oracle.price();
    }
}
