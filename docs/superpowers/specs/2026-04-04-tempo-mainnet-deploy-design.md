# Liquid Protocol V0 — Tempo Mainnet Deployment

**Date:** 2026-04-04
**Branch:** `deploy/tempo-mainnet`
**Status:** Design approved, pending implementation

## Goal

Create a new branch that prepares Liquid Protocol V0 for deployment on Tempo Mainnet (chain ID 4217). No Solidity contract changes — configuration and deployment script modifications only. Deploy a subset of the protocol: core + hooks + compatible extensions + LP locker. Skip ETH-dependent extensions and MEV modules.

## Context

Tempo is a USD-denominated L1 with ~500ms deterministic finality. There is no native ETH or WETH. The quote token will be **pathUSD** (`0x20C0000000000000000000000000000000000000`). Tempo has no flashblocks or MEV infrastructure, so MEV protection modules are not applicable.

## Tempo Mainnet Addresses

| Contract | Address |
|----------|---------|
| **Quote Token (pathUSD)** | `0x20C0000000000000000000000000000000000000` |
| **Uniswap V4 PoolManager** | `0x33620f62c5b9b2086dd6b62f4a297a9f30347029` |
| **Uniswap V4 PositionManager** | `0x3fc79444f8eacc1894775493ff3fa41f1e35ce11` |
| **UniversalRouter** | `0xa2dc7d0266f0cc50b3eeaf36c9bfcecff1beea91` |
| **Permit2** | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| **V3 SwapRouter** | `0x6a3988d2366ad79917a2399f18a1a82b157470e1` |
| **V3 SwapRouter02** | `0x7e9d53081e961201837336bcd81f52ae92691a8f` |

| Detail | Value |
|--------|-------|
| Chain ID | 4217 |
| RPC | `https://rpc.tempo.xyz` |
| Block Explorer | `https://explore.tempo.xyz` |
| Native Currency | USD (6 decimals) |

## Pre-Deployment

### Phase P1: Bridge Funds to Tempo

Tempo has no native gas token — all transaction fees are paid in TIP-20 stablecoins. The deployer wallet needs stablecoins on Tempo before any transactions.

**Recommended path:**
1. Bridge USDC from Base to Tempo via **Stargate** (LayerZero) — this mints **USDC.e** (`0x20C000000000000000000000b9537d11c60E8b50`) on Tempo
2. Swap some USDC.e for **pathUSD** on Tempo's enshrined stablecoin DEX (needed as the default fee token for non-TIP-20 contract interactions)

**Stargate details:**
- Base Stargate Pool (EID 30184): `0x27a16dc786820B16E5c9028b75B99F6f604b5d26`
- Tempo StargateOFTUSDC: `0x8c76e2F6C5ceDA9AA7772e7efF30280226c44392`
- Tempo LZ EndpointV2: `0x20Bb7C2E2f4e5ca2B4c57060d1aE2615245dCc9C`
- Tempo LZ Endpoint ID: `30410`

**Alternative bridges:** Across (`app.across.to`), Relay (`relay.link`), Squid (`app.squidrouter.com`), Bungee (`bungee.exchange`).

**Alternative onramp:** Tempo Wallet (`wallet.tempo.xyz`) has a built-in fiat onramp and bridge UI.

### Phase P2: Deploy Admin Safe

Safe singleton contracts are deployed on Tempo at canonical CREATE2 addresses:

| Contract | Address |
|----------|---------|
| Safe v1.4.1 Singleton | `0x41675C099F32341bf84BFc5382aF534df5C7461a` |
| SafeProxyFactory v1.4.1 | `0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67` |
| Safe v1.3.0 Singleton | `0xd9Db270c1B5E3Bd161E8c8503c55cEABeE709552` |
| Safe Singleton Factory | `0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7` |

**Note:** The Safe UI (`app.safe.global`) does not yet support Tempo — listed as "coming soon" in Tempo docs. The Safe must be created programmatically.

**Approach:** Write a Foundry script (`script/tempo/00_DeploySafe.s.sol`) that calls `SafeProxyFactory.createProxyWithNonce()` with the desired owners and threshold. This produces a deterministic Safe address that becomes `OWNER_ADDRESS` for all subsequent phases.

**Inputs needed before deployment:**
- List of Safe owner addresses
- Confirmation threshold (e.g., 2-of-3)

**Output:** `OWNER_ADDRESS` env var for `.env.tempo`

## Deployment Scope

### Deployed (8 phases: P1, P2, then 0-5)

| Phase | Script | Contracts | Changes from Base |
|-------|--------|-----------|-------------------|
| 0 | `00_DeployCore.s.sol` | Liquid, LiquidFeeLocker, LiquidPoolExtensionAllowlist | None — pass pathUSD where WETH was used |
| 1 | `01_DeployHooks.s.sol` | LiquidHookDynamicFeeV2, LiquidHookStaticFeeV2 | None — CREATE2 salt mining with Tempo addresses |
| 2 | `02_DeployExtensions.s.sol` | LiquidAirdropV2, LiquidVault | **Modified** — skip 4 ETH-dependent extensions (PresaleAllowlist depends on PresaleEthToCreator) |
| 3b | `03b_DeployLpLocker.s.sol` | LiquidLpLockerFeeConversion | None |
| 4 | `04_ConfigureAllowlists.s.sol` | (configuration only) | **Modified** — only allowlist deployed contracts |
| 5 | `05_TransferOwnership.s.sol` | (ownership transfer) | **Modified** — remove MEV contracts from transfer list |

### Skipped

| Contract | Reason |
|----------|--------|
| LiquidUniv4EthDevBuy | Uses `msg.value` / native ETH wrapping |
| LiquidUniv3EthDevBuy | Uses `msg.value` / native ETH wrapping |
| LiquidPresaleEthToCreator | Uses `payable` functions, `msg.value`, ETH transfers |
| LiquidPresaleAllowlist | Depends on LiquidPresaleEthToCreator (constructor arg) |
| LiquidSniperAuctionV2 | MEV module — no MEV infra on Tempo |
| LiquidMevDescendingFees | MEV module — no MEV infra on Tempo |
| LiquidSniperUtilV2 | MEV util — depends on `msg.value` + no MEV infra |

Phase 3a (`03a_DeployMev.s.sol`) is skipped entirely.

## File Changes

### 0. `script/tempo/00_DeploySafe.s.sol` (new file)

Foundry script to deploy a Safe proxy on Tempo via `SafeProxyFactory.createProxyWithNonce()`. Takes owner addresses and threshold from env vars (`SAFE_OWNERS`, `SAFE_THRESHOLD`). Outputs the Safe proxy address for use as `OWNER_ADDRESS` in subsequent phases.

### 1. `foundry.toml`

Add Tempo chain to `[etherscan]` section:

```toml
[etherscan]
base = { key = "${ETHERSCAN_API_KEY_1}", url = "https://api.etherscan.io/v2/api?chainid=8453" }
base_sepolia = { key = "${ETHERSCAN_API_KEY_1}", url = "https://api.etherscan.io/v2/api?chainid=84532" }
tempo = { key = "${TEMPO_EXPLORER_API_KEY}", url = "https://explore.tempo.xyz/api" }
```

Note: The exact explorer API URL format needs to be confirmed against Tempo's explorer documentation. Tempo uses a Blockscout-based explorer, so the verification endpoint may be `https://explore.tempo.xyz/api` or similar.

### 2. Deployment Scripts

**`02_DeployExtensions.s.sol`** — Create a Tempo-specific variant or add conditional logic to skip:
- LiquidUniv4EthDevBuy
- LiquidUniv3EthDevBuy
- LiquidPresaleEthToCreator

Only deploy: LiquidAirdropV2, LiquidVault, LiquidPresaleAllowlist.

**`04_ConfigureAllowlists.s.sol`** — Remove allowlist entries for:
- Skipped extensions (3 ETH-dependent)
- MEV modules (SniperAuction, MevDescendingFees)

**`05_TransferOwnership.s.sol`** — Remove ownership transfer calls for:
- LiquidSniperAuctionV2
- LiquidPresaleEthToCreator

### 3. `.env.tempo` (new file)

Environment variable template for Tempo deployment:

```bash
# Deployer
DEPLOYER_PRIVATE_KEY=
OWNER_ADDRESS=                  # Tempo Safe address

# Verification
TEMPO_EXPLORER_API_KEY=

# RPC
TEMPO_RPC_URL=https://rpc.tempo.xyz

# External Contracts (Tempo Mainnet)
WETH=0x20C0000000000000000000000000000000000000  # pathUSD (no WETH on Tempo)
UNISWAP_V4_POOL_MANAGER=0x33620f62c5b9b2086dd6b62f4a297a9f30347029
UNISWAP_V4_POSITION_MANAGER=0x3fc79444f8eacc1894775493ff3fa41f1e35ce11
UNISWAP_UNIVERSAL_ROUTER=0xa2dc7d0266f0cc50b3eeaf36c9bfcecff1beea91
PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3
UNISWAP_V3_SWAP_ROUTER=0x6a3988d2366ad79917a2399f18a1a82b157470e1

# Protocol Config
LIQUID_PRESALE_FEE_RECIPIENT=

# Phase 0 Outputs
LIQUID_FACTORY=
LIQUID_FEE_LOCKER=
POOL_EXTENSION_ALLOWLIST=

# Phase 1 Outputs
LIQUID_HOOK_DYNAMIC_FEE_V2=
LIQUID_HOOK_STATIC_FEE_V2=

# Phase 2 Outputs (Tempo subset — no ETH-dependent extensions)
LIQUID_AIRDROP_V2=
LIQUID_VAULT=

# Phase 3b Output
LIQUID_LP_LOCKER_FEE_CONVERSION=
```

### 4. `README.md`

Add a Tempo Mainnet section documenting:
- Deployed contract addresses (populated post-deployment)
- pathUSD as quote token
- Excluded modules and why

## Design Decisions

1. **pathUSD passed as `WETH` parameter** — The contracts store this as an immutable. Variable names in the code say `weth` but the value will be pathUSD. This is a naming mismatch but functionally correct since the core contracts treat it as a generic ERC20 quote token.

2. **Separate deployment script variants vs. conditionals** — Prefer creating Tempo-specific script variants (e.g., `02_DeployExtensions_Tempo.s.sol`) rather than adding if/else logic to existing scripts. This keeps Base deployment scripts untouched and audited.

3. **No Solidity changes** — All contracts compile and deploy as-is. The subset approach avoids touching audited code.

4. **MEV modules excluded** — Tempo's deterministic finality and lack of MEV infrastructure make these modules non-functional.

## Risks

- **pathUSD decimal mismatch**: pathUSD likely has 6 decimals vs. WETH's 18. The protocol handles arbitrary decimals correctly in pool math, but pool pricing will differ significantly. Pool creators need to be aware of this.
- **Explorer verification**: Tempo's block explorer API format is unconfirmed. May need adjustment after testing.
- **LiquidPresaleAllowlist**: Verified — no `msg.value` or `payable` usage. Safe for Tempo.
- **Safe UI unavailable**: The Safe must be managed programmatically (SDK or scripts) until Safe adds Tempo UI support. This adds operational overhead for multisig transactions.
- **Tempo fee token handling**: Contract deployments on Tempo require a TIP-20 stablecoin for gas. The deployer wallet must hold pathUSD or USDC.e. Foundry's `forge script --broadcast` needs testing to confirm it handles Tempo's fee model correctly.

## Future Work

- New Tempo-native extensions for presale and dev buy functionality (ERC20-based, no `msg.value`)
- MEV protection if Tempo introduces relevant infrastructure
