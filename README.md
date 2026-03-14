# Liquid Protocol

Smart contracts for the Liquid Protocol token deployment system on Base, forked from Clanker v4.

## Overview

Liquid Protocol is a token factory that deploys ERC-20 tokens paired with Uniswap V4 liquidity pools on Base. It supports configurable LP fee strategies, MEV protection at launch, and pre-launch token distribution via a modular extension system.

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

## Building

```bash
git submodule update --init --recursive
forge build
forge test
```

Compiler: Solidity 0.8.28, viaIR, optimizer 20,000 runs, EVM target Cancun.

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
