# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test

```bash
git submodule update --init --recursive              # REQUIRED before first build (lib/universal-router etc.)
forge build                                          # compile all
forge build --profile lplocker                       # LiquidLpLockerFeeConversion only (100 runs — too big at 20k)
forge test                                           # all tests (requires BASE_RPC_URL env var for fork tests)
forge test --match-path "test/vault/**" -v          # vault suite only
forge test --match-test test_depositVVV_mintsWstDIEM -vvvv   # single test with traces
BASE_RPC_URL=https://... forge test --match-path "test/vault/**"  # fork tests
forge fmt                                            # format
forge fmt --check                                    # CI format check
```

**Use Foundry v1.5.1** (`forge --version` → `1.5.1-stable`). `forge fmt` output differs between Foundry releases, so a newer/older toolchain will reformat files and break the CI `fmt --check` (this is why commit `d83ac8a` pins it). Match the pin before committing formatting.

**Etherscan verification** reads `ETHERSCAN_API_KEY_1` from the `[etherscan]` block in `foundry.toml` (not `ETHERSCAN_KEY`). When you pass `--etherscan-api-key` on the CLI it overrides that; otherwise export `ETHERSCAN_API_KEY_1`.

Full paths required (not on default PATH):

| Tool | Path |
|------|------|
| `forge`, `cast`, `anvil` | `~/.foundry/bin/` |
| `op` (1Password CLI) | `/opt/homebrew/bin/op` |

Secrets:
- **Deployer v6** (for the planned v6 security-fix redeploy — not yet deployed; v5 is live): `0xf04822e5B0E76A34aeeA936c79B4439f794b8Be1` — `op item get rhuh6s2tocpjzdi7kvvnjrps7i --field credential --reveal` (vault: `Personal`, item: "wstDIEM v6 Deployer EOA"). Fund from wstdiem-deployer Splits account `0xf4DB2a7B6902924EFCd8270d23B205969EfF3316`.
- **Deployer v5** (legacy, v5 contracts only): `0x10900528c57BBCe07C223B25Ae9bB66966274b5D` — `op item get el4qwixmdot757dpxcqgfo43qe --field "private key" --reveal` (vault: `mog.capital`)
- **Deployer v4** (legacy, do not reuse): `op item get dlvppn2nk3mkz2ewgcu3yhqbj4 --field private_key --reveal`
- **Keeper EOA**: `0x988CE72d127b8A06821BBb3708897dBdc0D66f2f` — `cat ~/.splits/config.json | python3 -c "import sys,json; print(json.load(sys.stdin)['key']['privateKey'])"`. Fund from wstdiem-keeper Splits account `0x102368E997ced4b94d093813B3c1F5fB1F15f4B1`.
- **Etherscan key**: `op item get ggwsiftg2sspnxai22vkbj2yea --field credential --reveal`

## Stack

- Solidity 0.8.28, viaIR, 20,000 optimizer runs, Cancun EVM
- All on-chain work targets **Base mainnet** (chain ID 8453)
- Safe multisig (`0x872c561f699B42977c093F0eD8b4C9a431280c6c`) owns all vault contracts — use `script/vault/SafeBatch.s.sol` pattern for owner-only calls

## Project Architecture

This repo has two distinct subsystems that share infrastructure but are otherwise independent:

### 1. Liquid Protocol (original codebase)
Token launchpad forked from Clanker V4.1. Deploys ERC-20 tokens with permanent Uniswap V4 LP, MEV protection, and fee splits.

- `src/Liquid.sol` — factory that deploys tokens, hooks, and LP in one transaction
- `src/LiquidToken.sol` — ERC-20 template (deployed per token)
- `src/LiquidFeeLocker.sol` — locks LP positions, collects trading fees
- `src/hooks/` — Uniswap V4 hooks: `LiquidHookStaticFeeV2` and `LiquidHookDynamicFeeV2`. Both implement `IUnlockCallback` for V4's lock/unlock pattern.
- `src/mev-modules/` — MEV auction and descending-fee modules wired at deploy time
- `src/extensions/` — optional add-ons: presale, airdrop, dev buy (V3 and V4 variants)
- `src/lp-lockers/` — `LiquidLpLockerFeeConversion` handles fee conversion from locked LP positions

### 2. wstDIEM Vault (new subsystem in `src/vault/`)
ERC-4626 vault that wraps staked DIEM (sDIEM) from Venice AI protocol. wstDIEM is liquid staked DIEM — analogous to wstETH.

**Key invariant:** DIEM never leaves the vault. `DIEM.stake()` moves DIEM from `balanceOf` into Venice's internal `stakedInfos`. `totalAssets()` sums all three buckets: `idle + amountStaked + coolDownAmount`. `stakedInfos(addr)` returns `(amountStaked, coolDownEnd, coolDownAmount)` — field 1 is a timestamp, not an amount.

**Contract responsibilities:**

| Contract | Role |
|----------|------|
| `InferenceVault` | ERC-4626 vault. Deposit DIEM → stake via `DIEM.stake()` → mint wstDIEM. `creditDIEM()` accrues yield non-dilutively (no new shares). Withdrawals gated behind 14-day timelock + 24h DIEM unstake cooldown. |
| `Router` | Multi-path entry: `depositWETH` (WETH→DIEM via Uniswap V3→vault), `depositVVV` (VVV→sVVV→mintDiem→vault), `exitToWETH` (wstDIEM→WETH via V4 `unlockCallback`). |
| `FeeRouter` | Aggregates protocol fee income (WETH, USDC, VVV, wstDIEM). Configurable `FeeMode` per token: `CREDIT_VAULT` (swap→DIEM→creditDIEM), `CURVE_VOL` (add to Curve LP), `HOLD`. `harvest()` and `harvestVVV()` are `onlyOwner`. |
| `SurplusStakingWrapper` | Thin wrapper for user deposits with referral tracking. |
| `AgentTGERegistry` | Tracks agent lifecycle: Bronze/Silver/Gold tiers, 30-day dormancy window. |
| `InferenceProduct` | On-chain registry and USDC settlement layer for selling Venice AI inference capacity. Each "slot" is an ephemeral wallet with sDIEM staked. Buyers pay USDC → routes to `FeeRouter.receiveUSDC()`. Two creation paths: VVV (stake VVV to wallets off-chain, keeper completes mintDiem+DIEM.stake) or Direct (pre-funded wallets). Marketplace params (model IDs, per-token pricing, rev share) configurable by owner for Surplus AI / AntPool integration. |
| `adapters/` | Venue adapters (`BaseInferenceAdapter` abstract + `AntSeedAdapter`, `SurplusAdapter`, `X402Adapter`). Each receives settlement USDC from an inference venue, then `routeYield()` (onlyOperator) swaps USDC→WETH→DIEM (Uniswap V3 multi-hop) and calls `vault.creditDIEM()` to raise the wstDIEM rate for all holders, net of `operatorFeeBps`. |
| `oracles/` | Morpho Blue price oracles, one per market: `WstDiemUsdcOracle`, `WstDiemWethOracle` (both **DEPRECATED** — hardcode `DIEM = $1`; markets unseeded, do not use — MOG-542/549, see Security & Audit), and `WstDiemVvvOracle` (fully on-chain, no USD feed — `convertToAssets()` × Aerodrome DIEM/VVV TWAP, immutable; the MOG-544 fix and canonical market). |
| `WstDIEMHook` | Uniswap V4 hook for the wstDIEM/WETH dynamic-fee pool (MOG-548). `beforeSwap` returns the fee OR'd with `LPFeeLibrary.OVERRIDE_FEE_FLAG` so V4 actually applies it; the fee **value** is still the constant `FEE_NORMAL` (5 bps) — NAV/TWAP-based fee selection remains deferred to WP-5. Deployed via CREATE2 salt-mining (address low bits `0x1080`). |
| `LiquidityManager` | Persistent, parameterized V4 LP manager owned by the Safe (MOG-548). Holds the wstDIEM/WETH position; `onlySafe` add / remove / collect / grantOperator. Pool key (currencies, fee, tickSpacing, hooks) + tick range are constructor immutables, so one deploy targets exactly one pool. |

**External protocol dependencies (Base mainnet):**

| Protocol | Address | Used for |
|----------|---------|---------|
| DIEM token (Venice) | `0xF4d97F2da56e8c3098f3a8D538DB630A2606a024` | Vault asset; has built-in `stake()`/`initiateUnstake()`/`unstake()` |
| VVV token (liquid ERC-20) | `0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf` | Tradeable "Venice Token". Router `depositVVV` input; wstDIEM/VVV Morpho **loan token**; the Aerodrome DIEM/VVV pair. **Distinct from sVVV — this is the one to use as `vvv`.** |
| VVV staking → sVVV (non-transferrable) | `0x321b7ff75154472B18EDb199033fF4D116F340Ff` | `stake(address to, uint256 vvvAmount)` → sVVV; `mintDiem(uint256, uint256)` → DIEM (returns void). Cannot be a Morpho loan token or an oracle pool token. |
| Uniswap V3 SwapRouter02 | `0x2626664c2603336E57B271c5C0b26F421741e481` | WETH→DIEM (1% pool) and USDC→WETH→DIEM swaps |
| Uniswap V4 PoolManager | `0x498581fF718922c3f8e6A244956aF099B2652b2b` | wstDIEM/WETH pool; Router uses `unlock`→`unlockCallback` pattern |
| Morpho Blue | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` | wstDIEM/DIEM, /USDC, /WETH lending markets (oracle addresses below) |
| Curve DIEM/wstDIEM | `0xB9c7F62e4EeC145bFa1C6bBc5fFdFf246181FdA2` | StableSwap exit pool (v5) |
| Aerodrome DIEM/VVV pool (volatile v2) | `0xbB345D35450BF9Ee76F3D2cE214E8e7AC5e1071d` | Only deep DIEM DEX liquidity (~$6M v2; token0=liquid VVV, token1=DIEM). `quote(DIEM,1e18,n)` is the TWAP source for `WstDiemVvvOracle` — DIEM has no USD-liquid market. Size borrow caps to this pool's depth, not CL-pool totals. |

**Active deployed addresses (Base mainnet) — v5.** The canonical, maintained source is **`docs/vault/mainnet-addresses.md`** — trust it over this table when they differ (this one drifts). Quick reference:

| Contract | Address |
|----------|---------|
| InferenceVault (wstDIEM v5) | `0xb9f23c33FfD2213f31C0cFb6c9e2fDf525a9Dd2D` |
| FeeRouter | `0x3b8d968DCca09E319fac7Df741804Af5644E3a60` |
| Router | `0x6fF481F4B3B0E2ADa548D454F7011D1ed51532B6` |
| AgentTGERegistry | `0x09a4227935FF15b261533238F79935CCcA0e7941` |
| SurplusStakingWrapper | `0x04fAc3e264bD05478Ffc1Caa25394403f8eBc7d7` |
| InferenceProduct | `0x8620304D28c162E2D2Ae3bF279516DAc368D6879` |
| Curve DIEM/wstDIEM | `0xB9c7F62e4EeC145bFa1C6bBc5fFdFf246181FdA2` |
| Morpho wstDIEM/DIEM oracle (86% LLTV) | `0xB1B192fc0190bA15F4EC76BF6032123bc688F76D` |
| Morpho wstDIEM/DIEM oracle (77% LLTV) | `0xE762e8011D453853638D1978398df8b1D383A2D9` |
| Morpho wstDIEM/USDC oracle (DEPRECATED — MOG-542, do not use) | `0x7F3eAb9863d4f5a1d34d89f7b802C0eA2469b51a` |
| Morpho wstDIEM/WETH oracle (DEPRECATED — MOG-542, do not use) | `0x73FddCCBB524b04b43EdED9C4d20C061DE291F07` |
| Morpho wstDIEM/VVV oracle (62.5%, on-chain TWAP — MOG-544) | `0xC76e2fe5176B432035Def5362023a8DF36bEE94E` |
| AntSeedAdapter | `0xE9C2BE3ab25E97Ef4364c505202016106Bec6a6e` |
| SurplusAdapter | `0xB67A86Ab50e30d7509eeD205Fc01A70758B227Db` |
| X402Adapter | `0xC3C3CaC663f88304a38Cb9C4e9c02bB57DB00142` |
| Safe (owner) | `0x872c561f699B42977c093F0eD8b4C9a431280c6c` |

wstDIEM/VVV Morpho market (MOG-544, created 2026-06-05, **unseeded — borrows gated on liquidation depth, MOG-536**): ID `0xab0345699b8e7a86763b6adbf165c6cd367d11d8e6d875c0f1a20861d8f4f8c8` — collateral wstDIEM, loan **liquid VVV** `0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf`, oracle `0xC76e2fe5176B432035Def5362023a8DF36bEE94E`, IRM `0x46415998764C29aB2a25CbeA6254146D50D22687`.

**Old vault (v4, 2026-06-01) — withdrawals enabled June 17 UTC (MOG-520):**

| Contract | Address |
|----------|---------|
| InferenceVault v4 (old API) | `0x4751BA2b09374C1929FC01734a166e3c8cd75810` |

## Critical Interface Notes

These are non-obvious and have caused bugs:

- **`IVVVStaking.mintDiem(uint256, uint256)` returns void.** Use balance delta: `uint256 before = IERC20(diem).balanceOf(address(this)); mintDiem(...); uint256 minted = IERC20(diem).balanceOf(address(this)) - before;`
- **sVVV is non-transferrable.** `transferFrom` on the VVV staking contract reverts with `NOT_TRANSFERRABLE`. Router cannot pull sVVV from users — only the `depositVVV` path (which stakes VVV inside the Router itself) works.
- **`DIEM.stake()` moves DIEM out of `balanceOf`.** After staking, `DIEM.balanceOf(vault) == 0`. `totalAssets()` must sum `stakedInfos` instead.
- **Uniswap V3 SwapRouter02 on Base is `0x2626...`.** The Ethereum mainnet address (`0x68b3...`) is a different contract on Base.
- **V4 `IPoolManager.swap()` takes a full `PoolKey` struct**, not individual currency args. Import from `@uniswap/v4-core/src/types/PoolKey.sol`.
- **`DIEM.stake()` requires no prior `approve`.** The DIEM contract stakes from `msg.sender`'s own balance.

## Deployment Scripts

All vault scripts live in `script/vault/`:

- `DeployAll.s.sol` — deploys the full vault stack (InferenceVault, FeeRouter, Router, Curve pool, Morpho market, AgentTGERegistry, SurplusStakingWrapper). Requires `DEPLOYER_ADDRESS`, `TREASURY_ADDRESS`, `SAFE_MULTISIG_ADDRESS` env vars.
- `DeployRouter.s.sol` — standalone Router redeploy (used frequently as Router is upgraded without re-deploying the vault).
- `SafeBatch.s.sol` — executes Safe multisig transactions programmatically. Reads `SAFE_SK1` and `SAFE_SK2` (bytes32 private keys) + `EXECUTOR_PK` from env. Signatures sorted by signer address ascending (Safe spec). Safe signers in 1Password: `liq-safe-signer-1` (vault `mog.capital`), `liq-safe-signer-2` (vault `Personal`).
- `InitPools.s.sol` — initializes V4 pool and seeds Curve pool with available balances.

The directory holds ~20 scripts beyond these four. Owner-only actions follow the `Safe*.s.sol` naming and all use the `SafeBatch` signing pattern above (`SAFE_SK1`/`SAFE_SK2`/`EXECUTOR_PK`): e.g. `SafeEnableWithdrawals`, `SafeAddV4LP`, `SafeManageV4LP`, `SafeSeedCapital`, `SafeKeeperSetup`. Deploy variants include `DeployAndWireAdapters`, `DeployCurvePool`, `DeployMorphoMarketsV2`, `CreateMorphoMarket75`.

**Old v4 vault withdrawal sequence (MOG-520, ~June 17–18 UTC)** — the Safe holds the v4 wstDIEM, so each step routes through the Safe:
1. `SafeEnableWithdrawals.s.sol` — enable withdrawals on the old vault.
2. `SafeRequestWithdrawV4.s.sol` — `requestWithdraw(shares)` for the Safe's full v4 balance.
3. `cast send <OLD_VAULT> 'flushBatch()'` (keeper) → wait ~24h → `settleBatch()` → `claimBatch(batchId)`.

See `docs/vault/KEEPER_RUNBOOK.md` for the authoritative ops procedure.

Typical deploy pattern (v5, using new deployer):
```bash
DEPLOYER_PK=$(op item get el4qwixmdot757dpxcqgfo43qe --field "private key" --reveal | tr -d '[:space:]')
DEPLOYER_PK="$PK" forge script script/vault/DeployRouter.s.sol \
  --rpc-url https://base-mainnet.g.alchemy.com/v2/<key> \
  --private-key "$PK" --broadcast --verify \
  --etherscan-api-key "$ETHERSCAN_KEY"
```

## Test Structure

Fork tests require `BASE_RPC_URL` env var. They use the live DIEM and VVV staking contracts.

- `test/vault/mocks/MockDIEM.sol` — implements the Venice DIEM staking interface for unit tests (no fork needed). `stake()` burns from `balanceOf` and tracks in internal mapping.
- Unit tests (`InferenceVaultTest`, etc.) use `MockDIEM` — no fork.
- Fork tests (`InferenceVaultForkTest`, `RouterV4Test`, `SurplusStakingWrapperTest`, `VaultStackIntegrationTest`) fork Base mainnet and use real contracts.
- `test/vault/integration/VaultStack.t.sol` — end-to-end coverage: deposit → creditDIEM → rate check → full withdrawal flow → VVV path → Morpho lifecycle.

## Documentation

Vault docs live in `docs/vault/` and are kept more current than this file:

- `mainnet-addresses.md` — **canonical** deployed addresses (all versions, Morpho markets, Splits accounts).
- `KEEPER_RUNBOOK.md` — routine keeper ops and the v4 withdrawal procedure.
- `SYSTEM_OVERVIEW.md` — architecture narrative; `wstdiem-economics.md` — rate/yield mechanics; `GROWTH_PLAN.md` — TVL/growth strategy; `DEPOSIT_GUIDE.md` — user deposit paths.
- `SECURITY_REVIEW.md` — latest vault security review (see below).

For the **Liquid Protocol** side, `README.md` lists all deployed core/hook/extension/MEV addresses and `EXTENSION-ALLOWLIST.md` covers the extension approval process.

## Security & Audit

- **Liquid Protocol** is a fork of [Clanker v4](https://github.com/clanker-devco/v4-contracts), audited by **0xMacro** and **Cantina**. The hook/locker/extension logic is architecturally identical to the audited code (only `Clanker*`→`Liquid*` renames + own factory).
- **The wstDIEM vault (`src/vault/**`) is new and unaudited.** An agent-driven review (`docs/vault/SECURITY_REVIEW.md`, MOG-532) surfaced **1 High + 2 Medium**. v6 **addresses the two Mediums** (USD oracles deprecated → MOG-542/549; `recordFeeReceipt` gated → MOG-543). The **High (MOG-541, `routeYield` `amountOutMinimum=0`) is NOT code-fixed** — it is risk-accepted via `onlyOperator` access control (operator must use a private relay; implement `minDiemOut` before scaling TVL). A third-party audit is recommended before large external TVL.
- **Live oracle caveat:** the deployed `WstDiemUsdcOracle` / `WstDiemWethOracle` **hardcode `DIEM = $1`**, but DIEM trades ≈ $1,100+ (it's a perpetuity ≈ 89 VVV). Treat the wstDIEM/USDC and wstDIEM/WETH Morpho markets as **mispriced — do not seed meaningful TVL**. The fix is `WstDiemVvvOracle` (VVV-denominated, fully on-chain). The wstDIEM/DIEM leverage-loop market uses the vault rate directly and is unaffected. These two markets are now formally deprecated (MOG-549); the VVV market is canonical. (MOG-549 sweep: `$1/DIEM/day` is correct as an *inference entitlement* in `AgentTGERegistry`/`InferenceProduct`; it was only wrong as a *collateral price* in these two oracles + the V4 init.)
