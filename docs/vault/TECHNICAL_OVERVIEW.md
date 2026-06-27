# wstDIEM — Contract Reference

**Brief overview.** wstDIEM is an ERC-4626 vault that wraps staked DIEM (Venice AI's staking token — 1 staked DIEM = $1/day of inference in perpetuity). Deposit DIEM → vault stakes it on Venice → mint wstDIEM. Inference and protocol revenue (USDC/WETH) is swapped back into DIEM and credited to the vault, raising the wstDIEM→DIEM exchange rate for all holders (wstETH model). Withdrawals are async via a redeem queue (~2 days). v6 is **LIVE on Base mainnet** (chain 8453); lending markets are created but unseeded.

- **Source:** [`src/vault/`](../../src/vault/) · **Deploy scripts:** [`script/vault/`](../../script/vault/) · **Live addresses:** [`mainnet-addresses.md`](./mainnet-addresses.md)
- Solidity 0.8.28, viaIR, 20k optimizer runs, Cancun. Owner = Safe `0x872c561f699B42977c093F0eD8b4C9a431280c6c`.

---

## Contracts

| Contract | Code | Deployed by | Live address (v6) | Role |
|----------|------|-------------|-------------------|------|
| **InferenceVault** | [`InferenceVault.sol`](../../src/vault/InferenceVault.sol) | [`DeployV6.s.sol`](../../script/vault/DeployV6.s.sol) | `0xe49FA849cB37b0e7A42B2335e333fb99474167ba` | ERC-4626 vault + wstDIEM token; staking, `creditDIEM`, async redeem queue, ERC-1271 |
| **Router** | [`Router.sol`](../../src/vault/Router.sol) | [`DeployV6.s.sol`](../../script/vault/DeployV6.s.sol) / [`DeployRouter.s.sol`](../../script/vault/DeployRouter.s.sol) | `0x74ad4532133Ba538945a5371D249560E66CC7c71` | WETH/VVV deposit paths, `exitToWETH`, Morpho leverage loop |
| **FeeRouter** | [`FeeRouter.sol`](../../src/vault/FeeRouter.sol) | [`DeployV6.s.sol`](../../script/vault/DeployV6.s.sol) | `0xa13a6e75d696bAceB38236389eeFD6eCa5FD4ED3` | Aggregates protocol fees, routes per-token to vault/Curve |
| **SurplusStakingWrapper** | [`SurplusStakingWrapper.sol`](../../src/vault/SurplusStakingWrapper.sol) | [`DeployV6.s.sol`](../../script/vault/DeployV6.s.sol) | `0x1A74750eb49c2f6C8C44B9eadaE5C55C7941F271` | Deposit wrapper with referral tracking + sync Curve exit |
| **AgentTGERegistry** | [`AgentTGERegistry.sol`](../../src/vault/AgentTGERegistry.sol) | [`DeployV6.s.sol`](../../script/vault/DeployV6.s.sol) | `0xb13830e7f72Eef167A7F188285feBa5f7C1198Ef` | Agent tiers (Bronze/Silver/Gold) + 30-day dormancy |
| **InferenceProduct** | [`InferenceProduct.sol`](../../src/vault/InferenceProduct.sol) | [`DeployV6.s.sol`](../../script/vault/DeployV6.s.sol) | `0xE43c4B1930531360c3924F72e9395e9c5bC4a5F3` | Capacity ledger; sells inference (USDC) → FeeRouter |
| **WstDIEMHook** | [`WstDIEMHook.sol`](../../src/vault/WstDIEMHook.sol) | [`DeployWstDiemHook.s.sol`](../../script/vault/DeployWstDiemHook.s.sol) (and `DeployV6`) | `0xf010A31BBD4B501b4232b1945EC18584Ff9B5080` | Uniswap V4 dynamic-fee hook for wstDIEM/WETH pool (flat 5 bps today) |
| **LiquidityManager** | [`LiquidityManager.sol`](../../src/vault/LiquidityManager.sol) | [`DeployV6.s.sol`](../../script/vault/DeployV6.s.sol) | `0xbA4129d3718f32Ed48343d40CfAf6Be9096D086b` | Safe-owned V4 LP position manager (add/remove/collect) |

### Adapters (`src/vault/adapters/`)

| Contract | Code | Deployed by | Live address (v6) | Role |
|----------|------|-------------|-------------------|------|
| **BaseInferenceAdapter** | [`BaseInferenceAdapter.sol`](../../src/vault/adapters/BaseInferenceAdapter.sol) | — (abstract) | — | Shared `receiveSettlement` + `routeYield(minDiemOut)` logic (USDC→WETH→DIEM, 90/10 split) |
| **AntSeedAdapter** | [`AntSeedAdapter.sol`](../../src/vault/adapters/AntSeedAdapter.sol) | [`DeployV6Adapters.s.sol`](../../script/vault/DeployV6Adapters.s.sol) | `0xed98A5f4F3AcFd0752A81FDd03DD28b7A44A18b7` | AntSeed venue settlement |
| **SurplusAdapter** | [`SurplusAdapter.sol`](../../src/vault/adapters/SurplusAdapter.sol) | [`DeployV6Adapters.s.sol`](../../script/vault/DeployV6Adapters.s.sol) | `0x91b3E39Ef6335D97876AdB4448A998c7cbD3885F` | Surplus Intelligence venue settlement |
| **X402Adapter** | [`X402Adapter.sol`](../../src/vault/adapters/X402Adapter.sol) | [`DeployV6Adapters.s.sol`](../../script/vault/DeployV6Adapters.s.sol) | _not deployed for v6 (v5 only)_ | X402 micropayment settlement |

### Oracles (`src/vault/oracles/`)

| Contract | Code | Deployed by | Live address (v6) | Role |
|----------|------|-------------|-------------------|------|
| **WstDiemVvvOracle** | [`WstDiemVvvOracle.sol`](../../src/vault/oracles/WstDiemVvvOracle.sol) | [`DeployV6.s.sol`](../../script/vault/DeployV6.s.sol) | `0x9E982637f26aAaAd0bfDBe3c6c1846120C4E5A62` | **Canonical** Morpho oracle (vault rate × Aerodrome DIEM/VVV TWAP, fully on-chain) |
| **WstDiemDiemOracle** | _inline in [`DeployV6.s.sol`](../../script/vault/DeployV6.s.sol) (L80)_ | [`DeployV6.s.sol`](../../script/vault/DeployV6.s.sol) | `0xAF29776f93FE0bf21282bF792A52AC212f20F45c` | wstDIEM/DIEM leverage-loop oracle (uses vault rate directly) |
| **WstDiemUsdcOracle** | [`WstDiemUsdcOracle.sol`](../../src/vault/oracles/WstDiemUsdcOracle.sol) | — | **DEPRECATED** | Hardcodes DIEM=$1 — do not use (MOG-542/549) |
| **WstDiemWethOracle** | [`WstDiemWethOracle.sol`](../../src/vault/oracles/WstDiemWethOracle.sol) | — | **DEPRECATED** | Hardcodes DIEM=$1 — do not use (MOG-542/549) |

### Interfaces (`src/vault/interfaces/`)

[`IInferenceVault.sol`](../../src/vault/interfaces/IInferenceVault.sol) · [`IFeeRouter.sol`](../../src/vault/interfaces/IFeeRouter.sol) · [`IInferenceToken.sol`](../../src/vault/interfaces/IInferenceToken.sol) · [`IAgentTGERegistry.sol`](../../src/vault/interfaces/IAgentTGERegistry.sol)

---

## Deployment scripts (`script/vault/`)

**Primary (v6):**

| Script | Purpose |
|--------|---------|
| [`DeployV6.s.sol`](../../script/vault/DeployV6.s.sol) | **Full v6 stack** — vault, Router, FeeRouter, hook, oracles, LiquidityManager, registry, wrapper, InferenceProduct |
| [`DeployV6Adapters.s.sol`](../../script/vault/DeployV6Adapters.s.sol) | AntSeed + Surplus adapters (MOG-541 `routeYield(minDiemOut)` fix) |
| [`DeployWstDiemHook.s.sol`](../../script/vault/DeployWstDiemHook.s.sol) | Standalone V4 hook (CREATE2 salt-mined to address low bits `0x1080`) |
| [`DeployVvvMarket.s.sol`](../../script/vault/DeployVvvMarket.s.sol) | wstDIEM/VVV Morpho market + oracle |
| [`DeployCurvePool.s.sol`](../../script/vault/DeployCurvePool.s.sol) | DIEM/wstDIEM Curve StableSwap pool |
| [`InitV4Pool.s.sol`](../../script/vault/InitV4Pool.s.sol) / [`InitPools.s.sol`](../../script/vault/InitPools.s.sol) | Initialize V4 pool + seed pools |

**Owner-only (Safe, via [`SafeBatch.s.sol`](../../script/vault/SafeBatch.s.sol) signing pattern):** `SafeAddV4LP`, `SafeManageV4LP`, `SafeKeeperSetup`, `SafeSeedCapital`, `SafeEnableWithdrawals`, `SafeRetireOldAdapters`, `SafeAddSurplusChannel`, … (full list in [`script/vault/`](../../script/vault/)).

**Keeper:** [`KeeperRelay.s.sol`](../../script/vault/KeeperRelay.s.sol) — pushes settlement USDC into adapters and calls `routeYield`. See [`KEEPER_RUNBOOK.md`](./KEEPER_RUNBOOK.md).

**Legacy / variants:** [`DeployAll.s.sol`](../../script/vault/DeployAll.s.sol) (v4-era full deploy), [`DeployRouter.s.sol`](../../script/vault/DeployRouter.s.sol) (standalone Router redeploy), [`DeployMorphoMarket.s.sol`](../../script/vault/DeployMorphoMarket.s.sol) / [`DeployMorphoMarketsV2.s.sol`](../../script/vault/DeployMorphoMarketsV2.s.sol) / [`CreateMorphoMarket75.s.sol`](../../script/vault/CreateMorphoMarket75.s.sol), [`DeployAndWireAdapters.s.sol`](../../script/vault/DeployAndWireAdapters.s.sol), [`ConfigureRouterV4.s.sol`](../../script/vault/ConfigureRouterV4.s.sol), [`ComputePoolId.s.sol`](../../script/vault/ComputePoolId.s.sol).

---

## More docs

[`mainnet-addresses.md`](./mainnet-addresses.md) (canonical addresses) · [`SYSTEM_OVERVIEW.md`](./SYSTEM_OVERVIEW.md) · [`wstdiem-economics.md`](./wstdiem-economics.md) · [`DEPOSIT_GUIDE.md`](./DEPOSIT_GUIDE.md) · [`KEEPER_RUNBOOK.md`](./KEEPER_RUNBOOK.md) · [`SECURITY_REVIEW.md`](./SECURITY_REVIEW.md) · [`V6_DEPLOY_RUNBOOK.md`](./V6_DEPLOY_RUNBOOK.md)
