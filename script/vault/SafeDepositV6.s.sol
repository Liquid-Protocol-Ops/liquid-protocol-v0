// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

// Safe interface (Gnosis Safe v1.3)
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

interface IVaultView {
    function previewDeposit(uint256 assets) external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function paused() external view returns (bool);
}

interface IERC20View {
    function balanceOf(address) external view returns (uint256);
}

/// @notice Deposits Safe-held DIEM into the LIVE v6 InferenceVault (wstDIEM), Safe receives shares.
///         Two consecutive Safe txs: DIEM.approve(v6, AMOUNT) then v6.deposit(AMOUNT, Safe).
///         Used to redeploy the 2.746 DIEM recovered from the old v4 vault into productive yield.
///
/// Run (dry-run):  SAFE_SK1=<bytes32> SAFE_SK2=<bytes32> EXECUTOR_PK=<uint256> BASE_RPC_URL=<url> \
///   forge script script/vault/SafeDepositV6.s.sol --tc SafeDepositV6 --rpc-url $BASE_RPC_URL
/// Broadcast: append --broadcast --slow
contract SafeDepositV6 is Script {
    address constant SAFE = 0x872c561f699B42977c093F0eD8b4C9a431280c6c;
    address constant VAULT = 0xe49FA849cB37b0e7A42B2335e333fb99474167ba; // v6 InferenceVault
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;
    address constant ZERO = address(0);

    address constant SK2_ADDR = 0x6FDDe67e9c545AcdcE17944bf8f9988E1f88aa9E;
    address constant SK1_ADDR = 0x8f60eB404a5CA868f37bc798ec4c54FA0dcCFC9F;

    // Exact DIEM recovered from the v4 vault redeem (2.746136... DIEM).
    uint256 constant DIEM_AMOUNT = 2746136181161634959;

    uint256 sk1;
    uint256 sk2;

    function setUp() public {
        sk1 = uint256(vm.envBytes32("SAFE_SK1"));
        sk2 = uint256(vm.envBytes32("SAFE_SK2"));
        require(vm.addr(sk1) == SK1_ADDR, "SAFE_SK1 mismatch");
        require(vm.addr(sk2) == SK2_ADDR, "SAFE_SK2 mismatch");
    }

    function run() external {
        require(!IVaultView(VAULT).paused(), "vault paused");
        uint256 safeDiem = IERC20View(DIEM).balanceOf(SAFE);
        require(safeDiem >= DIEM_AMOUNT, "Safe DIEM balance too low");
        uint256 expectShares = IVaultView(VAULT).previewDeposit(DIEM_AMOUNT);
        uint256 sharesBefore = IVaultView(VAULT).balanceOf(SAFE);
        console.log("Safe DIEM balance :", safeDiem);
        console.log("Depositing DIEM   :", DIEM_AMOUNT);
        console.log("Expected wstDIEM  :", expectShares);

        vm.startBroadcast(vm.envUint("EXECUTOR_PK"));
        _execSafe(DIEM, abi.encodeWithSignature("approve(address,uint256)", VAULT, DIEM_AMOUNT));
        console.log("Tx1: DIEM.approve(v6, amount) done");
        _execSafe(VAULT, abi.encodeWithSignature("deposit(uint256,address)", DIEM_AMOUNT, SAFE));
        console.log("Tx2: v6.deposit(amount, Safe) done");
        vm.stopBroadcast();

        uint256 sharesAfter = IVaultView(VAULT).balanceOf(SAFE);
        console.log("Safe wstDIEM gained:", sharesAfter - sharesBefore);
    }

    function _execSafe(address to, bytes memory data) internal {
        uint256 nonce = ISafe(SAFE).nonce();
        bytes32 txHash = ISafe(SAFE).getTransactionHash(to, 0, data, 0, 0, 0, 0, ZERO, ZERO, nonce);
        // Sign: SK2 (lower address) first, SK1 second — Safe requires ascending signer order.
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(sk2, txHash);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(sk1, txHash);
        bytes memory sigs = abi.encodePacked(r2, s2, v2, r1, s1, v1);
        bool ok = ISafe(SAFE).execTransaction(to, 0, data, 0, 0, 0, 0, ZERO, payable(ZERO), sigs);
        require(ok, "SafeTx failed");
    }
}
