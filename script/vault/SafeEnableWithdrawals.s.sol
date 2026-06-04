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

/// @notice Calls enableWithdrawals() on the old InferenceVault v4.
///         Run this 14 days after SafeInitiateWithdrawals.s.sol.
///         After this, wstDIEM holders can requestWithdraw → flushBatch → claimBatch.
///
/// Run:
///   SAFE_SK1=<bytes32> SAFE_SK2=<bytes32> EXECUTOR_PK=<uint256> \
///   forge script script/vault/SafeEnableWithdrawals.s.sol \
///     --rpc-url $BASE_RPC_URL --broadcast
contract SafeEnableWithdrawals is Script {
    address constant SAFE = 0x872c561f699B42977c093F0eD8b4C9a431280c6c;
    address constant OLD_VAULT = 0x4751BA2b09374C1929FC01734a166e3c8cd75810;

    uint256 sk1;
    uint256 sk2;

    function setUp() public {
        sk1 = uint256(vm.envBytes32("SAFE_SK1"));
        sk2 = uint256(vm.envBytes32("SAFE_SK2"));
    }

    function run() external {
        vm.startBroadcast(vm.envUint("EXECUTOR_PK"));
        _execSafe(OLD_VAULT, abi.encodeWithSignature("enableWithdrawals()"));
        console.log("enableWithdrawals() sent on", OLD_VAULT);
        console.log("wstDIEM holders may now requestWithdraw -> flushBatch -> claimBatch.");
        vm.stopBroadcast();
    }

    function _execSafe(address to, bytes memory data) internal {
        ISafe safe = ISafe(SAFE);
        uint256 nonce = safe.nonce();

        bytes32 txHash =
            safe.getTransactionHash(to, 0, data, 0, 0, 0, 0, address(0), address(0), nonce);

        address addr1 = vm.addr(sk1);
        address addr2 = vm.addr(sk2);
        uint256 lower = addr1 < addr2 ? sk1 : sk2;
        uint256 higher = addr1 < addr2 ? sk2 : sk1;

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(lower, txHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(higher, txHash);

        bytes memory sigs = abi.encodePacked(r1, s1, v1, r2, s2, v2);
        safe.execTransaction(to, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), sigs);
    }
}
