# wstDIEM Liquid Inference Vault — Base Mainnet Addresses

**Deployed:** 2026-06-01  
**Chain:** Base mainnet (chain 8453)  
**Deployer:** `0xeEd4c6fd992e003cA01f10a3c3e7D8B671789698`  
**Owner (Safe):** `0x872c561f699B42977c093F0eD8b4C9a431280c6c`  
**Treasury:** `0x872c561f699B42977c093F0eD8b4C9a431280c6c`

---

## Contract Addresses

| Contract | Address | Basescan |
|----------|---------|---------|
| `InferenceVault` (wstDIEM) | `0xd2069DB11f157C5d86b6ef2D36bAAd6411E14b63` | [view](https://basescan.org/address/0xd2069DB11f157C5d86b6ef2D36bAAd6411E14b63) |
| Curve DIEM/wstDIEM pool | `0x12380121477335b9F91CE413850DBedb7CDB9fdD` | [view](https://basescan.org/address/0x12380121477335b9F91CE413850DBedb7CDB9fdD) |
| `FeeRouter` | `0xc4845F25B84EA8970D622fbF4FF7d10a6Fb7829e` | [view](https://basescan.org/address/0xc4845F25B84EA8970D622fbF4FF7d10a6Fb7829e) |
| `Router` | `0x1C3709eCc560E3c5f529544ef36daA10E352f862` | [view](https://basescan.org/address/0x1C3709eCc560E3c5f529544ef36daA10E352f862) |
| `AgentTGERegistry` | `0x8Dc32dA92B89a0968BEc020924491FE94573bef2` | [view](https://basescan.org/address/0x8Dc32dA92B89a0968BEc020924491FE94573bef2) |
| `SurplusStakingWrapper` | `0x93577aAA7469Ef62198680Bc006a45e9bd6292B3` | [view](https://basescan.org/address/0x93577aAA7469Ef62198680Bc006a45e9bd6292B3) |
| Morpho oracle | `0xE762e8011D453853638D1978398df8b1D383A2D9` | [view](https://basescan.org/address/0xE762e8011D453853638D1978398df8b1D383A2D9) |

## Morpho Market

| Parameter | Value |
|-----------|-------|
| Loan token | DIEM (`0xF4d97F2da56e8c3098f3a8D538DB630A2606a024`) |
| Collateral token | wstDIEM (`0xd2069DB11f157C5d86b6ef2D36bAAd6411E14b63`) |
| Oracle | `0xE762e8011D453853638D1978398df8b1D383A2D9` |
| IRM | Adaptive Curve (`0x46415998764C29aB2a25CbeA6254146D50D22687`) |
| LLTV | 77% (`770000000000000000`) |

## Deployment Transactions

| Action | Tx Hash |
|--------|---------|
| Deploy InferenceVault | `0x6e0a6a9ef3dedd05c0...` |
| Deploy FeeRouter | `0xc914e170ab0cea6c8a...` |
| Deploy Router | `0x48b141c4350d5d9f2e...` |
| Deploy AgentTGERegistry | `0x590af196053097b296...` |
| Deploy SurplusStakingWrapper | `0x2d6f587bfe9d457722...` |
| Create Morpho market | `0xc714a7d9c6941190a4...` |
| Transfer ownership to Safe | (final txs) |

> Full broadcast artifacts: `broadcast/DeployAll.s.sol/8453/run-latest.json`

## Post-deploy checklist

- [ ] Verify all contracts on Basescan (`forge verify-contract`)
- [ ] Smoke test: first DIEM deposit into InferenceVault
- [ ] Smoke test: first fee routing event
- [ ] Add InferenceVault address to liquid-protocol-ops scripts
- [ ] Update agent-autonomopoly harness constants with wstDIEM vault address
