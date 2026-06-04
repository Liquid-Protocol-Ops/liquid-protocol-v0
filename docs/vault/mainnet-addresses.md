# wstDIEM Liquid Inference Vault — Base Mainnet Addresses

**Last updated:** 2026-06-03 (v5)
**Chain:** Base mainnet (chain 8453)
**Owner (Safe):** `0x872c561f699B42977c093F0eD8b4C9a431280c6c`

---

## Core Stack (v5)

| Contract | Address | Basescan |
|----------|---------|---------|
| InferenceVault (wstDIEM) | `0xb9f23c33FfD2213f31C0cFb6c9e2fDf525a9Dd2D` | [view](https://basescan.org/address/0xb9f23c33ffd2213f31c0cfb6c9e2fdf525a9dd2d) |
| FeeRouter | `0x3b8d968DCca09E319fac7Df741804Af5644E3a60` | [view](https://basescan.org/address/0x3b8d968dcca09e319fac7df741804af5644e3a60) |
| Router | `0x6fF481F4B3B0E2ADa548D454F7011D1ed51532B6` | [view](https://basescan.org/address/0x6ff481f4b3b0e2ada548d454f7011d1ed51532b6) |
| AgentTGERegistry | `0x09a4227935FF15b261533238F79935CCcA0e7941` | [view](https://basescan.org/address/0x09a4227935ff15b261533238f79935ccca0e7941) |
| SurplusStakingWrapper | `0x04fAc3e264bD05478Ffc1Caa25394403f8eBc7d7` | [view](https://basescan.org/address/0x04fac3e264bd05478ffc1caa25394403f8ebc7d7) |
| InferenceProduct | `0x8620304D28c162E2D2Ae3bF279516DAc368D6879` | [view](https://basescan.org/address/0x8620304d28c162e2d2ae3bf279516dac368d6879) |

## Venue Adapters (v5)

| Contract | Address | Basescan |
|----------|---------|---------|
| AntSeedAdapter | `0xE9C2BE3ab25E97Ef4364c505202016106Bec6a6e` | [view](https://basescan.org/address/0xe9c2be3ab25e97ef4364c505202016106bec6a6e) |
| SurplusAdapter | `0xB67A86Ab50e30d7509eeD205Fc01A70758B227Db` | [view](https://basescan.org/address/0xb67a86ab50e30d7509eed205fc01a70758b227db) |
| X402Adapter | `0xC3C3CaC663f88304a38Cb9C4e9c02bB57DB00142` | [view](https://basescan.org/address/0xc3c3cac663f88304a38cb9c4e9c02bb57db00142) |

## Morpho Markets (v5)

| Market | Oracle | LLTV | Basescan |
|--------|--------|------|---------|
| wstDIEM/DIEM (leverage loop) | `0xB1B192fc0190bA15F4EC76BF6032123bc688F76D` | 86% | [view](https://basescan.org/address/0xb1b192fc0190ba15f4ec76bf6032123bc688f76d) |
| wstDIEM/USDC | `0x7F3eAb9863d4f5a1d34d89f7b802C0eA2469b51a` | 62.5% | [view](https://basescan.org/address/0x7f3eab9863d4f5a1d34d89f7b802c0ea2469b51a) |
| wstDIEM/WETH | `0x73FddCCBB524b04b43EdED9C4d20C061DE291F07` | 62.5% | [view](https://basescan.org/address/0x73fddccbb524b04b43eded9c4d20c061de291f07) |
| wstDIEM/DIEM (77% LLTV) | `0xE762e8011D453853638D1978398df8b1D383A2D9` | 77% | — |

## Liquidity Pools (v5)

| Pool | Address |
|------|---------|
| Curve DIEM/wstDIEM StableSwap | `0xB9c7F62e4EeC145bFa1C6bBc5fFdFf246181FdA2` |
| Uniswap V4 WETH/wstDIEM (0.3%) | Pool in `0x498581fF718922c3f8e6A244956aF099B2652b2b` (PoolManager) |

## External Dependencies (Base mainnet)

| Protocol | Address | Used for |
|----------|---------|---------|
| DIEM token | `0xF4d97F2da56e8c3098f3a8D538DB630A2606a024` | Vault asset; built-in `stake()`/`unstake()` |
| VVV staking (sVVV) | `0x321b7ff75154472B18EDb199033fF4D116F340Ff` | `depositVVV` Router path |
| Uniswap V3 SwapRouter02 | `0x2626664c2603336E57B271c5C0b26F421741e481` | WETH/USDC→DIEM swaps |
| Uniswap V4 PoolManager | `0x498581fF718922c3f8e6A244956aF099B2652b2b` | WETH/wstDIEM pool |
| Morpho Blue | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` | Leverage markets |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | Adapter settlement |

## Deployer & Governance

| Role | Address | 1Password |
|------|---------|---------|
| Safe (owner) | `0x872c561f699B42977c093F0eD8b4C9a431280c6c` | SK1: `liq-safe-signer-1` (mog.capital), SK2: `liq-safe-signer-2` (Personal) |
| Deployer v5 | `0x10900528c57BBCe07C223B25Ae9bB66966274b5D` | `el4qwixmdot757dpxcqgfo43qe` (mog.capital) |
| veniceSigner | `0x10900528c57BBCe07C223B25Ae9bB66966274b5D` | Same as deployer v5 — rotate to Privy wallet before production |

## Old Vault (v4 — withdrawals pending July 1)

| Contract | Address | Status |
|----------|---------|--------|
| InferenceVault v4 | `0x4751BA2b09374C1929FC01734a166e3c8cd75810` | Withdrawals unlock 2026-07-01 03:32 UTC (MOG-520) |
