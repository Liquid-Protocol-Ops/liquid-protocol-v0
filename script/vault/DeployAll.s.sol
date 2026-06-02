// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentTGERegistry} from "../../src/vault/AgentTGERegistry.sol";
import {FeeRouter} from "../../src/vault/FeeRouter.sol";
import {InferenceProduct} from "../../src/vault/InferenceProduct.sol";
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
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant ADAPTIVE_CURVE_IRM = 0x46415998764C29aB2a25CbeA6254146D50D22687;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        require(deployer == msg.sender, "DeployAll: DEPLOYER_ADDRESS must match broadcaster");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        require(treasury != address(0), "DeployAll: TREASURY_ADDRESS not set");
        address safe = vm.envAddress("SAFE_MULTISIG_ADDRESS");

        vm.startBroadcast();

        // Phase A: wstDIEM vault
        InferenceVault vault = new InferenceVault(DIEM, treasury, deployer);
        console.log("InferenceVault:", address(vault));

        // Seed deposit — burns 1 DIEM worth of shares to address(1) to prevent the
        // first-depositor inflation attack. Deployer must hold at least 1e18 DIEM.
        // The +1 virtual buffer alone is insufficient; a seed makes the attack uneconomical.
        uint256 SEED = 1e18; // 1 DIEM
        IERC20(DIEM).approve(address(vault), SEED);
        vault.deposit(SEED, address(1)); // address(1) = effectively burned
        console.log("Vault seeded with 1 DIEM (shares to address(1))");

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
        Router router = new Router(address(vault), WETH, VVV, VVV_STAKING);
        // Router no longer manages curvePool; FeeRouter handles Curve VOL.
        console.log("Router:", address(router));

        // Phase D: AgentTGERegistry
        AgentTGERegistry registry = new AgentTGERegistry(address(feeRouter), deployer);
        console.log("AgentTGERegistry:", address(registry));

        // Phase D: SurplusStakingWrapper
        SurplusStakingWrapper wrapper = new SurplusStakingWrapper(address(vault), curvePool);
        console.log("SurplusStakingWrapper:", address(wrapper));

        // Phase D: InferenceProduct — on-chain registry for selling Venice inference capacity
        InferenceProduct inferenceProduct =
            new InferenceProduct(USDC, address(feeRouter), deployer);
        console.log("InferenceProduct:", address(inferenceProduct));

        // Phase E: Morpho oracle + market
        // Use deployOracle() directly — DeployMorphoMarket.run() calls vm.startBroadcast() internally,
        // and _createMarket() is internal so we inline the market creation here.
        DeployMorphoMarket morphoDeployer = new DeployMorphoMarket(address(vault));
        address oracle = morphoDeployer.deployOracle();
        console.log("Morpho oracle:", oracle);

        uint256 lltv = 77e16;
        require(
            IMorpho(MORPHO_BLUE).isLltvEnabled(lltv),
            "DeployAll: 77e16 LLTV not enabled on Morpho Blue"
        );
        MarketParams memory params = MarketParams({
            loanToken: DIEM,
            collateralToken: address(vault),
            oracle: oracle,
            irm: ADAPTIVE_CURVE_IRM,
            lltv: lltv
        });
        IMorpho(MORPHO_BLUE).createMarket(params);
        console.log("Morpho wstDIEM/DIEM market created with LLTV:", lltv);

        // Transfer ownership of all mutable contracts to Safe multisig
        vault.transferOwnership(safe);
        feeRouter.transferOwnership(safe);
        router.transferOwnership(safe);
        registry.transferOwnership(safe);
        wrapper.transferOwnership(safe);
        inferenceProduct.transferOwnership(safe);

        vm.stopBroadcast();

        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("Ownership transferred to Safe:", safe);
    }
}
