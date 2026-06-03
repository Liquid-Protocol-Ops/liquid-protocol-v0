# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test

```bash
forge build                                          # compile all
forge test                                           # all tests (requires BASE_RPC_URL env var for fork tests)
forge test --match-path "test/vault/**" -v          # vault suite only
forge test --match-test test_depositVVV_mintsWstDIEM -vvvv   # single test with traces
BASE_RPC_URL=https://... forge test --match-path "test/vault/**"  # fork tests
forge fmt                                            # format
forge fmt --check                                    # CI format check
```

Full paths required (not on default PATH):

| Tool | Path |
|------|------|
| `forge`, `cast`, `anvil` | `~/.foundry/bin/` |
| `op` (1Password CLI) | `/opt/homebrew/bin/op` |

Secrets:
- **Deployer v5** (wstDIEM InferenceVault v5): `0x10900528c57BBCe07C223B25Ae9bB66966274b5D` — `op item get el4qwixmdot757dpxcqgfo43qe --field "private key" --reveal` (vault: `mog.capital`, item: "wstDIEM Deployer v5")
- **Deployer v4** (legacy, do not reuse): `op item get dlvppn2nk3mkz2ewgcu3yhqbj4 --field private_key --reveal`
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

**External protocol dependencies (Base mainnet):**

| Protocol | Address | Used for |
|----------|---------|---------|
| DIEM token (Venice) | `0xF4d97F2da56e8c3098f3a8D538DB630A2606a024` | Vault asset; has built-in `stake()`/`initiateUnstake()`/`unstake()` |
| VVV staking (also sVVV ERC-20) | `0x321b7ff75154472B18EDb199033fF4D116F340Ff` | `stake(address to, uint256 vvvAmount)` → sVVV; `mintDiem(uint256, uint256)` → DIEM (returns void) |
| Uniswap V3 SwapRouter02 | `0x2626664c2603336E57B271c5C0b26F421741e481` | WETH→DIEM (1% pool) and USDC→WETH→DIEM swaps |
| Uniswap V4 PoolManager | `0x498581fF718922c3f8e6A244956aF099B2652b2b` | wstDIEM/WETH pool; Router uses `unlock`→`unlockCallback` pattern |
| Morpho Blue | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` | wstDIEM/DIEM markets (see v4 addresses below) |
| Curve DIEM/wstDIEM | `0xB9c7F62e4EeC145bFa1C6bBc5fFdFf246181FdA2` | StableSwap exit pool (v5) |

**Active deployed addresses (Base mainnet) — v5, 2026-06-03:**

| Contract | Address |
|----------|---------|
| InferenceVault (wstDIEM v5) | `0xb9f23c33FfD2213f31C0cFb6c9e2fDf525a9Dd2D` |
| FeeRouter | `0x3b8d968DCca09E319fac7Df741804Af5644E3a60` |
| Router | `0x6fF481F4B3B0E2ADa548D454F7011D1ed51532B6` |
| AgentTGERegistry | `0x09a4227935FF15b261533238F79935CCcA0e7941` |
| SurplusStakingWrapper | `0x04fAc3e264bD05478Ffc1Caa25394403f8eBc7d7` |
| InferenceProduct | `0x8620304D28c162E2D2Ae3bF279516DAc368D6879` |
| Curve DIEM/wstDIEM | `0xB9c7F62e4EeC145bFa1C6bBc5fFdFf246181FdA2` |
| Morpho wstDIEM/DIEM oracle (86%) | `0xB1B192fc0190bA15F4EC76BF6032123bc688F76D` |
| Morpho wstDIEM/USDC oracle (62.5%) | `0x7F3eAb9863d4f5a1d34d89f7b802C0eA2469b51a` |
| Morpho wstDIEM/WETH oracle (62.5%) | `0x73FddCCBB524b04b43EdED9C4d20C061DE291F07` |
| Safe (owner) | `0x872c561f699B42977c093F0eD8b4C9a431280c6c` |

**Old vault (v4, 2026-06-01) — withdrawals enabled July 1 (MOG-520):**

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
