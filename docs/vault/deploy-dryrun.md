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
| `InferenceVault` (wstDIEM) | `0xd2069DB11f157C5d86b6ef2D36bAAd6411E14b63` |
| Curve DIEM/wstDIEM pool | `0x12380121477335b9F91CE413850DBedb7CDB9fdD` |
| `FeeRouter` | `0xc4845F25B84EA8970D622fbF4FF7d10a6Fb7829e` |
| `Router` | `0x1C3709eCc560E3c5f529544ef36daA10E352f862` |
| `AgentTGERegistry` | `0x8Dc32dA92B89a0968BEc020924491FE94573bef2` |
| `SurplusStakingWrapper` | `0x93577aAA7469Ef62198680Bc006a45e9bd6292B3` |
| Morpho oracle | `0xE762e8011D453853638D1978398df8b1D383A2D9` |

---

## Gas estimate

| Metric | Value |
|--------|-------|
| Estimated gas price | 0.01075 gwei |
| Estimated total gas | 16,335,162 |
| Estimated ETH required | **0.0001756 ETH** |

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
| `DEPLOYER_ADDRESS` | `0xeEd4c6fd992e003cA01f10a3c3e7D8B671789698` | Fresh deployer wallet — key in 1Password `base` vault → "wstDIEM Vault Deployer" |
| `TREASURY_ADDRESS` | `0x872c561f699B42977c093F0eD8b4C9a431280c6c` | ✅ Confirmed — same Safe as governance |
| `SAFE_MULTISIG_ADDRESS` | `0x872c561f699B42977c093F0eD8b4C9a431280c6c` | ✅ Confirmed — Liquid Protocol governance Safe |

---

## Pre-live deploy checklist (MOG-501 / WP-14)

- [x] Confirm `TREASURY_ADDRESS` — `0x872c561f699B42977c093F0eD8b4C9a431280c6c` (Safe)
- [x] Confirm `SAFE_MULTISIG_ADDRESS` — `0x872c561f699B42977c093F0eD8b4C9a431280c6c`
- [ ] **Fund deployer** — `0xeEd4c6fd992e003cA01f10a3c3e7D8B671789698` has 0 ETH (fresh wallet); send ≥ 0.001 ETH from Safe before broadcasting
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
DEPLOYER_ADDRESS=0xeEd4c6fd992e003cA01f10a3c3e7D8B671789698 \
TREASURY_ADDRESS=0x872c561f699B42977c093F0eD8b4C9a431280c6c \
SAFE_MULTISIG_ADDRESS=0x872c561f699B42977c093F0eD8b4C9a431280c6c \
forge script script/vault/DeployAll.s.sol \
  --rpc-url https://base-mainnet.g.alchemy.com/v2/<key> \
  --private-key $(op item get dlvppn2nk3mkz2ewgcu3yhqbj4 --field private_key --reveal) \
  --broadcast \
  --slow \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY_1 \
  -vvv
```
