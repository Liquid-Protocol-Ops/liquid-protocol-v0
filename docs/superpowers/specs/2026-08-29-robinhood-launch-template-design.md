# Robinhood Launch Template — breakout ladder + top-trader reward pool

**Date:** 2026-08-29 · **Chain:** Robinhood Chain (4663) · **Status:** design approved in-session (Gordon), pending spec review

A default deployment template for Liquid-factory launches on Robinhood Chain:
SPY-paired, dynamic-fee (2%→5%), a 7-position "breakout ladder" tuned for
volatility harvest and aggressive price action, and a pre-migration
**top-trader reward pool** — LP fees pre-$2M-MC reward the month's top traders
by realized PnL; post-migration all fees flow to the creator (protocol team
fees unchanged throughout).

## 1. Existing rails this builds on (all live on 4663)

| Piece | Address | Notes |
|---|---|---|
| Liquid factory | `0x65c40274a1a2178a5140f80fcd6fe7efb954e6c2` | SPYING launch = precedent (`script/LaunchSpying.s.sol`) |
| LiquidHookDynamicFeeV2 | `0xdee7dcdcf599306d3c29e8dd0e6f4c9c4b6f68cc` | per-pool `{baseFee, maxLpFee, feeControlNumerator, …}` |
| LiquidMevDescendingFees | `0xd86416eedb067213df7336662b3fa3b3a1a5e205` | launch anti-snipe decay |
| LP locker (v2, 4663-only) | `0x4AB39080B54121136fEfFf86857641F40dA6b964` | REQUIRED for Paired conversion (v1 reverts on RH's forked Universal Router — 6-field `minHopPriceX36` params) |
| SPY (tokenized equity) | `0x117cc2133c37B721F49dE2A7a74833232B3B4C0C` | paired token |
| Protocol treasury | RH Safe (owner of all 7 Ownables + `teamFeeRecipient`) | receives stub pot at migration |

## 2. Position ladder ("breakout ladder")

Total supply 1e9 ×1e18 (AIPLAY/SPYING convention), 100% into LP, single-sided
token, 7 positions (per cap), tick spacing 60, ticks snapped down.

Tick math at deploy time: `tick(MC_usd) = ln(MC_usd / (1e9 × SPY_usd_live)) / ln(1.0001)`,
SPY/USD fetched live at deploy (from the SPY-quoted pools or an off-chain
price with operator confirmation). Start MC default **$25k** (parameter).

| Pos | Supply bps | MC range (USD) | Density (bps/ln-span) | Role |
|---|---|---|---|---|
| 1 | 600 | $25k → $2M | ~1.4 | thin launch float; MEV decay taxes the snipe wave |
| 2 | 2200 | $2M → $4M | ~31.7 | the wall — churn zone, dynamic fee rides the 5% cap |
| 3 | 2400 | $4M → $16M | ~17.3 | main body — two-way volatility monetization |
| 4 | 2000 | $16M → $256M | ~7.2 | density halves — breakouts run |
| 5 | 1400 | $256M → $4B | ~5.1 | thin — volume moves price fast |
| 6 | 900 | $4B → $65B | ~3.2 | very thin — aggressive continuation |
| 7 | 500 | $65B → MAX_TICK | ~0.4 | moonbag tail |

Sum = 10_000 bps exactly (factory `positionBps` invariant). Density declines
monotonically above $4M: each breakout is easier than the last, while the deep
$2–16M zone (46% of supply) concentrates churn where the dynamic fee earns.

## 3. Fee configuration

- **Dynamic hook** (`PoolDynamicConfigVars`): `baseFee = 20_000` (2% floor),
  `maxLpFee = 50_000` (5% cap), `feeControlNumerator > 0` (volatility term ON —
  unlike SPYING's flat 0). Hook formula (verified in
  `src/hooks/LiquidHookDynamicFeeV2.sol:_getLpFee`):
  `fee = min(baseFee + feeControlNumerator × volAccumulator² / FEE_CONTROL_DENOMINATOR, maxLpFee)`.
  Exact numerator calibrated in the implementation plan (target: reach the 5%
  cap under launch-day tick swings; check Clanker-standard values).
  Other vars per SPYING: `referenceTickFilterPeriod 3600`, `resetPeriod 86_400`,
  `resetTickFilter 500`, `decayFilterBps 9_000`.
- **MEV module**: `startingFee 500_000` (50%) → `endingFee 20_000` (2%, = base
  floor; SPYING used 1%), `secondsToDecay 120`.
- **Fee preference**: `Paired` — all LP fees convert to SPY via the v2 locker.
- **Protocol team fees**: factory-level, untouched, accrue to treasury in both
  phases ("fixed liquid protocol fees").

## 4. TopTraderRewardPool (new contract)

Deployed per-launch (or singleton w/ per-pool accounting — decide in plan;
default per-launch for isolation). Set as the launch's **sole
`rewardRecipient` (10_000 bps)**; `rewardAdmin` = creator (recovery path).

State machine — one-way latch:

- **Phase BONDING (pre-migration):** SPY fee inflows accrue to the current
  month's pot. `awardMonth(address[3] winners)` — callable by `keeper` role
  once per calendar month (UTC) — splits that month's pot **60/30/10** to the
  top-3 traders by realized PnL. Emits full accounting events.
- **`migrate()`** — permissionless. Succeeds when the pool's **spot tick** ≥
  the immutable `migrationTick` (computed at deploy for $2M MC from live SPY —
  note: SPY drift changes the USD meaning of the latch after deploy; accepted).
  Spot-tick trigger chosen deliberately over TWAP (owner decision 2026-08-29);
  documented wick risk: a single-block pump can latch migration early.
  On migration: **current stub pot → protocol treasury (RH Safe)**, phase flips.
- **Phase MIGRATED:** contract is a passthrough — `claim()` forwards its full
  SPY (and any token) balance to `creator`. No keeper role remains active.

rPNL definition (v1): per-address realized PnL **in SPY terms** over the
calendar month, computed from the pool's swap ledger only (SPY received from
sells − SPY spent on buys, FIFO basis for partial exits; wallet-to-wallet
token transfers carry zero basis). Wash-trading is self-defeating: every
round-trip pays the 2–5% dynamic fee into the very pot being contested.

**Trust model (v1, explicit):** the keeper picks winners off-chain. Mitigations:
computation published per month (artifact + script in repo), full event trail,
top-3 split dilutes manipulation payoff. Merkle-verifiable winners = v2.

## 5. Keeper (off-chain)

Monthly job (GHA cron or keeper-kit, pattern per ops repo): index pool swaps
via 4663 RPC/Blockscout → compute per-address monthly rPNL → publish artifact
→ call `awardMonth`. Uses the RH keeper wallet; TIER-2 signing keys stay out
of automation per credential-tier policy.

## 6. Deliverables & phasing

1. **P1 — contract + template:** `src/extensions/TopTraderRewardPool.sol` (or
   `src/periphery/`), `script/LaunchRobinhoodTemplate.s.sol` (env-param
   name/symbol/start-MC/SPY-price; builds ladder + fee config + pool as
   recipient), Foundry unit tests + 4663 fork test (ladder geometry, latch,
   award paths, migration sweep).
2. **P2 — keeper:** rPNL indexer + monthly cron + publication.
3. **P3 — website `[ROBINHOOD]` section** (liquid-website): nav entry + page —
   addresses, ladder preview/curve visual, reward-pool explainer, launch
   how-to (script-driven; in-browser 4663 deploys are a later phase).

## 7. Risks / open items

- Spot-tick wick migration (accepted by owner; revisit if abused).
- SPY-price drift: `migrationTick` fixed at deploy; $2M label drifts with SPY.
- Keeper trust on winner selection (v1); merkle proofs later.
- `feeControlNumerator` calibration needed before mainnet broadcast.
- Deploy safety: run deploy-safety-reviewer before any 4663 broadcast.
