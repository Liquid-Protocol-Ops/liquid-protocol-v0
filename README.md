# Liquid Protocol

Smart contracts for the Liquid Protocol token deployment system on Base, forked from Clanker v4.

## Overview

Liquid Protocol is a token factory that deploys ERC-20 tokens paired with Uniswap V4 liquidity pools on Base. It supports configurable LP fee strategies, MEV protection at launch, and pre-launch token distribution via a modular extension system.

This repository also contains a second subsystem — the **[wstDIEM Vault](#wstdiem-vault-base-mainnet)** (`src/vault/`): an ERC-4626 liquid-staking wrapper for [Venice AI](https://venice.ai)'s DIEM, with inference-revenue yield, Curve / Uniswap v4 liquidity, and Morpho leverage markets.

## Deployed Contracts (Base Mainnet)

### Core
| Contract | Address |
|----------|---------|
| Liquid (Factory) | [`0x04F1a284168743759BE6554f607a10CEBdB77760`](https://basescan.org/address/0x04F1a284168743759BE6554f607a10CEBdB77760) |
| LiquidFeeLocker | [`0xF7d3BE3FC0de76fA5550C29A8F6fa53667B876FF`](https://basescan.org/address/0xF7d3BE3FC0de76fA5550C29A8F6fa53667B876FF) |
| LiquidPoolExtensionAllowlist | [`0xb614167d79aDBaA9BA35d05fE1d5542d7316Ccaa`](https://basescan.org/address/0xb614167d79aDBaA9BA35d05fE1d5542d7316Ccaa) |

### Hooks (Uniswap V4)
| Contract | Address |
|----------|---------|
| LiquidHookDynamicFeeV2 | [`0x80E2F7dC8C2C880BbC4BDF80A5Fb0eB8B1DB68CC`](https://basescan.org/address/0x80E2F7dC8C2C880BbC4BDF80A5Fb0eB8B1DB68CC) |
| LiquidHookStaticFeeV2 | [`0x9811f10Cd549c754Fa9E5785989c422A762c28cc`](https://basescan.org/address/0x9811f10Cd549c754Fa9E5785989c422A762c28cc) |

### Extensions
| Contract | Address |
|----------|---------|
| LiquidAirdropV2 | [`0x1423974d48f525462f1c087cBFdCC20BDBc33CdD`](https://basescan.org/address/0x1423974d48f525462f1c087cBFdCC20BDBc33CdD) |
| LiquidVault | [`0xdFCCC93257c20519A9005A2281CFBdF84836d50E`](https://basescan.org/address/0xdFCCC93257c20519A9005A2281CFBdF84836d50E) |
| LiquidUniv4EthDevBuy | [`0x5934097864dC487D21A7B4e4EEe201A39ceF728D`](https://basescan.org/address/0x5934097864dC487D21A7B4e4EEe201A39ceF728D) |
| LiquidUniv3EthDevBuy | [`0x376028cfb6b9A120E24Aa14c3FAc4205179c0025`](https://basescan.org/address/0x376028cfb6b9A120E24Aa14c3FAc4205179c0025) |
| LiquidPresaleEthToCreator | [`0x3bca63EcB49d5f917092d10fA879Fdb422740163`](https://basescan.org/address/0x3bca63EcB49d5f917092d10fA879Fdb422740163) |
| LiquidPresaleAllowlist | [`0xCBb4ccC4B94E23233c14759f4F9629F7dD01f10B`](https://basescan.org/address/0xCBb4ccC4B94E23233c14759f4F9629F7dD01f10B) |

### LP Lockers
| Contract | Address |
|----------|---------|
| LiquidLpLockerFeeConversion | [`0x77247fCD1d5e34A3703AcA898A591Dc7422435f3`](https://basescan.org/address/0x77247fCD1d5e34A3703AcA898A591Dc7422435f3) |

### MEV Modules
| Contract | Address |
|----------|---------|
| LiquidSniperAuctionV2 | [`0x187e8627c02c58F31831953C1268e157d3BfCefd`](https://basescan.org/address/0x187e8627c02c58F31831953C1268e157d3BfCefd) |
| LiquidMevDescendingFees | [`0x8D6B080e48756A99F3893491D556B5d6907b6910`](https://basescan.org/address/0x8D6B080e48756A99F3893491D556B5d6907b6910) |
| LiquidSniperUtilV2 | [`0x2B6cd5Be183c388Dd0074d53c52317df1414cd9f`](https://basescan.org/address/0x2B6cd5Be183c388Dd0074d53c52317df1414cd9f) |

### External Dependencies
| Contract | Address |
|----------|---------|
| Uniswap V4 Pool Manager | [`0x498581fF718922c3f8e6A244956aF099B2652b2b`](https://basescan.org/address/0x498581fF718922c3f8e6A244956aF099B2652b2b) |
| WETH | [`0x4200000000000000000000000000000000000006`](https://basescan.org/address/0x4200000000000000000000000000000000000006) |
| Universal Router | [`0x6fF5693b99212Da76ad316178A184AB56D299b43`](https://basescan.org/address/0x6fF5693b99212Da76ad316178A184AB56D299b43) |
| Permit2 | [`0x000000000022D473030F116dDEE9F6B43aC78BA3`](https://basescan.org/address/0x000000000022D473030F116dDEE9F6B43aC78BA3) |

**Owner (Gnosis Safe):** [`0x872c561f699B42977c093F0eD8b4C9a431280c6c`](https://basescan.org/address/0x872c561f699B42977c093F0eD8b4C9a431280c6c)

All contracts are verified on Basescan with explicit Liquid Protocol source code.

## Contract Architecture

### Core
| Contract | Description |
|----------|-------------|
| `Liquid` | Token factory — orchestrates deployment, pool init, and module coordination |
| `LiquidToken` | ERC-20 token (+ Permit, Votes, Burnable, IERC7802 cross-chain) — 100B fixed supply |
| `LiquidFeeLocker` | Escrow for LP fees with per-depositor allowlist |
| `LiquidDeployer` | CREATE2 deterministic token deployer |
| `OwnerAdmins` | Owner + admin access control used by the factory |

### Hooks (Uniswap V4)
| Contract | Description |
|----------|-------------|
| `LiquidHookV2` | Base hook — pool init, swap callbacks, MEV module coordination |
| `LiquidHookDynamicFeeV2` | Dynamic LP fee strategy |
| `LiquidHookStaticFeeV2` | Static LP fee strategy |
| `LiquidPoolExtensionAllowlist` | Per-pool extension allowlist management |

### LP Lockers
| Contract | Description |
|----------|-------------|
| `LiquidLpLockerFeeConversion` | Locks liquidity, manages reward recipients and fee distribution |

### Extensions
| Contract | Description |
|----------|-------------|
| `LiquidAirdropV2` | Merkle-based airdrop with mutable root and admin controls |
| `LiquidVault` | Lock tokens for later release |
| `LiquidUniv4EthDevBuy` | Dev buy from Uniswap V4 pool at launch |
| `LiquidUniv3EthDevBuy` | Dev buy from Uniswap V3 pool at launch |
| `LiquidPresaleAllowlist` | Allowlist-gated presale |
| `LiquidPresaleEthToCreator` | Presale with ETH forwarded to creator |

### MEV Modules
| Contract | Description |
|----------|-------------|
| `LiquidSniperAuctionV2` | Auction-based sniper protection with descending fees |
| `LiquidMevDescendingFees` | Parabolic fee decay (up to 80% initial, max 2 min) |
| `LiquidSniperUtilV2` | Utility for interacting with sniper auctions |

## wstDIEM Vault (Base Mainnet)

A second subsystem in this repo (`src/vault/`): an ERC-4626 wrapper for staked DIEM from [Venice AI](https://venice.ai). Depositing DIEM stakes it on Venice (`DIEM.stake()`) and mints **wstDIEM** — a liquid, transferable, yield-bearing token. The vault monetizes its Venice inference budget by selling it on Surplus and compounds the proceeds back in (`creditDIEM()`), so the wstDIEM/DIEM exchange rate is a one-way ratchet. wstDIEM stays composable across Curve, Uniswap v4, and Morpho.

### Core (v6 — live)
| Contract | Address |
|----------|---------|
| InferenceVault (wstDIEM) | [`0xe49FA849cB37b0e7A42B2335e333fb99474167ba`](https://basescan.org/address/0xe49FA849cB37b0e7A42B2335e333fb99474167ba) |
| Router | [`0x74ad4532133Ba538945a5371D249560E66CC7c71`](https://basescan.org/address/0x74ad4532133Ba538945a5371D249560E66CC7c71) |
| FeeRouter | [`0xa13a6e75d696bAceB38236389eeFD6eCa5FD4ED3`](https://basescan.org/address/0xa13a6e75d696bAceB38236389eeFD6eCa5FD4ED3) |
| WstDIEMHook (V4 dynamic fee) | [`0xf010A31BBD4B501b4232b1945EC18584Ff9B5080`](https://basescan.org/address/0xf010A31BBD4B501b4232b1945EC18584Ff9B5080) |
| LiquidityManager (Safe-controlled V4 LP) | [`0xbA4129d3718f32Ed48343d40CfAf6Be9096D086b`](https://basescan.org/address/0xbA4129d3718f32Ed48343d40CfAf6Be9096D086b) |
| AgentTGERegistry | [`0xb13830e7f72Eef167A7F188285feBa5f7C1198Ef`](https://basescan.org/address/0xb13830e7f72Eef167A7F188285feBa5f7C1198Ef) |
| SurplusStakingWrapper | [`0x1A74750eb49c2f6C8C44B9eadaE5C55C7941F271`](https://basescan.org/address/0x1A74750eb49c2f6C8C44B9eadaE5C55C7941F271) |
| InferenceProduct | [`0xE43c4B1930531360c3924F72e9395e9c5bC4a5F3`](https://basescan.org/address/0xE43c4B1930531360c3924F72e9395e9c5bC4a5F3) |

### Oracles (Morpho)
| Contract | Address |
|----------|---------|
| WstDiemDiemOracle (vault NAV — 86% LLTV market) | [`0xAF29776f93FE0bf21282bF792A52AC212f20F45c`](https://basescan.org/address/0xAF29776f93FE0bf21282bF792A52AC212f20F45c) |
| WstDiemVvvOracle (on-chain TWAP — 62.5% LLTV market) | [`0x9E982637f26aAaAd0bfDBe3c6c1846120C4E5A62`](https://basescan.org/address/0x9E982637f26aAaAd0bfDBe3c6c1846120C4E5A62) |

### Venue Adapters
| Contract | Address |
|----------|---------|
| AntSeedAdapter | [`0xed98A5f4F3AcFd0752A81FDd03DD28b7A44A18b7`](https://basescan.org/address/0xed98A5f4F3AcFd0752A81FDd03DD28b7A44A18b7) |
| SurplusAdapter | [`0x91b3E39Ef6335D97876AdB4448A998c7cbD3885F`](https://basescan.org/address/0x91b3E39Ef6335D97876AdB4448A998c7cbD3885F) |

### Liquidity & Lending
| Venue | Address / Market |
|-------|------------------|
| Curve DIEM/wstDIEM (StableSwap-NG) | [`0x21c33a1Bb5f6Eb43563e1fB9e7AA1D4E90C1A0CD`](https://basescan.org/address/0x21c33a1Bb5f6Eb43563e1fB9e7AA1D4E90C1A0CD) |
| Uniswap v4 wstDIEM/WETH (dynamic fee) | PoolManager `0x498581fF…`, hook `0xf010…5080`, tickSpacing 60 |
| Morpho wstDIEM/DIEM (86% LLTV) | [market `0xdd6b9f10…`](https://app.morpho.org/base/market/0xdd6b9f10bf69445ebba0626ef54042af628cdf65dda98ff68df4d235d4d56c76) |
| Morpho wstDIEM/VVV (62.5% LLTV) | oracle `0x9E98…` — created, unseeded |

### External Dependencies
| Protocol | Address |
|----------|---------|
| DIEM token (Venice) | [`0xF4d97F2da56e8c3098f3a8D538DB630A2606a024`](https://basescan.org/address/0xF4d97F2da56e8c3098f3a8D538DB630A2606a024) |
| VVV token (liquid ERC-20) | [`0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf`](https://basescan.org/address/0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf) |
| VVV staking → sVVV | [`0x321b7ff75154472B18EDb199033fF4D116F340Ff`](https://basescan.org/address/0x321b7ff75154472B18EDb199033fF4D116F340Ff) |
| Morpho Blue | [`0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb`](https://basescan.org/address/0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb) |
| Uniswap V4 PoolManager | [`0x498581fF718922c3f8e6A244956aF099B2652b2b`](https://basescan.org/address/0x498581fF718922c3f8e6A244956aF099B2652b2b) |
| Uniswap V3 SwapRouter02 | [`0x2626664c2603336E57B271c5C0b26F421741e481`](https://basescan.org/address/0x2626664c2603336E57B271c5C0b26F421741e481) |

**Owner (Gnosis Safe):** [`0x872c561f699B42977c093F0eD8b4C9a431280c6c`](https://basescan.org/address/0x872c561f699B42977c093F0eD8b4C9a431280c6c) · **Treasury (Splits):** [`0x2AfE303f4AbD285631872c5A971e5D32fBF1E087`](https://basescan.org/address/0x2AfE303f4AbD285631872c5A971e5D32fBF1E087)

### Vault Architecture (`src/vault/`)
| Contract | Description |
|----------|-------------|
| `InferenceVault` | ERC-4626 vault. Deposit DIEM → `DIEM.stake()` → mint wstDIEM. `creditDIEM()` accrues yield non-dilutively. Withdrawals are async via a redeem queue — `requestRedeem` enters a batch (~1-day open window), then a ~24h Venice unstake cooldown, then `claimRedeem` (~2 days total). |
| `Router` | Multi-path entry/exit: `depositWETH` (WETH→DIEM→vault), `depositVVV` (VVV→sVVV→DIEM→vault), `exitToWETH` (wstDIEM→WETH via V4), plus single-tx flash-loan leverage (`loopDeposit` / `unloopDeposit`). |
| `FeeRouter` | Aggregates protocol fee income (WETH / USDC / VVV / wstDIEM); routes per a configurable per-token `FeeMode`. |
| `adapters/` | Venue adapters (`BaseInferenceAdapter` + AntSeed / Surplus / X402). Each receives inference-settlement USDC, swaps to DIEM, and calls `creditDIEM()`. |
| `oracles/` | Morpho price oracles. `WstDiemVvvOracle` is fully on-chain (`convertToAssets()` × Aerodrome DIEM/VVV TWAP); `WstDiemDiemOracle` prices the wstDIEM/DIEM leverage market off the vault NAV. |
| `WstDIEMHook` | Uniswap v4 dynamic-fee hook for the wstDIEM/WETH pool. |
| `LiquidityManager` | Safe-owned manager for the wstDIEM/WETH v4 LP position. |
| `AgentTGERegistry` | Tracks agent lifecycle (Bronze/Silver/Gold tiers, 30-day dormancy). |
| `InferenceProduct` | On-chain registry + USDC settlement for selling Venice inference capacity. |
| `SurplusStakingWrapper` | Thin user-deposit wrapper with referral tracking. |

> **Security — the vault is new and unaudited.** Unlike the Liquid Protocol launchpad above (an audited Clanker v4 fork), `src/vault/**` is original code. An agent-driven review ([`docs/vault/SECURITY_REVIEW.md`](docs/vault/SECURITY_REVIEW.md)) surfaced **1 High + 2 Medium**; see that report for per-finding deployed status. A third-party audit is recommended before large external TVL.

## Building

```bash
git submodule update --init --recursive
forge build
forge test
```

Compiler: Solidity 0.8.28, viaIR, optimizer 20,000 runs, EVM target Cancun.

## Documentation

- [Extension Allowlist Process](EXTENSION-ALLOWLIST.md) — how extensions are reviewed, approved, and managed

## Security

This codebase is forked from [Clanker v4](https://github.com/clanker-devco/v4-contracts), which has been audited by:

- **0xMacro** — [Clanker A-3 Audit Report](https://0xmacro.com/library/audits/clanker-3) (covers hooks, extensions, MEV modules, fee locker, LP locker)
  - [macro_v4_audit_1.pdf](https://github.com/clanker-devco/v4-contracts/blob/main/audits/macro_v4_audit_1.pdf)
  - [macro_v4_audit_2.pdf](https://github.com/clanker-devco/v4-contracts/blob/main/audits/macro_v4_audit_2.pdf)
- **Cantina** — [clanker-contracts portfolio](https://cantina.xyz/portfolio/e4db23cd-f46d-4d99-adca-a60941b44f65)
  - [cantina_v4_audit_1.pdf](https://github.com/clanker-devco/v4-contracts/blob/main/audits/cantina_v4_audit_1.pdf)

The Liquid Protocol fork renames `Clanker*` to `Liquid*` and deploys under its own factory, but the core hook, locker, and extension logic is architecturally identical to the audited codebase. All contracts are verified on Basescan.

## Attribution

Forked from [Clanker v4](https://github.com/clanker-devco/v4-contracts) by Clanker Devco. The original contracts are licensed under MIT (per SPDX headers). Deprecated v4.0 contracts have been removed and all references rebranded to Liquid Protocol.

## License

MIT -- see [LICENSE](./LICENSE).
