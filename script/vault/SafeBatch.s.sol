// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

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
    ) external payable returns (bool success);

    function nonce() external view returns (uint256);
}

contract SafeBatch is Script {
    address constant SAFE = 0x872c561f699B42977c093F0eD8b4C9a431280c6c;
    address constant ZERO = address(0);

    // Safe requires signatures sorted by signer address ascending.
    // Signer 2 (0x6FDD) < Signer 1 (0x8f60), so SIG2 first.
    uint256 sk1;
    uint256 sk2;
    address executor; // pays gas — can be any EOA with ETH

    function setUp() public {
        sk1 = uint256(vm.envBytes32("SAFE_SK1"));
        sk2 = uint256(vm.envBytes32("SAFE_SK2"));
        executor = vm.envAddress("EXECUTOR");
    }

    function run() external {
        vm.startBroadcast(vm.envUint("EXECUTOR_PK"));

        // initiateEnableWithdrawals already called — unlocks 2026-06-15 21:41 UTC
        address[8] memory deprecated = [
            0xc4845F25B84EA8970D622fbF4FF7d10a6Fb7829e, // FeeRouter v1
            0x1C3709eCc560E3c5f529544ef36daA10E352f862, // Router v1
            0x23b43f4B8902147a2ccbb3f337947AD54Be71153, // Router v2
            0x4C56e11b7C7a6C411BD67138df19B48d1b32d9b7, // Router v3
            0x601361c2d095f39ca6C5221DDA90e78AB3ba5F05, // Router v4
            0x4D590397D2fe409a4B223906fbd0635FEF30ad7c, // Router v5
            0x8Dc32dA92B89a0968BEc020924491FE94573bef2, // AgentTGERegistry v1
            0x93577aAA7469Ef62198680Bc006a45e9bd6292B3 // SurplusStakingWrapper v1
        ];

        bytes memory renounce = abi.encodeWithSignature("renounceOwnership()");
        for (uint256 i = 0; i < deprecated.length; i++) {
            _execSafe(deprecated[i], renounce);
            console.log("renounced:", deprecated[i]);
        }

        vm.stopBroadcast();
    }

    function _execSafe(address to, bytes memory data) internal {
        uint256 nonce = ISafe(SAFE).nonce();
        bytes32 txHash = ISafe(SAFE).getTransactionHash(to, 0, data, 0, 0, 0, 0, ZERO, ZERO, nonce);

        // Sign with both keys (signer 2 first — lower address)
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(sk2, txHash);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(sk1, txHash);

        bytes memory sigs = abi.encodePacked(r2, s2, v2, r1, s1, v1);

        bool success =
            ISafe(SAFE).execTransaction(to, 0, data, 0, 0, 0, 0, ZERO, payable(ZERO), sigs);
        require(success, "SafeTx failed");
    }
}
