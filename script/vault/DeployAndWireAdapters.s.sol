// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AntSeedAdapter} from "../../src/vault/adapters/AntSeedAdapter.sol";
import {SurplusAdapter} from "../../src/vault/adapters/SurplusAdapter.sol";
import {X402Adapter} from "../../src/vault/adapters/X402Adapter.sol";
import {Script, console} from "forge-std/Script.sol";

// DeployAndWireAdapters
// 1. Deploys AntSeedAdapter, SurplusAdapter, X402Adapter (executor key).
// 2. Registers each as a venue adapter on InferenceVault v5 via Safe multisig.
//
// Run:
//   SAFE_SK1=<bytes32> SAFE_SK2=<bytes32> EXECUTOR_PK=<uint256> \
//   forge script script/vault/DeployAndWireAdapters.s.sol \
//     --rpc-url $BASE_RPC_URL --broadcast

interface ISafe {
    function getTransactionHash(
        address,
        uint256,
        bytes calldata,
        uint8,
        uint256,
        uint256,
        uint256,
        address,
        address,
        uint256
    ) external view returns (bytes32);
    function execTransaction(
        address,
        uint256,
        bytes calldata,
        uint8,
        uint256,
        uint256,
        uint256,
        address,
        address payable,
        bytes memory
    ) external payable returns (bool);
    function nonce() external view returns (uint256);
}

contract DeployAndWireAdapters is Script {
    address constant VAULT = 0xb9f23c33FfD2213f31C0cFb6c9e2fDf525a9Dd2D; // InferenceVault v5
    address constant SAFE = 0x872c561f699B42977c093F0eD8b4C9a431280c6c;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // USDC on Base
    address constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481; // V3 SwapRouter02

    address constant ZERO = address(0);

    uint256 sk1;
    uint256 sk2;

    function setUp() public {
        sk1 = uint256(vm.envBytes32("SAFE_SK1"));
        sk2 = uint256(vm.envBytes32("SAFE_SK2"));
    }

    function run() external {
        uint256 executorPk = vm.envUint("EXECUTOR_PK");
        vm.startBroadcast(executorPk);

        // ── Deploy adapters (owned by Safe from birth) ────────────────────────
        AntSeedAdapter antSeed = new AntSeedAdapter(VAULT, USDC, SWAP_ROUTER, SAFE);
        SurplusAdapter surplus = new SurplusAdapter(VAULT, USDC, SWAP_ROUTER, SAFE);
        X402Adapter x402 = new X402Adapter(VAULT, USDC, SWAP_ROUTER, SAFE);

        console.log("AntSeedAdapter:", address(antSeed));
        console.log("SurplusAdapter:", address(surplus));
        console.log("X402Adapter:   ", address(x402));

        vm.stopBroadcast();

        // ── Register each adapter via Safe ────────────────────────────────────
        // setVenueAdapter(address adapter, bool enabled)
        _execSafe(
            VAULT, abi.encodeWithSignature("setVenueAdapter(address,bool)", address(antSeed), true)
        );
        console.log("Registered AntSeedAdapter");

        _execSafe(
            VAULT, abi.encodeWithSignature("setVenueAdapter(address,bool)", address(surplus), true)
        );
        console.log("Registered SurplusAdapter");

        _execSafe(
            VAULT, abi.encodeWithSignature("setVenueAdapter(address,bool)", address(x402), true)
        );
        console.log("Registered X402Adapter");

        console.log("All adapters deployed and registered.");
    }

    function _execSafe(address to, bytes memory data) internal {
        ISafe safe = ISafe(SAFE);
        uint256 nonce = safe.nonce();
        bytes32 txHash = safe.getTransactionHash(to, 0, data, 0, 0, 0, 0, ZERO, ZERO, nonce);

        address addr1 = vm.addr(sk1);
        address addr2 = vm.addr(sk2);
        uint256 lower = addr1 < addr2 ? sk1 : sk2;
        uint256 higher = addr1 < addr2 ? sk2 : sk1;

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(lower, txHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(higher, txHash);

        bytes memory sigs = abi.encodePacked(r1, s1, v1, r2, s2, v2);

        vm.broadcast(vm.envUint("EXECUTOR_PK"));
        bool ok = safe.execTransaction(to, 0, data, 0, 0, 0, 0, ZERO, payable(ZERO), sigs);
        require(ok, "SafeTx failed");
    }
}
