// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {GondolaAdapter} from "../../src/vault/adapters/GondolaAdapter.sol";
import {Script, console} from "forge-std/Script.sol";

// DeployGondolaAdapter — venue adapter for Gondola (gondola-ai.com) on the v6 vault.
//
// 1. Deploys the adapter (initialOwner = deployer, to configure in-script).
// 2. setKeeper = the wstdiem-keeper, so it may call routeYield(minDiemOut). Gondola pays out by
//    plain USDC transfer to the payout address, so no settler is set. operatorFeeBps stays 10%.
// 3. transferOwnership to the Safe.
// 4. Registers it on the vault via the Safe (setVenueAdapter) so it may call creditDIEM().
//
// After it runs: set the printed address as the payout address on Gondola's Sell page.
//
// Run:
//   EXECUTOR_PK=<deployer pk> SAFE_SK1=<bytes32> SAFE_SK2=<bytes32> \
//   forge script script/vault/DeployGondolaAdapter.s.sol --tc DeployGondolaAdapter \
//     --rpc-url $BASE_RPC_URL [--broadcast --slow]

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

contract DeployGondolaAdapter is Script {
    address constant VAULT = 0xe49FA849cB37b0e7A42B2335e333fb99474167ba; // InferenceVault v6
    address constant SAFE = 0x872c561f699B42977c093F0eD8b4C9a431280c6c;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481; // V3 SwapRouter02 (Base)
    address constant KEEPER = 0x988CE72d127b8A06821BBb3708897dBdc0D66f2f; // wstdiem-keeper (operator)
    address constant ZERO = address(0);

    uint256 sk1;
    uint256 sk2;

    function run() external {
        uint256 pk = vm.envUint("EXECUTOR_PK");
        address deployer = vm.addr(pk);
        sk1 = uint256(vm.envBytes32("SAFE_SK1"));
        sk2 = uint256(vm.envBytes32("SAFE_SK2"));

        vm.startBroadcast(pk);

        // 1. Deploy (deployer owns transiently to configure).
        GondolaAdapter gon = new GondolaAdapter(VAULT, USDC, SWAP_ROUTER, deployer);

        // 2. Keeper calls routeYield(minDiemOut). No settler: payouts are plain transfers.
        gon.setKeeper(KEEPER);

        // 3. Hand the adapter to the Safe.
        gon.transferOwnership(SAFE);

        // 4. Register on the vault (Safe-owned) so it may creditDIEM().
        _execSafe(
            VAULT, abi.encodeWithSignature("setVenueAdapter(address,bool)", address(gon), true)
        );

        vm.stopBroadcast();

        console.log("=== Gondola adapter live ===");
        console.log("GondolaAdapter (set as the Gondola payout address):", address(gon));
        console.log("keeper (operator):", KEEPER);
    }

    function _execSafe(address to, bytes memory data) internal {
        ISafe safe_ = ISafe(SAFE);
        uint256 nonce = safe_.nonce();
        bytes32 txHash = safe_.getTransactionHash(to, 0, data, 0, 0, 0, 0, ZERO, ZERO, nonce);
        address a1 = vm.addr(sk1);
        address a2 = vm.addr(sk2);
        uint256 lower = a1 < a2 ? sk1 : sk2;
        uint256 higher = a1 < a2 ? sk2 : sk1;
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(lower, txHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(higher, txHash);
        bytes memory sigs = abi.encodePacked(r1, s1, v1, r2, s2, v2);
        require(
            safe_.execTransaction(to, 0, data, 0, 0, 0, 0, ZERO, payable(ZERO), sigs),
            "SafeTx failed"
        );
    }
}
