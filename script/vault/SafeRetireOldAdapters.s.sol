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

/// @notice Deregisters the OLD venue adapters (pre-MOG-541, amountOutMinimum=0) from the v6 vault
///         after the patched adapters were deployed + registered via DeployV6Adapters.s.sol.
///         Safe-routed (2-of-3). Env: SAFE_SK1, SAFE_SK2 (bytes32), EXECUTOR_PK (uint256).
contract SafeRetireOldAdapters is Script {
    address constant SAFE = 0x872c561f699B42977c093F0eD8b4C9a431280c6c;
    address constant VAULT = 0xe49FA849cB37b0e7A42B2335e333fb99474167ba;
    address constant OLD_ANT = 0x8885B256609e1D7C1FB2f1dB58a379D2efb8bbf3;
    address constant OLD_SUR = 0xf50ca14f49bD090fC13680019Ed8dF5046626e8b;

    uint256 sk1;
    uint256 sk2;

    function run() external {
        uint256 pk = vm.envUint("EXECUTOR_PK");
        sk1 = uint256(vm.envBytes32("SAFE_SK1"));
        sk2 = uint256(vm.envBytes32("SAFE_SK2"));

        vm.startBroadcast(pk);
        _execSafe(VAULT, abi.encodeWithSignature("setVenueAdapter(address,bool)", OLD_ANT, false));
        _execSafe(VAULT, abi.encodeWithSignature("setVenueAdapter(address,bool)", OLD_SUR, false));
        vm.stopBroadcast();
        console.log("Retired old AntSeed + Surplus adapters");
    }

    function _execSafe(address to, bytes memory data) internal {
        ISafe safe = ISafe(SAFE);
        uint256 n = safe.nonce();
        bytes32 txHash = safe.getTransactionHash(to, 0, data, 0, 0, 0, 0, address(0), address(0), n);

        address a1 = vm.addr(sk1);
        address a2 = vm.addr(sk2);
        uint256 lower = a1 < a2 ? sk1 : sk2;
        uint256 higher = a1 < a2 ? sk2 : sk1;

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(lower, txHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(higher, txHash);
        bytes memory sigs = abi.encodePacked(r1, s1, v1, r2, s2, v2);

        require(
            safe.execTransaction(to, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), sigs),
            "Safe tx failed"
        );
    }
}
