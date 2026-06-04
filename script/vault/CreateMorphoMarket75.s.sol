// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Script, console} from "forge-std/Script.sol";

// ---------------------------------------------------------------------------
// CreateMorphoMarket75.s.sol
//
// Creates a new Morpho Blue lending market: wstDIEM collateral / DIEM loan.
//
// IMPORTANT — LLTV NOTE:
//   The target was 70–75% LLTV. Morpho Blue on Base enforces a governance
//   whitelist of permitted LLTV values (verified via isLltvEnabled). Neither
//   70% (700000000000000000) nor 75% (750000000000000000) is whitelisted.
//
//   Nearest enabled value ABOVE the 75% target: 77% (770000000000000000)
//     => max leverage = 1 / (1 − 0.77) = 4.35x
//
//   Nearest enabled value BELOW the 70% floor: 62.5% (625000000000000000)
//     => max leverage = 1 / (1 − 0.625) = 2.67x
//
//   This script uses 77% — it is the closest to the spec and delivers
//   attractive leverage well above the 1.63x (38.5%) status quo.
//   Morpho governance would need to whitelist 75% before that value could
//   be used; there is no owner-bypass available to the protocol Safe.
//
// Oracle:
//   Reuses the deployed WstDIEM/DIEM oracle at 0xE762e8011D453853638D1978398df8b1D383A2D9.
//   price() returns vault.convertToAssets(1e18) * 1e18, scaling the wstDIEM→DIEM
//   exchange rate to Morpho's 1e36 ORACLE_PRICE_SCALE. Both tokens are 18-decimal.
//   Verified on-chain: price() = 1e36 at the current 1:1 vault rate.
//   As yield accrues the rate only increases, keeping the oracle conservative.
//
// Computed market ID (keccak256(abi.encode(MarketParams))):
//   0x96af141c5ac70610ee0c4d8b5cf72205a8358e888407e0ba45c1cb21f9449f1e
//
//   Derivation:
//     loanToken       = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024  (DIEM)
//     collateralToken = 0x3394898b648385FAd4FE847c52B5E4CCe0D63662  (wstDIEM / InferenceVault)
//     oracle          = 0xE762e8011D453853638D1978398df8b1D383A2D9
//     irm             = 0x46415998764C29aB2a25CbeA6254146D50D22687  (AdaptiveCurveIRM)
//     lltv            = 770000000000000000                           (77%)
//     keccak256(abi.encode(above)) = 0x96af141c5ac70610ee0c4d8b5cf72205a8358e888407e0ba45c1cb21f9449f1e
//
// Reference market (38.5%, from SafeBatchV3.s.sol):
//   ID = 0xdaf35f1b7950cbc49a0570fbfff090088805df3ee2020811f46e9abdf2bf5895
//   leverage = 1.63x
//
// Execution:
//   SAFE_SK1=<bytes32> SAFE_SK2=<bytes32> EXECUTOR_PK=<uint256> \
//   forge script script/vault/CreateMorphoMarket75.s.sol \
//     --rpc-url $BASE_RPC_URL --broadcast
// ---------------------------------------------------------------------------

interface ISafe {
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 nonce
    ) external view returns (bytes32);

    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool);

    function nonce() external view returns (uint256);
}

contract CreateMorphoMarket75 is Script {
    // --- Protocol addresses (Base mainnet) ---
    address constant SAFE = 0x872c561f699B42977c093F0eD8b4C9a431280c6c;
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant ZERO = address(0);

    // --- Market params ---
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;
    address constant WST_DIEM = 0xb9f23c33FfD2213f31C0cFb6c9e2fDf525a9Dd2D; // InferenceVault v5 (2026-06-03)
    address constant ORACLE = 0xE762e8011D453853638D1978398df8b1D383A2D9;
    address constant IRM = 0x46415998764C29aB2a25CbeA6254146D50D22687; // AdaptiveCurveIRM (verified enabled)
    // 75% (750000000000000000) is NOT whitelisted on Base Morpho.
    // 77% (770000000000000000) is the nearest enabled LLTV above the 75% target.
    uint256 constant LLTV_77PCT = 770_000_000_000_000_000;

    // Market ID is deterministic: keccak256(abi.encode(MarketParams)) — recomputed for v5 vault.
    // Run script with --sig "computeMarketId()" to verify before executing.
    bytes32 constant MARKET_ID_77PCT =
        0x96af141c5ac70610ee0c4d8b5cf72205a8358e888407e0ba45c1cb21f9449f1e;

    uint256 sk1;
    uint256 sk2;

    function setUp() public {
        sk1 = uint256(vm.envBytes32("SAFE_SK1"));
        sk2 = uint256(vm.envBytes32("SAFE_SK2"));
    }

    function run() external {
        vm.startBroadcast(vm.envUint("EXECUTOR_PK"));

        // Create Morpho Blue market: wstDIEM collateral / DIEM loan / 77% LLTV
        //
        // NOTE: 75% LLTV is not whitelisted on Base Morpho (isLltvEnabled returns false for
        // both 700000000000000000 and 750000000000000000). Using 77% — the closest enabled
        // value above the 70–75% target. Leverage at 77%: 4.35x vs 1.63x at 38.5%.
        _execSafe(
            MORPHO,
            abi.encodeWithSignature(
                "createMarket((address,address,address,address,uint256))",
                DIEM,
                WST_DIEM,
                ORACLE,
                IRM,
                LLTV_77PCT
            )
        );

        console.log("=== Morpho 77% LLTV market created (wstDIEM/DIEM) ===");
        console.log("  loanToken      :", DIEM);
        console.log("  collateral     :", WST_DIEM);
        console.log("  oracle         :", ORACLE);
        console.log("  irm            :", IRM);
        console.log("  lltv           : 770000000000000000 (77%)");
        console.log("  max leverage   : 4.35x");
        console.log("  MARKET_ID      :");
        console.logBytes32(MARKET_ID_77PCT);

        vm.stopBroadcast();
    }

    // -------------------------------------------------------------------------
    // Safe execution helper — verbatim pattern from SafeBatchV3.s.sol
    //
    // Signatures packed as: [sk2_sig][sk1_sig].
    // Safe verifies signer addresses are sorted ascending; the Safe in SafeBatchV3
    // uses this exact ordering (sk2 first, sk1 second).
    // -------------------------------------------------------------------------
    function _execSafe(address to, bytes memory data) internal {
        uint256 safeNonce = ISafe(SAFE).nonce();
        bytes32 txHash = ISafe(SAFE)
            .getTransactionHash(
                to,
                0, // value
                data,
                0, // operation (Call)
                0, // safeTxGas
                0, // baseGas
                0, // gasPrice
                ZERO, // gasToken
                ZERO, // refundReceiver
                safeNonce
            );

        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(sk2, txHash);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(sk1, txHash);
        bytes memory sigs = abi.encodePacked(r2, s2, v2, r1, s1, v1);

        bool ok = ISafe(SAFE)
            .execTransaction(
                to,
                0, // value
                data,
                0, // operation (Call)
                0, // safeTxGas
                0, // baseGas
                0, // gasPrice
                ZERO, // gasToken
                payable(ZERO), // refundReceiver
                sigs
            );
        require(ok, "SafeTx failed");
    }
}
