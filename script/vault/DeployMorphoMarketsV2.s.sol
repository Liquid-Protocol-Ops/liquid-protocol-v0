// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {WstDiemUsdcOracle} from "../../src/vault/oracles/WstDiemUsdcOracle.sol";
import {WstDiemWethOracle} from "../../src/vault/oracles/WstDiemWethOracle.sol";
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

// Deploys Morpho lending markets for wstDIEM collateral with USDC and WETH loan tokens.
//
// These markets let wstDIEM holders borrow liquid assets without selling their position.
// Inference yield continues accruing to the deposited wstDIEM while it serves as collateral.
//
// USDC market: wstDIEM → borrow USDC (borrow stables against staked inference capacity)
// WETH market: wstDIEM → borrow WETH (borrow ETH against staked inference capacity)
//
// LLTV: 62.5% for both — conservative given oracle relies on DIEM ≈ $1 assumption.
// Upgrade LLTV once on-chain DIEM/USD price feed exists (e.g. Chainlink or Uniswap TWAP).
//
// Run:
//   DEPLOYER_PK=$(op item get <id> --field private_key --reveal | tr -d '[:space:]')
//   DEPLOYER_PK="$PK" forge script script/vault/DeployMorphoMarketsV2.s.sol \
//     --rpc-url $BASE_RPC_URL --broadcast --verify
contract DeployMorphoMarketsV2 is Script {
    // Morpho Blue on Base
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant ADAPTIVE_IRM = 0x46415998764C29aB2a25CbeA6254146D50D22687;

    // Tokens
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    // Chainlink ETH/USD on Base (heartbeat ~20 min, we use 1h threshold)
    address constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    uint256 constant STALENESS_SECONDS = 3600;

    // 62.5% LLTV — conservative for oracle without live DIEM/USD feed
    uint256 constant LLTV = 625e15;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        // WSTDIEM_ADDRESS env var — use the freshly deployed vault address
        address WSTDIEM = vm.envAddress("WSTDIEM_ADDRESS");
        vm.startBroadcast(pk);

        IMorpho morpho = IMorpho(MORPHO);
        require(morpho.isLltvEnabled(LLTV), "62.5% LLTV not enabled on Morpho Blue");

        // ── wstDIEM / USDC market ─────────────────────────────────────────
        WstDiemUsdcOracle usdcOracle = new WstDiemUsdcOracle(WSTDIEM);
        console.log("WstDiemUsdcOracle:", address(usdcOracle));

        // Sanity check: oracle should return ~1e24 for a fresh vault
        uint256 usdcPrice = usdcOracle.price();
        console.log("USDC oracle price (expect ~1e24):", usdcPrice);

        morpho.createMarket(
            MarketParams({
                loanToken: USDC,
                collateralToken: WSTDIEM,
                oracle: address(usdcOracle),
                irm: ADAPTIVE_IRM,
                lltv: LLTV
            })
        );
        console.log("wstDIEM/USDC Morpho market created (LLTV 62.5%)");

        // ── wstDIEM / WETH market ─────────────────────────────────────────
        WstDiemWethOracle wethOracle =
            new WstDiemWethOracle(WSTDIEM, ETH_USD_FEED, STALENESS_SECONDS);
        console.log("WstDiemWethOracle:", address(wethOracle));

        uint256 wethPrice = wethOracle.price();
        console.log("WETH oracle price:", wethPrice);

        morpho.createMarket(
            MarketParams({
                loanToken: WETH,
                collateralToken: WSTDIEM,
                oracle: address(wethOracle),
                irm: ADAPTIVE_IRM,
                lltv: LLTV
            })
        );
        console.log("wstDIEM/WETH Morpho market created (LLTV 62.5%)");

        vm.stopBroadcast();

        console.log("=== MORPHO MARKETS V2 DEPLOYED ===");
        console.log("Collateral (wstDIEM):", WSTDIEM);
        console.log("Market 1: loan=USDC  oracle=WstDiemUsdcOracle LLTV=62.5%");
        console.log("Market 2: loan=WETH  oracle=WstDiemWethOracle LLTV=62.5%");
    }
}
