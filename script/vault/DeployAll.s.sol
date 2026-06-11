// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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

interface IPoolManager {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }
    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external returns (int24 tick);
}

contract DeployAll is Script {
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;
    address constant VVV_STAKING = 0x321b7ff75154472B18EDb199033fF4D116F340Ff;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant ADAPTIVE_CURVE_IRM = 0x46415998764C29aB2a25CbeA6254146D50D22687;
    address constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70; // Chainlink Base

    // LLTVs — all confirmed enabled on Morpho Blue (Base)
    // DIEM: 86% — borrowing your own underlying (like stETH/ETH). Oracle tracks exact rate.
    // USDC: 62.5% — single oracle risk (DIEM=$1 assumption). Conservative for launch.
    // WETH: 62.5% — dual oracle risk (DIEM=$1 + Chainlink). Upgrade to 77% market later.
    uint256 constant LLTV_DIEM = 860e15; // 86%
    uint256 constant LLTV_USDC = 625e15; // 62.5%
    uint256 constant LLTV_WETH = 625e15; // 62.5%

    // V4 pool
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    uint24 constant V4_FEE = 3000;
    int24 constant V4_TICK_SPACING = 60;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        require(deployer == msg.sender, "DeployAll: DEPLOYER_ADDRESS must match broadcaster");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        require(treasury != address(0), "DeployAll: TREASURY_ADDRESS not set");
        address safe = vm.envAddress("SAFE_MULTISIG_ADDRESS");

        vm.startBroadcast();

        // Phase A: wstDIEM vault
        // veniceSigner: hot key for Venice API key challenges (separate from Safe).
        // Set to deployer initially; rotate via setVeniceSigner once keeper key is ready.
        address veniceSigner = vm.envOr("VENICE_SIGNER_ADDRESS", deployer);
        InferenceVault vault = new InferenceVault(DIEM, treasury, veniceSigner, deployer);
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
            new FeeRouter(address(vault), WETH, VVV, VVV_STAKING, curvePool, address(0), deployer);
        console.log("FeeRouter:", address(feeRouter));
        vault.setVenueAdapter(address(feeRouter), true);

        // Phase C: Router
        Router router = new Router(address(vault), WETH, VVV, VVV_STAKING, address(0), deployer);
        // Router no longer manages curvePool; FeeRouter handles Curve VOL.
        console.log("Router:", address(router));

        // Phase D: AgentTGERegistry
        AgentTGERegistry registry = new AgentTGERegistry(address(feeRouter), deployer);
        console.log("AgentTGERegistry:", address(registry));

        // Phase D: SurplusStakingWrapper
        SurplusStakingWrapper wrapper =
            new SurplusStakingWrapper(address(vault), curvePool, deployer);
        console.log("SurplusStakingWrapper:", address(wrapper));

        // Phase D: InferenceProduct — on-chain registry for selling Venice inference capacity
        InferenceProduct inferenceProduct = new InferenceProduct(USDC, address(feeRouter), deployer);
        console.log("InferenceProduct:", address(inferenceProduct));

        // Phase E: Morpho markets — DIEM, USDC, WETH
        IMorpho morpho = IMorpho(MORPHO_BLUE);
        require(morpho.isLltvEnabled(LLTV_DIEM), "86% LLTV not enabled");
        require(morpho.isLltvEnabled(LLTV_USDC), "62.5% LLTV not enabled");

        // E1: wstDIEM/DIEM (86% — leverage loop market)
        DeployMorphoMarket morphoDeployer = new DeployMorphoMarket(address(vault));
        address diemOracle = morphoDeployer.deployOracle();
        morpho.createMarket(
            MarketParams({
                loanToken: DIEM,
                collateralToken: address(vault),
                oracle: diemOracle,
                irm: ADAPTIVE_CURVE_IRM,
                lltv: LLTV_DIEM
            })
        );
        console.log("Morpho wstDIEM/DIEM (86%)    oracle:", diemOracle);

        // E2: wstDIEM/USDC (62.5% — borrow stables against inference capacity)
        WstDiemUsdcOracle usdcOracle = new WstDiemUsdcOracle(address(vault));
        morpho.createMarket(
            MarketParams({
                loanToken: USDC,
                collateralToken: address(vault),
                oracle: address(usdcOracle),
                irm: ADAPTIVE_CURVE_IRM,
                lltv: LLTV_USDC
            })
        );
        console.log("Morpho wstDIEM/USDC (62.5%)  oracle:", address(usdcOracle));

        // E3: wstDIEM/WETH (62.5% — borrow ETH against inference capacity)
        WstDiemWethOracle wethOracle = new WstDiemWethOracle(address(vault), ETH_USD_FEED, 3600);
        morpho.createMarket(
            MarketParams({
                loanToken: WETH,
                collateralToken: address(vault),
                oracle: address(wethOracle),
                irm: ADAPTIVE_CURVE_IRM,
                lltv: LLTV_WETH
            })
        );
        console.log("Morpho wstDIEM/WETH (62.5%)  oracle:", address(wethOracle));

        // Phase F: V4 wstDIEM/WETH pool initialization
        // Currency ordering: V4 requires currency0 < currency1 by address.
        // Router.wethIsCurrency0 is set the same way in its constructor.
        bool wethIsCurrency0 = uint160(WETH) < uint160(address(vault));
        (address c0, address c1) = wethIsCurrency0 ? (WETH, address(vault)) : (address(vault), WETH);

        // sqrtPriceX96 = sqrt(price) * 2^96, where price = c1/c0 in raw token units.
        // Both tokens are 18 dec, so price = whole-token ratio.
        // If wethIsCurrency0: price = wstDIEM per WETH ≈ ETH/USD price
        // If !wethIsCurrency0: price = WETH per wstDIEM ≈ 1 / (ETH/USD price)
        // We use a fixed sqrtPriceX96 close to current price; small error is fine
        // (pool can be arbitraged to exact price after initialization).
        // Computed at deploy time: ETH ≈ $1993 → stored in script before broadcast.
        // If price drifts significantly, re-initialize by creating a new pool.
        uint160 sqrtPriceX96;
        if (wethIsCurrency0) {
            // price = wstDIEM/WETH ≈ 1993 → sqrtPrice ≈ 44.64 → sqrtPriceX96 ≈ 3.537e30
            sqrtPriceX96 = 3_537_686_061_396_150_883_421_670_866_944;
        } else {
            // price = WETH/wstDIEM ≈ 1/1993 → sqrtPrice ≈ 0.02240 → sqrtPriceX96 ≈ 1.775e27
            sqrtPriceX96 = 1_774_711_203_519_680_000_000_000_000_000;
        }

        IPoolManager.PoolKey memory v4Key = IPoolManager.PoolKey({
            currency0: c0,
            currency1: c1,
            fee: V4_FEE,
            tickSpacing: V4_TICK_SPACING,
            hooks: address(0)
        });
        int24 v4Tick = IPoolManager(POOL_MANAGER).initialize(v4Key, sqrtPriceX96);
        router.setV4Pool(POOL_MANAGER);
        console.log("V4 wstDIEM/WETH pool initialized at tick:", uint256(int256(v4Tick)));
        console.log("V4 currency0:", c0);
        console.log("V4 wethIsCurrency0:", wethIsCurrency0);

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
