# wstDIEM — Fee Structure & Economics

**Last updated:** 2026-06-01  
**Vault:** `0xa6076Ac24f21A9c526d6d32774d66cBB804Cf649`  
**Chain:** Base mainnet

---

## What wstDIEM Is

wstDIEM is a liquid, transferrable ERC-4626 wrapper for **sDIEM** (staked DIEM) in the Venice AI ecosystem.

- **Deposit DIEM** → vault calls `DIEM.stake(amount)` → DIEM moves from liquid `balanceOf` into Venice's internal `stakedInfos` position
- **Receive wstDIEM** → liquid ERC-20 representing a pro-rata share of the vault's total staked DIEM
- **Exchange rate** increases over time as protocol fees are credited to the vault non-dilutively

Analogous to wstETH (Lido): wstDIEM is the non-rebasing wrapper over a rebasing staked position. The rate of 1 wstDIEM → DIEM rises as yield accrues.

---

## Fee Structure

### Deposit Fee (InferenceVault)

| TVL | Fee | Recipient |
|-----|-----|-----------|
| < $5M (5,000,000 DIEM) | **0.1% (10 bps)** | Treasury (Safe) as extra wstDIEM shares |
| ≥ $5M | **0.5% (50 bps)** | Treasury (Safe) as extra wstDIEM shares |

Fee is taken at deposit time as additional shares minted to treasury — not as a separate DIEM transfer. The depositor gets slightly fewer shares than the raw deposit amount.

**Formula:** `feeShares = convertToShares(assets * feeBps / 10000)` computed pre-deposit so the ratio is well-defined at genesis.

### Withdrawal Fee
None. No fee on withdrawal — however withdrawals are currently **disabled** (14-day governance timelock + 24h DIEM unstake cooldown). Primary exit path is the V4 wstDIEM/WETH pool or the Curve DIEM/wstDIEM pool.

### Router Fee
None. The Router (`0xaa266759...`) is a pass-through — it charges no protocol fee on `depositWETH`, `depositVVV`, or `exitToWETH`.

### Curve DIEM/wstDIEM Pool
Standard Curve StableSwap fee (~0.04%) on swaps. LP earnings go to whoever provides liquidity (protocol-owned LP at launch).

### V4 wstDIEM/WETH Pool
**0.3% swap fee** on wstDIEM/WETH trades. LP earnings go to whoever provides liquidity (protocol-owned LP at launch, pending Safe 20 WETH deployment).

### Morpho Lending (38.5% LLTV market)
**No fee to borrowers from the protocol.** Borrowers pay the Adaptive Curve IRM interest rate to DIEM lenders. The protocol is the initial DIEM lender and earns this interest directly.

---

## Yield Sources for wstDIEM Holders

The wstDIEM exchange rate appreciates as DIEM accrues to the vault non-dilutively via `creditDIEM()`. DIEM never leaves the vault — the staked position is strictly monotonically increasing.

### Primary: Inference Revenue (USDC → DIEM → vault)

Protocol agents (AUTONOMOPOLY and future deploy-autonomous agents) sell Venice AI inference on Surplus AI for USDC. All USDC earned flows back to the vault — agents are execution infrastructure, not beneficiaries.

**Flow:**
```
Agent (own sVVV + own sDIEM) → Surplus AI provider
        ↓ buyer pays USDC per request
Agent earns USDC → sends to FeeRouter
        ↓ FeeRouter.receiveUSDC(amount) [pending implementation]
Swap USDC → WETH → DIEM (V3 pools)
        ↓ vault.creditDIEM(diemAmount)
Vault stakes DIEM, no new shares minted
        ↓
wstDIEM exchange rate increases for all holders
```

**Why this is the primary yield:** Each agent deployed via deploy-autonomous contributes its inference earnings to the vault. As the agent fleet grows, so does the USDC income stream. This scales with the number of agents and requests served, not just with the staking base.

**FeeRouter update needed:** A `receiveUSDC(uint256 amount)` function that swaps USDC → WETH → DIEM via V3 and calls `vault.creditDIEM()`. Currently FeeRouter accepts WETH, VVV, and wstDIEM — USDC support is the next addition.

### Secondary: Protocol Fee Income (Liquid Protocol fees)

The `FeeRouter` receives fee income from Liquid Protocol token launches:

| Input | Path | Outcome |
|-------|------|---------|
| **VVV** (Venice token fees) | `receiveVVV()` → batch → `stake()` → sVVV → `mintDiem()` → `vault.creditDIEM()` | Rate increase |
| **WETH** (swap fees) | `receiveWETH()` → WETH → DIEM (V3) → `vault.creditDIEM()` *(stub, pending)* | Rate increase |
| **wstDIEM** (direct fees) | `receivewstDIEM()` → Curve VOL | Curve liquidity |

### Tertiary: Morpho Lending Interest

Protocol supplies DIEM to the Morpho 38.5% market. Interest paid by borrowers accrues to the protocol and is credited back to the vault periodically via `creditDIEM()`.

### Quaternary: V4 Pool Swap Fees

0.3% of every wstDIEM/WETH trade goes to the V4 LP position. Collected and reinvested as DIEM → `creditDIEM()` periodically.

### Base Layer: DIEM Native Staking Rewards *(to be verified)*

The DIEM staking contract may distribute additional VVV or DIEM rewards to stakers. If so, these accrue automatically to the vault's position.

---

## The Leverage Flywheel

```
Agent deposits wstDIEM as Morpho collateral
        ↓
Borrows DIEM (up to 38.5% of collateral value)
        ↓
Spends DIEM on Venice AI inference (calls DIEM.stake())
        ↓
Venice API generates usage → Liquid Protocol earns fees
        ↓
FeeRouter.receiveVVV() / receiveWETH() accumulate
        ↓
harvestVVV() / harvest() → creditDIEM() to vault
        ↓
wstDIEM exchange rate rises → wstDIEM collateral worth more
        ↓
Agents can borrow more → more inference → more fees → ...
```

---

## Inference Access — Current Architecture Constraints

**wstDIEM does NOT grant Venice inference access directly.**

Venice requires sDIEM (staked DIEM) in the **user's own wallet**. The vault holds all staked DIEM under its own contract address. Individual wstDIEM holders cannot delegate or use the vault's Venice inference quota without:

1. Withdrawing from the vault (once withdrawals are enabled — June 15, 2026)
2. Receiving liquid DIEM
3. Calling `DIEM.stake(amount)` from their own wallet
4. Using Venice API with their newly staked position

### Surplus Intelligence via Surplus AI + AntSeed

**DIEM never leaves the vault.** The vault is a pure accumulator — its sDIEM position only grows, never shrinks. Inference selling happens at the agent level, and revenue loops back into the vault via `creditDIEM()`.

[Surplus AI](https://antseed.com) operates a marketplace where Venice AI inference capacity is sold for USDC per request using x402/HTTP 402 payment channels on Base. Providers register their Venice API key and earn USDC from buyers.

**The architecture:**

```
Protocol agents (AUTONOMOPOLY, future agents)
  ├── own sVVV → Venice API key gate (non-transferrable)
  └── own sDIEM → Venice inference budget ($1/DIEM/day)
           ↓ register on Surplus AI
  Buyers purchase inference → pay USDC per request
           ↓
  Agent earns USDC
           ↓ convert USDC → DIEM (market buy)
  FeeRouter.creditDIEM(amount) → vault stakes more DIEM
           ↓
  wstDIEM exchange rate rises — all holders benefit
  Vault DIEM position is strictly monotonically increasing
```

**The vault's role:** Passive accumulator. Receives DIEM from FeeRouter. Stakes it. Never unstakes it (unless enabling user withdrawals). The vault contract address is NOT a Venice provider.

**AUTONOMOPOLY can sell inference on Surplus AI today:**
- sVVV = 4.5397 → Venice API key already active
- sDIEM = 9.6 → $9.60/day Venice inference budget
- Register Venice API key on Surplus AI → earn USDC from buyers
- USDC → buy DIEM → creditDIEM() → vault rate up

**As more agents launch** (via deploy-autonomous), each agent stakes its own DIEM separately, sells inference on Surplus AI, and compounds back into the vault. The vault TVL grows from agent activity without any central coordination.

---

## Withdrawal Flow (Current)

| Step | Who | When |
|------|-----|------|
| `initiateEnableWithdrawals()` called | Safe (owner) | ✅ done — June 1, 2026 |
| Governance timelock expires | — | **June 15, 2026 21:41 UTC** |
| `enableWithdrawals()` called | Anyone | After June 15 |
| `initiateUnstake(amount)` | Safe (owner) | Must pre-unstake enough DIEM for expected withdrawals |
| 24h DIEM cooldown | — | Automatic |
| `completeUnstake()` | Anyone | After cooldown |
| User redeems wstDIEM for DIEM | User | After `enableWithdrawals()` and sufficient DIEM unstaked |

Primary liquidity path for users who don't want to wait: **sell wstDIEM on V4 wstDIEM/WETH pool** or swap via **Curve DIEM/wstDIEM pool**.

---

## Planned Protocol-Owned Liquidity (20 WETH budget)

All LP positions are protocol-owned (Safe). Gas is negligible on Base.

| Venue | WETH | Mechanism | IL profile | Recoverability |
|-------|------|-----------|-----------|---------------|
| **Morpho DIEM supply** | **12 WETH (60%)** | Swap WETH→DIEM via V3, supply to 38.5% market as lender | None — pure lending | High: get DIEM back + interest; convert to WETH when unwinding |
| **V4 wstDIEM/WETH** (concentrated) | **6 WETH (30%)** | Pair 3 WETH + 3 WETH worth of wstDIEM; concentrated range ±70% | ~3.4% IL at boundary; beyond ±70% position goes single-sided | Good; fees offset modest IL |
| **Curve DIEM/wstDIEM** | **1 WETH (5%)** | Swap 0.5 WETH→DIEM + 0.5 WETH→DIEM→wstDIEM; add to both sides | Minimal — stableswap near parity | High |
| **WETH reserve** | **1 WETH (5%)** | Keep liquid in Safe | None | 100% |

### V4 Concentrated Range Parameters

- **tickLower:** `-9,900` (−70% from current price; 1 WETH = 0.37 wstDIEM)
- **tickUpper:** `7,440` (+70% from current price; 1 WETH = 2.10 wstDIEM)
- **Current tick:** 2,140 (1 WETH ≈ 1.24 wstDIEM at deployment)
- **Fee tier:** 0.3%
- **IL at boundary:** ~3.4% (vs ~5.7% for full-range at same move)
- **Re-ranging:** Free on Base — re-range position if price exits the band

When WETH price rises more than 70% vs wstDIEM, the LP becomes 100% wstDIEM (WETH fully sold). When WETH drops more than 70% vs wstDIEM, the LP becomes 100% WETH (wstDIEM fully bought). In both cases the position is outside range and earns no fees until re-ranged.

### Surplus Intelligence — Future Work

The Morpho interest earned (12 WETH → DIEM → lent at X% APY) could be auctioned daily to inference buyers for USDC. This requires a keeper contract that:
1. Collects Morpho accrued interest (DIEM)
2. Auctions DIEM to buyers who pay USDC
3. Distributes USDC pro-rata to wstDIEM holders, or reinvests as `creditDIEM()`

Not implemented. Current vault is yield-accumulation only.

---

## Deployed Contracts Summary

| Contract | Address | Role |
|----------|---------|------|
| `InferenceVault` (wstDIEM) | `0xa6076Ac24f21A9c526d6d32774d66cBB804Cf649` | Core ERC-4626 vault |
| `Router` v6 | `0xaa266759d6d546b3710D84E99ba49089812dCcBD` | Deposit paths: WETH, VVV, exitToWETH |
| `FeeRouter` | `0x67fA697Da772052119b289DDCa987b0A90592243` | Fee income routing to vault |
| `SurplusStakingWrapper` | `0x4468FD8a503399c096be95D11a24037Cd7168b1b` | Deposit wrapper with referral tracking |
| `AgentTGERegistry` | `0xf1c0bD66aD078182F5C06AFeC423F30233c5Ac65` | Agent lifecycle and dormancy tracking |
| Curve DIEM/wstDIEM | `0x60b9bDfFE446A17202b0e56318ED3aE67bb2694E` | StableSwap exit pool |
| V4 wstDIEM/WETH | PoolId `0x43da55...1f15` | AMM exit pool, `exitToWETH` target |
| Morpho 38.5% market | MarketId `0x84f275...589` | DIEM borrow market, wstDIEM collateral |
| Morpho 77% market (legacy) | — | Deprecated; 38.5% is canonical |
