// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

// Run this BEFORE SafeSeedCapital if the Safe holds ETH rather than WETH.
// Wraps 2 ETH → 2 WETH so the Safe can call WETH.approve() and Router.depositWETH().
//
// Run:
//   SAFE_SK1=<bytes32> SAFE_SK2=<bytes32> EXECUTOR_PK=<uint256> \
//   forge script script/vault/SafeWrapETH.s.sol --rpc-url $BASE_RPC_URL [--broadcast]

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

contract SafeWrapETH is Script {
    address constant SAFE = 0x872c561f699B42977c093F0eD8b4C9a431280c6c;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant ZERO = address(0);

    address constant SK2_ADDR = 0x6FDDe67e9c545AcdcE17944bf8f9988E1f88aa9E;
    address constant SK1_ADDR = 0x8f60eB404a5CA868f37bc798ec4c54FA0dcCFC9F;

    uint256 constant WRAP_AMOUNT = 2e18; // 2 ETH → 2 WETH

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

        // WETH.deposit{value: 2 ether}() — wraps ETH from Safe balance into WETH
        uint256 nonce = ISafe(SAFE).nonce();
        bytes memory data = abi.encodeWithSignature("deposit()");
        bytes32 txHash =
            ISafe(SAFE).getTransactionHash(WETH, WRAP_AMOUNT, data, 0, 0, 0, 0, ZERO, ZERO, nonce);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(sk2, txHash);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(sk1, txHash);
        bytes memory sigs = abi.encodePacked(r2, s2, v2, r1, s1, v1);

        // Note: value = WRAP_AMOUNT (ETH sent with the tx from Safe's ETH balance)
        bool ok = ISafe(SAFE)
            .execTransaction(WETH, WRAP_AMOUNT, data, 0, 0, 0, 0, ZERO, payable(ZERO), sigs);
        require(ok, "SafeTx failed");
        console.log("Wrapped 2 ETH -> 2 WETH in Safe");

        vm.stopBroadcast();
    }
}
