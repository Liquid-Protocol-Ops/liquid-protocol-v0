# Liquid Protocol — Deployment Orchestration Plan

## Prerequisites

1. Copy `.env.example` to `.env` and fill in:
   - `DEPLOYER_PRIVATE_KEY` — funded wallet on Base
   - `OWNER_ADDRESS` — multisig or EOA that will own all contracts
   - `BASESCAN_API_KEY` — from basescan.org
   - `LIQUID_FEE_RECIPIENT` — protocol fee address for presales
2. Ensure deployer wallet has enough ETH for gas (~0.05 ETH recommended)
3. Run `forge build` to confirm compilation succeeds

## Deployment Phases

Each phase deploys a group of contracts. After each phase, copy the logged addresses into `.env` before running the next phase.

### Verification Flags

Every `forge script` command below includes `--verify --verifier etherscan --slow` so contracts are verified on Basescan at deploy time. If verification fails for any contract, use the fallback:

```bash
forge verify-contract <ADDRESS> <ContractName> \
  --verifier etherscan \
  --verifier-url https://api.basescan.org/api \
  --etherscan-api-key $BASESCAN_API_KEY \
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
  --verifier-url https://api.basescan.org/api \
  --etherscan-api-key $BASESCAN_API_KEY \
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
  --verifier-url https://api.basescan.org/api \
  --etherscan-api-key $BASESCAN_API_KEY \
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
  --verifier-url https://api.basescan.org/api \
  --etherscan-api-key $BASESCAN_API_KEY \
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
  --verifier-url https://api.basescan.org/api \
  --etherscan-api-key $BASESCAN_API_KEY \
  --slow
```

**After:** Copy all 4 addresses into `.env`.

---

### Phase 4 — Configure Allowlists

No new deployments. Calls `enableHook`, `enableLocker`, `enableExtension`, `enableMevModule` on the Liquid factory.

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

Replace `$BASE_RPC_URL` with `$BASE_SEPOLIA_RPC_URL` and `--verifier-url` with `https://api-sepolia.basescan.org/api`. External contract addresses (PoolManager, etc.) may differ on Sepolia — update `.env` accordingly.

## Post-Deploy Checklist

- [ ] All contracts show green checkmark on Basescan
- [ ] `Liquid.owner()` returns expected `OWNER_ADDRESS`
- [ ] Hooks, lockers, extensions, MEV modules are enabled on factory
- [ ] Test a `deployToken()` call on testnet before mainnet
