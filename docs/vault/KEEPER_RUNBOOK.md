# wstDIEM Keeper Runbook

**Keeper EOA:** `0x32fDdfB0eeC6c638d5C8b7cabF3bE9065478e90E`
**1Password item:** `zfk52wt5di6kn3j76o6o7kngi4` (vault: `base`)
**FeeRouter:** `0x21fe048B10dC9bED2Ee0Ae76724C627CA7F35F61`
**AntSeed Agent ID:** 54271 — registered as channel 0 in FeeRouter

---

## Keeper Role

The keeper is a trusted off-chain EOA that:
1. Serves Venice AI inference via the x402 payment protocol (AntSeed, Surplus Intelligence)
2. Settles inference revenue from USDC into the vault via `FeeRouter.settleAndHarvest()`
3. Calls `harvest()` and `harvestVVV()` as needed

The keeper has `onlyOwnerOrKeeper` access on FeeRouter — it can call `settleAndHarvest`, `harvest`, and `harvestVVV` without going through the Safe. All configuration changes (adding channels, changing FeeModes, rotating the keeper address itself) require a Safe transaction.

---

## settleAndHarvest — Primary Settlement Call

```solidity
function settleAndHarvest(uint256 channelId, uint256 amount) external onlyOwnerOrKeeper
```

This is the normal keeper flow. For AntSeed channel 0:

1. Keeper receives USDC from Surplus Intelligence / AntSeed settlement
2. Keeper calls `FeeRouter.settleAndHarvest(0, amount)` with the net USDC amount (after platform fee)
3. FeeRouter pulls USDC from the keeper's EOA, credits `channels[0].totalRevenue`, and immediately calls `_harvest()`
4. `_harvest()` swaps USDC → WETH → DIEM via Uniswap V3 multihop and calls `vault.creditDIEM(diemAcquired)`
5. Vault stakes the DIEM and the wstDIEM exchange rate rises

**Required approval before calling:** Keeper must approve FeeRouter to spend USDC:
```bash
cast send 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
  "approve(address,uint256)" \
  0x21fe048B10dC9bED2Ee0Ae76724C627CA7F35F61 \
  <amount> \
  --rpc-url $BASE_RPC_URL_URL --private-key $KEEPER_PRIVATE_KEY
```

Then call settleAndHarvest:
```bash
cast send 0x21fe048B10dC9bED2Ee0Ae76724C627CA7F35F61 \
  "settleAndHarvest(uint256,uint256)" \
  0 <usdc_amount_6dec> \
  --rpc-url $BASE_RPC_URL_URL --private-key $KEEPER_PRIVATE_KEY
```

---

## Required Environment Variables (Railway)

| Variable | Description |
|----------|-------------|
| `KEEPER_PRIVATE_KEY` | Private key for `0x32fD...0e90` — from 1P item `zfk52wt5di6kn3j76o6o7kngi4` |
| `BASE_RPC_URL` | Alchemy or QuickNode Base mainnet RPC URL |
| `VENICE_API_KEY` | Venice Bearer token — generated via `generate_web3_key` (see below) |
| `ANTSEED_AGENT_ID` | `54271` |
| `CHANNEL_ID` | `0` (optional — defaults to 0) |
| `MIN_SETTLE_USDC` | Minimum USDC to trigger settlement (optional — defaults to 1.0) |
| `POLL_INTERVAL_MS` | Polling interval in ms (optional — defaults to 120000 = 2 min) |

---

## Monitoring

Check pending USDC and exchange rate with `cast`:

```bash
# Pending USDC in FeeRouter (6 decimals)
cast call 0x21fe048B10dC9bED2Ee0Ae76724C627CA7F35F61 \
  "pendingUSDC()(uint256)" --rpc-url $BASE_RPC_URL

# Current wstDIEM exchange rate (DIEM per 1 wstDIEM, 18 dec)
cast call 0x4751BA2b09374C1929FC01734a166e3c8cd75810 \
  "convertToAssets(uint256)(uint256)" 1000000000000000000 --rpc-url $BASE_RPC_URL

# Vault totalAssets (18 dec)
cast call 0x4751BA2b09374C1929FC01734a166e3c8cd75810 \
  "totalAssets()(uint256)" --rpc-url $BASE_RPC_URL

# Channel 0 lifetime revenue (6 dec USDC)
cast call 0x21fe048B10dC9bED2Ee0Ae76724C627CA7F35F61 \
  "channels(uint256)((string,address,uint256,bool,uint256))" 0 --rpc-url $BASE_RPC_URL
```

---

## Restarting the Railway Service

1. Log in to [railway.app](https://railway.app) and navigate to the keeper service
2. Click **Restart** in the service panel, or push a new deploy to trigger a restart
3. Verify startup by checking Railway logs — the keeper should log its EOA address and the FeeRouter address on boot
4. Confirm it is healthy by checking that `pendingUSDC()` decrements on the next settlement cycle

---

## Withdrawal Queue Automation

The vault has an async withdrawal queue managed by `flush()` and `settle()`. The keeper's `settle.ts` handles this automatically each poll cycle, but you can also run steps manually:

```bash
# Check current batch (5-tuple: batchId, diemTotal, openedAt, userCount, flushableAt)
cast call 0x4751BA2b09374C1929FC01734a166e3c8cd75810 \
  "currentBatchInfo()(uint32,uint128,uint64,uint32,uint64)" --rpc-url $BASE_RPC_URL_URL

# Flush a batch when flushableAt <= now and diemTotal > 0
cast send 0x4751BA2b09374C1929FC01734a166e3c8cd75810 \
  "flush()" --rpc-url $BASE_RPC_URL_URL --private-key $KEEPER_PRIVATE_KEY

# Check which batch is currently unstaking
cast call 0x4751BA2b09374C1929FC01734a166e3c8cd75810 \
  "unstakingBatch()(uint32)" --rpc-url $BASE_RPC_URL_URL

# Get unstaking batch info (5-tuple: diemTotal, openedAt, unlockAt, userCount, settled)
cast call 0x4751BA2b09374C1929FC01734a166e3c8cd75810 \
  "unstakeBatches(uint32)(uint128,uint64,uint64,uint32,bool)" \
  <batchId> --rpc-url $BASE_RPC_URL_URL

# Settle an unstaking batch when unlockAt <= now and not yet settled
cast send 0x4751BA2b09374C1929FC01734a166e3c8cd75810 \
  "settle()" --rpc-url $BASE_RPC_URL_URL --private-key $KEEPER_PRIVATE_KEY
```

---

## Rotating the Venice API Key

The Venice API key is a Bearer token generated by signing a challenge with the keeper's private key. Venice supports ERC-1271 for contract accounts — the vault itself can be a Venice account. The keeper EOA signs the challenge on behalf of its own staked DIEM position.

Three curl steps:

**Step 1 — Request a challenge nonce:**
```bash
CHALLENGE=$(curl -s -X POST https://api.venice.ai/api/v1/auth/generate_web3_key_challenge \
  -H "Content-Type: application/json" \
  -d '{"wallet_address": "0x32fDdfB0eeC6c638d5C8b7cabF3bE9065478e90E"}' \
  | jq -r '.challenge')
echo "Challenge: $CHALLENGE"
```

**Step 2 — Sign the challenge with the keeper EOA:**
```bash
SIG=$(cast wallet sign --private-key $KEEPER_PRIVATE_KEY "$CHALLENGE")
echo "Signature: $SIG"
```

**Step 3 — Submit signature to get a new API key:**
```bash
NEW_KEY=$(curl -s -X POST https://api.venice.ai/api/v1/auth/generate_web3_key \
  -H "Content-Type: application/json" \
  -d "{
    \"wallet_address\": \"0x32fDdfB0eeC6c638d5C8b7cabF3bE9065478e90E\",
    \"challenge\": \"$CHALLENGE\",
    \"signature\": \"$SIG\"
  }" | jq -r '.api_key')
echo "New API key: $NEW_KEY"
```

Update `VENICE_API_KEY` in Railway environment variables with the new key and restart the service.

---

## Handling Failed settleAndHarvest

| Revert message | Cause | Fix |
|---------------|-------|-----|
| `"not owner or keeper"` | Caller is not the keeper EOA or Safe | Confirm tx is sent from `0x32fD...0e90` with correct private key |
| `"ERC20: insufficient allowance"` | Keeper has not approved FeeRouter for USDC | Run `USDC.approve(FeeRouter, amount)` before calling settleAndHarvest |
| `"ERC20: transfer amount exceeds balance"` | Keeper does not hold enough USDC | Check keeper USDC balance; wait for AntSeed settlement to fund the EOA |
| `"channel inactive"` | Channel 0 has been deactivated | Safe must call `FeeRouter.setChannelActive(0, true)` to reactivate |
| `"STF"` (Safe Transfer From) | Usually an allowance or balance issue | Check both USDC balance and allowance on the keeper address |

---

## Split Flow: receiveFromChannel + harvest

If `settleAndHarvest` needs to be broken into two steps (e.g., to test routing without an immediate harvest):

```bash
# Step 1: approve + receiveFromChannel (books the revenue without swapping)
cast send 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
  "approve(address,uint256)" \
  0x21fe048B10dC9bED2Ee0Ae76724C627CA7F35F61 <amount> \
  --rpc-url $BASE_RPC_URL_URL --private-key $KEEPER_PRIVATE_KEY

cast send 0x21fe048B10dC9bED2Ee0Ae76724C627CA7F35F61 \
  "receiveFromChannel(uint256,uint256)" 0 <amount> \
  --rpc-url $BASE_RPC_URL_URL --private-key $KEEPER_PRIVATE_KEY

# Step 2: harvest when ready (swaps and credits vault)
cast send 0x21fe048B10dC9bED2Ee0Ae76724C627CA7F35F61 \
  "harvest()" \
  --rpc-url $BASE_RPC_URL_URL --private-key $KEEPER_PRIVATE_KEY
```

---

## VVV Harvest

Call `harvestVVV()` when the FeeRouter has accumulated >= 100 VVV (the default `vvvBatchThreshold`):

```bash
# Check pending VVV (18 dec)
cast call 0x21fe048B10dC9bED2Ee0Ae76724C627CA7F35F61 \
  "pendingVVV()(uint256)" --rpc-url $BASE_RPC_URL

# Harvest VVV (no-op if below threshold)
cast send 0x21fe048B10dC9bED2Ee0Ae76724C627CA7F35F61 \
  "harvestVVV()" \
  --rpc-url $BASE_RPC_URL_URL --private-key $KEEPER_PRIVATE_KEY
```

`harvestVVV()` stakes all pending VVV → sVVV → calls `mintDiem(sVVV, 0)` → measures DIEM output via balance delta → calls `vault.creditDIEM(diemMinted)`. The function is a no-op (silently returns) if `_pendingVVV < vvvBatchThreshold`.

---

## Migrating Keeper to a Hetzner VPS

1. Provision a Hetzner Cloud VPS (CX22 or larger), Ubuntu 24.04
2. Copy the keeper binary or repo to `/opt/keeper/`
3. Create `/etc/systemd/system/keeper.service`:

```ini
[Unit]
Description=wstDIEM Keeper
After=network.target

[Service]
Type=simple
User=keeper
WorkingDirectory=/opt/keeper
EnvironmentFile=/etc/keeper/env
ExecStart=/opt/keeper/keeper-server
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

4. Create `/etc/keeper/env` with the environment variables listed above (chmod 600)
5. Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable keeper
sudo systemctl start keeper
sudo journalctl -fu keeper
```

6. Update the Railway service to point to the VPS or disable the Railway deployment once VPS is confirmed healthy.
