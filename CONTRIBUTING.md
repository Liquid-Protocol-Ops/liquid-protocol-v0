# Contributing

## Before You Start

- Read the relevant contract code and understand the design.
- Review existing audits in `audits/` for context on security decisions.
- For breaking changes or new extensions, open an issue first for discussion.

## Setup

```bash
git clone --recurse-submodules https://github.com/Liquid-Protocol-Ops/liquid-protocol-v0.git
cd liquid-protocol-v0
forge install
forge build
forge test
```

## PR Requirements

- `forge build` succeeds with no warnings.
- `forge test` passes.
- `forge fmt --check` passes.
- Security-critical changes must be clearly described in the PR.
- New extensions must follow the pattern in `src/extensions/`.

## Security-Critical Paths

Changes to these areas require extra scrutiny:
- `Liquid.sol` — core deployment logic
- `LiquidFeeLocker.sol` — LP locking and fee collection
- `src/hooks/` — Uniswap V4 hook logic
- `src/mev-modules/` — MEV protection
