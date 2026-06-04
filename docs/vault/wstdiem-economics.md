# wstDIEM — Fee Structure & Economics

**Last updated:** 2026-06-03
**Vault:** `0xb9f23c33FfD2213f31C0cFb6c9e2fDf525a9Dd2D` (InferenceVault v5)
**Chain:** Base mainnet

---

## Summary

wstDIEM is a rebasing-rate token. You hold a fixed share count; each share redeems for more DIEM over time as yield accrues through three channels: inference revenue (Venice API), Liquid Protocol fee income, and (optionally) Morpho borrowing interest. There is no performance fee and no withdrawal fee — one entry fee only.

---

## Fee Layer 1: Deposit Fee

Charged once at deposit. Tiered by vault TVL:

| TVL | Fee | Recipient |
|-----|-----|-----------|
| Below 5M DIEM | **10 bps (0.10%)** | Treasury (Safe), as wstDIEM shares |
| 5M DIEM and above | **50 bps (0.50%)** | Treasury (Safe), as wstDIEM shares |

The fee is minted as vault-owned shares to the treasury address. It does not dilute the exchange rate for other holders — it is taken from the depositor's assets before shares are calculated.

No withdrawal fee. No performance fee. No management fee.

---

## Fee Layer 2: Venue Adapter Operator Split

When AntSeed, Surplus, or X402 settle USDC inference revenue, `routeYield()` splits it:

```
100% USDC revenue
  ├── 90% → swap USDC→WETH→DIEM → vault.creditDIEM()
  │         raises wstDIEM exchange rate for ALL holders equally
  └── 10% → swap USDC→WETH→DIEM → vault.creditWstDIEM(adapter)
            mints wstDIEM to the adapter at current rate
            adapter is owned by Safe — this is the protocol's inference revenue cut
```

Default split: 90/10. Operator fee is configurable by Safe up to 20% max.

The 10% adapter cut compounds over time as wstDIEM (not extracted as USDC), so the protocol participates in its own yield growth.

---

## Fee Layer 3: FeeRouter (Liquid Protocol)

The FeeRouter aggregates external fee income from Liquid Protocol token launches. Each token type has a configurable routing mode:

| Mode | Effect |
|------|--------|
| `CREDIT_VAULT` | Swap to DIEM via Uniswap V3 → `creditDIEM()` → rate increase for all holders |
| `CURVE_VOL` | Add to Curve DIEM/wstDIEM LP → earns trading fees |
| `HOLD` | Accumulate in FeeRouter until owner decides |

WETH earned from Liquid Protocol token swaps is the primary FeeRouter input. As Liquid Protocol volume grows, this directly compounds the wstDIEM exchange rate for all holders.

---

## Fee Layer 4: Morpho Borrowing Interest

The 77% LLTV wstDIEM/DIEM market enables leveraged exposure:

```
Supply DIEM to Morpho → earn interest from borrowers
Borrow DIEM against wstDIEM collateral → pay interest
```

Interest rate is determined by AdaptiveCurveIRM (utilization-based). This creates an additional yield source for DIEM suppliers — separate from the vault exchange rate. Morpho's protocol fee is set by Morpho governance (not by us).

---

## Yield Flow for a wstDIEM Holder

```
You hold: 1,000 wstDIEM
          = 1,000 shares
          redeemable for, say, 1,050 DIEM today

Sources that increase the redemption rate:
  Venice inference USDC (via adapters)   → 90% to rate
  Liquid Protocol WETH (via FeeRouter)   → 100% to rate
  Morpho borrowing interest              → only if you also supply DIEM to Morpho

Sources that go to Safe treasury:
  Deposit fee (0.1% or 0.5%)
  Adapter operator cut (10% of inference USDC, held as wstDIEM)

Nothing is extracted from your position once you deposit.
```

---

## Swap Costs (paid to Uniswap, not the protocol)

| Path | Fee |
|------|-----|
| depositWETH: WETH→DIEM (V3 1% pool) | 1.0% |
| Adapter yield: USDC→WETH (V3 0.05% pool) | 0.05% |
| Adapter yield: WETH→DIEM (V3 1% pool) | 1.0% |
| exitToWETH: wstDIEM→WETH (V4 0.3% pool) | 0.3% |
| Curve exit: wstDIEM→DIEM (StableSwap) | ~0.04% |

These are external AMM fees, not protocol revenue. The WETH/DIEM 1% pool fee is the dominant cost for WETH-path depositors and adapter yield routing.

---

## Exchange Rate Formula

```
rate = totalAssets() / totalSupply()
     = (amountStaked + coolDownAmount - pendingWithdrawalDiem)
       / totalSupply()
```

`creditDIEM(amount)` increases `amountStaked` (DIEM is immediately staked) without increasing `totalSupply`, so the rate rises proportionally for all existing shares. `creditWstDIEM(amount, recipient)` mints new shares at the current rate — it does not dilute, it is equivalent to a deposit with no fee.
