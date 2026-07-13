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
- `src/vault/oracles/` — Morpho price oracles (see checklist below)

## Oracle Checklist (any new or modified Morpho market/oracle)

A Morpho market's `(loanToken, collateralToken, oracle, irm, lltv)` tuple is **immutable at creation** — there is no upgrade path. Getting an oracle wrong means creating a new market and migrating, not patching the old one. Work through this before writing `createMarket`:

1. **Is any leg of the price a spot price from a pool the protocol can move?** If the protocol (or an entity closely tied to it — a vault, a Splits treasury, a large single depositor) could plausibly be the dominant supplier/borrower on this exact market, do not price that market's own collateral/debt pair off that pool's spot price or a short TWAP on it. Use the vault's own accounting (e.g. `ERC4626.convertToAssets()`) for that leg instead — a redemption-rate oracle, the same pattern Lido's stETH markets use on Aave, and the pattern already used by `WstDiemDiemOracle`.
2. **If an AMM leg is unavoidable** (e.g. the asset genuinely has no other price source, as with DIEM/VVV in `WstDiemVvvOracle`): confirm the leg prices a *different* pair than the market's own collateral/debt pair, use a TWAP (not instantaneous spot) sized so sustaining a manipulated price across the whole window costs more than the position it would unlock, and add a staleness bound that reverts closed (never serves a stale price). Document the manipulation-cost reasoning inline in the oracle's comments — see `WstDiemVvvOracle.sol`'s header for the pattern to follow.
3. **Size the LLTV and any borrow cap to real pool depth**, not to the collateral's paper value — a thin pool makes any TWAP window cheaper to sustain a dislocation across.
4. **Before merging, verify the LIVE on-chain state directly** (`cast call` against `Morpho.idToMarketParams`/`Morpho.market`, or the oracle's own getters) — don't trust a script or doc's claimed addresses. A stale doc pointing at a dead/superseded market is exactly the kind of gap that lets a real risk go unnoticed (see the 2026-07-13 cleanup in `docs/vault/mainnet-addresses.md`).
