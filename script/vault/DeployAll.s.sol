// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentTGERegistry} from "../../src/vault/AgentTGERegistry.sol";
import {FeeRouter} from "../../src/vault/FeeRouter.sol";
import {InferenceProduct} from "../../src/vault/InferenceProduct.sol";
import {InferenceVault} from "../../src/vault/InferenceVault.sol";
import {Router} from "../../src/vault/Router.sol";
import {SurplusStakingWrapper} from "../../src/vault/SurplusStakingWrapper.sol";
import {WstDiemUsdcOracle} from "../../src/vault/oracles/WstDiemUsdcOracle.sol";
import {WstDiemWethOracle} from "../../src/vault/oracles/WstDiemWethOracle.sol";
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
    address constant DIEM             = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;
    address constant WETH             = 0x4200000000000000000000000000000000000006;
    address constant VVV              = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;
    address constant VVV_STAKING      = 0x321b7ff75154472B18EDb199033fF4D116F340Ff;
    address constant USDC             = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant MORPHO_BLUE      = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant ADAPTIVE_CURVE_IRM = 0x46415998764C29aB2a25CbeA6254146D50D22687;
    address constant ETH_USD_FEED     = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70; // Chainlink Base

    // LLTVs — must be enabled on Morpho Blue (Base)
    uint256 constant LLTV_DIEM  = 385e15;  // 38.5% — conservative, DIEM has no external price feed
    uint256 constant LLTV_USDC  = 625e15;  // 62.5% — USDC market, DIEM=$1 oracle assumption
    uint256 constant LLTV_WETH  = 625e15;  // 62.5% — WETH market, Chainlink ETH/USD

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

        // Seed deposit: burn a small position to address(1) to prevent first-depositor
        // inflation attack. Even 0.01 DIEM makes the attack require donating ~1e34 DIEM
        // (far more than total supply). Deployer needs only this amount of DIEM.
        uint256 SEED = 1e16; // 0.01 DIEM
        IERC20(DIEM).approve(address(vault), SEED);
        vault.deposit(SEED, address(1));
        console.log("Vault seeded (0.01 DIEM burned to address(1))");

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

        // Phase E: Morpho markets — DIEM, USDC, WETH
        IMorpho morpho = IMorpho(MORPHO_BLUE);
        require(morpho.isLltvEnabled(LLTV_DIEM), "38.5% LLTV not enabled");
        require(morpho.isLltvEnabled(LLTV_USDC), "62.5% LLTV not enabled");

        // E1: wstDIEM/DIEM (38.5% — leverage loop market)
        DeployMorphoMarket morphoDeployer = new DeployMorphoMarket(address(vault));
        address diemOracle = morphoDeployer.deployOracle();
        morpho.createMarket(MarketParams({
            loanToken: DIEM, collateralToken: address(vault),
            oracle: diemOracle, irm: ADAPTIVE_CURVE_IRM, lltv: LLTV_DIEM
        }));
        console.log("Morpho wstDIEM/DIEM (38.5%)  oracle:", diemOracle);

        // E2: wstDIEM/USDC (62.5% — borrow stables against inference capacity)
        WstDiemUsdcOracle usdcOracle = new WstDiemUsdcOracle(address(vault));
        morpho.createMarket(MarketParams({
            loanToken: USDC, collateralToken: address(vault),
            oracle: address(usdcOracle), irm: ADAPTIVE_CURVE_IRM, lltv: LLTV_USDC
        }));
        console.log("Morpho wstDIEM/USDC (62.5%)  oracle:", address(usdcOracle));

        // E3: wstDIEM/WETH (62.5% — borrow ETH against inference capacity)
        WstDiemWethOracle wethOracle = new WstDiemWethOracle(address(vault), ETH_USD_FEED, 3600);
        morpho.createMarket(MarketParams({
            loanToken: WETH, collateralToken: address(vault),
            oracle: address(wethOracle), irm: ADAPTIVE_CURVE_IRM, lltv: LLTV_WETH
        }));
        console.log("Morpho wstDIEM/WETH (62.5%)  oracle:", address(wethOracle));

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
