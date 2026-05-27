// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DeployMorphoMarket, WstDIEMMorphoOracle} from "../../script/vault/DeployMorphoMarket.s.sol";
import {InferenceVault} from "../../src/vault/InferenceVault.sol";
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
    address constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant ADAPTIVE_CURVE_IRM = 0x46415998764C29aB2a25CbeA6254146D50D22687;

    InferenceVault vault;
    WstDIEMMorphoOracle oracle;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        vault = new InferenceVault(DIEM, makeAddr("treasury"), address(this));
        oracle = new WstDIEMMorphoOracle(address(vault));
    }

    function test_oracle_priceIsNonZero() public view {
        assertGt(oracle.price(), 0, "oracle price must be non-zero");
    }

    function test_oracle_priceApprox1e36() public view {
        // Fresh vault: convertToAssets(1e18) = 1e18, so price = 1e36
        assertApproxEqRel(oracle.price(), 1e36, 0.01e18, "initial price ~1e36");
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
            oracle: address(oracle),
            irm: ADAPTIVE_CURVE_IRM,
            lltv: lltv
        });

        // Should not revert
        morpho.createMarket(params);
    }
}
