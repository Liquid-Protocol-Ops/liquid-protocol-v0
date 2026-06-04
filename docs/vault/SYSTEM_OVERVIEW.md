# wstDIEM Vault — System Overview

**Version:** v5 (2026-06-03)
**Chain:** Base mainnet (chain ID 8453)
**Owner (Safe):** `0x872c561f699B42977c093F0eD8b4C9a431280c6c`
**InferenceVault v5:** `0xb9f23c33FfD2213f31C0cFb6c9e2fDf525a9Dd2D`

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
| InferenceVault | `0xb9f23c33FfD2213f31C0cFb6c9e2fDf525a9Dd2D` | ERC-4626 vault, wstDIEM token, withdrawal queue |
| FeeRouter | `0x3b8d968DCca09E319fac7Df741804Af5644E3a60` | Aggregates Liquid Protocol fees, routes to vault |
| Router | `0x6fF481F4B3B0E2ADa548D454F7011D1ed51532B6` | WETH/VVV entry, Morpho leverage loop |
| AntSeedAdapter | `0xE9C2BE3ab25E97Ef4364c505202016106Bec6a6e` | AntSeed USDC settlement |
| SurplusAdapter | `0xB67A86Ab50e30d7509eeD205Fc01A70758B227Db` | Surplus AI USDC settlement |
| X402Adapter | `0xC3C3CaC663f88304a38Cb9C4e9c02bB57DB00142` | X402 micropayment settlement |
| SurplusStakingWrapper | `0x04fAc3e264bD05478Ffc1Caa25394403f8eBc7d7` | Referral deposit wrapper |
| AgentTGERegistry | `0x09a4227935FF15b261533238F79935CCcA0e7941` | Agent lifecycle tracking |
| InferenceProduct | `0x8620304D28c162E2D2Ae3bF279516DAc368D6879` | On-chain inference slot registry |
| Curve DIEM/wstDIEM | `0xB9c7F62e4EeC145bFa1C6bBc5fFdFf246181FdA2` | StableSwap exit pool |
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
