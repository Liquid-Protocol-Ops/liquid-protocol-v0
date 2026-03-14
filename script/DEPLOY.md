# Liquid Protocol — Deployment Orchestration Plan

## Prerequisites

1. Copy `.env.example` to `.env` and fill in:
   - `DEPLOYER_PRIVATE_KEY` — funded wallet on Base
   - `OWNER_ADDRESS` — multisig or EOA that will own all contracts
   - `ETHERSCAN_API_KEY` — from etherscan.io (Etherscan v2 — single key, chain ID selects Base)
   - `LIQUID_PRESALE_FEE_RECIPIENT` — protocol fee address for presales
2. Ensure deployer wallet has enough ETH for gas (~0.05 ETH recommended)
3. Run `forge build` to confirm compilation succeeds

## Deployment Phases

Each phase deploys a group of contracts. After each phase, copy the logged addresses into `.env` before running the next phase.

### Verification Flags

Every `forge script` command below includes `--verify --verifier etherscan --slow` so contracts are verified on Basescan at deploy time. If verification fails for any contract, use the fallback:

```bash
forge verify-contract <ADDRESS> <ContractName> \
  --verifier etherscan \
  --verifier-url https://api.etherscan.io/v2/api?chainid=8453 \
  --etherscan-api-key $ETHERSCAN_API_KEY_1 \
  --constructor-args $(cast abi-encode "constructor(...)" arg1 arg2) \
  --watch
```

---

### Phase 0 — Core Infrastructure

Deploys: `Liquid`, `LiquidFeeLocker`, `LiquidPoolExtensionAllowlist`

```bash
source .env && forge script script/00_DeployCore.s.sol:DeployCore \
  --rpc-url $BASE_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  --verify \
  --verifier etherscan \
  --verifier-url https://api.etherscan.io/v2/api?chainid=8453 \
  --etherscan-api-key $ETHERSCAN_API_KEY_1 \
  --slow
```

**After:** Copy `LIQUID_FACTORY`, `LIQUID_FEE_LOCKER`, `POOL_EXTENSION_ALLOWLIST` addresses from console output into `.env`.

---

### Phase 1 — Hooks

Deploys: `LiquidHookDynamicFeeV2`, `LiquidHookStaticFeeV2`

Requires: `LIQUID_FACTORY`, `POOL_EXTENSION_ALLOWLIST` from Phase 0

```bash
source .env && forge script script/01_DeployHooks.s.sol:DeployHooks \
  --rpc-url $BASE_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  --verify \
  --verifier etherscan \
  --verifier-url https://api.etherscan.io/v2/api?chainid=8453 \
  --etherscan-api-key $ETHERSCAN_API_KEY_1 \
  --slow
```

**After:** Copy `LIQUID_HOOK_DYNAMIC_FEE_V2`, `LIQUID_HOOK_STATIC_FEE_V2` into `.env`.

---

### Phase 2 — Extensions

Deploys: `LiquidAirdropV2`, `LiquidVault`, `LiquidUniv4EthDevBuy`, `LiquidUniv3EthDevBuy`, `LiquidPresaleEthToCreator`, `LiquidPresaleAllowlist`

Requires: `LIQUID_FACTORY` from Phase 0

```bash
source .env && forge script script/02_DeployExtensions.s.sol:DeployExtensions \
  --rpc-url $BASE_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  --verify \
  --verifier etherscan \
  --verifier-url https://api.etherscan.io/v2/api?chainid=8453 \
  --etherscan-api-key $ETHERSCAN_API_KEY_1 \
  --slow
```

**After:** Copy all 6 extension addresses into `.env`.

---

### Phase 3 — LP Locker + MEV Modules

Deploys: `LiquidLpLockerFeeConversion`, `LiquidSniperAuctionV2`, `LiquidMevDescendingFees`, `LiquidSniperUtilV2`

Requires: `LIQUID_FACTORY`, `LIQUID_FEE_LOCKER` from Phase 0

```bash
source .env && forge script script/03_DeployLpLockerAndMev.s.sol:DeployLpLockerAndMev \
  --rpc-url $BASE_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  --verify \
  --verifier etherscan \
  --verifier-url https://api.etherscan.io/v2/api?chainid=8453 \
  --etherscan-api-key $ETHERSCAN_API_KEY_1 \
  --slow
```

**After:** Copy all 4 addresses into `.env`.

---

### Phase 4 — Configure Allowlists

No new deployments. Calls `setHook`, `setLocker`, `setExtension`, `setMevModule` on the Liquid factory.

Requires: ALL addresses from Phases 0–3

```bash
source .env && forge script script/04_ConfigureAllowlists.s.sol:ConfigureAllowlists \
  --rpc-url $BASE_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  --slow
```

---

## Dependency Graph

```
Phase 0: Liquid ─────────────────┐
         LiquidFeeLocker ────────┤
         PoolExtensionAllowlist ─┤
                                 │
Phase 1: HookDynamicFeeV2 ◄─────┤ (needs Factory + Allowlist)
         HookStaticFeeV2  ◄─────┤
                                 │
Phase 2: AirdropV2 ◄────────────┤ (needs Factory)
         Vault ◄─────────────────┤
         Univ4EthDevBuy ◄────────┤
         Univ3EthDevBuy ◄────────┤
         PresaleEthToCreator ◄───┤
         PresaleAllowlist ◄──────┤ (needs PresaleEthToCreator)
                                 │
Phase 3: LpLockerFeeConv ◄──────┤ (needs Factory + FeeLocker)
         SniperAuctionV2 ◄──────┤ (needs Factory + FeeLocker)
         MevDescendingFees       │ (no dependencies)
         SniperUtilV2 ◄──────────  (needs SniperAuctionV2)

Phase 4: ConfigureAllowlists     (enables all modules on the factory)
```

## Base Sepolia (Testnet)

Replace `$BASE_RPC_URL` with `$BASE_SEPOLIA_RPC_URL` and `--verifier-url` with `https://api.etherscan.io/v2/api?chainid=84532`. Same `ETHERSCAN_API_KEY` works for both networks. External contract addresses (PoolManager, etc.) may differ on Sepolia — update `.env` accordingly.

## Post-Deploy Checklist

- [ ] All contracts show green checkmark on Basescan
- [ ] `Liquid.owner()` returns expected `OWNER_ADDRESS`
- [ ] Hooks, lockers, extensions, MEV modules are enabled on factory

### Critical: FeeLocker Depositor Setup

The LP Locker must be registered as an allowed depositor on the FeeLocker, otherwise **all swaps will revert** with `Unauthorized()` when the hook tries to route LP fees through the FeeLocker.

```bash
# From the owner (multisig):
cast send $LIQUID_FEE_LOCKER "addDepositor(address)" $LP_LOCKER_FEE_CONVERSION
```

Without this, the `beforeSwap` hook callback calls `collectRewardsWithoutUnlock` → `storeFees` on the FeeLocker, which checks `allowedDepositors[msg.sender]` and reverts.

### Critical: Set Team Fee Recipient

Protocol fees accumulate as WETH in the factory contract. To claim them, a team fee recipient must be set:

```bash
# From the owner (multisig):
cast send $LIQUID_FACTORY "setTeamFeeRecipient(address)" $TEAM_FEE_RECIPIENT
```

Then claim with:

```bash
cast send $LIQUID_FACTORY "claimTeamFees(address)" $WETH
```

### Smoke Test

- [ ] `addDepositor` called on FeeLocker for the LP Locker
- [ ] `setTeamFeeRecipient` called on Factory
- [ ] Test a `deployToken()` call on testnet before mainnet
- [ ] Test a buy swap (ETH → token) via Universal Router
- [ ] Test a sell swap (token → ETH) via Universal Router
- [ ] Test `collectRewards` + `claimFees` for creator fees
- [ ] Test `claimTeamFees` for protocol fees
