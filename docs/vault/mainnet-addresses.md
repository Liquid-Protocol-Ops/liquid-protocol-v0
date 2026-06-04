# wstDIEM Liquid Inference Vault — Base Mainnet Addresses

**Last updated:** 2026-06-02 (v4 — new deployer v3)
**Chain:** Base mainnet (chain 8453)
**Owner (Safe):** `0x872c561f699B42977c093F0eD8b4C9a431280c6c`
**Treasury:** `0x872c561f699B42977c093F0eD8b4C9a431280c6c`
**Deployer v3:** `0x66205fdA77114A5357E7bDcac6dDb356cfF0063b` (1P: `jq4xbffwt3m6nrfn6ompar6nzm` in `base` vault, field `password`)

---

## ACTIVE CONTRACTS — use these

| Contract | Address | Basescan |
|----------|---------|---------|
| `InferenceVault` (wstDIEM) | `0x4751BA2b09374C1929FC01734a166e3c8cd75810` | [view](https://basescan.org/address/0x4751BA2b09374C1929FC01734a166e3c8cd75810) |
| `FeeRouter` | `0x21fe048B10dC9bED2Ee0Ae76724C627CA7F35F61` | [view](https://basescan.org/address/0x21fe048B10dC9bED2Ee0Ae76724C627CA7F35F61) |
| `Router` v8 | `0x6f5FF03a91cb1703B7CB8d85572f990bcB04273D` | [view](https://basescan.org/address/0x6f5FF03a91cb1703B7CB8d85572f990bcB04273D) |
| `AgentTGERegistry` | `0x49be7fE8D661b892AC0461818a5C714574e83998` | [view](https://basescan.org/address/0x49be7fE8D661b892AC0461818a5C714574e83998) |
| `SurplusStakingWrapper` | `0xB0f9c45dAacD89F0d90cbE0E65d0dA20fa1ac415` | [view](https://basescan.org/address/0xB0f9c45dAacD89F0d90cbE0E65d0dA20fa1ac415) |
| `InferenceProduct` | `0x9b7d8B23cb223F75F5F1Ead25f12205940960F62` | [view](https://basescan.org/address/0x9b7d8B23cb223F75F5F1Ead25f12205940960F62) |
| Curve DIEM/wstDIEM | `0x39A4b4779C71E1A18d500627639682c9583Ee86f` | [view](https://basescan.org/address/0x39A4b4779C71E1A18d500627639682c9583Ee86f) |
| Morpho oracle | see `broadcast/DeployAll.s.sol/8453/run-latest.json` | — |

## V4 wstDIEM/WETH Pool

| Field | Value |
|-------|-------|
| PoolManager | `0x498581fF718922c3f8e6A244956aF099B2652b2b` |
| **currency0** | **WETH** `0x4200000000000000000000000000000000000006` (lower address) |
| **currency1** | **wstDIEM** `0x4751BA2b09374C1929FC01734a166e3c8cd75810` |
| fee | 0.3% (3000) |
| tickSpacing | 60 |
| tickLower | 62160 |
| tickUpper | 92100 |
| `wethIsCurrency0` | `true` — WETH is currency0 in v4 deployment |

> **Important:** In v4, WETH (`0x4200...`) < wstDIEM (`0x4751...`), so WETH is currency0 and wstDIEM is currency1. This is the **opposite of the v3 deployment** (vault `0x3394...` where wstDIEM was currency0). The Router `wethIsCurrency0` immutable is `true`.

## DEPRECATED v3 Contracts — do not use

| Contract | Address |
|----------|---------|
| `InferenceVault` v3 | `0x3394898b648385FAd4FE847c52B5E4CCe0D63662` |
| `FeeRouter` v3 | `0x33B218bd86046AAd25c209B1d7Adb7e8A6648387` |
| `Router` v7 | `0xA92EF6a90058f52556e74504324D28D7EC8d49a2` |
| `AgentTGERegistry` v3 | `0xcD30D20a8053f9B0abe408CB1c7e6cFDff3c0D83` |
| `SurplusStakingWrapper` v3 | `0x3bcfc3AFEEe1F3077fD15c9FBE9FDaD13e47a283` |
| Curve DIEM/wstDIEM v3 | `0x01773049bA5c5cEF28072e5c071a629b4dee555c` |

## Morpho Markets

| Market | LLTV | Collateral | Market ID |
|--------|------|-----------|-----------|
| **Active** | **38.5%** | wstDIEM v3 (`0x3394...`) | (from createMarket tx) |

**Shared params:** loan=DIEM, oracle=`0xE762e8...`, IRM=`0x464159...`

## External Tokens & Protocols

| Token/Contract | Address |
|----------------|---------|
| DIEM (Venice staking) | `0xF4d97F2da56e8c3098f3a8D538DB630A2606a024` |
| VVV | `0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf` |
| sVVV / VVV staking | `0x321b7ff75154472B18EDb199033fF4D116F340Ff` |
| WETH | `0x4200000000000000000000000000000000000006` |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Morpho Blue | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` |
| Uniswap V3 SwapRouter02 | `0x2626664c2603336E57B271c5C0b26F421741e481` |
| Uniswap V4 PoolManager | `0x498581fF718922c3f8e6A244956aF099B2652b2b` |
| WETH/DIEM V3 pool (1%) | `0x80d995189ecc593672aD4703b250a5e82672EB1D` |
| WETH/VVV V3 pool (0.3%) | `0x8eaF39189c73819D3949cAB2b1a7AFCE8e3bA0D9` |

## FeeRouter Income Paths

| Token | Function | Default mode | Effect |
|-------|----------|-------------|--------|
| WETH (protocol fees) | `receiveWETH(amount)` | `CREDIT_VAULT` | WETH→DIEM→creditDIEM |
| USDC (inference revenue) | `receiveUSDC(amount)` | `CREDIT_VAULT` | USDC→WETH→DIEM→creditDIEM |
| VVV (Venice fees) | `receiveVVV(amount)` | `CREDIT_VAULT` | VVV→sVVV→mintDiem→creditDIEM |
| wstDIEM (direct fees) | `receivewstDIEM(amount)` | `CURVE_VOL` | add to Curve VOL |

`harvest()` and `harvestVVV()` are `onlyOwner`.

## DEPRECATED — do not use

All v1 and v2 contracts are deprecated. Key deprecated addresses:

| Contract | Address |
|----------|---------|
| InferenceVault v2 | `0xa6076Ac24f21A9c526d6d32774d66cBB804Cf649` |
| FeeRouter v1 | `0x67fA697Da772052119b289DDCa987b0A90592243` |
| Router v6 | `0xaa266759d6d546b3710D84E99ba49089812dCcBD` |
| All prior Router versions | see git history |

> Full broadcast artifacts: `broadcast/DeployAll.s.sol/8453/run-latest.json`
