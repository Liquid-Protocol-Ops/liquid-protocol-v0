# wstDIEM — Fee Structure & Economics

**Last updated:** 2026-10-22 (fees checked on-chain)
**Vault:** `0xe49FA849cB37b0e7A42B2335e333fb99474167ba` (InferenceVault v6)
**Chain:** Base mainnet

---

## Summary

wstDIEM is a rebasing-rate token. You hold a fixed share count; each share redeems for more DIEM over time as yield accrues through three channels: inference revenue (Venice API), Liquid Protocol fee income, and (optionally) Morpho borrowing interest. Fees: a **0.05% deposit fee** and a **5% fee on credited yield**, both minted to the treasury as wstDIEM. No withdrawal fee and no management fee. Live values: `currentDepositFeeBps()` and `yieldFeeBps()` on the vault.

---

## DIEM Value (≫ $1) & VVV-Denominated Liquidity

DIEM is **not** a $1 stablecoin. Each staked DIEM grants **$1/day of Venice inference in perpetuity**, so it prices like a perpetuity — **~$1,100–1,360 on-chain** (≈89 VVV × $15.29 VVV/USD, 2026-06-05), roughly 1,200× $1.

DIEM has **no USD-liquid DEX market**. Its only deep liquidity is **DIEM/VVV on Aerodrome (~$9M total)** — a ~$6M volatile pool plus CL pools (37,340 DIEM supply, ~78% staked, ~3,680 across all pools). Implications:

- Any DIEM/USD oracle must hop DIEM→VVV→USD. The existing wstDIEM/USDC & wstDIEM/WETH Morpho oracles hardcode `DIEM = $1` and are flagged for fix (**MOG-542**, see `SECURITY_REVIEW.md`).
- The high-LLTV lending market is denominated in **VVV**: borrow VVV against wstDIEM via `WstDiemVvvOracle` (fully on-chain, no USD feed). VVV is liquid (~$700M mcap, ~$90M/24h vol). See **MOG-544** and the Leverage Loop section below.
- External liquidity centers on VVV; Curve DIEM/wstDIEM is a thin peg-keeper because raw DIEM is scarce.

---

## Fee Layer 1: Deposit Fee

Charged once at deposit. Flat, set by the Safe with `setDepositFeeBps` (hard cap 10%):

| Fee | Rate | Recipient |
|-----|------|-----------|
| Deposit fee | **0.05% (5 bps)**, flat, since 2026-10-22. 0.25% (25 bps) from 2026-07-16; 2.5% (250 bps) at launch | Treasury `0x2AfE303f4AbD285631872c5A971e5D32fBF1E087`, as wstDIEM shares |

The fee is taken from depositor assets before shares are calculated and minted to the treasury as wstDIEM — the protocol compounds its cut rather than extracting USDC. It does not dilute the exchange rate for existing holders.

No withdrawal fee. No management fee.

## Fee Layer 1b: Yield Fee

`creditDIEM(amount)` mints `yieldFeeBps` (**5%, 500 bps**; hard cap 20%, `setYieldFeeBps`) of each credit to the treasury as wstDIEM, priced before the credit lands, so holders keep 95% of every credit.

---

## Fee Layer 2: Venue Adapter Operator Split

When AntSeed, Surplus, or X402 settle USDC inference revenue, `routeYield()` splits it:

```
100% USDC revenue
  ├── 95% → swap USDC→WETH→DIEM → vault.creditDIEM()
  │         raises wstDIEM exchange rate for ALL holders equally (less the 5% yield fee)
  └──  5% → swap USDC→WETH→DIEM → vault.creditWstDIEM(adapter)
            mints wstDIEM to the adapter at current rate
            adapter is owned by Safe — this is the protocol's inference revenue cut
```

Operator fee: **0% since 2026-10-22 20:39 UTC** (Safe nonce 130), so the whole swap output is credited to the vault; 5% from 2026-07-16 (MOG-593); 10% at launch. Configurable by the Safe up to 20% max.

The 5% adapter cut compounds over time as wstDIEM (not extracted as USDC), so the protocol participates in its own yield growth.

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
  Venice inference USDC (via adapters)   → ~95% to rate (100% credited, less the 5% yield fee; ~90% before 2026-10-22)
  Liquid Protocol WETH (via FeeRouter)   → 95% to rate (less the 5% yield fee)
  Morpho borrowing interest              → only if you also supply DIEM to Morpho

Sources that go to Safe treasury:
  Deposit fee (0.05%)
  Yield fee (5% of each creditDIEM, as wstDIEM)
  Adapter operator cut (5% of inference USDC, held as wstDIEM)

No fee is taken from your shares after you deposit; the yield fee only reduces how fast the rate rises.
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

---

## Leverage Loop Economics (Morpho)

`Router.loopDeposit(diemAmount, targetLTV, minWstOut)` turns a single DIEM deposit into a leveraged wstDIEM position in one transaction:

```
Step 1: Flash borrow X DIEM from Morpho wstDIEM/DIEM market
Step 2: Deposit (your DIEM + X) into vault → receive wstDIEM
Step 3: Supply wstDIEM as Morpho collateral on your behalf
Step 4: Borrow X DIEM to repay flash loan
```

Resulting position for a 1 DIEM deposit at 4x loop:

| | No loop | 2x loop | 4x loop (77% LTV) |
|-|---------|---------|-------------------|
| wstDIEM exposure | 1 DIEM | 2 DIEM | ~4.35 DIEM |
| Morpho borrow | 0 | 1 DIEM | ~3.35 DIEM |
| Yield on exposure | 1x rate | 2x rate | 4.35x rate |
| Liquidation risk | None | Low | Medium (77% LTV) |

The yield earned on the full collateral minus the Morpho borrow rate is the net return. At low borrow utilization the spread is wide; rate risk increases as Morpho fills up.

`Router.unloopDeposit()` exits via flash repay + Curve wstDIEM→DIEM swap, unwinding in one transaction.

---

## Agent Denomination

wstDIEM is the target denomination for autonomous agent pricing:

- **Capacity:** 1 wstDIEM entitles the holder to Venice inference proportional to the vault's total sDIEM stake divided by total wstDIEM supply
- **Compounding:** An agent holding wstDIEM earns rate appreciation automatically — no claiming, no restaking
- **Alignment:** Agents that route USDC revenue through adapters increase the exchange rate, making their own wstDIEM holdings more valuable
- **Collateral:** Agents can borrow DIEM against wstDIEM on Morpho to fund operations without liquidating their staked position

The effective "cost" of Venice inference in DIEM terms falls over time as the vault grows — wstDIEM buys more inference capacity per DIEM invested each period.
