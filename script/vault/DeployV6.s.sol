// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AgentTGERegistry} from "../../src/vault/AgentTGERegistry.sol";
import {FeeRouter} from "../../src/vault/FeeRouter.sol";
import {InferenceProduct} from "../../src/vault/InferenceProduct.sol";
import {InferenceVault} from "../../src/vault/InferenceVault.sol";
import {LiquidityManager} from "../../src/vault/LiquidityManager.sol";
import {MarketParams as RouterMarketParams, Router} from "../../src/vault/Router.sol";
import {SurplusStakingWrapper} from "../../src/vault/SurplusStakingWrapper.sol";
import {WstDIEMHook} from "../../src/vault/WstDIEMHook.sol";
import {IInferenceVault} from "../../src/vault/interfaces/IInferenceVault.sol";
import {WstDiemVvvOracle} from "../../src/vault/oracles/WstDiemVvvOracle.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Script, console} from "forge-std/Script.sol";

// ── External interfaces (Base mainnet) ─────────────────────────────────────────

struct MorphoMarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

interface IMorpho {
    function createMarket(MorphoMarketParams calldata params) external;
    function isLltvEnabled(uint256 lltv) external view returns (bool);
}

interface ICurveStableSwapNGFactory {
    function deploy_plain_pool(
        string calldata name,
        string calldata symbol,
        address[] calldata coins,
        uint256 A,
        uint256 fee,
        uint256 offpeg_fee_multiplier,
        uint256 ma_exp_time,
        uint256 implementation_idx,
        uint8[] calldata asset_types,
        bytes4[] calldata method_ids,
        address[] calldata oracles
    ) external returns (address);
}

interface IPMInit {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }
    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external returns (int24 tick);
}

interface IAeroPool {
    function quote(address tokenIn, uint256 amountIn, uint256 granularity)
        external
        view
        returns (uint256);
}

interface IChainlink {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

// ── Minimal wstDIEM/DIEM oracle (vault NAV; no USD feed) ───────────────────────
// price() = convertToAssets(1e18) × 1e18 = DIEM-per-wstDIEM at Morpho's 1e36 scale.
contract WstDiemDiemOracle {
    IInferenceVault public immutable vault;

    constructor(address _vault) {
        vault = IInferenceVault(_vault);
    }

    function price() external view returns (uint256) {
        return vault.convertToAssets(1e18) * 1e18;
    }
}

/// @title DeployV6
/// @notice Fresh, clean redeploy of the wstDIEM vault stack (v6) — architecture C:
///         a single-use EOA (funded from Splits via WETH→ETH unwrap) runs this script,
///         deploying everything, wiring it, then handing ownership to the Safe.
///
/// Differences vs the legacy DeployAll (v5):
///   - WstDIEMHook deployed (CREATE2, flag-mined) and the V4 pool is a DYNAMIC_FEE_FLAG
///     hooked pool initialized at the on-chain-anchored price (no hardcoded ~1996 wstDIEM/WETH).
///   - WstDiemVvvOracle is the hardened version (granularity 24 + staleness guard) and the
///     VVV market is created here.
///   - The deprecated DIEM=$1 USDC/WETH oracles/markets are NOT deployed.
///   - LiquidityManager deployed (Safe-controlled V4 LP manager).
///
/// Env:
///   DEPLOYER_PK         fresh EOA private key (funded with ETH for gas + 0.01 DIEM for the seed)
///   TREASURY_ADDRESS    fee treasury (e.g. the Safe or a treasury Splits)
///   SAFE_ADDRESS        Gnosis Safe that ends up owning every Ownable contract
///   VENICE_SIGNER       optional; defaults to the deployer (rotate post-launch)
///   SQRT_PRICE_X96      operator-computed V4 init price (validated against the on-chain anchor)
///   VVV_USD_E8          operator VVV/USD (1e8) — the one off-chain leg of the anchor
///
/// Dry run (no broadcast): provide a throwaway DEPLOYER_PK and run with --rpc-url.
/// The Curve factory's tx.origin==msg.sender guard is satisfied because, under --broadcast,
/// the direct factory call below is sent from the EOA.
contract DeployV6 is Script {
    // Base mainnet
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf; // LIQUID VVV
    address constant VVV_STAKING = 0x321b7ff75154472B18EDb199033fF4D116F340Ff;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant ADAPTIVE_IRM = 0x46415998764C29aB2a25CbeA6254146D50D22687;
    address constant AERO_POOL = 0xbB345D35450BF9Ee76F3D2cE214E8e7AC5e1071d; // Aerodrome volatile VVV/DIEM
    address constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70; // Chainlink ETH/USD (Base)
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant CURVE_FACTORY = 0xd2002373543Ce3527023C75e7518C274A51ce712;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // LLTVs (all enabled on Morpho Blue / Base)
    uint256 constant LLTV_DIEM_86 = 860e15;
    uint256 constant LLTV_VVV = 625e15;

    // Oracle config (hardened — MOG-548 security review)
    uint256 constant TWAP_GRANULARITY = 24; // ~12h window
    uint256 constant MAX_OBS_AGE = 7200; // 2h staleness bound

    // V4 hooked pool
    uint24 constant DYNAMIC_FEE = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    int24 constant V4_TICK_SPACING = 60;
    int24 constant TICK_TOLERANCE = 300; // supplied sqrtPrice must be within ~3% of the anchor

    uint256 constant SEED = 1e16; // 0.01 DIEM inflation-attack guard (burned to address(1))

    // Deployed addresses (populated by _deploy, asserted by the dry-run test)
    struct Deployment {
        address vault;
        address hook;
        address vvvOracle;
        address diemOracle;
        address curvePool;
        address feeRouter;
        address router;
        address registry;
        address wrapper;
        address product;
        address liquidityManager;
        int24 v4Tick;
    }

    function run() external returns (Deployment memory d) {
        // Production: DEPLOYER_PK = the fresh single-use EOA. Dry-run: omit DEPLOYER_PK and
        // pass `--sender <DIEM-holder> --unlocked` to simulate as a funded, EOA-origin caller
        // (satisfies both the 0.01-DIEM seed and the Curve factory's tx.origin==msg.sender guard).
        uint256 pk = vm.envOr("DEPLOYER_PK", uint256(0));
        address deployer = pk != 0 ? vm.addr(pk) : msg.sender;
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address safe = vm.envAddress("SAFE_ADDRESS");
        address veniceSigner = vm.envOr("VENICE_SIGNER", deployer);
        uint160 sqrtPriceX96 = uint160(vm.envUint("SQRT_PRICE_X96"));
        uint256 vvvUsdE8 = vm.envUint("VVV_USD_E8");

        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();
        d = _deploy(deployer, treasury, safe, veniceSigner, sqrtPriceX96, vvvUsdE8);
        vm.stopBroadcast();

        _verify(d, safe);
        _log(d, safe);
    }

    /// @dev Self-check the end state so a dry-run (forge script --rpc-url, no broadcast) asserts,
    ///      not just runs. Reverts if ownership or Router wiring is wrong.
    function _verify(Deployment memory d, address safe) internal view {
        require(InferenceVault(d.vault).owner() == safe, "vault owner != safe");
        require(FeeRouter(d.feeRouter).owner() == safe, "feeRouter owner != safe");
        require(Router(d.router).owner() == safe, "router owner != safe");
        require(AgentTGERegistry(d.registry).owner() == safe, "registry owner != safe");
        require(SurplusStakingWrapper(d.wrapper).owner() == safe, "wrapper owner != safe");
        require(InferenceProduct(d.product).owner() == safe, "product owner != safe");
        require(Router(d.router).v4Pool() == POOL_MANAGER, "router v4Pool not set");
        require(Router(d.router).wstDiemV4Hooks() == d.hook, "router hook not wired");
        require(Router(d.router).wstDiemV4Fee() == DYNAMIC_FEE, "router v4 fee not dynamic");
        require(Router(d.router).curvePool() == d.curvePool, "router curve not set");
    }

    /// @dev Pure deploy logic (no broadcast) so the fork dry-run test can call it and assert.
    ///      `caller` is the account that transiently owns the Ownable contracts to wire them,
    ///      then hands ownership to `safe`.
    function _deploy(
        address caller,
        address treasury,
        address safe,
        address veniceSigner,
        uint160 sqrtPriceX96,
        uint256 vvvUsdE8
    ) public returns (Deployment memory d) {
        // 1. Vault (caller owns transiently to wire; transferred to safe at the end).
        InferenceVault vault = new InferenceVault(DIEM, treasury, veniceSigner, caller);
        d.vault = address(vault);

        // 2. Inflation-attack guard: burn a 0.01 DIEM position to address(1) atomically.
        IERC20(DIEM).approve(address(vault), SEED);
        vault.deposit(SEED, address(1));

        // 3. WstDIEMHook via CREATE2 (flag-mined address; bits 0x1080).
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG);
        bytes memory hookArgs =
            abi.encode(IPoolManager(POOL_MANAGER), IInferenceVault(address(vault)));
        (address hookAddr, bytes32 hookSalt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(WstDIEMHook).creationCode, hookArgs);
        WstDIEMHook hook = new WstDIEMHook{salt: hookSalt}(
            IPoolManager(POOL_MANAGER), IInferenceVault(address(vault))
        );
        require(address(hook) == hookAddr, "hook addr mismatch");
        d.hook = address(hook);

        // 4. Hardened VVV oracle (granularity 24 + 2h staleness bound).
        d.vvvOracle = address(
            new WstDiemVvvOracle(address(vault), AERO_POOL, VVV, TWAP_GRANULARITY, MAX_OBS_AGE)
        );

        // 5. Curve DIEM/wstDIEM pool — called DIRECTLY here so msg.sender==tx.origin (EOA guard).
        d.curvePool = _deployCurve(address(vault));

        // 6. FeeRouter (needs curvePool at construction).
        FeeRouter feeRouter =
            new FeeRouter(address(vault), WETH, VVV, VVV_STAKING, d.curvePool, address(0), caller);
        d.feeRouter = address(feeRouter);

        // 7. Router.
        Router router = new Router(address(vault), WETH, VVV, VVV_STAKING, address(0), caller);
        d.router = address(router);

        // 8. Registry / wrapper / product.
        d.registry = address(new AgentTGERegistry(address(feeRouter), caller));
        d.wrapper = address(new SurplusStakingWrapper(address(vault), d.curvePool, caller));
        d.product = address(new InferenceProduct(USDC, address(feeRouter), caller));

        // 9. DIEM (vault-NAV) oracle for the leverage market.
        d.diemOracle = address(new WstDiemDiemOracle(address(vault)));

        // 10. V4 hooked pool: validate operator price against the on-chain anchor, then init.
        d.v4Tick = _initV4Pool(address(vault), address(hook), sqrtPriceX96, vvvUsdE8);

        // 11. LiquidityManager (Safe-controlled). currency ordering: WETH<wstDIEM ? (WETH,vault):(vault,WETH).
        (address c0, address c1) =
            WETH < address(vault) ? (WETH, address(vault)) : (address(vault), WETH);
        d.liquidityManager = address(
            new LiquidityManager(
                POOL_MANAGER,
                c0,
                c1,
                DYNAMIC_FEE,
                V4_TICK_SPACING,
                -887_220,
                887_220,
                address(hook),
                safe
            )
        );

        // 12. Morpho markets — VVV (canonical) + DIEM 86% (leverage loop). NO USDC/WETH.
        IMorpho morpho = IMorpho(MORPHO_BLUE);
        require(
            morpho.isLltvEnabled(LLTV_VVV) && morpho.isLltvEnabled(LLTV_DIEM_86), "LLTV not enabled"
        );
        morpho.createMarket(
            MorphoMarketParams(VVV, address(vault), d.vvvOracle, ADAPTIVE_IRM, LLTV_VVV)
        );
        morpho.createMarket(
            MorphoMarketParams(DIEM, address(vault), d.diemOracle, ADAPTIVE_IRM, LLTV_DIEM_86)
        );

        // 13. Wire (caller is still owner).
        vault.setVenueAdapter(address(feeRouter), true);
        router.setV4Pool(POOL_MANAGER);
        router.setSwapFees(10_000, DYNAMIC_FEE, V4_TICK_SPACING, address(hook));
        router.setCurvePool(d.curvePool);
        router.setLeverageMarket(
            RouterMarketParams(DIEM, address(vault), d.diemOracle, ADAPTIVE_IRM, LLTV_DIEM_86)
        );

        // 14. Hand ownership of every Ownable contract to the Safe.
        vault.transferOwnership(safe);
        feeRouter.transferOwnership(safe);
        router.transferOwnership(safe);
        AgentTGERegistry(d.registry).transferOwnership(safe);
        SurplusStakingWrapper(d.wrapper).transferOwnership(safe);
        InferenceProduct(d.product).transferOwnership(safe);
    }

    function _deployCurve(address vault) internal returns (address pool) {
        address[] memory coins = new address[](2);
        coins[0] = DIEM;
        coins[1] = vault;
        uint8[] memory assetTypes = new uint8[](2);
        assetTypes[0] = 0; // standard ERC20
        assetTypes[1] = 3; // ERC4626 (Curve calls convertToAssets natively)
        bytes4[] memory methodIds = new bytes4[](2);
        address[] memory oracles = new address[](2);
        pool = ICurveStableSwapNGFactory(CURVE_FACTORY)
            .deploy_plain_pool(
                "DIEM/wstDIEM",
                "wstDIEM-LP",
                coins,
                300,
                30_000_000,
                8 * 10 ** 10,
                600,
                0,
                assetTypes,
                methodIds,
                oracles
            );
    }

    /// @dev Anchor: expectedTick from convertToAssets × Aerodrome DIEM/VVV TWAP × Chainlink ETH/USD
    ///      × operator VVV/USD. Reverts if the supplied sqrtPrice deviates > TICK_TOLERANCE.
    function _initV4Pool(address vault, address hook, uint160 sqrtPriceX96, uint256 vvvUsdE8)
        internal
        returns (int24 tick)
    {
        uint256 a = IInferenceVault(vault).convertToAssets(1e18); // DIEM/wstDIEM, 1e18
        uint256 q = IAeroPool(AERO_POOL).quote(DIEM, 1e18, TWAP_GRANULARITY); // VVV/DIEM, 1e18
        (, int256 ans,,,) = IChainlink(ETH_USD_FEED).latestRoundData();
        require(ans > 0, "bad ETH/USD");
        uint256 e = uint256(ans); // USD/WETH, 1e8

        uint256 denom = a * q * vvvUsdE8;
        require(denom > 0, "zero denom");
        // price (wstDIEM per WETH) × 2^192 = E·1e36·2^192 / (A·Q·V)
        uint256 priceX192 = FullMath.mulDiv(e * 1e36, uint256(1) << 192, denom);
        uint160 expectedSqrt = uint160(Math.sqrt(priceX192));
        int24 expectedTick = TickMath.getTickAtSqrtPrice(expectedSqrt);
        int24 impliedTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        console.log("V4 anchor - expected tick / supplied tick:");
        console.logInt(expectedTick);
        console.logInt(impliedTick);
        int24 diff =
            impliedTick > expectedTick ? impliedTick - expectedTick : expectedTick - impliedTick;
        require(diff <= TICK_TOLERANCE, "V4 price deviates from on-chain anchor");

        (address c0, address c1) = WETH < vault ? (WETH, vault) : (vault, WETH);
        IPMInit.PoolKey memory key = IPMInit.PoolKey({
            currency0: c0,
            currency1: c1,
            fee: DYNAMIC_FEE,
            tickSpacing: V4_TICK_SPACING,
            hooks: hook
        });
        tick = IPMInit(POOL_MANAGER).initialize(key, sqrtPriceX96);
    }

    function _log(Deployment memory d, address safe) internal pure {
        console.log("=== wstDIEM v6 DEPLOYED (owner: Safe) ===");
        console.log("Safe:", safe);
        console.log("InferenceVault:", d.vault);
        console.log("WstDIEMHook:", d.hook);
        console.log("WstDiemVvvOracle:", d.vvvOracle);
        console.log("WstDiemDiemOracle:", d.diemOracle);
        console.log("Curve pool:", d.curvePool);
        console.log("FeeRouter:", d.feeRouter);
        console.log("Router:", d.router);
        console.log("AgentTGERegistry:", d.registry);
        console.log("SurplusStakingWrapper:", d.wrapper);
        console.log("InferenceProduct:", d.product);
        console.log("LiquidityManager:", d.liquidityManager);
        console.log("V4 pool tick:");
        console.logInt(d.v4Tick);
    }
}
