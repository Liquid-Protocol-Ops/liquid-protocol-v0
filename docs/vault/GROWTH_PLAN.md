# wstDIEM Growth Plan — Seeding, Liquidity & Agent Integration

**Last updated:** 2026-06-04
**Vault:** `0xe49FA849cB37b0e7A42B2335e333fb99474167ba` (InferenceVault v6)
**Chain:** Base mainnet

---

## Core Thesis

wstDIEM is a DIEM accumulation vehicle. The goal is to make it the canonical way to hold DIEM productively:

- **Stake DIEM** → wstDIEM appreciates as Venice inference revenue accrues
- **Use wstDIEM as collateral** → borrow DIEM on Morpho → re-stake → compound exposure
- **Agents denominate in wstDIEM** → inference revenue routes back through the vault → rate accelerates

Every lever reinforces the others. TVL growth increases Venice capacity → more inference revenue → faster rate appreciation → wstDIEM more attractive as collateral.

---

## Phase 0: Capital Recovery (June 4–18)

Recover the ~2.756 DIEM locked in old vault (v4) 13 days early.

### Step 1 — Initiate withdrawals today

Old vault has a 14-day timelock: `initiateEnableWithdrawals()` → wait 14d → `enableWithdrawals()`.
July 1 was a calendar target assuming June 17 initiation. Initiating today gets us DIEM June 18.

```bash
# Safe tx via SafeInitiateWithdrawals.s.sol
SAFE_SK1=$(op item get "liq-safe-signer-1" --field "private key" --reveal --vault "mog.capital" | tr -d '[:space:]')
SAFE_SK2=$(op item get "liq-safe-signer-2" --field "private key" --reveal --vault "Personal" | tr -d '[:space:]')
EXECUTOR_PK=$(op item get el4qwixmdot757dpxcqgfo43qe --field "private key" --reveal | tr -d '[:space:]')

SAFE_SK1="$SAFE_SK1" SAFE_SK2="$SAFE_SK2" EXECUTOR_PK="$EXECUTOR_PK" \
  forge script script/vault/SafeInitiateWithdrawals.s.sol \
  --rpc-url $BASE_RPC_URL --broadcast
```

### Step 2 — Enable and drain on June 18

```bash
# Enable withdrawals
SAFE_SK1=... SAFE_SK2=... EXECUTOR_PK=... \
  forge script script/vault/SafeEnableWithdrawals.s.sol \
  --rpc-url $BASE_RPC_URL --broadcast

# Then keeper flow (old vault uses different API — requestWithdraw/flushBatch/claimBatch)
# requestWithdraw for all 2.739 wstDIEM held by Safe
# flush immediately (Safe is only holder — batch ready)
# wait 24h for Venice cooldown
# claimBatch → 2.756 DIEM to Safe
```

**Result:** ~2.756 DIEM available in Safe on June 18 to deploy into v5.

---

## Phase 1: Vault Seeding (June 18–25)

Deploy recovered DIEM into v5 to establish a non-trivial starting TVL.

**Allocation:**
- 2.0 DIEM → deposit into v5 (`vault.deposit(2e18, safe)`) → receive wstDIEM at 1:1
- 0.5 DIEM → hold in Safe for Morpho supply-side seed (Phase 2)
- 0.256 DIEM → reserve for gas and pool seeding ops

**After deposit:**
- v5 TVL: 2.01 DIEM (2.0 deposited + 0.01 seed)
- Safe holds: ~2.0 wstDIEM (at 1:1 rate, rate will grow from here)

---

## Phase 2: Liquidity Pool Seeding (June 25 – July 5)

Establish functional AMM depth so wstDIEM is tradeable without the async queue.

> **Updated 2026-06-05 (post security review + DIEM liquidity analysis):** DIEM has no USD-liquid market — its only deep DEX liquidity is **DIEM/VVV on Aerodrome (~$9M; DIEM ≈ $1,200 ≈ 89 VVV)**. The liquidity plan is now **VVV-centric**: Curve DIEM/wstDIEM becomes a thin peg-keeper (raw DIEM is scarce — 37,340 supply, ~78% staked), and **wstDIEM/VVV (2d)** is the primary external venue + Morpho lending market (MOG-544). The wstDIEM/USDC & wstDIEM/WETH Morpho oracles hardcode DIEM=$1 and are **gated by MOG-542** — keep their LLTV conservative until a real DIEM/USD source exists. See `SECURITY_REVIEW.md`.

### 2a. Curve DIEM/wstDIEM — StableSwap depth

Pool: `0x21c33a1Bb5f6Eb43563e1fB9e7AA1D4E90C1A0CD`

Add balanced liquidity at ~1:1 ratio. Target: enough depth that a 0.1 DIEM exit has <0.5% slippage.

```bash
# Approve and add_liquidity
cast send $DIEM "approve(address,uint256)" $CURVE_POOL $DIEM_AMOUNT --private-key $PK
cast send $WSTDIEM "approve(address,uint256)" $CURVE_POOL $WSTDIEM_AMOUNT --private-key $PK
cast send $CURVE_POOL "add_liquidity(uint256[],uint256)" "[${DIEM_AMOUNT},${WSTDIEM_AMOUNT}]" 0 --private-key $PK
```

### 2b. Uniswap V4 WETH/wstDIEM — concentrated range

Pool key: `{currency0: wstDIEM, currency1: WETH, fee: 3000, tickSpacing: 60, hooks: address(0)}`
Pool already initialized (via InitPools.s.sol).

Deploy LiquidityManager (SafeManageV4LP.s.sol) then add a narrow range around current price.
The LP earns 0.3% on WETH↔wstDIEM trades and doubles as the Router's `exitToWETH` exit.

Target: enough WETH-side depth to absorb a 0.05 ETH wstDIEM exit without >2% slippage.

### 2c. Morpho DIEM supply — enable leverage loop

Market: wstDIEM/DIEM at 86% LLTV (`0xB1B192fc0190bA15F4EC76BF6032123bc688F76D`). This market's oracle is the vault rate itself (no USD assumption), so it is sound — but the **86% LLTV raise is gated by the security review** (MOG-542) and DIEM/wstDIEM liquidation depth.

Supply 0.3–0.5 DIEM to Morpho as the first lender. This bootstraps the lending market so borrowers can use the leverage loop (`Router.loopDeposit()`).

```bash
cast send $MORPHO "supply((address,address,address,address,uint256),uint256,uint256,address,bytes)" \
  "($LOAN_TOKEN,$COLLATERAL_TOKEN,$ORACLE,$IRM,$LLTV)" $SUPPLY_AMOUNT 0 $SAFE "0x" \
  --private-key $EXECUTOR_PK
```

### 2d. wstDIEM/VVV — VVV lending market + primary external liquidity (Option 2)

DIEM's real liquidity is DIEM/VVV, so re-center external liquidity here. Create a **Morpho wstDIEM (collateral) / VVV (loan) market** priced by the fully on-chain `WstDiemVvvOracle` (`price = convertToAssets(1e18) × DIEM/VVV TWAP` — no USD feed). Lenders supply VVV; wstDIEM holders borrow VVV (loopable via `VVVStaking.mintDiem`). Seed a wstDIEM/VVV pool (Aerodrome CL or Curve **crypto** pool — NOT stable, VVV is volatile) as the exit + liquidation route. Size LLTV/caps to the ~$9M DIEM/VVV depth (~$100–300k exposure ceiling today). Tracked in **MOG-544**.

**After Phase 2 (VVV-centric):**
- Curve DIEM/wstDIEM: thin peg-keeper + liquidation sync-hop (not the main venue — raw DIEM is scarce)
- **wstDIEM/VVV: primary external liquidity + VVV lending market (MOG-544)**
- V4 wstDIEM/WETH: de-prioritized, kept small
- Morpho wstDIEM/DIEM: DIEM-denominated leverage loop (vault-rate oracle, sound); USDC/WETH markets gated by MOG-542

---

## Phase 3: Simple UI (July 5–20)

Build the wstDIEM interface in `liquid-website-april-10`. Three pages.

### `/vault` — Entry page

- Hero: exchange rate (DIEM per wstDIEM), TVL, APY estimate from last 7-day creditDIEM events
- Deposit widget: DIEM input → estimated wstDIEM out; WETH input → depositWETH path
- "How yield works": three income sources with live amounts
- CTA: deposit and link to /vault/borrow for leverage

### `/vault/borrow` — Leverage loop

- Collateral slider: deposit X DIEM → get wstDIEM → borrow Y DIEM against it → re-deposit
- Shows: net wstDIEM position, effective LTV, estimated yield boost at current rate
- Max: 4.35x at 77% LLTV (button to auto-calc max safe leverage)
- Unwind button: unloopDeposit

### `/vault/portfolio` — User positions

- wstDIEM balance → current DIEM redemption value
- Pending withdrawal requests + claimable flag
- Morpho position: collateral, borrow, health factor
- Link to async exit flow

### Tech stack alignment

All reads via `wagmi` + `viem` using existing Privy auth from liquid-website-april-10.
Contracts are already ABIs-available from the repo. No new indexer needed — use direct `cast call` equivalents in the frontend (viem `readContract`).

---

## Phase 4: Agent Denomination in wstDIEM (July 20+)

Position wstDIEM as the native denomination token for autonomous agent economics.

### 4a. Venice API key registration

Register the vault's Venice API key via ERC-1271:
1. Venice sends challenge hash
2. Sign with `veniceSigner` key
3. Venice calls `vault.isValidSignature(hash, sig)` → `0x1626ba7e` → registers key
4. Vault's inference capacity = proportional to its sDIEM stake

**Before this:** rotate `veniceSigner` from deployer to a Privy server wallet via Safe tx `setVeniceSigner(privy_addr)`.

### 4b. AgentTGERegistry tiers in wstDIEM

Current: Bronze/Silver/Gold tiers track staked amounts in Venice units.
Target: tier thresholds denominated in wstDIEM (which compounds automatically), removing the need to manually re-tier as DIEM price changes.

Update `AgentTGERegistry` tier logic to call `vault.convertToAssets(shares)` for DIEM-equivalent valuation.

### 4c. InferenceProduct slots priced in wstDIEM

Each InferenceProduct slot represents staked DIEM inference capacity. Buyers who pay USDC get:
- USDC routes to adapter → 90% credits DIEM into vault → rate rises
- Slot can alternatively be purchased by depositing wstDIEM directly (eliminating the USDC→DIEM swap)

When agents pay in wstDIEM, all DIEM stays in the vault — no outflow, just reallocation.

### 4d. Autonomous agent accumulation loop

For `deploy-autonomous` agents:
- Agents earn inference revenue (USDC) from serving requests
- Revenue routes via adapter → `creditDIEM()` → vault exchange rate rises
- Agents' own wstDIEM holdings appreciate without doing anything
- Agents with more wstDIEM → more Venice capacity → can serve more requests → earn more

Wire up: `deploy-autonomous` harness deposits USDC yield into adapter → adapter routes to vault.

---

## Flywheel Summary

```
External USDC (Venice inference, AntSeed, Surplus, X402)
  └─► Adapters → creditDIEM → rate ↑ for all wstDIEM holders

External WETH (Liquid Protocol token launches)
  └─► FeeRouter → WETH→DIEM swap → creditDIEM → rate ↑

User deposits DIEM
  └─► vault.deposit() → wstDIEM minted at current rate
      → can Morpho-loop up to 4.35x exposure
      → leveraged position still earns the same rate appreciation

Agents earn inference USDC
  └─► same as adapter path → feeds back into vault rate

wstDIEM rate rises
  └─► existing collateral worth more in Morpho → healthier leverage
  └─► agents' wstDIEM worth more → more Venice capacity
  └─► attracts more depositors → more TVL → more Venice capacity → more inference revenue
```

---

## Key Metrics to Track

| Metric | Target (30 days) | How to check |
|--------|-----------------|-------------|
| Vault TVL | 10 DIEM | `cast call $VAULT "totalAssets()(uint256)"` |
| Exchange rate | >1.001 (growing) | `cast call $VAULT "convertToAssets(uint256)(uint256)" 1e18` |
| Curve pool depth | 2+ DIEM total | Curve UI or `pool.balances(0)` |
| Morpho supply | 0.3+ DIEM | Morpho market supply query |
| Leverage loops used | >0 | `Router.LoopDeposit` events |
| USDC routed via adapters | First real revenue | Adapter `YieldRouted` events |
