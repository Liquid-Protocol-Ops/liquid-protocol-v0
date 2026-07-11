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

interface IVault {
    function balanceOf(address) external view returns (uint256);
    function maxRedeem(address) external view returns (uint256);
    function previewRedeem(uint256) external view returns (uint256);
}

/// @notice Final step of the v4 recovery: redeem the Safe's wstDIEM v4 shares for DIEM (to the Safe).
///         PRECONDITIONS: enableWithdrawals() done, initiateUnstake() done, ~24h passed, AND
///         completeUnstake() called (permissionless) so DIEM is idle. Verify maxRedeem(SAFE) == balance.
///
/// Run: SAFE_SK1=<bytes32> SAFE_SK2=<bytes32> EXECUTOR_PK=<uint256> BASE_RPC_URL=<url> \
///   forge script script/vault/SafeRedeemV4.s.sol --tc SafeRedeemV4 --rpc-url $BASE_RPC_URL --broadcast
contract SafeRedeemV4 is Script {
    address constant SAFE = 0x872c561f699B42977c093F0eD8b4C9a431280c6c;
    address constant OLD_VAULT = 0x4751BA2b09374C1929FC01734a166e3c8cd75810;

    uint256 sk1;
    uint256 sk2;

    function setUp() public {
        sk1 = uint256(vm.envBytes32("SAFE_SK1"));
        sk2 = uint256(vm.envBytes32("SAFE_SK2"));
    }

    function run() external {
        uint256 shares = IVault(OLD_VAULT).balanceOf(SAFE);
        uint256 redeemable = IVault(OLD_VAULT).maxRedeem(SAFE);
        require(shares > 0, "Safe has no v4 shares");
        require(
            redeemable >= shares,
            "not fully redeemable: run completeUnstake() first / wait cooldown"
        );
        console.log("Redeeming shares:", shares);
        console.log("Expected DIEM out:", IVault(OLD_VAULT).previewRedeem(shares));

        vm.startBroadcast(vm.envUint("EXECUTOR_PK"));
        // redeem(shares, receiver=SAFE, owner=SAFE) — msg.sender is the Safe via execTransaction
        _execSafe(
            OLD_VAULT,
            abi.encodeWithSignature("redeem(uint256,address,address)", shares, SAFE, SAFE)
        );
        console.log("redeem() sent. DIEM delivered to the Safe.");
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
        bool ok =
            safe.execTransaction(to, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), sigs);
        require(ok, "Safe tx failed");
    }
}
