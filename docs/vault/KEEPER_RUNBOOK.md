# wstDIEM Keeper Runbook

**Chain:** Base mainnet (chain ID 8453)
**InferenceVault v6:** `0xe49FA849cB37b0e7A42B2335e333fb99474167ba`
**FeeRouter:** `0xa13a6e75d696bAceB38236389eeFD6eCa5FD4ED3`
**Safe (owner):** `0x872c561f699B42977c093F0eD8b4C9a431280c6c`

---

## Keeper Responsibilities

The keeper is a permissionless or lightly-permissioned EOA that runs routine vault operations. Most functions are fully permissionless; a few are `onlyOwner` (Safe) or `onlyOperator` (adapter owner).

---

## 1. Withdrawal Queue (fully permissionless)

Run these in sequence as conditions are met. Anyone can call them.

### flush()

**When:** after `minBatchOpenSecs` (default 1 day) since batch opened, OR when batch reaches 50 users (immediate).

```bash
cast send $VAULT "flush()" \
  --rpc-url $BASE_RPC_URL --private-key $KEEPER_PK
```

Check if flushable:
```bash
cast call $VAULT "currentBatchStatus()(uint32,uint128,uint64,uint32,uint64)" \
  --rpc-url $BASE_RPC_URL
# returns: (batchId, diemTotal, openedAt, userCount, flushableAt)
# flush is allowed when block.timestamp >= flushableAt OR userCount >= 50
```

### settle()

**When:** ~24h after flush (Venice cooldown has expired).

```bash
cast send $VAULT "settle()" \
  --rpc-url $BASE_RPC_URL --private-key $KEEPER_PK
```

Check cooldown:
```bash
cast call $DIEM "stakedInfos(address)(uint256,uint256,uint256)" $VAULT \
  --rpc-url $BASE_RPC_URL
# (amountStaked, coolDownEnd, coolDownAmount)
# settle() is callable when block.timestamp > coolDownEnd AND coolDownAmount > 0
```

### claimRedeem(requestId)

**When:** after settle. Can be called by anyone; DIEM goes to the `receiver` stored at request time.

```bash
cast send $VAULT "claimRedeem(uint256)" $REQUEST_ID \
  --rpc-url $BASE_RPC_URL --private-key $KEEPER_PK
```

---

## 2. Adapter Yield Routing (onlyOperator — Safe or designated keeper)

Routes accumulated USDC from a venue adapter into the vault.

```bash
# Check USDC balance in adapter
cast call $ADAPTER "usdc()(address)" --rpc-url $BASE_RPC_URL
cast call $USDC "balanceOf(address)(uint256)" $ADAPTER --rpc-url $BASE_RPC_URL

# Route yield (requires operator role — Safe or set keeper)
cast send $ADAPTER "routeYield()" \
  --rpc-url $BASE_RPC_URL --private-key $KEEPER_PK
```

Adapter addresses:
- AntSeedAdapter: `0xE9C2BE3ab25E97Ef4364c505202016106Bec6a6e`
- SurplusAdapter: `0xB67A86Ab50e30d7509eeD205Fc01A70758B227Db`
- X402Adapter: `0xC3C3CaC663f88304a38Cb9C4e9c02bB57DB00142`

---

## 3. FeeRouter Harvest (onlyOwner — Safe)

Converts accumulated WETH/USDC in the FeeRouter to DIEM and credits the vault.

```bash
# Check pending WETH
cast call $FEE_ROUTER "pendingWETH()(uint256)" --rpc-url $BASE_RPC_URL

# Harvest via Safe tx
# Calls FeeRouter.harvest() — swaps WETH→DIEM→creditDIEM
# Use SafeBatch.s.sol or execute directly via Safe app
```

---

## 4. Venice ERC-1271 Key Registration

To register a Venice API key bound to the vault's staked DIEM:

1. Venice sends a challenge to sign
2. Sign with `veniceSigner` key (`0x10900528c57BBCe07C223B25Ae9bB66966274b5D`)
3. Venice calls `vault.isValidSignature(hash, sig)` — returns `0x1626ba7e` if valid
4. Venice registers the API key, giving the vault access proportional to its staked DIEM

Current `veniceSigner` is the deployer key (`el4qwixmdot757dpxcqgfo43qe` in 1P). Rotate to a Privy server wallet via Safe before production:

```bash
# Safe tx: vault.setVeniceSigner(newAddress)
cast calldata "setVeniceSigner(address)" $NEW_SIGNER
# then execute via SafeBatch.s.sol
```

---

## 5. Monitoring

Key things to watch:

```bash
# Exchange rate (DIEM per wstDIEM)
cast call $VAULT "convertToAssets(uint256)(uint256)" 1000000000000000000 \
  --rpc-url $BASE_RPC_URL

# Total staked DIEM
cast call $DIEM "stakedInfos(address)(uint256,uint256,uint256)" $VAULT \
  --rpc-url $BASE_RPC_URL

# Total supply of wstDIEM
cast call $VAULT "totalSupply()(uint256)" --rpc-url $BASE_RPC_URL

# Current batch state
cast call $VAULT "currentBatchStatus()(uint32,uint128,uint64,uint32,uint64)" \
  --rpc-url $BASE_RPC_URL

# Pending withdrawal liability
cast call $VAULT "pendingWithdrawalDiem()(uint256)" --rpc-url $BASE_RPC_URL
```

---

## 6. Emergency Pause (Safe only)

If a critical issue is found:

```bash
# Pause blocks: deposit, requestRedeem, flush
# Does NOT block: settle, claimRedeem (withdrawals always complete)
# Safe tx: vault.pause()
cast calldata "pause()"
# execute via SafeBatch.s.sol

# Unpause
cast calldata "unpause()"
```

---

## Environment Variables

```bash
export BASE_RPC_URL=https://base-mainnet.g.alchemy.com/v2/<key>
export VAULT=0xe49FA849cB37b0e7A42B2335e333fb99474167ba
export FEE_ROUTER=0xa13a6e75d696bAceB38236389eeFD6eCa5FD4ED3
export DIEM=0xF4d97F2da56e8c3098f3a8D538DB630A2606a024

# Keeper EOA (0x988C…6f2f) — local Splits signing key, also used for on-chain keeper calls
# Fund via wstdiem-keeper Splits account (0x102368E997ced4b94d093813B3c1F5fB1F15f4B1)
export KEEPER_PK=$(cat ~/.splits/config.json | python3 -c "import sys,json; print(json.load(sys.stdin)['key']['privateKey'])")

# Deployer v6 EOA — only needed for contract deployment, not routine keeper ops
export DEPLOYER_V6_PK=$(op item get rhuh6s2tocpjzdi7kvvnjrps7i --field credential --reveal)
```

---

## Key Dates

| Date | Action |
|------|--------|
| 2026-06-04 | Run `SafeInitiateWithdrawals.s.sol` on old vault v4 — starts 14-day timelock (MOG-520) |
| 2026-06-18 | Run `SafeEnableWithdrawals.s.sol` — then requestWithdraw / flushBatch / wait 24h / claimBatch → ~2.756 DIEM to Safe |
| After June 18 | Deposit recovered DIEM into v5 per GROWTH_PLAN.md Phase 0–1 |

> **Note:** July 1 was the original target assuming June 17 initiation. Initiating today cuts 13 days off the timeline. MOG-520 can be updated accordingly.
