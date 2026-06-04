// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

// RecoverLPWstDIEM — trades WETH into the WETH/wstDIEM V4 pool to extract the
// wstDIEM locked in the LiquidityHelper LP position (0x7060d57e...).
//
// WHY THIS WORKS
// --------------
// The LP position (owned by 0x7060d57e) holds ~2.718 wstDIEM + ~0.00153 WETH
// as liquidity. We cannot call removeLiquidity — that helper has no such
// function. But we CAN trade AGAINST the LP as a normal swapper:
//
//   swap WETH -> wstDIEM (zeroForOne = true)
//
// The LP provides wstDIEM to us (the trader); we pay WETH into the LP.
// The LP's wstDIEM balance drains to zero as we push price to the lower tick.
// We receive ~2.718 wstDIEM, redeemable from the vault after July 1.
//
// COST
// ----
// To drain all wstDIEM from the LP (push price from initial tick ~75981 down
// to lower tick 62160), we pay approximately:
//
//   WETH_cost = L x (1/sqrtLower - 1/sqrtCurrent)
//             = 122e15 x (1/22.36 - 1/44.64)
//             = 122e15 x 0.02233
//             ~= 0.00272 WETH   (~$6 at $2200/ETH)
//
// Plus 0.3% swap fee (goes into the locked LP). Total: ~0.00273 WETH.
// Script uses 0.004 WETH as buffer; excess is returned to RECIPIENT.
//
// USAGE
// -----
// Estimate first (no --broadcast):
//   EXECUTOR_PK=<uint256> forge script script/vault/RecoverLPWstDIEM.s.sol \
//     --rpc-url $BASE_RPC_URL -vvvv
//
// Broadcast:
//   EXECUTOR_PK=<uint256> forge script script/vault/RecoverLPWstDIEM.s.sol \
//     --rpc-url $BASE_RPC_URL --broadcast
//
// Override recipient (default = Safe):
//   RECIPIENT=<address> EXECUTOR_PK=... forge script ...
//
// Override WETH budget (default = 0.004 WETH):
//   WETH_BUDGET=4000000000000000 EXECUTOR_PK=... forge script ...

// ─── Interfaces ────────────────────────────────────────────────────────────────

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

interface IPoolManager {
    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified; // negative = exact input
        uint160 sqrtPriceLimitX96; // price ceiling/floor — use MIN+1 to drain fully
    }
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (int256 swapDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

// ─── WstDIEMRecovery ──────────────────────────────────────────────────────────
//
// Single-use swap contract deployed inline. Holds the WETH budget, calls
// PoolManager.unlock(), swaps WETH for wstDIEM, returns both tokens to
// `recipient` (Safe by default).
//
// Anyone who holds the WETH budget can call execute(). The only entry points
// are execute() and unlockCallback() (PM-gated).
//
contract WstDIEMRecovery {
    // V4 PoolManager on Base mainnet
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant WSTDIEM = 0x4751BA2b09374C1929FC01734a166e3c8cd75810;

    // Uniswap V4 absolute minimum sqrtPrice — set as limit to allow full drain.
    // Source: TickMath.MIN_SQRT_PRICE = 4295128739
    uint160 constant MIN_SQRT_PRICE_PLUS_ONE = 4_295_128_740;

    address public immutable recipient;

    constructor(address _recipient) {
        recipient = _recipient;
    }

    // Execute the recovery swap. Contract must already hold `wethBudget` WETH.
    function execute(uint256 wethBudget) external {
        bytes memory data = abi.encode(wethBudget);
        IPoolManager(POOL_MANAGER).unlock(data);

        // Return all received wstDIEM + any unspent WETH to recipient.
        _sweep(WSTDIEM);
        _sweep(WETH);
    }

    // Called by PoolManager during unlock.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == POOL_MANAGER, "only PM");
        uint256 wethBudget = abi.decode(data, (uint256));

        PoolKey memory key = PoolKey({
            currency0: WETH, currency1: WSTDIEM, fee: 3000, tickSpacing: 60, hooks: address(0)
        });

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(wethBudget), // exact WETH input (negative = exact in)
            sqrtPriceLimitX96: MIN_SQRT_PRICE_PLUS_ONE // drain to lower tick
        });

        // swapDelta packed as int256: upper 128 = amount0, lower 128 = amount1
        int256 swapDelta = IPoolManager(POOL_MANAGER).swap(key, params, "");
        int128 amount0 = int128(swapDelta >> 128); // WETH delta (negative = we owe)
        int128 amount1 = int128(swapDelta); // wstDIEM delta (positive = PM owes us)

        // Settle WETH owed to PoolManager (sync -> push exact amount -> settle)
        if (amount0 < 0) {
            uint256 wethOwed = uint256(uint128(-amount0));
            IPoolManager(POOL_MANAGER).sync(WETH);
            IERC20(WETH).transfer(POOL_MANAGER, wethOwed);
            IPoolManager(POOL_MANAGER).settle();

            console.log("WETH paid into pool:", wethOwed);
        }

        // Take wstDIEM owed to us from PoolManager
        if (amount1 > 0) {
            uint256 wstDiemOut = uint256(uint128(amount1));
            IPoolManager(POOL_MANAGER).take(WSTDIEM, address(this), wstDiemOut);

            console.log("wstDIEM recovered:  ", wstDiemOut);
        }

        return "";
    }

    function _sweep(address token) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).transfer(recipient, bal);
    }
}

// ─── Script ───────────────────────────────────────────────────────────────────

contract RecoverLPWstDIEM is Script {
    address constant SAFE = 0x872c561f699B42977c093F0eD8b4C9a431280c6c;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant WSTDIEM = 0x4751BA2b09374C1929FC01734a166e3c8cd75810;

    // Buffer over the ~0.00272 WETH needed to drain the LP.
    uint256 constant DEFAULT_WETH_BUDGET = 0.004e18;

    function run() external {
        uint256 pk = vm.envUint("EXECUTOR_PK");
        address recipient = vm.envOr("RECIPIENT", SAFE);
        uint256 wethBudget = vm.envOr("WETH_BUDGET", DEFAULT_WETH_BUDGET);
        address executor = vm.addr(pk);

        console.log("Executor:    ", executor);
        console.log("Recipient:   ", recipient);
        console.log("WETH budget: ", wethBudget);
        console.log("--- Deploying WstDIEMRecovery and executing swap ---");

        vm.startBroadcast(pk);

        // Deploy recovery contract
        WstDIEMRecovery recovery = new WstDIEMRecovery(recipient);
        console.log("WstDIEMRecovery:", address(recovery));

        // Fund it with the WETH budget (executor must hold WETH)
        // In forge script with a funded EOA, send via low-level transfer.
        // WETH on Base is an ERC-20 — we need to hold WETH, not ETH.
        // If executor holds native ETH, wrap it first via WETH.deposit().
        (bool ok,) = WETH.call{value: 0}(
            abi.encodeWithSignature("transfer(address,uint256)", address(recovery), wethBudget)
        );
        require(ok, "WETH transfer to recovery failed - ensure executor holds WETH");

        // Execute the swap: recovery swaps WETH -> wstDIEM, returns all to recipient
        recovery.execute(wethBudget);

        vm.stopBroadcast();

        // Final balances
        console.log("--- Done ---");
        console.log("wstDIEM at recipient:");
        console.log(IERC20(WSTDIEM).balanceOf(recipient));
    }
}
