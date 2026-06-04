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

// SafeSeedCapital — seeds the wstDIEM vault and Router with initial capital.
//
// Executes 4 consecutive Safe transactions:
//   Tx 1: DIEM.approve(vault, DIEM_AMOUNT)
//   Tx 2: vault.deposit(DIEM_AMOUNT, Safe)   → Safe receives wstDIEM
//   Tx 3: WETH.approve(Router, WETH_AMOUNT)
//   Tx 4: Router.depositWETH(WETH_AMOUNT, 0, Safe) → Safe receives wstDIEM
//
// PRE-REQUISITES (check before running):
//   Safe must hold at least DIEM_AMOUNT of DIEM and WETH_AMOUNT of WETH.
//   If Safe holds ETH (not WETH), run SafeWrapETH.s.sol first.
//
// Run (dry-run, no broadcast):
//   SAFE_SK1=<bytes32> SAFE_SK2=<bytes32> EXECUTOR_PK=<uint256> \
//   forge script script/vault/SafeSeedCapital.s.sol --rpc-url $BASE_RPC_URL
//
// Broadcast:
//   add --broadcast to the above command.
//
// Env vars:
//   SAFE_SK1    — private key of liq-safe-signer-1 (0x8f60...) as bytes32 hex
//   SAFE_SK2    — private key of liq-safe-signer-2 (0x6FDD...) as bytes32 hex
//   EXECUTOR_PK — private key of the tx broadcaster (any funded EOA, e.g. deployer v3)
contract SafeSeedCapital is Script {
    // v4 contracts (2026-06-01 deployment)
    address constant SAFE = 0x872c561f699B42977c093F0eD8b4C9a431280c6c;
    address constant VAULT = 0x4751BA2b09374C1929FC01734a166e3c8cd75810;
    address constant ROUTER = 0x6f5FF03a91cb1703B7CB8d85572f990bcB04273D;
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant ZERO = address(0);

    // Signer addresses — signatures must be sorted ascending by address.
    // SK2 (0x6FDD) < SK1 (0x8f60), so SK2 always signs/appears first.
    // These are not secrets — just used to verify signing order.
    address constant SK2_ADDR = 0x6FDDe67e9c545AcdcE17944bf8f9988E1f88aa9E;
    address constant SK1_ADDR = 0x8f60eB404a5CA868f37bc798ec4c54FA0dcCFC9F;

    // Capital amounts.
    // Only DIEM is deposited here — WETH stays in Safe for V4 LP (SafeAddV4LP.s.sol).
    uint256 constant DIEM_AMOUNT = 2.74e18; // 2.74 DIEM -> vault -> 2.74 wstDIEM (~$2.74)

    uint256 sk1;
    uint256 sk2;

    function setUp() public {
        sk1 = uint256(vm.envBytes32("SAFE_SK1"));
        sk2 = uint256(vm.envBytes32("SAFE_SK2"));

        // Sanity: verify key ↔ address mapping
        require(vm.addr(sk1) == SK1_ADDR, "SAFE_SK1 does not match expected signer address");
        require(vm.addr(sk2) == SK2_ADDR, "SAFE_SK2 does not match expected signer address");
    }

    function run() external {
        vm.startBroadcast(vm.envUint("EXECUTOR_PK"));

        console.log("Safe nonce before:", ISafe(SAFE).nonce());

        // -- Step 1: Approve vault to spend DIEM --
        _execSafe(DIEM, abi.encodeWithSignature("approve(address,uint256)", VAULT, DIEM_AMOUNT));
        console.log("Tx1: DIEM.approve(vault, 2.74 DIEM) done");

        // -- Step 2: Deposit DIEM -> vault -> Safe receives wstDIEM --
        _execSafe(VAULT, abi.encodeWithSignature("deposit(uint256,address)", DIEM_AMOUNT, SAFE));
        console.log("Tx2: vault.deposit(2.74 DIEM, Safe) done");

        console.log("=== SEED CAPITAL COMPLETE ===");
        console.log("Safe nonce after:", ISafe(SAFE).nonce());
        console.log("Safe holds ~2.74 wstDIEM");
        console.log("Run SafeAddV4LP.s.sol next to pair wstDIEM with ~0.00137 WETH in V4");

        vm.stopBroadcast();
    }

    function _execSafe(address to, bytes memory data) internal {
        uint256 nonce = ISafe(SAFE).nonce();
        bytes32 txHash = ISafe(SAFE).getTransactionHash(to, 0, data, 0, 0, 0, 0, ZERO, ZERO, nonce);
        // Sign: SK2 (lower address) first, SK1 second
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(sk2, txHash);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(sk1, txHash);
        bytes memory sigs = abi.encodePacked(r2, s2, v2, r1, s1, v1);
        bool ok = ISafe(SAFE).execTransaction(to, 0, data, 0, 0, 0, 0, ZERO, payable(ZERO), sigs);
        require(ok, "SafeTx failed");
    }
}
