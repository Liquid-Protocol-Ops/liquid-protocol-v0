// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {WstDiemVvvOracle} from "../../src/vault/oracles/WstDiemVvvOracle.sol";
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

// ---------------------------------------------------------------------------
// DeployVvvMarket.s.sol  (MOG-544)
//
// Deploys the fully on-chain WstDiemVvvOracle and creates the VVV-denominated
// Morpho Blue market: collateral = wstDIEM, loan = liquid VVV.
//
// Why VVV-denominated: DIEM has no USD-liquid DEX market — its only deep
// liquidity is DIEM/VVV on Aerodrome (~$6M v2 pool). The wstDIEM/USDC & /WETH
// oracles hardcode DIEM=$1 and are mispriced (MOG-542); this market prices
// collateral trustlessly off the real trading pair. price() = vault rate ×
// Aerodrome DIEM→VVV TWAP, no USD feed. Oracle is immutable.
//
// CRITICAL: the loan token and the oracle's `_vvv` arg are LIQUID VVV
//   (0xacfE6019…, the pool's token), NOT the sVVV staking contract
//   (0x321b7ff7…). sVVV is non-transferrable and cannot be a Morpho loan token;
//   passing it to the oracle reverts TokenNotInPool.
//
// SAFETY — this script is harmless to run (no funds at risk):
//   * the oracle is immutable & view-only;
//   * createMarket is permissionless and seeds no liquidity.
//   The go-live gate is SEPARATE: do NOT supply borrowable VVV / open borrows
//   until the liquidation path (wstDIEM → DIEM via Curve → VVV via Aerodrome)
//   has real depth (MOG-536) and a borrow cap is set, sized to the ~$6M v2 pool.
//
// LLTV: defaults to 62.5% (the conservative enabled value used by the USDC/WETH
//   markets). 77% / 86% are also enabled but riskier here — collateral value
//   rides DIEM/VVV volatility, not a stable peg. Confirm before raising.
//
// Dry run (simulate, no broadcast — validates oracle sanity, isLltvEnabled, createMarket;
// prints the oracle address, price(), and MARKET_ID). Use any throwaway key as sender:
//   DEPLOYER_PK=0x<throwaway> forge script script/vault/DeployVvvMarket.s.sol \
//     --rpc-url $BASE_RPC_URL
//
// Execute (v6 deployer):
//   PK=$(op item get rhuh6s2tocpjzdi7kvvnjrps7i --field credential --reveal | tr -d '[:space:]')
//   DEPLOYER_PK="$PK" forge script script/vault/DeployVvvMarket.s.sol \
//     --rpc-url $BASE_RPC_URL --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY_1
// ---------------------------------------------------------------------------
contract DeployVvvMarket is Script {
    // Morpho Blue on Base
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant ADAPTIVE_IRM = 0x46415998764C29aB2a25CbeA6254146D50D22687;

    // Market tokens
    address constant WSTDIEM = 0xb9f23c33FfD2213f31C0cFb6c9e2fDf525a9Dd2D; // InferenceVault v5
    address constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf; // LIQUID VVV (loan token)
    address constant AERO_POOL = 0xbB345D35450BF9Ee76F3D2cE214E8e7AC5e1071d; // Aerodrome volatile VVV/DIEM

    // Oracle config — granularity 24 ≈ ~12h TWAP + 2h staleness bound (MOG-548 security review:
    // granularity 2 was too short for a single-pool, no-external-market asset → multi-block
    // manipulation risk). Superseded by the DeployV6 orchestrator; retained for provenance/compile.
    uint256 constant TWAP_GRANULARITY = 24;
    uint256 constant MAX_OBSERVATION_AGE = 7200;

    // 62.5% LLTV — conservative; collateral value rides DIEM/VVV volatility.
    uint256 constant LLTV = 625e15;

    function run() external {
        IMorpho morpho = IMorpho(MORPHO);
        require(morpho.isLltvEnabled(LLTV), "LLTV not enabled on Morpho Blue");

        vm.startBroadcast(vm.envUint("DEPLOYER_PK"));

        WstDiemVvvOracle oracle =
            new WstDiemVvvOracle(WSTDIEM, AERO_POOL, VVV, TWAP_GRANULARITY, MAX_OBSERVATION_AGE);
        console.log("WstDiemVvvOracle deployed:", address(oracle));

        // Sanity: price() = vaultRate(≈1e18) × TWAP(≈89.7e18) ≈ 8.97e37 at a fresh rate.
        // Catch a misconfigured oracle before the market is created.
        uint256 p = oracle.price();
        console.log("oracle.price() (expect ~8.9e37):", p);
        require(p > 1e37 && p < 1e39, "oracle price outside sane band");

        morpho.createMarket(
            MarketParams({
                loanToken: VVV,
                collateralToken: WSTDIEM,
                oracle: address(oracle),
                irm: ADAPTIVE_IRM,
                lltv: LLTV
            })
        );

        bytes32 marketId = keccak256(
            abi.encode(
                MarketParams({
                    loanToken: VVV,
                    collateralToken: WSTDIEM,
                    oracle: address(oracle),
                    irm: ADAPTIVE_IRM,
                    lltv: LLTV
                })
            )
        );

        console.log("=== wstDIEM/VVV Morpho market created ===");
        console.log("  loanToken (liquid VVV):", VVV);
        console.log("  collateral (wstDIEM)  :", WSTDIEM);
        console.log("  oracle                :", address(oracle));
        console.log("  irm                   :", ADAPTIVE_IRM);
        console.log("  lltv                  : 625e15 (62.5%)");
        console.log("  MARKET_ID             :");
        console.logBytes32(marketId);
        console.log(
            "GATE: do NOT supply VVV / open borrows until liquidation depth exists (MOG-536)."
        );

        vm.stopBroadcast();
    }
}
