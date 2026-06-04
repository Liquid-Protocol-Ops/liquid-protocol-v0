// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

// SafeAddV4LP - adds liquidity to the wstDIEM/WETH V4 pool via Safe.
//
// Uses the V4 PoolManager's unlock() -> modifyLiquidity() pattern directly,
// via an intermediate LiquidityHelper contract deployed in this script.
//
// Pool: WETH (currency0) / wstDIEM (currency1), fee=0.3%, tickSpacing=60
// Current tick at deploy: 75981 (1 WETH ~= 1993 wstDIEM ~= $1993/ETH)
//
// Position: tickLower=62160 (~$500/ETH), tickUpper=92100 (~$10000/ETH)
// Wide range - covers most price scenarios, low management overhead.
//
// Budget: 1 WETH + proportional wstDIEM from Safe balance.
// The helper computes the exact wstDIEM amount from the liquidity math.
//
// Run AFTER SafeSeedCapital.s.sol (Safe needs wstDIEM balance).
//
// Run:
//   SAFE_SK1=<bytes32> SAFE_SK2=<bytes32> EXECUTOR_PK=<uint256> \
//   forge script script/vault/SafeAddV4LP.s.sol --rpc-url $BASE_RPC_URL [--broadcast]

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

interface IPoolManager {
    struct ModifyLiquidityParams {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta; // positive = add, negative = remove
        bytes32 salt;
    }
    function unlock(bytes calldata data) external returns (bytes memory);
    // Returns (BalanceDelta callerDelta, BalanceDelta feesAccrued).
    // BalanceDelta is a packed int256: upper 128 bits = amount0, lower 128 bits = amount1.
    // Negative amount = caller owes tokens to PoolManager (must settle).
    function modifyLiquidity(
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (int256 callerDelta, int256 feesAccrued);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

// Intermediate helper: deployed by script, receives tokens from Safe,
// calls PoolManager.unlock(), adds liquidity, sends LP NFT/receipt back to Safe.
// Deployed fresh each run so it holds no state or value between calls.
contract LiquidityHelper {
    address immutable poolManager;
    address immutable weth;
    address immutable wstDIEM;
    address immutable safe;

    int24 constant TICK_LOWER = 62_160; // ~$500/ETH
    int24 constant TICK_UPPER = 92_100; // ~$10,000/ETH

    constructor(address _pm, address _weth, address _wstDIEM, address _safe) {
        poolManager = _pm;
        weth = _weth;
        wstDIEM = _wstDIEM;
        safe = _safe;
    }

    // Called by Safe. Adds liquidity using the WETH + wstDIEM already held by this contract.
    function addLiquidity(uint128 liquidityDesired) external {
        PoolKey memory key = PoolKey({
            currency0: weth, currency1: wstDIEM, fee: 3000, tickSpacing: 60, hooks: address(0)
        });

        // Approve PoolManager to pull tokens during settlement
        IERC20(weth).approve(poolManager, type(uint256).max);
        IERC20(wstDIEM).approve(poolManager, type(uint256).max);

        bytes memory callbackData = abi.encode(key, liquidityDesired);
        IPoolManager(poolManager).unlock(callbackData);

        // Return any unused tokens to Safe
        uint256 wethLeft = IERC20(weth).balanceOf(address(this));
        uint256 wstDiemLeft = IERC20(wstDIEM).balanceOf(address(this));
        if (wethLeft > 0) IERC20(weth).transfer(safe, wethLeft);
        if (wstDiemLeft > 0) IERC20(wstDIEM).transfer(safe, wstDiemLeft);
    }

    // Called by PoolManager during unlock()
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == poolManager, "only PM");
        (PoolKey memory key, uint128 liquidityDesired) = abi.decode(data, (PoolKey, uint128));

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidityDelta: int256(uint256(liquidityDesired)),
            salt: bytes32(0)
        });

        // callerDelta is a packed BalanceDelta (int256):
        //   amount0 = int128(callerDelta >> 128)  [upper 128 bits]
        //   amount1 = int128(callerDelta)          [lower 128 bits]
        // Negative = caller owes that token to PoolManager (must settle).
        (int256 callerDelta,) = IPoolManager(poolManager).modifyLiquidity(key, params, "");

        int128 amount0 = int128(callerDelta >> 128);
        int128 amount1 = int128(callerDelta);

        if (amount0 < 0) {
            uint256 toSettle0 = uint256(uint128(-amount0));
            IPoolManager(poolManager).sync(key.currency0);
            IERC20(key.currency0).transfer(poolManager, toSettle0);
            IPoolManager(poolManager).settle();
        }
        if (amount1 < 0) {
            uint256 toSettle1 = uint256(uint128(-amount1));
            IPoolManager(poolManager).sync(key.currency1);
            IERC20(key.currency1).transfer(poolManager, toSettle1);
            IPoolManager(poolManager).settle();
        }

        console.log("LP settled: WETH  =", amount0 < 0 ? uint256(uint128(-amount0)) : 0);
        console.log("LP settled: wstDIEM =", amount1 < 0 ? uint256(uint128(-amount1)) : 0);
        return "";
    }
}

contract SafeAddV4LP is Script {
    address constant SAFE = 0x872c561f699B42977c093F0eD8b4C9a431280c6c;
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant VAULT = 0x4751BA2b09374C1929FC01734a166e3c8cd75810; // wstDIEM
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant ZERO = address(0);

    address constant SK2_ADDR = 0x6FDDe67e9c545AcdcE17944bf8f9988E1f88aa9E;
    address constant SK1_ADDR = 0x8f60eB404a5CA868f37bc798ec4c54FA0dcCFC9F;

    // LP budget — sized to consume exactly the 2.74 wstDIEM from SafeSeedCapital.
    //
    // Math (tick range 62160-92100, current tick 75981, ETH ~$1993):
    //   sqrtPrice      = sqrt(1993)  ~= 44.64
    //   sqrtPriceLower = sqrt(500)   ~= 22.36  (tick 62160)
    //   sqrtPriceUpper = sqrt(10000) = 100.00  (tick 92100)
    //
    //   L = wstDIEM / (sqrtPrice - sqrtPriceLower)
    //     = 2.74e18  / (44.64 - 22.36)
    //     = 2.74e18  / 22.28
    //     ~= 1.23e17
    //
    //   WETH needed = L * (1/sqrtPrice - 1/sqrtPriceUpper)
    //               = 1.23e17 * (1/44.64 - 1/100)
    //               = 1.23e17 * (0.02240 - 0.01)
    //               = 1.23e17 * 0.01240
    //               ~= 1.525e15  (~0.00153 WETH, ~$3.04 at $1993/ETH)
    //
    // The helper receives 2.74 wstDIEM + 0.002 WETH and returns any unused tokens to Safe.
    // The remaining ~1.998 WETH stays in Safe untouched.
    uint128 constant LIQUIDITY = 122_000_000_000_000_000; // 1.23e17 L units
    uint256 constant WSTDIEM_BUDGET = 2.74e18; // exact — all from SafeSeedCapital deposit
    uint256 constant WETH_BUDGET = 0.002e18; // slight buffer over 0.00153; excess returned

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

        // Deploy helper (no constructor args that need Safe signing)
        LiquidityHelper helper = new LiquidityHelper(POOL_MANAGER, WETH, VAULT, SAFE);
        console.log("LiquidityHelper deployed:", address(helper));

        // Safe Tx 1: transfer WETH budget to helper
        _execSafe(
            WETH, abi.encodeWithSignature("transfer(address,uint256)", address(helper), WETH_BUDGET)
        );
        console.log("Tx1: WETH transferred to helper");

        // Safe Tx 2: transfer wstDIEM budget to helper
        _execSafe(
            VAULT,
            abi.encodeWithSignature("transfer(address,uint256)", address(helper), WSTDIEM_BUDGET)
        );
        console.log("Tx2: wstDIEM transferred to helper");

        // Safe Tx 3: call helper.addLiquidity - adds position, returns unused tokens to Safe
        _execSafe(address(helper), abi.encodeWithSignature("addLiquidity(uint128)", LIQUIDITY));
        console.log("Tx3: addLiquidity executed");

        console.log("=== V4 LP COMPLETE ===");
        console.log("Position: WETH/wstDIEM tick 62160-92100 (~$500-$10000 ETH range)");
        console.log("Consumed: ~2.74 wstDIEM + ~0.00153 WETH (~$3.04 of WETH)");
        console.log("Remaining ~1.998 WETH returned/stays in Safe");

        vm.stopBroadcast();
    }

    function _execSafe(address to, bytes memory data) internal {
        uint256 nonce = ISafe(SAFE).nonce();
        bytes32 txHash = ISafe(SAFE).getTransactionHash(to, 0, data, 0, 0, 0, 0, ZERO, ZERO, nonce);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(sk2, txHash);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(sk1, txHash);
        bytes memory sigs = abi.encodePacked(r2, s2, v2, r1, s1, v1);
        bool ok = ISafe(SAFE).execTransaction(to, 0, data, 0, 0, 0, 0, ZERO, payable(ZERO), sigs);
        require(ok, "SafeTx failed");
    }
}
