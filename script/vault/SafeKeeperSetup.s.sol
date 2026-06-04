// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

// SafeKeeperSetup — wires the keeper EOA for autonomous inference operations.
//
// Executes 6 consecutive Safe transactions:
//   Tx 1: WETH.approve(V3Router, 0.01 WETH)
//   Tx 2: V3Router.exactInputSingle(WETH->VVV, 0.01 WETH, minOut=0, recipient=Safe)
//   Tx 3: VVV.approve(vault, 1 VVV)
//   Tx 4: vault.fundKeeperVVV(keeperEOA, ...) -> keeper receives sVVV, can mint Venice API key
//   Tx 5: FeeRouter.setKeeper(keeperEOA)      -> keeper can call harvest/settleAndHarvest
//   Tx 6: vault.setKeeper(keeperEOA)          -> keeper can call vault.fundKeeperVVV later
//
// After running: keeper EOA (0x32fD...) self-mints Venice API key:
//   GET  https://api.venice.ai/api/v1/api_keys/generate_web3_key  -> token
//   Sign token with keeper private key (personal_sign)
//   POST back with {address, signature, token, apiKeyType: "INFERENCE"}
//   -> receive Bearer API key
//
// Run:
//   SAFE_SK1=<bytes32> SAFE_SK2=<bytes32> EXECUTOR_PK=<uint256> \
//   forge script script/vault/SafeKeeperSetup.s.sol --rpc-url $BASE_RPC_URL [--broadcast]

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

interface ISwapRouterV3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256);
}

contract SafeKeeperSetup is Script {
    address constant SAFE = 0x872c561f699B42977c093F0eD8b4C9a431280c6c;
    address constant VAULT = 0x4751BA2b09374C1929FC01734a166e3c8cd75810;
    address constant FEEROUTER = 0x21fe048B10dC9bED2Ee0Ae76724C627CA7F35F61;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;
    address constant VVV_STAKING = 0x321b7ff75154472B18EDb199033fF4D116F340Ff;
    address constant V3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant ZERO = address(0);

    // Keeper EOA that will run the off-chain inference server.
    // Must match the 1P item: zfk52wt5di6kn3j76o6o7kngi4
    address constant KEEPER = 0x32fDdfB0eeC6c638d5C8b7cabF3bE9065478e90E;

    // WETH/VVV Uniswap V3 pool fee (0.3%)
    uint24 constant VVV_POOL_FEE = 3000;

    // Swap 0.01 WETH -> VVV. Only 1 VVV is needed to mint a Venice API key.
    // Any VVV received beyond 1e18 stays in Safe for future use.
    uint256 constant WETH_FOR_VVV = 0.01e18;

    // Stake exactly 1 VVV to keeper — minimum required to mint Venice API key.
    uint256 constant VVV_TO_STAKE = 1e18;

    address constant SK2_ADDR = 0x6FDDe67e9c545AcdcE17944bf8f9988E1f88aa9E;
    address constant SK1_ADDR = 0x8f60eB404a5CA868f37bc798ec4c54FA0dcCFC9F;

    uint256 sk1;
    uint256 sk2;

    function setUp() public {
        sk1 = uint256(vm.envBytes32("SAFE_SK1"));
        sk2 = uint256(vm.envBytes32("SAFE_SK2"));
        require(vm.addr(sk1) == SK1_ADDR, "SAFE_SK1 mismatch");
        require(vm.addr(sk2) == SK2_ADDR, "SAFE_SK2 mismatch");
    }

    function run() external {
        vm.startBroadcast(vm.envUint("EXECUTOR_PK"));

        console.log("Safe nonce before:", ISafe(SAFE).nonce());
        console.log("Keeper EOA:", KEEPER);

        // Tx 1: WETH.approve(V3Router, 0.01 WETH)
        _execSafe(
            WETH, abi.encodeWithSignature("approve(address,uint256)", V3_ROUTER, WETH_FOR_VVV)
        );
        console.log("Tx1: WETH.approve(V3Router) done");

        // Tx 2: Swap 0.01 WETH -> VVV, Safe receives VVV
        _execSafe(
            V3_ROUTER,
            abi.encodeWithSignature(
                "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))",
                WETH,
                VVV,
                VVV_POOL_FEE,
                SAFE,
                WETH_FOR_VVV,
                0,
                0
            )
        );
        console.log("Tx2: WETH->VVV swap done (Safe now holds VVV)");

        // Tx 3: VVV.approve(vault, 1 VVV) so vault can pull it for staking
        _execSafe(VVV, abi.encodeWithSignature("approve(address,uint256)", VAULT, VVV_TO_STAKE));
        console.log("Tx3: VVV.approve(vault) done");

        // Tx 4: vault.fundKeeperVVV -> stakes 1 VVV to keeper EOA (keeper gets sVVV)
        // Keeper can then call Venice API to mint its own API key (no human in loop).
        _execSafe(
            VAULT,
            abi.encodeWithSignature(
                "fundKeeperVVV(address,address,address,uint256)",
                KEEPER,
                VVV,
                VVV_STAKING,
                VVV_TO_STAKE
            )
        );
        console.log("Tx4: vault.fundKeeperVVV done (keeper has sVVV, can mint Venice key)");

        // Tx 5: FeeRouter.setKeeper -> keeper can call harvest/settleAndHarvest
        _execSafe(FEEROUTER, abi.encodeWithSignature("setKeeper(address)", KEEPER));
        console.log("Tx5: FeeRouter.setKeeper done");

        // Tx 6: vault.setKeeper -> keeper registered on vault
        _execSafe(VAULT, abi.encodeWithSignature("setKeeper(address)", KEEPER));
        console.log("Tx6: vault.setKeeper done");

        console.log("=== KEEPER SETUP COMPLETE ===");
        console.log("Keeper:", KEEPER);
        console.log("Next: keeper self-mints Venice API key via generate_web3_key endpoint");
        console.log("Then: register on AntSeed with ANTSEED_IDENTITY_HEX=<keeper_pk>");

        vm.stopBroadcast();
    }

    function _execSafe(address to, bytes memory data) internal {
        uint256 nonce = ISafe(SAFE).nonce();
        bytes32 txHash = ISafe(SAFE).getTransactionHash(to, 0, data, 0, 0, 0, 0, ZERO, ZERO, nonce);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(sk2, txHash);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(sk1, txHash);
        bytes memory sigs = abi.encodePacked(r2, s2, v2, r1, s1, v1);
        bool ok = ISafe(SAFE).execTransaction(to, 0, data, 0, 0, 0, 0, ZERO, payable(ZERO), sigs);
        require(ok, "SafeTx failed");
    }
}
