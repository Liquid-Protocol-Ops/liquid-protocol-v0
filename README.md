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
