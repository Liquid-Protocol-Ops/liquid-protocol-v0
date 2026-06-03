// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

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

struct PoolKey {
    address currency0;
    address currency1;
    uint24  fee;
    int24   tickSpacing;
    address hooks;
}

interface IPoolManager {
    struct ModifyLiquidityParams {
        int24   tickLower;
        int24   tickUpper;
        int256  liquidityDelta;
        bytes32 salt;
    }
    function unlock(bytes calldata data) external returns (bytes memory);
    function modifyLiquidity(PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata hookData)
        external returns (int256 callerDelta, int256 feesAccrued);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface ISafe {
    function getTransactionHash(address to, uint256 value, bytes calldata data, uint8 operation,
        uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address gasToken,
        address refundReceiver, uint256 nonce) external view returns (bytes32);
    function execTransaction(address to, uint256 value, bytes calldata data, uint8 operation,
        uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address gasToken,
        address payable refundReceiver, bytes memory signatures) external payable returns (bool);
    function nonce() external view returns (uint256);
}

// ─── LiquidityManager ─────────────────────────────────────────────────────────
//
// Persistent contract. Only `safe` can call mutating functions.
// The V4 LP position is owned by this contract's address.
// To remove or collect: the Safe calls this contract; this contract calls PoolManager.
//
// Pool: WETH / wstDIEM, fee=0.3%, tickSpacing=60
// Position: tickLower=62160 (~$500/ETH), tickUpper=92100 (~$10,000/ETH)
//
contract LiquidityManager {
    address public immutable poolManager;
    address public immutable weth;
    address public immutable wstDIEM;
    address public immutable safe;

    int24 constant TICK_LOWER = 62160;
    int24 constant TICK_UPPER = 92100;

    enum Action { ADD, REMOVE, COLLECT_FEES }

    struct CallbackData {
        PoolKey key;
        Action  action;
        uint128 liquidity;
    }

    constructor(address _pm, address _weth, address _wstDIEM, address _safe) {
        poolManager = _pm;
        weth        = _weth;
        wstDIEM     = _wstDIEM;
        safe        = _safe;
    }

    modifier onlySafe() {
        require(msg.sender == safe, "only Safe");
        _;
    }

    // ── Add liquidity ──
    // Safe must pre-send WETH + wstDIEM to this contract before calling.
    // Any unused tokens are returned to Safe after the unlock.
    function addLiquidity(uint128 liquidity) external onlySafe {
        _unlock(Action.ADD, liquidity);
        _returnExcess();
    }

    // ── Remove liquidity ──
    // Removes `liquidity` units from the position and sends WETH + wstDIEM to Safe.
    function removeLiquidity(uint128 liquidity) external onlySafe {
        _unlock(Action.REMOVE, liquidity);
        _returnExcess();
    }

    // ── Collect accrued fees (delta=0 modifyLiquidity) ──
    // Sends any accrued WETH + wstDIEM fees to Safe.
    function collectFees() external onlySafe {
        _unlock(Action.COLLECT_FEES, 0);
        _returnExcess();
    }

    // ── Grant operator access to another address ──
    // This is the function the old LiquidityHelper was missing.
    // Call this before deploying a successor manager so the new one can take over.
    function grantOperator(address operator, bool allowed) external onlySafe {
        // V4 PoolManager allowOperator — grants `operator` the ability to modify
        // positions owned by this contract.
        (bool ok,) = poolManager.call(
            abi.encodeWithSignature("allowOperator(address,bool)", operator, allowed)
        );
        require(ok, "allowOperator failed");
    }

    // ─────────────────────────────────────────────────────────────────────────

    function _unlock(Action action, uint128 liquidity) internal {
        PoolKey memory key = PoolKey({
            currency0:   weth,
            currency1:   wstDIEM,
            fee:         3000,
            tickSpacing: 60,
            hooks:       address(0)
        });
        IERC20(weth).approve(poolManager, type(uint256).max);
        IERC20(wstDIEM).approve(poolManager, type(uint256).max);
        bytes memory callbackData = abi.encode(CallbackData({key: key, action: action, liquidity: liquidity}));
        IPoolManager(poolManager).unlock(callbackData);
    }

    // Called by PoolManager during unlock.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == poolManager, "only PM");
        CallbackData memory cd = abi.decode(data, (CallbackData));

        int256 liquidityDelta;
        if (cd.action == Action.ADD) {
            liquidityDelta = int256(uint256(cd.liquidity));
        } else if (cd.action == Action.REMOVE) {
            liquidityDelta = -int256(uint256(cd.liquidity));
        } else {
            liquidityDelta = 0; // COLLECT_FEES: touch position, collect accrued fees
        }

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower:      TICK_LOWER,
            tickUpper:      TICK_UPPER,
            liquidityDelta: liquidityDelta,
            salt:           bytes32(0)
        });

        (int256 callerDelta,) = IPoolManager(poolManager).modifyLiquidity(cd.key, params, "");

        int128 amount0 = int128(callerDelta >> 128);
        int128 amount1 = int128(callerDelta);

        // PoolManager owes us tokens (remove or fee credit) → take
        if (amount0 > 0) {
            IPoolManager(poolManager).take(cd.key.currency0, address(this), uint256(uint128(amount0)));
        }
        if (amount1 > 0) {
            IPoolManager(poolManager).take(cd.key.currency1, address(this), uint256(uint128(amount1)));
        }

        // We owe PoolManager tokens (adding liquidity) → sync + transfer + settle
        if (amount0 < 0) {
            IPoolManager(poolManager).sync(cd.key.currency0);
            IERC20(cd.key.currency0).transfer(poolManager, uint256(uint128(-amount0)));
            IPoolManager(poolManager).settle();
        }
        if (amount1 < 0) {
            IPoolManager(poolManager).sync(cd.key.currency1);
            IERC20(cd.key.currency1).transfer(poolManager, uint256(uint128(-amount1)));
            IPoolManager(poolManager).settle();
        }

        return "";
    }

    function _returnExcess() internal {
        uint256 w  = IERC20(weth).balanceOf(address(this));
        uint256 ws = IERC20(wstDIEM).balanceOf(address(this));
        if (w  > 0) IERC20(weth).transfer(safe, w);
        if (ws > 0) IERC20(wstDIEM).transfer(safe, ws);
    }
}

// ─── Script ───────────────────────────────────────────────────────────────────

contract SafeManageV4LP is Script {
    address constant SAFE         = 0x872c561f699B42977c093F0eD8b4C9a431280c6c;
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant WSTDIEM      = 0x4751BA2b09374C1929FC01734a166e3c8cd75810;
    address constant WETH         = 0x4200000000000000000000000000000000000006;
    address constant ZERO         = address(0);

    uint256 sk1;
    uint256 sk2;

    // ── deployManager ──────────────────────────────────────────────────────
    // Run once. Save the printed address as MANAGER for subsequent calls.
    function deployManager() external {
        vm.startBroadcast(vm.envUint("EXECUTOR_PK"));
        LiquidityManager mgr = new LiquidityManager(POOL_MANAGER, WETH, WSTDIEM, SAFE);
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
        address manager  = vm.envAddress("MANAGER");
        uint128 liquidity = uint128(vm.envUint("LIQUIDITY"));
        uint256 wethBudget    = vm.envOr("WETH_BUDGET",    uint256(0.002e18));
        uint256 wstDiemBudget = vm.envOr("WSTDIEM_BUDGET", uint256(2.74e18));

        vm.startBroadcast(vm.envUint("EXECUTOR_PK"));

        _execSafe(WETH,    abi.encodeWithSignature("transfer(address,uint256)", manager, wethBudget));
        console.log("Tx1: sent", wethBudget, "WETH to manager");

        _execSafe(WSTDIEM, abi.encodeWithSignature("transfer(address,uint256)", manager, wstDiemBudget));
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
        address manager   = vm.envAddress("MANAGER");
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
        bytes32 txHash = safe_.getTransactionHash(
            to, 0, data, 0, 0, 0, 0, ZERO, ZERO, nonce
        );

        address addr1 = vm.addr(sk1);
        address addr2 = vm.addr(sk2);
        uint256 lower  = addr1 < addr2 ? sk1 : sk2;
        uint256 higher = addr1 < addr2 ? sk2 : sk1;

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(lower,  txHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(higher, txHash);

        bytes memory sigs = abi.encodePacked(r1, s1, v1, r2, s2, v2);
        bool ok = safe_.execTransaction(to, 0, data, 0, 0, 0, 0, ZERO, payable(ZERO), sigs);
        require(ok, "SafeTx failed");
    }
}
