# CLAUDE.md

## Project Overview

Liquid Protocol V0 — Solidity smart contracts for the Liquid Protocol on Base mainnet. Forked from Clanker V4.1. Deploys ERC-20 tokens with permanent Uniswap V4 LP, MEV protection, and fee splits.

## Build & Test

- `forge install` — install dependencies (git submodules)
- `forge build` — compile contracts
- `forge test` — run tests
- `forge test -vvvv` — run tests with full traces
- `forge fmt` — format Solidity code
- `forge fmt --check` — check formatting without modifying

## Stack

- Solidity 0.8.28, Foundry (forge/cast/anvil)
- EVM target: Cancun
- Optimizer: 20,000 runs, viaIR enabled
- Dependencies: OpenZeppelin, Uniswap V4 Core/Periphery, Permit2

## Source Structure

- `src/Liquid.sol` — core factory/deployer
- `src/LiquidFeeLocker.sol` — LP locking and fee collection
- `src/LiquidToken.sol` — ERC-20 token template
- `src/extensions/` — optional deployment extensions (presale, airdrop, vault, dev buy)
- `src/hooks/` — Uniswap V4 hooks (static fee, dynamic fee)
- `src/mev-modules/` — MEV protection modules
- `src/lp-lockers/` — LP position lockers
- `broadcast/` — deployment scripts
- `audits/` — audit reports (Cantina, Macro)

## Deployed Addresses (Base Mainnet)

See the ops repo for canonical addresses. Do NOT use addresses from the Clanker fork.
