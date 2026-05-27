// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

interface IMorpho {
    function createMarket(MarketParams calldata marketParams) external;
    function isLltvEnabled(uint256 lltv) external view returns (bool);
    function isIrmEnabled(address irm) external view returns (bool);
}

interface IInferenceVaultMinimal {
    function convertToAssets(uint256 shares) external view returns (uint256);
}

contract WstDIEMMorphoOracle {
    IInferenceVaultMinimal public immutable vault;

    constructor(address _vault) {
        vault = IInferenceVaultMinimal(_vault);
    }

    // Morpho oracle: price() returns collateral price in loan token, scaled to 1e36
    function price() external view returns (uint256) {
        return vault.convertToAssets(1e18) * 1e18;
    }
}

contract DeployMorphoMarket is Script {
    address constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;
    address constant ADAPTIVE_CURVE_IRM = 0x46415998764C29aB2a25CbeA6254146D50D22687;

    address immutable WSTDIEM;

    constructor(address wstDIEM) {
        WSTDIEM = wstDIEM;
    }

    function deployOracle() public returns (address) {
        return address(new WstDIEMMorphoOracle(WSTDIEM));
    }

    function run() external {
        vm.startBroadcast();
        address oracle = deployOracle();
        console.log("Morpho oracle deployed at:", oracle);
        _createMarket(oracle);
        vm.stopBroadcast();
    }

    function _createMarket(address oracle) internal {
        // Check available enabled LLTVs — if 77e16 isn't enabled, use the nearest enabled one
        IMorpho morpho = IMorpho(MORPHO_BLUE);
        uint256 lltv = 77e16;
        // Fall back to 0 LLTV (always enabled) if 77% isn't enabled
        if (!morpho.isLltvEnabled(lltv)) {
            lltv = 0;
        }

        MarketParams memory params = MarketParams({
            loanToken: DIEM,
            collateralToken: WSTDIEM,
            oracle: oracle,
            irm: ADAPTIVE_CURVE_IRM,
            lltv: lltv
        });

        IMorpho(MORPHO_BLUE).createMarket(params);
        console.log("Morpho wstDIEM/DIEM market created with LLTV:", lltv);
    }
}
