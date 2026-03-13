# Liquid Protocol

Smart contracts for the Liquid Protocol token deployment system, forked from Clanker v4.

## Overview

Liquid Protocol is a token factory that deploys ERC-20 tokens paired with Uniswap V4 liquidity pools on Base. It supports configurable LP fee strategies, MEV protection at launch, and pre-launch token distribution via a modular extension system.

## Usage

Token deployers call `Liquid::deployToken()` to deploy tokens with configurable:
- Static or dynamic fee Uniswap V4 pools via custom hooks
- LP reward splitting between multiple recipients
- Multiple initial liquidity positions with custom tick ranges
- Dev buys from the pool during token launch
- Token vaulting, airdrops, and presale mechanisms via extensions
- MEV protection via sniper auctions and descending fee curves

## Contracts

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

### Interfaces
| Interface | For |
|-----------|-----|
| `ILiquid` | Liquid |
| `ILiquidExtension` | Extension base |
| `ILiquidFeeLocker` | LiquidFeeLocker |
| `ILiquidHook` | Hook base (v1 compat) |
| `ILiquidHookV2` | LiquidHookV2 |
| `ILiquidHookDynamicFee` | LiquidHookDynamicFeeV2 |
| `ILiquidHookStaticFee` | LiquidHookStaticFeeV2 |
| `ILiquidHookV2PoolExtension` | Pool extension callbacks |
| `ILiquidPoolExtensionAllowlist` | Extension allowlist |
| `ILiquidLPLocker` | LP locker base |
| `ILiquidLpLockerMultiple` | Multi-position locker base |
| `ILiquidLpLockerFeeConversion` | Fee conversion locker |
| `ILiquidMevModule` | MEV module base |
| `ILiquidMevDescendingFees` | Descending fees config |
| `ILiquidSniperAuctionV0` | Sniper auction interface |
| `ILiquidAirdropV2` | AirdropV2 |
| `ILiquidVault` | Vault |
| `ILiquidUniv4EthDevBuy` | V4 dev buy |
| `ILiquidUniv3EthDevBuy` | V3 dev buy |
| `ILiquidPresaleAllowlist` | Presale allowlist |
| `ILiquidPresaleEthToCreator` | Presale ETH-to-creator |

## Building

```bash
git submodule update --init --recursive
forge build
forge test
```

## Attribution

This project is forked from [Clanker v4](https://github.com/clanker-devco/v4-contracts) by Clanker Devco. The original contracts are licensed under MIT (per SPDX headers). Deprecated v4.0 contracts have been removed and all references have been rebranded to Liquid Protocol.

## License

MIT -- see [LICENSE](./LICENSE).
