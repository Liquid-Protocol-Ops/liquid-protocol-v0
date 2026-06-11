# wstDIEM Vault v5 — Security Review

**Date:** 2026-06-05
**Scope:** `src/vault/**` (2,522 LoC — InferenceVault, FeeRouter, Router, InferenceProduct, adapters, oracles, AgentTGERegistry, SurplusStakingWrapper, WstDIEMHook).
**Method:** Claude Code multi-agent review — 8 parallel finders → dedup → 3 adversarial skeptics per finding (a finding survives only if <2 of 3 can refute it).
**Tracking:** Linear **MOG-532** (full report + comments). Fix tickets: **MOG-541 / MOG-542 / MOG-543**.
**Caveat:** Agent-driven review — a third-party audit is still recommended before large external TVL.

## Outcome

34 raw findings → 33 deduped → **3 confirmed** (1 High, 2 Medium). **No Critical**, and no principal-loss or share-accounting issues survived verification. All require contract changes (v6 redeploy).

| Sev | Contract | Finding | Fix |
|-----|----------|---------|-----|
| High | BaseInferenceAdapter (`routeYield`) | Swaps whole USDC balance USDC→WETH→DIEM with `amountOutMinimum = 0`, no oracle — full sandwich of accrued yield | Caller-supplied `minDiemOut` + private relay — **MOG-541** |
| Medium | WstDiem{Usdc,Weth}Oracle | Hardcode `DIEM = $1`; DIEM actually ≈ $1,200 (perpetuity). Mis-prices Morpho collateral → bad debt / unusable markets | Real DIEM/USD source, or VVV-denominated market — **MOG-542 / MOG-544** |
| Medium | AgentTGERegistry | `recordFeeReceipt()` never wired into FeeRouter → every agent markable-dormant 30d after registration; `markDormant` permissionless | Gate `markDormant` + keeper-driven refresh — **MOG-543** |

## DIEM value & liquidity (on-chain, 2026-06-05)

- **DIEM ≈ $1,100–1,360** (≈89 VVV × $15.29 VVV/USD) — a perpetuity yielding $1/day of Venice inference, ~1,200× the hardcoded $1.
- **No USD-liquid DEX market.** Only deep liquidity is **DIEM/VVV on Aerodrome (~$9M)** — a ~$6M volatile pool (`0xbB345D35…`) + CL pools. Total ~3,680 DIEM across all pools; 37,340 supply, ~78% staked.
- Drives the **Option 2** oracle decision: denominate the high-LLTV lending market in VVV with the fully on-chain `WstDiemVvvOracle` (MOG-544). The wstDIEM/DIEM leverage-loop market uses the vault rate directly (no USD) and is unaffected.
