// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LiquidityManager} from "../../src/vault/LiquidityManager.sol";
import {Script, console} from "forge-std/Script.sol";

// SafeManageV4LP — persistent LiquidityManager with add, remove, and fee-collect.
//
// ┌─ WHY THIS EXISTS ────────────────────────────────────────────────────────────┐
// │ SafeAddV4LP.s.sol deployed a single-use LiquidityHelper (0x7060d57e…) with  │
// │ no removeLiquidity function. The 2.718 wstDIEM LP position owned by that    │
// │ helper is permanently locked — it cannot grant allowOperator() to anyone    │
// │ and its unlockCallback only emits positive deltas (add only).                │
// │                                                                              │
// │ This script deploys a PERSISTENT LiquidityManager with full add/remove/     │
// │ collect. The Safe holds exclusive control. LP position is owned by the       │
// │ manager; the manager's remove function recovers tokens to the Safe.         │
// └──────────────────────────────────────────────────────────────────────────────┘
//
// Usage:
//   Deploy manager (once):
//     EXECUTOR_PK=<uint256> forge script script/vault/SafeManageV4LP.s.sol \
//       --sig "deployManager()" --rpc-url $BASE_RPC_URL [--broadcast]
//
//   Add liquidity (Safe txs: pre-send tokens → call addLiquidity):
//     SAFE_SK1=<bytes32> SAFE_SK2=<bytes32> EXECUTOR_PK=<uint256> \
//     MANAGER=<deployed_manager_address> LIQUIDITY=<uint128> \
//     forge script script/vault/SafeManageV4LP.s.sol \
//       --sig "addLiquidity()" --rpc-url $BASE_RPC_URL [--broadcast]
//
//   Remove liquidity (Safe tx: call removeLiquidity):
//     SAFE_SK1=<bytes32> SAFE_SK2=<bytes32> EXECUTOR_PK=<uint256> \
//     MANAGER=<deployed_manager_address> LIQUIDITY=<uint128> \
//     forge script script/vault/SafeManageV4LP.s.sol \
//       --sig "removeLiquidity()" --rpc-url $BASE_RPC_URL [--broadcast]
//
//   Collect accrued fees:
//     SAFE_SK1=<bytes32> SAFE_SK2=<bytes32> EXECUTOR_PK=<uint256> \
//     MANAGER=<deployed_manager_address> \
//     forge script script/vault/SafeManageV4LP.s.sol \
//       --sig "collectFees()" --rpc-url $BASE_RPC_URL [--broadcast]

// ─── Interfaces ───────────────────────────────────────────────────────────────

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

// ─── Script ───────────────────────────────────────────────────────────────────

contract SafeManageV4LP is Script {
    address constant SAFE = 0x872c561f699B42977c093F0eD8b4C9a431280c6c;
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant WSTDIEM = 0xb9f23c33FfD2213f31C0cFb6c9e2fDf525a9Dd2D; // v5
    address constant WETH = 0x4200000000000000000000000000000000000006;
    uint24 constant DYNAMIC_FEE = 0x800000;
    int24 constant TICK_SPACING = 60;
    int24 constant TICK_LOWER = -887_220; // full range
    int24 constant TICK_UPPER = 887_220;
    address constant ZERO = address(0);

    uint256 sk1;
    uint256 sk2;

    // ── deployManager ──────────────────────────────────────────────────────
    // Run once. Save the printed address as MANAGER for subsequent calls.
    // Requires WSTDIEM_HOOK env var (deployed in Task 5) and EXECUTOR_PK.
    function deployManager() external {
        address hook = vm.envAddress("WSTDIEM_HOOK"); // deployed in Task 5
        (address c0, address c1) = WETH < WSTDIEM ? (WETH, WSTDIEM) : (WSTDIEM, WETH);
        vm.startBroadcast(vm.envUint("EXECUTOR_PK"));
        LiquidityManager mgr = new LiquidityManager(
            POOL_MANAGER, c0, c1, DYNAMIC_FEE, TICK_SPACING, TICK_LOWER, TICK_UPPER, hook, SAFE
        );
        console.log("LiquidityManager deployed:", address(mgr));
        console.log("Save as MANAGER env var for addLiquidity/removeLiquidity/collectFees.");
        vm.stopBroadcast();
    }

    // ── addLiquidity ───────────────────────────────────────────────────────
    // Pre-conditions: Safe holds WETH + wstDIEM.
    // Safe tx 1: transfer WETH_BUDGET WETH to manager
    // Safe tx 2: transfer WSTDIEM_BUDGET wstDIEM to manager
    // Safe tx 3: manager.addLiquidity(LIQUIDITY)
    // Post: excess tokens returned to Safe automatically.
    function addLiquidity() external {
        _loadSigners();
        address manager = vm.envAddress("MANAGER");
        uint128 liquidity = uint128(vm.envUint("LIQUIDITY"));
        uint256 wethBudget = vm.envOr("WETH_BUDGET", uint256(0.002e18));
        uint256 wstDiemBudget = vm.envOr("WSTDIEM_BUDGET", uint256(2.74e18));

        vm.startBroadcast(vm.envUint("EXECUTOR_PK"));

        _execSafe(WETH, abi.encodeWithSignature("transfer(address,uint256)", manager, wethBudget));
        console.log("Tx1: sent", wethBudget, "WETH to manager");

        _execSafe(
            WSTDIEM, abi.encodeWithSignature("transfer(address,uint256)", manager, wstDiemBudget)
        );
        console.log("Tx2: sent", wstDiemBudget, "wstDIEM to manager");

        _execSafe(manager, abi.encodeWithSignature("addLiquidity(uint128)", liquidity));
        console.log("Tx3: addLiquidity executed - liquidity units:", uint256(liquidity));
        console.log("Excess tokens auto-returned to Safe.");

        vm.stopBroadcast();
    }

    // ── removeLiquidity ────────────────────────────────────────────────────
    // Removes LIQUIDITY units from the position. Tokens arrive in Safe.
    // To remove the full position, query the position's liquidity off-chain
    // and pass that exact amount (see cast call below in comments).
    //
    // Off-chain: cast call 0x498581... "getPosition(address,address,int24,int24,bytes32)(...)"
    //   $MANAGER $POOLID 62160 92100 0x0000...
    function removeLiquidity() external {
        _loadSigners();
        address manager = vm.envAddress("MANAGER");
        uint128 liquidity = uint128(vm.envUint("LIQUIDITY"));

        vm.startBroadcast(vm.envUint("EXECUTOR_PK"));
        _execSafe(manager, abi.encodeWithSignature("removeLiquidity(uint128)", liquidity));
        console.log("Tx: removeLiquidity executed - liquidity units removed:", uint256(liquidity));
        console.log("WETH + wstDIEM returned to Safe.");
        vm.stopBroadcast();
    }

    // ── collectFees ────────────────────────────────────────────────────────
    // Collects accrued trading fees from the LP position. Tokens go to Safe.
    function collectFees() external {
        _loadSigners();
        address manager = vm.envAddress("MANAGER");

        vm.startBroadcast(vm.envUint("EXECUTOR_PK"));
        _execSafe(manager, abi.encodeWithSignature("collectFees()"));
        console.log("Tx: collectFees executed. Accrued WETH + wstDIEM sent to Safe.");
        vm.stopBroadcast();
    }

    // ─────────────────────────────────────────────────────────────────────────

    function _loadSigners() internal {
        sk1 = uint256(vm.envBytes32("SAFE_SK1"));
        sk2 = uint256(vm.envBytes32("SAFE_SK2"));
    }

    function _execSafe(address to, bytes memory data) internal {
        ISafe safe_ = ISafe(SAFE);
        uint256 nonce = safe_.nonce();
        bytes32 txHash = safe_.getTransactionHash(to, 0, data, 0, 0, 0, 0, ZERO, ZERO, nonce);

        address addr1 = vm.addr(sk1);
        address addr2 = vm.addr(sk2);
        uint256 lower = addr1 < addr2 ? sk1 : sk2;
        uint256 higher = addr1 < addr2 ? sk2 : sk1;

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(lower, txHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(higher, txHash);

        bytes memory sigs = abi.encodePacked(r1, s1, v1, r2, s2, v2);
        bool ok = safe_.execTransaction(to, 0, data, 0, 0, 0, 0, ZERO, payable(ZERO), sigs);
        require(ok, "SafeTx failed");
    }
}
