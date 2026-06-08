// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console} from "forge-std/Test.sol";

// Morpho Blue surface (structs by value)
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

interface IMorpho {
    function supply(
        MarketParams memory m,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256, uint256);
    function supplyCollateral(
        MarketParams memory m,
        uint256 assets,
        address onBehalf,
        bytes memory data
    ) external;
    function borrow(
        MarketParams memory m,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256);
    function position(bytes32 id, address user)
        external
        view
        returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
    function market(bytes32 id)
        external
        view
        returns (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        );
    function accrueInterest(MarketParams memory m) external;
    function liquidate(
        MarketParams memory m,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes memory data
    ) external returns (uint256, uint256);
}

interface ICurve {
    // DIEM/wstDIEM StableSwap: coin0 = DIEM, coin1 = wstDIEM
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function add_liquidity(uint256[] calldata amounts, uint256 min_mint_amount)
        external
        returns (uint256);
}

interface IAeroSwap {
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IVVVStaking {
    function stake(address to, uint256 vvvAmount) external;
    function mintDiem(uint256 sVVVAmount, uint256 minDiemOut) external;
}

interface IVault {
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @notice Fork rehearsal of the live wstDIEM/VVV Morpho market (MOG-544) against the
///         REAL deployed contracts on Base: vault v5, oracle 0xC76e…, market 0xab03….
///         Stage 1 — economics (VVV→DIEM mint ratio) + the borrow side. Liquidation
///         unwind (Curve→Aerodrome) follows in a later stage.
/// Run: BASE_RPC_URL=<url> forge test --match-path "test/vault/integration/VvvMarketLifecycle.t.sol" -vv
contract VvvMarketLifecycleTest is Test {
    // Real Base mainnet deployments
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;
    address constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf; // liquid VVV
    address constant SVVV = 0x321b7ff75154472B18EDb199033fF4D116F340Ff; // staking → sVVV
    address constant WSTDIEM = 0xb9f23c33FfD2213f31C0cFb6c9e2fDf525a9Dd2D; // InferenceVault v5
    address constant ORACLE = 0xC76e2fe5176B432035Def5362023a8DF36bEE94E;
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant IRM = 0x46415998764C29aB2a25CbeA6254146D50D22687;
    uint256 constant LLTV = 625e15; // 62.5%
    address constant CURVE = 0xB9c7F62e4EeC145bFa1C6bBc5fFdFf246181FdA2; // DIEM/wstDIEM StableSwap

    MarketParams mp;
    bytes32 marketId;

    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        mp = MarketParams({
            loanToken: VVV, collateralToken: WSTDIEM, oracle: ORACLE, irm: IRM, lltv: LLTV
        });
        marketId = keccak256(abi.encode(mp));
        // confirm we forked past the deploy and hit the real market
        assertEq(marketId, 0xab0345699b8e7a86763b6adbf165c6cd367d11d8e6d875c0f1a20861d8f4f8c8);
    }

    /// The gating economic fact: how much DIEM does staking VVV + mintDiem yield?
    /// Decides whether WETH→VVV→DIEM can source meaningful DIEM at production scale.
    function test_mintRatio_vvvToDiem() public {
        uint256 vvvIn = 1000e18;
        deal(VVV, address(this), vvvIn);

        uint256 diemBefore = IERC20(DIEM).balanceOf(address(this));
        IERC20(VVV).approve(SVVV, vvvIn);
        IVVVStaking(SVVV).stake(address(this), vvvIn);
        uint256 sVvvAfterStake = IERC20(SVVV).balanceOf(address(this));
        IVVVStaking(SVVV).mintDiem(sVvvAfterStake, 0);
        uint256 sVvvAfterMint = IERC20(SVVV).balanceOf(address(this));
        uint256 diemOut = IERC20(DIEM).balanceOf(address(this)) - diemBefore;

        console.log("VVV staked          :", vvvIn / 1e18);
        console.log("sVVV after stake    :", sVvvAfterStake / 1e18);
        console.log("sVVV after mintDiem :", sVvvAfterMint / 1e18); // consumed? or retained?
        console.log("DIEM minted (wei)   :", diemOut);
        if (diemOut > 0) console.log("VVV per DIEM (mint) :", vvvIn / diemOut);

        // Compare: direct Aerodrome VVV->DIEM swap rate (market price).
        uint256 vvvPerDiemMkt = _aeroQuote(DIEM, 1e18); // VVV needed per 1 DIEM at TWAP
        console.log("VVV per DIEM (mkt)  :", vvvPerDiemMkt / 1e18);

        assertGt(diemOut, 0, "mintDiem should yield DIEM");
    }

    /// Borrow side against the LIVE oracle/market: lender supplies VVV, borrower posts
    /// wstDIEM collateral (minted from real DIEM via the real vault) and borrows VVV.
    function test_borrowVvv_againstRealMarket() public {
        IMorpho morpho = IMorpho(MORPHO);

        // Borrower mints real wstDIEM by depositing DIEM into the live vault.
        deal(DIEM, borrower, 100e18);
        vm.startPrank(borrower);
        IERC20(DIEM).approve(WSTDIEM, type(uint256).max);
        uint256 collat = IVault(WSTDIEM).deposit(100e18, borrower);
        vm.stopPrank();
        assertGt(collat, 0, "deposit minted no wstDIEM");

        // Lender supplies VVV liquidity.
        uint256 supplyVvv = 20_000e18;
        deal(VVV, lender, supplyVvv);
        vm.startPrank(lender);
        IERC20(VVV).approve(MORPHO, type(uint256).max);
        morpho.supply(mp, supplyVvv, 0, lender, "");
        vm.stopPrank();

        // Borrower posts collateral and borrows ~80% of the LLTV-implied max.
        uint256 priceWad = 1e36; // ORACLE_PRICE_SCALE
        uint256 maxBorrow = (uint256(collat) * _oraclePrice()) / priceWad * LLTV / 1e18;
        uint256 borrowVvv = (maxBorrow * 80) / 100;

        vm.startPrank(borrower);
        IERC20(WSTDIEM).approve(MORPHO, type(uint256).max);
        morpho.supplyCollateral(mp, collat, borrower, "");
        (uint256 borrowed,) = morpho.borrow(mp, borrowVvv, 0, borrower, borrower);
        vm.stopPrank();

        assertEq(IERC20(VVV).balanceOf(borrower), borrowed, "borrower received VVV");
        assertApproxEqAbs(borrowed, borrowVvv, 1);

        console.log("collateral wstDIEM:", uint256(collat) / 1e18);
        console.log("max borrow VVV    :", maxBorrow / 1e18);
        console.log("borrowed VVV (80%):", borrowed / 1e18);
        (,, uint128 posCollat) = morpho.position(marketId, borrower);
        assertEq(posCollat, collat, "collateral recorded");
    }

    /// Keystone: the full liquidation lifecycle + unwind that GATES the live market.
    /// underwater (via interest) → Morpho liquidate (seize wstDIEM) → unwind the seized
    /// collateral back to VVV: wstDIEM → DIEM (Curve) → VVV (Aerodrome).
    /// NOTE: Curve is seeded with deal'd tokens here — this proves the unwind ROUTING,
    /// NOT that real on-chain depth exists (live Curve is empty; that's a mainnet check).
    function test_liquidation_unwind() public {
        IMorpho morpho = IMorpho(MORPHO);

        // 1. Seed the (empty) live Curve DIEM/wstDIEM pool so the unwind hop has depth.
        address seeder = makeAddr("seeder");
        deal(DIEM, seeder, 2000e18);
        vm.startPrank(seeder);
        IERC20(DIEM).approve(WSTDIEM, type(uint256).max);
        uint256 seedShares = IVault(WSTDIEM).deposit(1000e18, seeder);
        IERC20(DIEM).approve(CURVE, type(uint256).max);
        IERC20(WSTDIEM).approve(CURVE, type(uint256).max);
        uint256[] memory amts = new uint256[](2);
        amts[0] = 1000e18; // DIEM (coin0)
        amts[1] = seedShares; // wstDIEM (coin1)
        ICurve(CURVE).add_liquidity(amts, 0);
        vm.stopPrank();

        // 2. Borrower opens a near-max position (collateral = real wstDIEM).
        deal(DIEM, borrower, 100e18);
        vm.startPrank(borrower);
        IERC20(DIEM).approve(WSTDIEM, type(uint256).max);
        uint256 collat = IVault(WSTDIEM).deposit(100e18, borrower);
        vm.stopPrank();

        uint256 maxBorrow = uint256(collat) * _oraclePrice() / 1e36 * LLTV / 1e18;
        uint256 borrowAmt = maxBorrow * 99 / 100;

        // Lender supplies just above the borrow → high utilization → fast interest.
        address lender2 = makeAddr("lender2");
        uint256 supplyAmt = borrowAmt * 103 / 100;
        deal(VVV, lender2, supplyAmt);
        vm.startPrank(lender2);
        IERC20(VVV).approve(MORPHO, type(uint256).max);
        morpho.supply(mp, supplyAmt, 0, lender2, "");
        vm.stopPrank();

        vm.startPrank(borrower);
        IERC20(WSTDIEM).approve(MORPHO, type(uint256).max);
        morpho.supplyCollateral(mp, collat, borrower, "");
        morpho.borrow(mp, borrowAmt, 0, borrower, borrower);
        vm.stopPrank();

        // 3. Accrue interest → debt grows past collateral × LLTV.
        vm.warp(block.timestamp + 120 days);
        morpho.accrueInterest(mp);

        (, uint128 borrowShares,) = morpho.position(marketId, borrower);
        (,, uint128 totBorrowAssets, uint128 totBorrowShares,,) = morpho.market(marketId);
        uint256 debt = uint256(borrowShares) * totBorrowAssets / totBorrowShares;
        assertGt(debt, maxBorrow, "position should be underwater after interest accrual");
        console.log("debt VVV        :", debt / 1e18);
        console.log("maxBorrow VVV   :", maxBorrow / 1e18);

        // 4. Liquidate: seize half the collateral, repaying VVV debt.
        address liquidator = makeAddr("liquidator");
        deal(VVV, liquidator, debt);
        uint256 vvvStart = IERC20(VVV).balanceOf(liquidator);
        vm.startPrank(liquidator);
        IERC20(VVV).approve(MORPHO, type(uint256).max);
        (uint256 seized, uint256 repaid) =
            morpho.liquidate(mp, borrower, uint256(collat) / 2, 0, "");
        vm.stopPrank();
        assertEq(IERC20(WSTDIEM).balanceOf(liquidator), seized, "liquidator holds seized wstDIEM");
        console.log("seized wstDIEM  :", seized / 1e18);
        console.log("repaid VVV      :", repaid / 1e18);

        // 5. Unwind seized wstDIEM → DIEM (Curve) → VVV (Aerodrome).
        vm.startPrank(liquidator);
        IERC20(WSTDIEM).approve(CURVE, type(uint256).max);
        uint256 diemOut = ICurve(CURVE).exchange(1, 0, seized, 0); // wstDIEM(1) → DIEM(0)
        assertGt(diemOut, 0, "Curve wstDIEM->DIEM yielded nothing");

        uint256 vvvOut = IAeroSwap(AERO_POOL).getAmountOut(diemOut, DIEM);
        IERC20(DIEM).transfer(AERO_POOL, diemOut);
        IAeroSwap(AERO_POOL).swap(vvvOut, 0, liquidator, ""); // token0 = VVV out
        vm.stopPrank();

        uint256 vvvEnd = IERC20(VVV).balanceOf(liquidator);
        assertGt(vvvOut, 0, "Aerodrome DIEM->VVV yielded nothing");
        assertGt(vvvEnd, vvvStart - repaid, "unwind must return VVV to the liquidator");
        console.log("DIEM from Curve :", diemOut / 1e18);
        console.log("VVV from unwind :", vvvOut / 1e18);
        console.log("liquidator net VVV (end - start):", int256(vvvEnd) - int256(vvvStart));
    }

    function _oraclePrice() internal view returns (uint256) {
        (bool ok, bytes memory ret) = ORACLE.staticcall(abi.encodeWithSignature("price()"));
        require(ok, "oracle price() failed");
        return abi.decode(ret, (uint256));
    }

    // Aerodrome DIEM/VVV pool TWAP: VVV out for `amountIn` of `tokenIn`.
    address constant AERO_POOL = 0xbB345D35450BF9Ee76F3D2cE214E8e7AC5e1071d;

    function _aeroQuote(address tokenIn, uint256 amountIn) internal view returns (uint256) {
        (bool ok, bytes memory ret) = AERO_POOL.staticcall(
            abi.encodeWithSignature("quote(address,uint256,uint256)", tokenIn, amountIn, uint256(2))
        );
        require(ok, "aero quote failed");
        return abi.decode(ret, (uint256));
    }
}
