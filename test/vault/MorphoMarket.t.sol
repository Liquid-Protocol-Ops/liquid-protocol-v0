// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DeployMorphoMarket, WstDIEMMorphoOracle} from "../../script/vault/DeployMorphoMarket.s.sol";
import {InferenceVault} from "../../src/vault/InferenceVault.sol";
import {WstDiemUsdcOracle} from "../../src/vault/oracles/WstDiemUsdcOracle.sol";
import {WstDiemWethOracle} from "../../src/vault/oracles/WstDiemWethOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console} from "forge-std/Test.sol";

struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

interface IMorpho {
    function createMarket(MarketParams calldata params) external;
    function isIrmEnabled(address irm) external view returns (bool);
    function isLltvEnabled(uint256 lltv) external view returns (bool);
}

contract MorphoMarketTest is Test {
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant ADAPTIVE_CURVE_IRM = 0x46415998764C29aB2a25CbeA6254146D50D22687;
    address constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    InferenceVault vault;
    WstDIEMMorphoOracle diemOracle;
    WstDiemUsdcOracle usdcOracle;
    WstDiemWethOracle wethOracle;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        vault =
            new InferenceVault(DIEM, makeAddr("treasury"), makeAddr("veniceSigner"), address(this));
        diemOracle = new WstDIEMMorphoOracle(address(vault));
        usdcOracle = new WstDiemUsdcOracle(address(vault));
        wethOracle = new WstDiemWethOracle(address(vault), ETH_USD_FEED, 3600);
    }

    // ── DIEM oracle (existing) ─────────────────────────────────────────────
    function test_diemOracle_priceIsNonZero() public view {
        assertGt(diemOracle.price(), 0, "oracle price must be non-zero");
    }

    function test_diemOracle_priceApprox1e36() public view {
        // Fresh vault: convertToAssets(1e18) = 1e18, so price = 1e36
        assertApproxEqRel(diemOracle.price(), 1e36, 0.01e18, "initial price ~1e36");
    }

    // ── USDC oracle ───────────────────────────────────────────────────────
    function test_usdcOracle_priceIsNonZero() public view {
        assertGt(usdcOracle.price(), 0);
    }

    function test_usdcOracle_freshVaultPriceIs1e24() public view {
        // Fresh vault rate = 1.0 → 1 wstDIEM = 1 DIEM = $1 = 1 USDC = 1e6 USDC units
        // Morpho price = 1e18 × 1e6 = 1e24
        assertApproxEqRel(usdcOracle.price(), 1e24, 0.01e18, "fresh vault: price ~1e24");
    }

    function test_usdcOracle_priceRisesWithRate() public {
        // Credit DIEM to raise exchange rate — price() must rise proportionally
        deal(DIEM, address(this), 1000e18);
        IERC20(DIEM).approve(address(vault), 1000e18);
        vault.deposit(1000e18, address(this));
        vault.setVenueAdapter(address(this), true);

        uint256 priceBefore = usdcOracle.price();

        // creditDIEM raises the rate
        deal(DIEM, address(this), 100e18);
        IERC20(DIEM).approve(address(vault), 100e18);
        vault.creditDIEM(100e18);

        assertGt(usdcOracle.price(), priceBefore, "oracle price must rise with vault rate");
    }

    function test_usdcOracle_borrowableAmountCorrect() public view {
        // 1 wstDIEM (1e18 units) → should borrow ~1 USDC (1e6 units) at rate = 1.0
        uint256 p = usdcOracle.price();
        uint256 borrowable = 1e18 * p / 1e36;
        // Should be close to 1e6 (1 USDC)
        assertApproxEqRel(borrowable, 1e6, 0.01e18, "1 wstDIEM ~1 USDC borrowable");
    }

    // ── WETH oracle ───────────────────────────────────────────────────────
    function test_wethOracle_priceIsNonZero() public view {
        assertGt(wethOracle.price(), 0);
    }

    function test_wethOracle_priceImpliesReasonableEthRate() public view {
        // 1 wstDIEM = ~$1 and ETH is somewhere between $1000-$10000
        // So 1 wstDIEM = 0.0001–0.001 WETH (1e14–1e15 WETH base units)
        uint256 p = wethOracle.price();
        uint256 wethPerWstDiem = 1e18 * p / 1e36; // WETH base units per wstDIEM
        // Sanity: between $100 ETH and $100,000 ETH
        assertGt(wethPerWstDiem, 1e13, "ETH price seems too high (>$100k)");
        assertLt(wethPerWstDiem, 1e16, "ETH price seems too low (<$100)");
    }

    function test_wethOracle_priceRisesWithRate() public {
        deal(DIEM, address(this), 1000e18);
        IERC20(DIEM).approve(address(vault), 1000e18);
        vault.deposit(1000e18, address(this));
        vault.setVenueAdapter(address(this), true);

        uint256 priceBefore = wethOracle.price();

        deal(DIEM, address(this), 100e18);
        IERC20(DIEM).approve(address(vault), 100e18);
        vault.creditDIEM(100e18);

        assertGt(wethOracle.price(), priceBefore, "WETH oracle price must rise with vault rate");
    }

    function test_createMorphoMarket() public {
        IMorpho morpho = IMorpho(MORPHO_BLUE);

        // Find an enabled LLTV
        uint256 lltv = 77e16;
        if (!morpho.isLltvEnabled(lltv)) {
            // Try other common LLTVs
            uint256[4] memory candidates =
                [uint256(86e16), uint256(625e15), uint256(385e15), uint256(0)];
            for (uint256 i = 0; i < candidates.length; i++) {
                if (morpho.isLltvEnabled(candidates[i])) {
                    lltv = candidates[i];
                    break;
                }
            }
        }

        assertTrue(morpho.isIrmEnabled(ADAPTIVE_CURVE_IRM), "IRM must be enabled");

        MarketParams memory params = MarketParams({
            loanToken: DIEM,
            collateralToken: address(vault),
            oracle: address(diemOracle),
            irm: ADAPTIVE_CURVE_IRM,
            lltv: lltv
        });

        // Should not revert
        morpho.createMarket(params);
    }
}
