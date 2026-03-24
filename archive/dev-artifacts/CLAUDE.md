# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Liquid Protocol smart contracts — a token deployment and liquidity management system on Base, forked from Clanker v4.1. The factory deploys ERC-20 tokens with Uniswap V4 liquidity pools, LP fee management, MEV protection, and pre-launch distribution via a modular plugin architecture. Deprecated v4.0 contracts have been removed; only current v4.1 implementations remain.

## Build & Test Commands

This is a Foundry (Solidity) project.

```bash
forge build              # Compile contracts
forge test               # Run all tests
forge test --match-test testFunctionName  # Run a single test
forge test -vvvv         # Run tests with full trace output
forge fmt                # Format code (line_length=100, tab_width=4, sort_imports)
forge fmt --check        # Check formatting without modifying
```

**Compiler settings:** Solidity 0.8.28, viaIR enabled, optimizer with 20,000 runs, EVM target `cancun`, no CBOR metadata.

## Architecture

### Modular Plugin System

The `Liquid` factory (`src/Liquid.sol`) orchestrates token deployment through four pluggable module types, each with an enable/disable allowlist:

1. **Hooks** (`src/hooks/`) — Uniswap V4 hook contracts that manage pool initialization, swap fees, and MEV module coordination. Two fee strategies:
   - `LiquidHookDynamicFeeV2` — dynamic LP fees
   - `LiquidHookStaticFeeV2` — static LP fees
   - Built on `LiquidHookV2` base with pool extension support via `LiquidPoolExtensionAllowlist`

2. **LP Lockers** (`src/lp-lockers/`) — Lock liquidity and manage reward distribution. Lockers are enabled per-hook (the `enabledLockers` mapping is `locker -> hook -> bool`).
   - `LiquidLpLockerFeeConversion` — manages reward recipients, LP positions, and fee distribution with conversion

3. **Extensions** (`src/extensions/`) — Pre/post-launch token distribution plugins. Up to 10 per deployment, max 90% of supply (9000 bps). Each receives tokens via `receiveTokens()`.
   - `LiquidVault` — lock tokens for later release
   - `LiquidAirdropV2` — merkle-based airdrops with admin controls and mutable merkle root
   - `LiquidUniv4EthDevBuy` / `LiquidUniv3EthDevBuy` — dev buys from pool at launch
   - `LiquidPresaleAllowlist` / `LiquidPresaleEthToCreator` — presale mechanisms

4. **MEV Modules** (`src/mev-modules/`) — Protect pools from MEV during launch. Initialized via the hook after pool creation.
   - `LiquidSniperAuctionV2` — auction-based sniper protection with descending fees
   - `LiquidMevDescendingFees` — parabolic fee decay (up to 80% initial, max 2 min duration)
   - `LiquidSniperUtilV2` — utility for interacting with sniper auctions

### Deployment Flow

`Liquid.deployToken(DeploymentConfig)` executes:
1. Deploy `LiquidToken` via `LiquidDeployer` (CREATE2 with salt)
2. Calculate extension supply split (bps-based)
3. Initialize Uniswap V4 pool via the hook
4. Place liquidity via the locker
5. Trigger extensions (vault, airdrop, dev buy, etc.)
6. Initialize MEV module on the hook

### Key Contracts

- **LiquidToken** (`src/LiquidToken.sol`) — ERC20 + ERC20Permit + ERC20Votes + ERC20Burnable + IERC7802 (superchain cross-chain mint/burn). Fixed 100B supply with 18 decimals.
- **LiquidFeeLocker** (`src/LiquidFeeLocker.sol`) — Escrow for LP fees with per-depositor allowlist.
- **OwnerAdmins** (`src/utils/OwnerAdmins.sol`) — Owner + admin access control pattern used by the factory.

### Dependencies (git submodules in `lib/`)

- forge-std, openzeppelin-contracts, v4-core, v4-periphery, universal-router, permit2, optimism (for IERC7802/Predeploys)

### Remappings

```
@openzeppelin/contracts/ -> lib/openzeppelin-contracts/contracts/
@contracts-bedrock/      -> lib/optimism/packages/contracts-bedrock/
@uniswap/v4-core/        -> lib/v4-core/
@uniswap/v4-periphery/   -> lib/v4-periphery/
@uniswap/universal-router/ -> lib/universal-router/
@uniswap/permit2/        -> lib/permit2/
```

### ABI Reference

`base_mainnet_abis/` contains JSON ABIs for deployed mainnet contracts.
