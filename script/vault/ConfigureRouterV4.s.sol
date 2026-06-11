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
    ) external payable returns (bool);
    function nonce() external view returns (uint256);
}

contract ConfigureRouterV4 is Script {
    address constant SAFE = 0x872c561f699B42977c093F0eD8b4C9a431280c6c;
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    uint24 constant DYNAMIC_FEE = 0x800000;
    address constant ZERO = address(0);

    uint256 sk1;
    uint256 sk2;

    function run() external {
        address router = vm.envAddress("ROUTER"); // redeployed Router from Task 7
        address hook = vm.envAddress("WSTDIEM_HOOK");
        sk1 = uint256(vm.envBytes32("SAFE_SK1"));
        sk2 = uint256(vm.envBytes32("SAFE_SK2"));

        vm.startBroadcast(vm.envUint("EXECUTOR_PK"));
        _execSafe(
            router,
            abi.encodeWithSignature(
                "setSwapFees(uint24,uint24,int24,address)",
                uint24(10_000),
                DYNAMIC_FEE,
                int24(60),
                hook
            )
        );
        console.log("setSwapFees executed (dynamic fee + hook)");
        _execSafe(router, abi.encodeWithSignature("setV4Pool(address)", POOL_MANAGER));
        console.log("setV4Pool executed");
        vm.stopBroadcast();
    }

    function _execSafe(address to, bytes memory data) internal {
        uint256 nonce = ISafe(SAFE).nonce();
        bytes32 txHash = ISafe(SAFE).getTransactionHash(to, 0, data, 0, 0, 0, 0, ZERO, ZERO, nonce);
        address a1 = vm.addr(sk1);
        address a2 = vm.addr(sk2);
        uint256 lower = a1 < a2 ? sk1 : sk2;
        uint256 higher = a1 < a2 ? sk2 : sk1;
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(lower, txHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(higher, txHash);
        bytes memory sigs = abi.encodePacked(r1, s1, v1, r2, s2, v2);
        require(
            ISafe(SAFE).execTransaction(to, 0, data, 0, 0, 0, 0, ZERO, payable(ZERO), sigs),
            "SafeTx failed"
        );
    }
}
