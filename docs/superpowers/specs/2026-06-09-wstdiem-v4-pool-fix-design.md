# wstDIEM V4 Pool Fix + Oracle Deprecation — Design Spec
**Date:** 2026-06-09  
**Tickets:** MOG-548 (V4 pool mis-initialized), MOG-542 (USDC/WETH oracle DIEM=$1), MOG-549 (audit sweep)  
**Status:** Approved for implementation

---

## Problem Statement

Three components hardcoded `DIEM = $1` (true value ≈ $1,450):

1. **V4 wstDIEM/WETH pool** — initialized at sqrtPriceX96 ≈ 3.54e30 (tick 75,981; ~1,996 wstDIEM/WETH). True ratio ≈ 1.17–1.72 wstDIEM/WETH (tick ~1,535–5,400 at current ETH prices). Pool is empty (active liquidity = 0), so this is latent — no funds at risk — but seeding it as-is would cause instant arb loss.
2. **WstDiemUsdcOracle** — `price() = convertToAssets(1e18) * 1e6` (hardcodes DIEM = $1 USDC).
3. **WstDiemWethOracle** — `price() = convertToAssets(1e18) * 1e26 / ethUsdPrice` (hardcodes DIEM = $1 USD).

A V4 pool cannot be re-initialized. DIEM has no USD-liquid market on-chain (its only deep DEX liquidity is DIEM/VVV on Aerodrome). The wstDIEM/USDC and wstDIEM/WETH Morpho markets are unseeded and effectively unusable; the VVV market (MOG-544) is the correct architecture going forward.

---

## Scope

### Track A — V4 Pool Fix (MOG-548)

Deploy a new correctly-priced wstDIEM/WETH V4 pool using the WstDIEMHook (dynamic fee). Includes:
- Bug fix in WstDIEMHook stub
- Hook deployment via CREATE2 salt mining
- Router update + redeploy
- New pool initialization at live-computed price
- Promoted parameterized LiquidityManager contract
- Fork test suite

### Track B — Oracle Deprecation (MOG-542 / MOG-549)

No on-chain action. Document the two broken oracles and their Morpho markets as deprecated. Close the audit sweep ticket.

---

## Track A: Architecture

### A1. WstDIEMHook Fix

**File:** `src/vault/WstDIEMHook.sol`

**Bug:** `_beforeSwap` returns `fee = FEE_NORMAL` (500) without `LPFeeLibrary.OVERRIDE_FEE_FLAG`. For a `DYNAMIC_FEE_FLAG` pool, V4 ignores the returned fee unless `OVERRIDE_FEE_FLAG` is OR'd in. The stub was never functional.

**Fix:**
```solidity
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

function _beforeSwap(...) internal pure override returns (bytes4, BeforeSwapDelta, uint24) {
    return (
        BaseHook.beforeSwap.selector,
        BeforeSwapDeltaLibrary.ZERO_DELTA,
        FEE_NORMAL | LPFeeLibrary.OVERRIDE_FEE_FLAG
    );
}
```

Also uncomment the `LPFeeLibrary` import line already in the file.

**No behavior change for WP-5** — the fee logic slot is preserved, only the flag is added.

### A2. Hook Deployment (CREATE2 Salt Mining)

V4 validates that a hook's address encodes its permissions. WstDIEMHook declares:
- `beforeSwap` → bit 7 set (`0x0080`)
- `afterInitialize` → bit 12 set (`0x1000`)
- Combined required mask: `0x1080`

The deployer must find a CREATE2 salt such that `uint160(hookAddr) & Hooks.ALL_HOOK_MASK == 0x1080`.

**Script:** `script/vault/DeployWstDiemHook.s.sol`

Uses the standard `HookMiner` pattern (iterate salt until address satisfies mask). Constructor args: `(IPoolManager POOL_MANAGER, IInferenceVault VAULT)`.

Deployed from deployer v6 EOA (`0xf04822e5B0E76A34aeeA936c79B4439f794b8Be1`).

### A3. Router Fix + Redeploy

**File:** `src/vault/Router.sol`

**Two changes** (both required for routing `exitToWETH` through a dynamic-fee *hooked* pool):

**(1) Allow the dynamic fee flag.** `setSwapFees` validation currently rejects `fee > 10_000`. `DYNAMIC_FEE_FLAG = 0x800000 = 8,388,608` exceeds this.

**(2) Make the V4 hooks address settable.** `unlockCallback` (Router.sol:225) **hardcodes** `hooks: IHooks(address(0))` when reconstructing the PoolKey for the exit swap. A pool created *with* WstDIEMHook has a different PoolKey (`hooks = hook address`), so the Router must target it. Add `address public wstDiemV4Hooks;` (defaults to `address(0)`, preserving current behavior until set), use it in the `unlockCallback` PoolKey, and set it via `setSwapFees`.

`setSwapFees` has **zero callers** in `script/` or `test/` (verified), so extend its signature rather than adding a parallel setter — keeps the full V4 pool-key config in one owner function:

```solidity
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

address public wstDiemV4Hooks; // V4 pool hook address (address(0) = no hook)

event SwapFeesSet(
    uint24 diemV3Fee, uint24 wstDiemV4Fee, int24 wstDiemV4TickSpacing, address wstDiemV4Hooks
);

function setSwapFees(
    uint24 _diemV3Fee,
    uint24 _wstDiemV4Fee,
    int24 _wstDiemV4TickSpacing,
    address _wstDiemV4Hooks
) external onlyOwner {
    require(_diemV3Fee > 0 && _diemV3Fee <= 10_000, "invalid DIEM V3 fee");
    bool isDynamic = _wstDiemV4Fee == LPFeeLibrary.DYNAMIC_FEE_FLAG;
    require(
        (_wstDiemV4Fee > 0 && _wstDiemV4Fee <= LPFeeLibrary.MAX_LP_FEE) || isDynamic,
        "invalid V4 fee"
    );
    require(_wstDiemV4TickSpacing > 0, "invalid tick spacing");
    diemV3Fee = _diemV3Fee;
    wstDiemV4Fee = _wstDiemV4Fee;
    wstDiemV4TickSpacing = _wstDiemV4TickSpacing;
    wstDiemV4Hooks = _wstDiemV4Hooks;
    emit SwapFeesSet(_diemV3Fee, _wstDiemV4Fee, _wstDiemV4TickSpacing, _wstDiemV4Hooks);
}
```

And in `unlockCallback`: `hooks: IHooks(wstDiemV4Hooks)` instead of `IHooks(address(0))`.

Router redeployed via `DeployRouter.s.sol` (standard procedure per CLAUDE.md). **Note:** the current `DeployRouter.s.sol` still hardcodes the *v4* vault (`0x4751…`); it must be updated to the v5 vault (`0xb9f23c33…`) before redeploy.

After redeployment, Safe calls:
- `Router.setSwapFees(10_000, DYNAMIC_FEE_FLAG, 60, <WstDIEMHook address>)`
- `Router.setV4Pool(POOL_MANAGER)` (address `0x498581fF…` — unchanged, just confirm it's set)

### A4. New V4 Pool Initialization

**PoolKey:**
```
currency0 = WETH  (0x4200…0006)
currency1 = wstDIEM v5  (0xb9f23c33…)
fee       = LPFeeLibrary.DYNAMIC_FEE_FLAG  (0x800000)
tickSpacing = 60
hooks     = WstDIEMHook (deployed address)
```

**sqrtPriceX96 — operator-provided, validated on-chain before broadcast:**

VVV has no Chainlink feed on Base; computing DIEM/USD fully on-chain requires a VVV/USDC TWAP that may not have adequate cardinality. To avoid a fragile multi-hop price chain at deploy time, the operator supplies `SQRT_PRICE_X96` as an env var after computing it off-chain from live market data:

```
wstDIEM_per_WETH ≈ WETH_USD / (convertToAssets(1e18) × DIEM_VVV_rate × VVV_USD)
sqrtPriceX96 = sqrt(wstDIEM_per_WETH) × 2^96
```

The deploy script:
1. Reads `vault.convertToAssets(1e18)` on-chain and logs it
2. Reads Chainlink ETH/USD on-chain and logs it
3. Reads `SQRT_PRICE_X96` env var provided by operator
4. Derives the implied tick and prints: `"Implied tick: X (expected ≈ 1500–5500 for current prices)"`
5. Requires operator confirmation (or `--broadcast` flag) before submitting

The operator computes the input using any trusted price source (Dune, CoinGecko, Aerodrome UI) and verifies the implied tick is in a sane range before broadcasting.

**Script:** `script/vault/InitV4Pool.s.sol` (replaces old `InitPools.s.sol` V4 section)

Deployed from deployer v6.

### A5. LiquidityManager Promotion

**File (new):** `src/vault/LiquidityManager.sol`

Move `LiquidityManager` from `script/vault/SafeManageV4LP.s.sol` into source. Parameterize:

```solidity
constructor(
    address _poolManager,
    address _currency0,
    address _currency1,
    uint24 _fee,
    int24 _tickSpacing,
    int24 _tickLower,
    int24 _tickUpper,
    address _hooks,
    address _safe
)
```

All pool key fields and tick range as constructor args. No hardcoded addresses or ticks.

**Interface preserved:** `addLiquidity(uint128)`, `removeLiquidity(uint128)`, `collectFees()`, `grantOperator(address, bool)`.

**Tick range for initial seed:** Full range (`tickLower = -887220`, `tickUpper = 887220`). Low TVL at bootstrap makes concentrated range impractical.

Script `SafeManageV4LP.s.sol` updated to import from `src/vault/LiquidityManager.sol` and pass the new PoolKey args (DYNAMIC_FEE_FLAG, 60, WstDIEMHook address).

### A6. Fork Tests

**File:** `test/vault/V4Pool.t.sol`

Test against a Base fork (`BASE_RPC_URL` env). Cases:
1. `test_poolInitializedAtCorrectPrice` — verify sqrtPriceX96 produces tick near expected (within 200 ticks of target)
2. `test_addAndRemoveLiquidity` — add full-range LP, remove full amount, confirm WETH + wstDIEM returned
3. `test_collectFees` — seed pool, execute a swap via `Router.exitToWETH`, collect fees, verify non-zero fee credit
4. `test_hookFeeOverride` — direct call into `WstDIEMHook._beforeSwap` (or via swap), assert returned fee = `FEE_NORMAL | OVERRIDE_FEE_FLAG`

---

## Track B: Oracle Deprecation

### B1. Contract NatSpec

Add `@custom:deprecated` to `WstDiemUsdcOracle` and `WstDiemWethOracle`:

```solidity
/// @custom:deprecated DIEM has no USD-liquid market; DIEM ≠ $1.
/// These markets are unseeded and must not be used. See WstDiemVvvOracle (MOG-544).
```

### B2. Docs Update

**`docs/vault/mainnet-addresses.md`:** Mark wstDIEM/USDC and wstDIEM/WETH Morpho markets as `[DEPRECATED — unseeded, do not supply/borrow]`.

**`CLAUDE.md` (repo root):** Update oracle table note from "DIEM=$1, see Security" to "DEPRECATED (MOG-542)".

### B3. Linear

- MOG-542: close with comment "USDC/WETH oracle path abandoned — VVV market (MOG-544) is canonical. Marked @deprecated in source."
- MOG-549: close with the audit-sweep result below. **The sweep distinguishes two roles of "$1" and only the second is a bug:**
  - **(A) Inference-entitlement accounting — `$1/DIEM/day` is CORRECT** (Venice's real perpetuity mechanic, not a market price):
    - `AgentTGERegistry` — `tierAllocations = [500e6, 2000e6, 5000e6]` USD/day entitlements; no DIEM↔USD market conversion. Legitimate.
    - `InferenceProduct` — `diemAmount` capacity = DIEM-days; sale price is owner-set `pricePerDiemDayUSDC = 0.8e6` ($0.80, deliberately ≠ $1). No collateral-price assumption.
  - **(B) Collateral market price — `DIEM = $1` is WRONG** (the actual bugs):
    - [x] `WstDiemUsdcOracle` — deprecated, unseeded (MOG-542)
    - [x] `WstDiemWethOracle` — deprecated, unseeded (MOG-542)
    - [x] V4 wstDIEM/WETH pool init — fixed via new pool (MOG-548)
  - **(C) Verified clean — convert at market, no `$1` term:**
    - [x] `FeeRouter._harvest` (WETH & USDC→DIEM) — `amountOutMinimum: 0`, market swap
    - [x] `BaseInferenceAdapter.routeYield` (USDC→WETH→DIEM) — `amountOutMinimum: 0`, market swap
    - [x] `Router` — swaps with caller `minOut`; no USD term
  - **(D) Unaffected by design:**
    - [x] wstDIEM/DIEM Morpho markets (86%/77%) — oracle = `convertToAssets` ratio, no USD
    - [x] wstDIEM/VVV Morpho market — fully on-chain TWAP, no USD
    - [x] UI/SDK — no deployed vault UI yet
  - **Note:** the minOut=0 swaps in (C) carry sandwich risk (a separate, pre-existing keeper-timing concern), not a $1 assumption — out of scope for MOG-549.

---

## Deployment Order

1. Fix and test WstDIEMHook (`src/vault/WstDIEMHook.sol`)
2. Write and test `src/vault/LiquidityManager.sol`
3. Write fork tests (`test/vault/V4Pool.t.sol`) — pass locally
4. Deploy WstDIEMHook via CREATE2 salt mining
5. Update Router + redeploy
6. Initialize new V4 pool (live sqrtPriceX96 from on-chain reads)
7. Safe txs: configure Router (setSwapFees + setV4Pool)
8. Track B: NatSpec + docs + Linear tickets

---

## What This Does NOT Include

- **WP-5 WstDIEMHook TWAP logic** — the hook is deployed but returns FEE_NORMAL (5 bps) for all swaps. NAV-deviation dynamic fee is a future work item.
- **Pool seeding** — seeding LP into the new pool is a separate operation (MOG-536 Phase 2), gated on having DIEM from the v4 withdrawal (June 18).
- **wstDIEM/USDC and wstDIEM/WETH Morpho market replacement** — deprecated and closed; no replacement planned until a native DIEM/USD on-chain source exists.
