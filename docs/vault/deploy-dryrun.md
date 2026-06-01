# wstDIEM Vault — DeployAll.s.sol Dry-Run

**Date:** 2026-06-01  
**Chain:** Base mainnet (fork, chain 8453)  
**Script:** `script/vault/DeployAll.s.sol`  
**Forge version:** 1.5.1  
**Status:** ✅ SIMULATION COMPLETE — no reverts

---

## Simulated contract addresses

These are deterministic CREATE addresses on a fork against the current Base mainnet state.
They will differ on live deploy if nonce differs.

| Contract | Simulated address |
|----------|-------------------|
| `InferenceVault` (wstDIEM) | `0x69F5b6A3588317C470c840335b3a86d14A218AA8` |
| Curve DIEM/wstDIEM pool | `0x12380121477335b9F91CE413850DBedb7CDB9fdD` |
| `FeeRouter` | `0xE2E092957369AE866CC0bF073E8d5d20b2bE0006` |
| `Router` | `0x208f354685163088f4d3A48D8E898DF037baEe58` |
| `AgentTGERegistry` | `0x8f129667BC02C9aaec1F419cd0D2d93eacCEF90A` |
| `SurplusStakingWrapper` | `0x9eBDF5696A2f3138d07e4135aB11010B095CCC24` |
| Morpho oracle | `0x4B510C8829378e973b3a10831140964148AFDc66` |

---

## Gas estimate

| Metric | Value |
|--------|-------|
| Estimated gas price | 0.011 gwei |
| Estimated total gas | 16,331,380 |
| Estimated ETH required | **0.000180 ETH** |

---

## Key checks passed

- [x] `DEPLOYER_ADDRESS == msg.sender` guard passed
- [x] Morpho Blue LLTV `77e16` (77%) confirmed enabled on Base mainnet
- [x] Curve DIEM/wstDIEM pool deployed successfully
- [x] Morpho wstDIEM/DIEM market created
- [x] Ownership transferred to Safe on all 5 mutable contracts

---

## Addresses used (dry-run placeholders)

> **⚠️ These must be replaced with real addresses before live deploy.**

| Variable | Dry-run value | Notes |
|----------|---------------|-------|
| `DEPLOYER_ADDRESS` | `0x49f5b131e083510d47b22f7f4526c1b0f7957cda` | Liquid Protocol deployer (existing Base deployer key) |
| `TREASURY_ADDRESS` | `0x872c561f699B42977c093F0eD8b4C9a431280c6c` | ✅ Confirmed — same Safe as governance |
| `SAFE_MULTISIG_ADDRESS` | `0x872c561f699B42977c093F0eD8b4C9a431280c6c` | ✅ Confirmed — Liquid Protocol governance Safe |

---

## Pre-live deploy checklist (MOG-501 / WP-14)

- [x] Confirm `TREASURY_ADDRESS` — `0x872c561f699B42977c093F0eD8b4C9a431280c6c` (Safe)
- [x] Confirm `SAFE_MULTISIG_ADDRESS` — `0x872c561f699B42977c093F0eD8b4C9a431280c6c`
- [ ] **Fund deployer** — `0x49f5b131e083510d47b22f7f4526c1b0f7957cda` has ~0 ETH; send ≥ 0.001 ETH from Safe before broadcasting
- [ ] Get approval on this doc before `--broadcast`

---

## Fork test results (PhaseE.t.sol)

Run: `forge test --match-path test/vault/integration/PhaseE.t.sol -vvv`

```
Ran 3 tests for test/vault/integration/PhaseE.t.sol:PhaseEIntegrationTest
[PASS] test_fork_agentRegistrationAndFeeReceipt() (gas: 139298)
[PASS] test_fork_vaultRateMonotone() (gas: 427794)
[PASS] test_fork_wstDIEMFeeRouterRoundtrip() (gas: 445252)

Suite result: ok. 3 passed; 0 failed; 0 skipped
```

---

## Live deploy command (fill in real addresses before running)

```bash
DEPLOYER_ADDRESS=<real-deployer> \
TREASURY_ADDRESS=<real-treasury> \
SAFE_MULTISIG_ADDRESS=<real-safe> \
forge script script/vault/DeployAll.s.sol \
  --rpc-url https://base-mainnet.g.alchemy.com/v2/<key> \
  --account <ledger-or-keystore> \
  --broadcast \
  --slow \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY_1 \
  -vvv
```
