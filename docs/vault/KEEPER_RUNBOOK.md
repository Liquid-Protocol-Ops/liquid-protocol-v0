# wstDIEM Vault Maintenance — Public Reference

**Chain:** Base mainnet (chain ID 8453)
**InferenceVault v6:** `0xe49FA849cB37b0e7A42B2335e333fb99474167ba`
**FeeRouter:** `0xa13a6e75d696bAceB38236389eeFD6eCa5FD4ED3`
**Safe (owner):** `0x872c561f699B42977c093F0eD8b4C9a431280c6c`

This page covers the vault calls anyone can make and how to read vault state. The protocol's own keeper runs the withdrawal queue and yield routing automatically. Its operating procedures, key management and Safe procedures are internal and live in the private ops repo.

---

## 1. Withdrawal Queue (fully permissionless)

Any account can move a redemption batch forward. The keeper normally does this; these are the calls if you want to do it yourself. Your DIEM always goes to the `receiver` you set in `requestRedeem`, whoever sends the transaction.

### flush()

**When:** after `minBatchOpenSecs` (default 1 day) since the batch opened, or as soon as the batch reaches 50 users.

```bash
cast call $VAULT "currentBatchInfo()(uint32,uint128,uint64,uint32,uint64)" \
  --rpc-url $BASE_RPC_URL
# returns: (batchId, diemTotal, openedAt, userCount, flushableAt)
# flush is allowed when block.timestamp >= flushableAt OR userCount >= 50

cast send $VAULT "flush()" --rpc-url $BASE_RPC_URL --private-key $YOUR_PK
```

### settle()

**When:** after Venice's ~24h unstake cooldown that `flush()` started.

```bash
cast call $DIEM "stakedInfos(address)(uint256,uint256,uint256)" $VAULT \
  --rpc-url $BASE_RPC_URL
# (amountStaked, coolDownEnd, coolDownAmount) — coolDownEnd is a timestamp
# settle() is callable when block.timestamp > coolDownEnd AND coolDownAmount > 0

cast send $VAULT "settle()" --rpc-url $BASE_RPC_URL --private-key $YOUR_PK
```

### claimRedeem(requestId)

**When:** after `settle()`.

```bash
cast send $VAULT "claimRedeem(uint256)" $REQUEST_ID \
  --rpc-url $BASE_RPC_URL --private-key $YOUR_PK
```

See [`DEPOSIT_GUIDE.md`](./DEPOSIT_GUIDE.md) for the full deposit and exit flow.

---

## 2. Yield Routing (operator-only)

Inference revenue arrives as USDC in the venue adapters (AntSeed `0xed98A5f4F3AcFd0752A81FDd03DD28b7A44A18b7`, Surplus `0x91b3E39Ef6335D97876AdB4448A998c7cbD3885F`). The operator calls `routeYield(minDiemOut)`, which swaps USDC→WETH→DIEM on Uniswap V3 and calls `vault.creditDIEM()`, raising the wstDIEM rate for all holders. `minDiemOut` is a caller-supplied slippage floor (the MOG-541 fix), set from a fresh quote. `script/vault/KeeperRelay.s.sol` is the relay script. Fees are in [`wstdiem-economics.md`](./wstdiem-economics.md).

Protocol fees collected in the FeeRouter are converted to DIEM and credited by the Safe (`FeeRouter.harvest()`, owner-only).

---

## 3. Monitoring (read-only)

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
cast call $VAULT "currentBatchInfo()(uint32,uint128,uint64,uint32,uint64)" \
  --rpc-url $BASE_RPC_URL

# Pending withdrawal liability
cast call $VAULT "pendingWithdrawalDiem()(uint256)" --rpc-url $BASE_RPC_URL

# Adapter USDC waiting to be routed
cast call $USDC "balanceOf(address)(uint256)" $ADAPTER --rpc-url $BASE_RPC_URL
```

---

## 4. Emergency Pause (Safe only)

The Safe can `pause()` the vault if a critical issue is found.

- **Blocked while paused:** `deposit`, `requestRedeem`, `flush`
- **Never blocked:** `settle`, `claimRedeem`, so withdrawals already in the queue always complete

---

## Environment

```bash
export BASE_RPC_URL=<a dedicated Base RPC endpoint>   # public RPCs rate-limit under load
export VAULT=0xe49FA849cB37b0e7A42B2335e333fb99474167ba
export FEE_ROUTER=0xa13a6e75d696bAceB38236389eeFD6eCa5FD4ED3
export DIEM=0xF4d97F2da56e8c3098f3a8D538DB630A2606a024
export USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
```

---

## Old v4 vault

The v4 vault (`0x4751BA2b09374C1929FC01734a166e3c8cd75810`) is a standard ERC-4626, not the batch-withdraw flow some earlier docs described. Its funds were recovered to the Safe on 2026-07-10 (MOG-520) and redeposited into v6. There is no 14-day timelock on v4; the 24h figure is Venice's DIEM unstake cooldown.
