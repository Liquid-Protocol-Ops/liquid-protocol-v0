// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {InferenceVault} from "../../src/vault/InferenceVault.sol";
import {LeverageAction, MarketParams, Router} from "../../src/vault/Router.sol";
import {MockDIEM} from "./mocks/MockDIEM.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console} from "forge-std/Test.sol";

// ── Mock Morpho Blue ──────────────────────────────────────────────────────────
//
// Implements:
//   - flashLoan: mints tokens to receiver, calls onMorphoFlashLoan, then pulls
//                repayment (same as Morpho's real free flash loan mechanic).
//   - supplyCollateral / withdrawCollateral: simple bookkeeping per (caller, market).
//   - borrow / repay: simple bookkeeping.
//   - setAuthorization: permission model.

contract MockMorpho {
    // per-account per-marketId collateral and borrow balances
    mapping(address account => mapping(bytes32 id => uint256)) public collateral;
    mapping(address account => mapping(bytes32 id => uint256)) public borrows;

    // authorization: operator => onBehalf => authorized
    mapping(address operator => mapping(address onBehalf => bool)) public isAuthorized;

    error NotAuthorized();

    // ── Authorization ─────────────────────────────────────────────────────────

    function setAuthorization(address operator, bool authorized) external {
        isAuthorized[operator][msg.sender] = authorized;
    }

    // ── Flash loan ────────────────────────────────────────────────────────────

    /// @dev Morpho's free flash loan: mint tokens to caller, invoke callback,
    ///      then pull repayment (caller must have approved this contract).
    ///      Callback reverts are bubbled up so Forge can match custom errors.
    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        // Give the flash-loaned tokens to the receiver.
        MockDIEM(token).mint(msg.sender, assets);

        // Call callback on the Router — bubble up any revert.
        (bool ok, bytes memory returnData) = msg.sender
            .call(abi.encodeWithSignature("onMorphoFlashLoan(uint256,bytes)", assets, data));
        if (!ok) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }

        // Pull repayment — router must have approved this contract for `assets`.
        IERC20(token).transferFrom(msg.sender, address(this), assets);
    }

    // ── Market operations (bookkeeping only — no health-factor check) ─────────

    function _marketId(MarketParams calldata params) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                params.loanToken, params.collateralToken, params.oracle, params.irm, params.lltv
            )
        );
    }

    function supplyCollateral(
        MarketParams calldata params,
        uint256 assets,
        address onBehalf,
        bytes calldata
    ) external {
        // Operator must be authorized by onBehalf (or be onBehalf).
        if (msg.sender != onBehalf && !isAuthorized[msg.sender][onBehalf]) {
            revert NotAuthorized();
        }
        IERC20(params.collateralToken).transferFrom(msg.sender, address(this), assets);
        collateral[onBehalf][_marketId(params)] += assets;
    }

    function withdrawCollateral(
        MarketParams calldata params,
        uint256 assets,
        address onBehalf,
        address receiver
    ) external {
        if (msg.sender != onBehalf && !isAuthorized[msg.sender][onBehalf]) {
            revert NotAuthorized();
        }
        collateral[onBehalf][_marketId(params)] -= assets;
        IERC20(params.collateralToken).transfer(receiver, assets);
    }

    function borrow(
        MarketParams calldata params,
        uint256 assets,
        uint256, /* shares */
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256) {
        if (msg.sender != onBehalf && !isAuthorized[msg.sender][onBehalf]) {
            revert NotAuthorized();
        }
        borrows[onBehalf][_marketId(params)] += assets;
        // Mint loan tokens to receiver.
        MockDIEM(params.loanToken).mint(receiver, assets);
        return (assets, 0);
    }

    function repay(
        MarketParams calldata params,
        uint256 assets,
        uint256, /* shares */
        address onBehalf,
        bytes calldata
    ) external returns (uint256, uint256) {
        if (msg.sender != onBehalf && !isAuthorized[msg.sender][onBehalf]) {
            revert NotAuthorized();
        }
        borrows[onBehalf][_marketId(params)] -= assets;
        IERC20(params.loanToken).transferFrom(msg.sender, address(this), assets);
        return (assets, 0);
    }

    // ── View helpers ─────────────────────────────────────────────────────────

    function getCollateral(address account, MarketParams calldata params)
        external
        view
        returns (uint256)
    {
        return collateral[account][_marketId(params)];
    }

    function getBorrow(address account, MarketParams calldata params)
        external
        view
        returns (uint256)
    {
        return borrows[account][_marketId(params)];
    }
}

// ── Mock Curve DIEM/wstDIEM pool ─────────────────────────────────────────────
//
// Simulates a 1:1 StableSwap (no slippage) so tests are deterministic.
// In production the Curve pool would trade at market price (wstDIEM > DIEM when
// yield has accrued). Index: 0=DIEM, 1=wstDIEM.

contract MockCurvePool {
    address public immutable diem;
    address public immutable wstDiem;

    constructor(address _diem, address _wstDiem) {
        diem = _diem;
        wstDiem = _wstDiem;
    }

    /// @dev exchange(i, j, dx, min_dy) — 1:1 mock, no fee.
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy)
        external
        returns (uint256 dy)
    {
        require((i == 0 && j == 1) || (i == 1 && j == 0), "MockCurve: invalid pair");

        address tokenIn = i == 0 ? diem : wstDiem;
        address tokenOut = j == 0 ? diem : wstDiem;

        IERC20(tokenIn).transferFrom(msg.sender, address(this), dx);

        // 1:1 swap — mint the output token (pool acts as infinite liquidity source).
        MockDIEM(tokenOut).mint(msg.sender, dx);
        dy = dx;

        require(dy >= min_dy, "MockCurve: slippage");
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

contract LeverageRouterTest is Test {
    // ── Fixtures ──────────────────────────────────────────────────────────────

    MockDIEM diem;
    InferenceVault vault;
    MockMorpho morpho;
    MockCurvePool curve;
    Router router;

    address alice = makeAddr("alice");

    MarketParams market;

    // LTV = 70%; must be < market.lltv (75%)
    uint256 constant TARGET_LTV = 0.7e18;
    uint256 constant MARKET_LLTV = 0.75e18;

    // ── setUp ─────────────────────────────────────────────────────────────────

    function setUp() public {
        // 1. Deploy mock tokens and vault.
        diem = new MockDIEM();
        vault = new InferenceVault(
            address(diem), makeAddr("treasury"), makeAddr("veniceSigner"), address(this)
        );
        // Note: the new vault has async withdrawal queue (requestRedeem/flush/settle/claimRedeem).
        // The leverage loop uses Curve for synchronous wstDIEM→DIEM exit in unloopDeposit,
        // so no vault withdrawal mechanics are needed in these tests.

        // 3. Deploy Morpho and Curve mocks.
        morpho = new MockMorpho();
        // MockCurvePool needs to mint wstDIEM — vault (wstDIEM) is an ERC20 but
        // minting requires calling vault.deposit. We use a special mock vault-aware
        // Curve that simply transfers from its own balance. To keep it simple we use
        // MockDIEM as a stand-in for wstDIEM in the Curve mock and override below.
        // Actually: MockCurvePool mints via MockDIEM(tokenOut).mint — but vault
        // (wstDIEM) is not a MockDIEM. We'll use a MockWstDIEM wrapper for Curve.
        // Simplest approach: for the unloop test, pre-fund the Curve mock with
        // wstDIEM by seeding it from alice's vault balance (no mint needed).
        curve = new MockCurvePool(address(diem), address(vault));

        // 4. Deploy Router (now with morpho param).
        //    weth and vvvStaking are irrelevant to leverage tests — use dummy addresses.
        router = new Router(
            address(vault),
            makeAddr("weth"),
            makeAddr("vvv"),
            makeAddr("vvvStaking"),
            address(morpho),
            address(this)
        );

        // 5. Configure Router.
        market = MarketParams({
            loanToken: address(diem),
            collateralToken: address(vault),
            oracle: address(0),
            irm: address(0),
            lltv: MARKET_LLTV
        });
        router.setLeverageMarket(market);
        router.setCurvePool(address(curve));

        // 6. Fund alice with DIEM.
        diem.mint(alice, 10_000e18);

        // 7. Alice authorizes Router on Morpho.
        vm.prank(alice);
        morpho.setAuthorization(address(router), true);

        // 8. Approve Router to pull DIEM from alice.
        vm.prank(alice);
        diem.approve(address(router), type(uint256).max);

        // 9. Pre-fund Curve mock with wstDIEM so it can exchange wstDIEM→DIEM.
        //    Alice deposits 5000 DIEM → gets wstDIEM → transfers to Curve pool.
        vm.startPrank(alice);
        diem.approve(address(vault), type(uint256).max);
        uint256 curveWstSeed = vault.deposit(5000e18, alice);
        IERC20(address(vault)).transfer(address(curve), curveWstSeed);
        vm.stopPrank();
    }

    // ── loopDeposit tests ─────────────────────────────────────────────────────

    /// @notice loopDeposit produces wstDIEM collateral close to totalDiem * (1-fee).
    function test_loopDeposit_producesCorrectWstAmount() public {
        uint256 diemIn = 1000e18;
        // totalDiem = 1000 / (1 - 0.70) = 3333.33...
        uint256 totalDiem = diemIn * 1e18 / (1e18 - TARGET_LTV);
        // expectedWst: vault applies 250 bps deposit fee
        uint256 expectedWst = vault.previewDeposit(totalDiem);

        vm.prank(alice);
        uint256 totalWst = router.loopDeposit(diemIn, TARGET_LTV, 0);

        // Return value should equal previewDeposit(totalDiem)
        assertApproxEqRel(totalWst, expectedWst, 0.01e18, "wst amount mismatch");
        assertGt(totalWst, 0, "must produce wstDIEM");
    }

    /// @notice The Morpho collateral ledger reflects the full wstDIEM amount.
    function test_loopDeposit_collateralOnMorpho() public {
        uint256 diemIn = 1000e18;
        uint256 totalDiem = diemIn * 1e18 / (1e18 - TARGET_LTV);
        uint256 expectedWst = vault.previewDeposit(totalDiem);

        vm.prank(alice);
        router.loopDeposit(diemIn, TARGET_LTV, 0);

        uint256 col = morpho.getCollateral(alice, market);
        assertApproxEqRel(col, expectedWst, 0.01e18, "Morpho collateral mismatch");
    }

    /// @notice Morpho borrow equals the flash-loan amount (totalDiem - diemIn).
    function test_loopDeposit_borrowEqualsFlashAmount() public {
        uint256 diemIn = 1000e18;
        uint256 totalDiem = diemIn * 1e18 / (1e18 - TARGET_LTV);
        uint256 expectedFlash = totalDiem - diemIn;

        vm.prank(alice);
        router.loopDeposit(diemIn, TARGET_LTV, 0);

        uint256 borrow = morpho.getBorrow(alice, market);
        assertApproxEqRel(borrow, expectedFlash, 0.01e18, "borrow != flashAmount");
    }

    /// @notice Realized LTV = borrow / collateralValue is close to targetLTV.
    ///         Uses approxEqRel to tolerate the vault deposit fee (250 bps).
    function test_loopDeposit_targetLTVRespected() public {
        uint256 diemIn = 1000e18;

        vm.prank(alice);
        router.loopDeposit(diemIn, TARGET_LTV, 0);

        uint256 col = morpho.getCollateral(alice, market);
        uint256 borrow = morpho.getBorrow(alice, market);

        // wstDIEM collateral is 1:1 with DIEM (fresh vault, no yield accrued yet).
        // realizedLTV = borrow / col
        uint256 realizedLTV = borrow * 1e18 / col;

        // loopDeposit routes equity+flash through vault.deposit, which charges
        // depositFeeBps. Post-fee collateral shrinks, so realized LTV =
        // target / (1 - depositFee). At the 2.5% fee a 70% target realizes ~71.8%,
        // held safely below the 75% LLTV by loopDeposit's fee-aware headroom guard.
        uint256 feeBps = vault.currentDepositFeeBps();
        uint256 expectedLTV = TARGET_LTV * 10_000 / (10_000 - feeBps);
        assertApproxEqRel(realizedLTV, expectedLTV, 0.005e18, "LTV mismatch");
    }

    /// @notice minWstOut slippage guard reverts when set above actual output.
    function test_loopDeposit_minWstOut_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("SlippageExceeded()"));
        router.loopDeposit(1000e18, TARGET_LTV, type(uint256).max);
    }

    /// @notice targetLTV >= lltv reverts with LtvTooHigh.
    function test_loopDeposit_ltvTooHigh_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("LtvTooHigh()"));
        router.loopDeposit(1000e18, MARKET_LLTV, 0); // targetLTV == lltv → revert
    }

    /// @notice Unauthorized caller on Morpho reverts.
    function test_loopDeposit_morphoNotAuthorized_reverts() public {
        address bob = makeAddr("bob");
        diem.mint(bob, 1000e18);
        vm.startPrank(bob);
        diem.approve(address(router), type(uint256).max);
        // bob did NOT call morpho.setAuthorization(router, true)
        vm.expectRevert();
        router.loopDeposit(1000e18, TARGET_LTV, 0);
        vm.stopPrank();
    }

    /// @notice Direct onMorphoFlashLoan call from non-Morpho reverts.
    function test_onMorphoFlashLoan_onlyMorpho() public {
        vm.expectRevert(abi.encodeWithSignature("OnlyMorpho()"));
        router.onMorphoFlashLoan(0, "");
    }

    // ── unloopDeposit tests ───────────────────────────────────────────────────

    /// @dev Helper: alice opens a leveraged position and returns (wstCollateral, diemBorrow).
    function _openPosition(uint256 diemIn)
        internal
        returns (uint256 wstCollateral, uint256 diemBorrow)
    {
        vm.prank(alice);
        router.loopDeposit(diemIn, TARGET_LTV, 0);
        wstCollateral = morpho.getCollateral(alice, market);
        diemBorrow = morpho.getBorrow(alice, market);
    }

    /// @notice unloopDeposit returns net DIEM to caller.
    function test_unloopDeposit_returnsDiem() public {
        (uint256 wstCol, uint256 diemBorrow) = _openPosition(1000e18);

        uint256 diemBefore = diem.balanceOf(alice);

        vm.prank(alice);
        uint256 netDiem = router.unloopDeposit(wstCol, diemBorrow, 0);

        uint256 diemAfter = diem.balanceOf(alice);
        assertGt(diemAfter, diemBefore, "alice must receive DIEM");
        // Net DIEM ≈ wstCol (1:1 Curve, no fee) - diemBorrow; with deposit fee
        // wstCol < totalDiem so net is positive but slightly less than initial equity.
        assertGt(netDiem, 0, "netDiem must be positive");
    }

    /// @notice After unloop, Morpho position is fully closed (zero collateral, zero borrow).
    function test_unloopDeposit_closesPosition() public {
        (uint256 wstCol, uint256 diemBorrow) = _openPosition(1000e18);

        vm.prank(alice);
        router.unloopDeposit(wstCol, diemBorrow, 0);

        assertEq(morpho.getCollateral(alice, market), 0, "collateral not cleared");
        assertEq(morpho.getBorrow(alice, market), 0, "borrow not cleared");
    }

    /// @notice minDiemOut slippage guard reverts when set above net DIEM output.
    function test_unloopDeposit_minDiemOut_reverts() public {
        (uint256 wstCol, uint256 diemBorrow) = _openPosition(1000e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("SlippageExceeded()"));
        router.unloopDeposit(wstCol, diemBorrow, type(uint256).max);
    }

    /// @notice Partial unwind: withdraw half the collateral and repay half the borrow.
    function test_unloopDeposit_partial() public {
        (uint256 wstCol, uint256 diemBorrow) = _openPosition(1000e18);

        uint256 halfWst = wstCol / 2;
        uint256 halfBorrow = diemBorrow / 2;

        vm.prank(alice);
        uint256 netDiem = router.unloopDeposit(halfWst, halfBorrow, 0);

        // Half the collateral should remain.
        assertApproxEqRel(
            morpho.getCollateral(alice, market), wstCol - halfWst, 0.01e18, "collateral remainder"
        );
        // Half the borrow should remain.
        assertApproxEqRel(
            morpho.getBorrow(alice, market), diemBorrow - halfBorrow, 0.01e18, "borrow remainder"
        );
        assertGt(netDiem, 0, "partial unloop must return DIEM");
    }

    // ── Admin tests ───────────────────────────────────────────────────────────

    function test_setLeverageMarket_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        router.setLeverageMarket(market);
    }

    function test_setCurvePool_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        router.setCurvePool(address(curve));
    }

    function test_loopDeposit_marketNotSet_reverts() public {
        // Deploy a fresh router with no market set.
        Router freshRouter = new Router(
            address(vault),
            makeAddr("weth2"),
            makeAddr("vvv2"),
            makeAddr("vvvStaking2"),
            address(morpho),
            address(this)
        );
        diem.mint(alice, 1000e18);
        vm.prank(alice);
        diem.approve(address(freshRouter), type(uint256).max);
        vm.prank(alice);
        morpho.setAuthorization(address(freshRouter), true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("MarketNotSet()"));
        freshRouter.loopDeposit(1000e18, TARGET_LTV, 0);
    }
}
