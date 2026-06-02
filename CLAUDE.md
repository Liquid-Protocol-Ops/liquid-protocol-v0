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

Secrets: deployer key via `op item get dlvppn2nk3mkz2ewgcu3yhqbj4 --field private_key --reveal`. Etherscan key via `op item get ggwsiftg2sspnxai22vkbj2yea --field credential --reveal`. Both are in 1Password.

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

**Key invariant:** DIEM never leaves the vault. `DIEM.stake()` moves DIEM from `balanceOf` into Venice's internal `stakedInfos`. `totalAssets()` sums all three buckets: `idle + stakedAmount + unstakingAmount`.

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
| Curve DIEM/wstDIEM | `0x39A4b4779C71E1A18d500627639682c9583Ee86f` | StableSwap exit pool (v4) |

**Active deployed addresses (Base mainnet) — v4, 2026-06-01:**

| Contract | Address |
|----------|---------|
| InferenceVault (wstDIEM) | `0x4751BA2b09374C1929FC01734a166e3c8cd75810` |
| FeeRouter | `0x21fe048B10dC9bED2Ee0Ae76724C627CA7F35F61` |
| Router v8 | `0x6f5FF03a91cb1703B7CB8d85572f990bcB04273D` |
| AgentTGERegistry | `0x49be7fE8D661b892AC0461818a5C714574e83998` |
| SurplusStakingWrapper | `0xB0f9c45dAacD89F0d90cbE0E65d0dA20fa1ac415` |
| InferenceProduct | `0x9b7d8B23cb223F75F5F1Ead25f12205940960F62` |
| Curve DIEM/wstDIEM | `0x39A4b4779C71E1A18d500627639682c9583Ee86f` |
| Morpho wstDIEM/DIEM oracle (86%) | `0xbaEc9cCcBa9884D403dBcEe15455E28781f1fd72` |
| Morpho wstDIEM/USDC oracle (62.5%) | `0x556B3B1a0de988407EF39e4a775d33280C06EEeb` |
| Morpho wstDIEM/WETH oracle (62.5%) | `0x25AcE9baFad49f0e7239E4b469edEEDc97d176fd` |
| Safe (owner) | `0x872c561f699B42977c093F0eD8b4C9a431280c6c` |

Note: The InferenceVault v4 above uses the **old API** (pre-redesign). The new InferenceVault.sol (src/vault/InferenceVault.sol on chore/repo-hardening) requires a fresh deployment via DeployAll.s.sol.

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

Typical deploy pattern:
```bash
DEPLOYER_PK=$(op item get <id> --field private_key --reveal | tr -d '[:space:]')
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
