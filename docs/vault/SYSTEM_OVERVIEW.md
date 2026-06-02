# wstDIEM Vault — System Overview

**Version:** v4 (2026-06-01)
**Chain:** Base mainnet (chain ID 8453)
**Owner (Safe):** `0x872c561f699B42977c093F0eD8b4C9a431280c6c`

---

## What is wstDIEM?

wstDIEM (Wrapped Staked DIEM) is an ERC-4626 vault that wraps sDIEM — staked DIEM from the Venice AI protocol — into a freely transferable, yield-bearing ERC-20 token. It is directly analogous to wstETH: depositors receive a token whose DIEM redemption value increases monotonically over time as inference revenue is credited to the vault.

**Key invariant:** DIEM never leaves the vault. `DIEM.stake()` moves DIEM from `balanceOf` into Venice's internal `stakedInfos`. `totalAssets()` sums all three buckets:

```
totalAssets() = idle DIEM (balanceOf) + amountStaked + coolDownAmount
```

`stakedInfos(vault)` returns `(amountStaked, coolDownEnd, coolDownAmount)` — the second field is a UNIX timestamp (cooldown expiry), not an amount.

---

## Deployed Addresses (v4, 2026-06-01)

| Contract | Address |
|----------|---------|
| `InferenceVault` (wstDIEM token) | `0x4751BA2b09374C1929FC01734a166e3c8cd75810` |
| `FeeRouter` | `0x21fe048B10dC9bED2Ee0Ae76724C627CA7F35F61` |
| `Router` v8 | `0x6f5FF03a91cb1703B7CB8d85572f990bcB04273D` |
| `InferenceProduct` | `0x9b7d8B23cb223F75F5F1Ead25f12205940960F62` |
| `AgentTGERegistry` | `0x49be7fE8D661b892AC0461818a5C714574e83998` |
| `SurplusStakingWrapper` | `0xB0f9c45dAacD89F0d90cbE0E65d0dA20fa1ac415` |
| Curve DIEM/wstDIEM StableSwap | `0x39A4b4779C71E1A18d500627639682c9583Ee86f` |

**External dependencies (Base mainnet):**

| Token / Protocol | Address |
|-----------------|---------|
| DIEM (Venice staking token) | `0xF4d97F2da56e8c3098f3a8D538DB630A2606a024` |
| VVV | `0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf` |
| sVVV / VVV staking contract | `0x321b7ff75154472B18EDb199033fF4D116F340Ff` |
| WETH | `0x4200000000000000000000000000000000000006` |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Uniswap V3 SwapRouter02 | `0x2626664c2603336E57B271c5C0b26F421741e481` |
| Uniswap V4 PoolManager | `0x498581fF718922c3f8e6A244956aF099B2652b2b` |
| Morpho Blue | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` |

---

## Architecture

### InferenceVault (ERC-4626)

The core vault. Deposits DIEM, stakes it immediately via `DIEM.stake()`, and mints wstDIEM shares. Yield accrues non-dilutively: when `FeeRouter.creditDIEM()` is called, DIEM is added to the staked pool without minting new shares, causing the exchange rate (`totalAssets / totalSupply`) to rise.

**Deposit fee:**
- TVL < 5,000,000 DIEM: 10 bps (0.10%)
- TVL >= 5,000,000 DIEM: 50 bps (0.50%)

Fee is captured by minting additional shares to the `treasury` address (the Safe).

**Withdrawal gate:** Withdrawals are disabled by default. The owner must call `initiateEnableWithdrawals()`, wait 14 days, then call `enableWithdrawals()`. Even after enabled, `maxWithdraw` is capped to the idle DIEM balance — only unstaked DIEM can be sent out. The primary liquidity path for users is the Curve DIEM/wstDIEM pool, not direct vault withdrawals.

**Unstaking flow:** Owner calls `initiateUnstake(amount)` → wait 24h cooldown → `completeUnstake()` → DIEM moves from `stakedInfos.coolDownAmount` back to `balanceOf`.

### FeeRouter

Aggregates all protocol income streams (WETH, USDC, VVV, wstDIEM) and routes them to the vault. Each token has a configurable `FeeMode`:

| Mode | Effect |
|------|--------|
| `CREDIT_VAULT` | Swap to DIEM via Uniswap V3, call `vault.creditDIEM()` — wstDIEM rate rises |
| `CURVE_VOL` | Deposit to Curve DIEM/wstDIEM pool as additional liquidity |
| `HOLD` | Accumulate in FeeRouter; manual sweep by owner |

**Default modes:** WETH, USDC, VVV → `CREDIT_VAULT`; wstDIEM → `CURVE_VOL`.

**Key functions (all `onlyOwnerOrKeeper`):**
- `settleAndHarvest(channelId, amount)` — keeper single-call entry: accepts USDC from a registered channel and immediately harvests into vault
- `harvest()` — routes all pending WETH + USDC + wstDIEM per their FeeModes
- `harvestVVV()` — stakes pending VVV → sVVV → `mintDiem` → `creditDIEM` (runs only when pending VVV >= threshold, default 100 VVV)

**Channel registry:** Each external inference marketplace (AntSeed, Surplus Intelligence) is registered as a channel with a `payoutWallet` and `platformFeeBps`. Revenue is tracked per channel via `totalRevenue`.

**USDC swap path:** USDC → WETH (V3 0.05% pool) → DIEM (V3 1% pool) via `exactInput` multihop.

### Router v8

Multi-path entry and exit contract. Stateless except for the V4 PoolManager address.

**Deposit paths:**
- `depositWETH(wethAmount, minWstDIEM, receiver)` — WETH → DIEM via V3 1% pool → `vault.deposit` → wstDIEM
- `depositVVV(vvvAmount, minWstDIEM, receiver)` — VVV → sVVV → `mintDiem` → `vault.deposit` → wstDIEM

**Exit path:**
- `exitToWETH(wstDIEMAmount, minWETH, receiver)` — sells wstDIEM into the V4 wstDIEM/WETH pool via `IPoolManager.unlock` → `unlockCallback` pattern

**V4 pool currency ordering (v4 deployment):**

In this deployment, WETH (`0x4200...`) < InferenceVault (`0x4751...`), so:
- `currency0` = WETH
- `currency1` = wstDIEM
- Router immutable `wethIsCurrency0 = true`

Selling wstDIEM for WETH: `zeroForOne = false` (c1 → c0), WETH returned as `delta.amount0()`.

### Morpho Markets

wstDIEM can be used as collateral to borrow against on Morpho Blue:

| Market | Loan Asset | LLTV |
|--------|-----------|------|
| wstDIEM / DIEM | DIEM | 86% |
| wstDIEM / USDC | USDC | 62.5% |
| wstDIEM / WETH | WETH | 62.5% |

### V4 Pool Parameters

| Field | Value |
|-------|-------|
| currency0 | WETH `0x4200000000000000000000000000000000000006` |
| currency1 | wstDIEM `0x4751BA2b09374C1929FC01734a166e3c8cd75810` |
| fee | 0.3% (3000) |
| tickSpacing | 60 |
| tickLower | 62160 |
| tickUpper | 92100 |
| hooks | none (`address(0)`) |

---

## Revenue Flow

```
AntSeed / Surplus Intelligence buyers
        |
        | pay USDC for inference capacity
        v
Keeper EOA (0x32fD...0e90)
        |
        | calls FeeRouter.settleAndHarvest(channelId, amount)
        |   └─ USDC approved from keeper to FeeRouter
        v
FeeRouter (0x21fe...)
        |
        | _harvest() — USDC mode: CREDIT_VAULT
        |
        | Step 1: USDC → WETH  (V3 0.05% pool)
        | Step 2: WETH → DIEM  (V3 1% pool)
        v
        DIEM lands in FeeRouter
        |
        | vault.creditDIEM(amount)
        v
InferenceVault (0x4751...)
        |
        | DIEM.stake(amount) → moves to stakedInfos
        | totalAssets() increases, totalSupply() unchanged
        v
wstDIEM exchange rate rises
(existing holders' shares now redeem for more DIEM)
```

---

## Yield Sources

| Source | Mechanism | Frequency |
|--------|-----------|-----------|
| Inference revenue (USDC) | AntSeed/Surplus buyers pay USDC; keeper calls `settleAndHarvest` | Per inference settlement |
| WETH protocol fees | Liquid Protocol swap hook fees routed via `receiveWETH` → harvest | Daily or batched |
| VVV Venice fees | Accumulated until >= 100 VVV threshold; `harvestVVV()` mints DIEM | Batched |
| Deposit fees | 10–50 bps minted as treasury shares on each deposit | Per deposit |

---

## Governance and Access Control

| Role | Address | Can Do |
|------|---------|--------|
| Owner (Safe 2-of-3) | `0x872c561f699B42977c093F0eD8b4C9a431280c6c` | All admin: setFeeRouter, setKeeper, setFeeMode, initiateEnableWithdrawals, addChannel, sweep |
| Keeper EOA | `0x32fDdfB0eeC6c638d5C8b7cabF3bE9065478e90E` | `harvest()`, `harvestVVV()`, `settleAndHarvest()` on FeeRouter only |
| Any address | — | `completeUnstake()` (permissionless — just finalizes DIEM cooldown) |

The governance slot is reserved in FeeRouter for future DAO/timelock ownership transfer via `initializeGovernance(address)`. At launch, the Safe is the sole owner.

---

## Peripheral Contracts

**SurplusStakingWrapper (`0xB0f9...415`):** Thin referral-aware deposit wrapper. Calls `vault.deposit` on behalf of users and emits referral codes for off-chain attribution. Also provides a Curve-based `unstakeForUser` path (wstDIEM index 1 → DIEM index 0).

**AgentTGERegistry (`0x49be...998`):** Tracks Venice agent lifecycle. Agents register at Bronze/Silver/Gold tiers (daily USD allocations: $500 / $2,000 / $5,000). Marked dormant after 30 days with no fee receipt.

**InferenceProduct (`0x9b7d...F62`):** USDC settlement layer for selling Venice inference capacity. Buyers purchase time-bounded allocations; USDC revenue flows to `FeeRouter.receiveUSDC()`.
