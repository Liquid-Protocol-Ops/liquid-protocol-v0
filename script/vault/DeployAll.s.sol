// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AgentTGERegistry} from "../../src/vault/AgentTGERegistry.sol";
import {FeeRouter} from "../../src/vault/FeeRouter.sol";
import {InferenceVault} from "../../src/vault/InferenceVault.sol";
import {Router} from "../../src/vault/Router.sol";
import {SurplusStakingWrapper} from "../../src/vault/SurplusStakingWrapper.sol";
import {DeployCurvePool} from "./DeployCurvePool.s.sol";
import {DeployMorphoMarket} from "./DeployMorphoMarket.s.sol";
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
}

contract DeployAll is Script {
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;
    address constant VVV_STAKING = 0x321b7ff75154472B18EDb199033fF4D116F340Ff;
    address constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant ADAPTIVE_CURVE_IRM = 0x46415998764C29aB2a25CbeA6254146D50D22687;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address safe = vm.envAddress("SAFE_MULTISIG_ADDRESS");

        vm.startBroadcast();

        // Phase A: wstDIEM vault
        InferenceVault vault = new InferenceVault(DIEM, treasury, deployer);
        console.log("InferenceVault:", address(vault));

        // Phase B: Curve DIEM/wstDIEM pool
        // Use deployPool() (no nested broadcast) — run() would call vm.startBroadcast() again
        DeployCurvePool curveDeployer = new DeployCurvePool(address(vault));
        address curvePool = curveDeployer.deployPool();
        console.log("Curve pool:", curvePool);

        // Phase C: FeeRouter
        FeeRouter feeRouter =
            new FeeRouter(address(vault), WETH, VVV, VVV_STAKING, curvePool, address(0));
        console.log("FeeRouter:", address(feeRouter));
        vault.setFeeRouter(address(feeRouter));

        // Phase C: Router
        Router router = new Router(address(vault), WETH, VVV_STAKING);
        router.setCurvePool(curvePool);
        console.log("Router:", address(router));

        // Phase D: AgentTGERegistry
        AgentTGERegistry registry = new AgentTGERegistry(address(feeRouter), deployer);
        console.log("AgentTGERegistry:", address(registry));

        // Phase D: SurplusStakingWrapper
        SurplusStakingWrapper wrapper = new SurplusStakingWrapper(address(vault), curvePool);
        console.log("SurplusStakingWrapper:", address(wrapper));

        // Phase E: Morpho oracle + market
        // Use deployOracle() directly — DeployMorphoMarket.run() calls vm.startBroadcast() internally,
        // and _createMarket() is internal so we inline the market creation here.
        DeployMorphoMarket morphoDeployer = new DeployMorphoMarket(address(vault));
        address oracle = morphoDeployer.deployOracle();
        console.log("Morpho oracle:", oracle);

        uint256 lltv = 77e16;
        if (!IMorpho(MORPHO_BLUE).isLltvEnabled(lltv)) {
            lltv = 0;
        }
        IMorpho(MORPHO_BLUE)
            .createMarket(
                MarketParams({
                    loanToken: DIEM,
                    collateralToken: address(vault),
                    oracle: oracle,
                    irm: ADAPTIVE_CURVE_IRM,
                    lltv: lltv
                })
            );
        console.log("Morpho wstDIEM/DIEM market created with LLTV:", lltv);

        // Transfer ownership of all mutable contracts to Safe multisig
        vault.transferOwnership(safe);
        feeRouter.transferOwnership(safe);
        router.transferOwnership(safe);
        registry.transferOwnership(safe);
        wrapper.transferOwnership(safe);

        vm.stopBroadcast();

        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("Ownership transferred to Safe:", safe);
    }
}
