# wstDIEM Vault — System Overview

**Version:** v5 (2026-06-10)
**Chain:** Base mainnet (chain ID 8453)
**Owner (Safe):** `0x872c561f699B42977c093F0eD8b4C9a431280c6c`
**InferenceVault v6:** `0xe49FA849cB37b0e7A42B2335e333fb99474167ba`

---

## What wstDIEM Is

wstDIEM (Wrapped Staked DIEM) is an ERC-20 vault share token representing a pro-rata claim on DIEM staked inside the Venice AI inference protocol. Modeled on wstETH: you hold a fixed share count that redeems for an increasing amount of DIEM over time as yield accrues. No claiming required — the exchange rate rises automatically.

The vault does three things:
1. **Stakes DIEM** on Venice, acquiring inference capacity (sDIEM)
2. **Settles inference revenue** from venue adapters (USDC from AntSeed, Surplus, X402) into more DIEM, compounding the rate for all holders
3. **Routes Liquid Protocol fees** (WETH from token launches) through the FeeRouter into additional DIEM

---

## Architecture

```
                    ┌──────────────────────────────────────┐
                    │         InferenceVault (wstDIEM)     │
                    │   ERC-4626 · ERC-20 · ERC-1271       │
                    │                                      │
  deposit(DIEM) ───►│ stake() → Venice sDIEM               │
                    │                                      │
                    │ totalAssets = staked + cooldown       │
                    │             - pendingWithdrawal       │
                    │                                      │
  creditDIEM() ────►│ raises exchange rate (no new shares) │
  creditWstDIEM()──►│ mints shares at current rate         │
                    │                                      │
  requestRedeem() ─►│ async withdrawal queue:              │
  flush() ─────────►│   initiateUnstake() on Venice        │
  settle() ─────── ►│   unstake() after ~24h cooldown      │
  claimRedeem() ───►│   transfer DIEM to receiver          │
                    └──────────────────────────────────────┘
                           ▲                    ▲
               ┌───────────┘        ┌───────────┘
               │                    │
       ┌───────────────┐   ┌──────────────────────┐
       │   FeeRouter   │   │   Venue Adapters     │
       │               │   │ AntSeedAdapter       │
       │ WETH/USDC/VVV │   │ SurplusAdapter       │
       │ → creditDIEM  │   │ X402Adapter          │
       └───────────────┘   │ USDC → creditDIEM    │
               ▲           │      → creditWstDIEM │
               │           └──────────────────────┘
       Liquid Protocol              ▲
       fee income          Venice API revenue (USDC)
```

---

## Contract Responsibilities

| Contract | Address | Role |
|----------|---------|------|
| InferenceVault | `0xe49FA849cB37b0e7A42B2335e333fb99474167ba` | ERC-4626 vault, wstDIEM token, withdrawal queue |
| FeeRouter | `0xa13a6e75d696bAceB38236389eeFD6eCa5FD4ED3` | Aggregates Liquid Protocol fees, routes to vault |
| Router | `0x74ad4532133Ba538945a5371D249560E66CC7c71` | WETH/VVV entry, Morpho leverage loop |
| AntSeedAdapter | `0xed98A5f4F3AcFd0752A81FDd03DD28b7A44A18b7` | AntSeed USDC settlement |
| SurplusAdapter | `0x91b3E39Ef6335D97876AdB4448A998c7cbD3885F` | Surplus AI USDC settlement |
| X402Adapter | _(not deployed for v6)_ | X402 micropayment settlement — v5-only, unregistered on v6 |
| SurplusStakingWrapper | `0x1A74750eb49c2f6C8C44B9eadaE5C55C7941F271` | Referral deposit wrapper |
| AgentTGERegistry | `0xb13830e7f72Eef167A7F188285feBa5f7C1198Ef` | Agent lifecycle tracking |
| InferenceProduct | `0xE43c4B1930531360c3924F72e9395e9c5bC4a5F3` | On-chain inference slot registry |
| Curve DIEM/wstDIEM | `0x21c33a1Bb5f6Eb43563e1fB9e7AA1D4E90C1A0CD` | StableSwap exit pool |
| Safe (owner) | `0x872c561f699B42977c093F0eD8b4C9a431280c6c` | 2-of-3 multisig, owns all contracts |

---

## Key Invariants

**`totalAssets()`** = `amountStaked + coolDownAmount - pendingWithdrawalDiem`

- `amountStaked`: DIEM actively staked in Venice
- `coolDownAmount`: DIEM in Venice unstaking cooldown (~24h window)
- `pendingWithdrawalDiem`: DIEM earmarked for pending redemptions — excluded to prevent oracle inflation during cooldown

**`stakedInfos(address)`** returns `(amountStaked, coolDownEnd, coolDownAmount)`.
Field 1 is a Unix timestamp (not an amount) — a live Venice interface quirk.

**`creditDIEM(amount)`**: stakes immediately, raises exchange rate, no new shares. Only callable by registered venue adapters.

**`creditWstDIEM(amount, recipient)`**: shares computed PRE-transfer to prevent rate inflation. Only callable by registered venue adapters.

---

## Withdrawal Queue

4-step async process to respect Venice's ~24h DIEM unstaking cooldown:

```
1. requestRedeem(shares, receiver)
      burns shares immediately
      locks DIEM at current rate → pendingWithdrawalDiem += diem
      assigns to current batch (max 50 users per batch)
      returns requestId

2. flush()  [permissionless: after 1 day, or when batch hits 50 users]
      calls Venice initiateUnstake()
      batch enters ~24h cooldown

3. settle()  [permissionless: after cooldown expires]
      calls Venice unstake()
      DIEM moves from cooldown to vault balance

4. claimRedeem(requestId)  [permissionless]
      sends DIEM to stored receiver
      clears pendingWithdrawalDiem for this request
```

`settle()` and `claimRedeem()` are NOT pausable — withdrawals can always complete once initiated.

---

## Morpho Leverage Loop

Router's `loopDeposit(diemAmount, targetLTV, minWstOut)` enables single-tx leverage:

```
Flash borrow DIEM from Morpho (77% LLTV market)
  → deposit all DIEM into vault → receive wstDIEM
  → supply wstDIEM as collateral on behalf of caller
  → borrow DIEM to repay flash loan
Net effect: caller holds leveraged wstDIEM position (up to 4.35x at 77% LLTV)
```

`unloopDeposit()` reverses via flash repay + Curve wstDIEM→DIEM swap.

---

## Venice ERC-1271 Integration

The vault implements `isValidSignature()`. Venice binds an API key to the vault's staked DIEM by verifying the vault's signature on a challenge. The vault checks that the signer is `veniceSigner` — a hot key separate from the Safe owner. Currently set to deployer; rotate to a Privy server wallet before production key registration.

---

## Liquidity Layer

Three exit/entry venues sit around the vault:

| Venue | Address | Purpose |
|-------|---------|---------|
| Curve DIEM/wstDIEM | `0x21c33a1Bb5f6Eb43563e1fB9e7AA1D4E90C1A0CD` | Sync exit: wstDIEM→DIEM at ~1:rate, no cooldown |
| Uniswap V4 wstDIEM/WETH (0.3%) | PoolManager `0x498581...` | Sync exit: wstDIEM→WETH via Router; also WETH entry |
| Morpho wstDIEM/DIEM (86% LLTV) | Oracle `0xB1B192...` | Leverage loop collateral; DIEM lending market |

The V4 pool doubles as the Router's `exitToWETH` backend. Morpho enables `loopDeposit` — borrow DIEM against wstDIEM collateral to re-deposit and compound exposure (up to 4.35x at 77% LLTV).

---

## VVV Lending Market & Oracle (planned — v6, MOG-544)

DIEM has no USD-liquid market (only DIEM/VVV on Aerodrome, ~$9M; DIEM ≈ $1,200), so the high-LLTV lending market is denominated in **VVV**: collateral wstDIEM, loan VVV, priced by **`WstDiemVvvOracle`** — fully on-chain (`price = convertToAssets(1e18) × DIEM/VVV TWAP`, no USD feed). Lenders supply VVV; wstDIEM holders borrow VVV (loopable via `mintDiem`). The wstDIEM/DIEM leverage-loop market above uses the vault rate directly (no USD) and is unaffected; the wstDIEM/USDC & wstDIEM/WETH oracles hardcode DIEM=$1 and are gated by MOG-542.

## Security Review

Claude Code multi-agent review of `src/vault/**` (2026-06-05): **3 confirmed findings (1 High, 2 Medium), no principal-loss issues**. See `docs/vault/SECURITY_REVIEW.md` and Linear MOG-532 (fixes: MOG-541/542/543).

## Agent Integration

wstDIEM is the denomination token for autonomous agent economics:

**Venice capacity:** The vault's sDIEM stake grants inference access. Agents registered against the vault's API key inherit proportional capacity. More vault TVL → more inference power.

**AgentTGERegistry:** Bronze/Silver/Gold tiers track agent staking. Target: tier thresholds in wstDIEM units (via `vault.convertToAssets(shares)`) so tiers auto-adjust as the exchange rate grows.

**InferenceProduct:** Inference slots (staked DIEM wallets) can be purchased by depositing wstDIEM directly — no USDC→DIEM swap. Revenue routes back through adapters → `creditDIEM()` → rate accrues to all holders.

**Autonomous agents (`deploy-autonomous`):** Agents earn USDC from serving inference → USDC flows through venue adapters → `creditDIEM()` → agents' own wstDIEM holdings appreciate. Each agent is a self-compounding node in the network.

---

## Accumulation Flywheel

```
Deposit DIEM
    │
    ▼
wstDIEM shares (fixed count, rising DIEM value)
    │
    ├─► Morpho collateral → borrow DIEM → re-deposit → multiply exposure
    │
    └─► Venice inference capacity (via staked DIEM)
            │
            ▼
        Inference revenue (USDC) → adapters → creditDIEM → rate ↑
            │
            ▼
        Same shares worth more DIEM → healthier Morpho health factor
            │
            ▼
        More borrowing headroom → deeper loop possible
```

The exchange rate is a one-way ratchet: `creditDIEM()` only adds assets, never removes them.
