# Tempo Mainnet Deployment — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a `deploy/tempo-mainnet` branch with deployment scripts and configuration for deploying Liquid Protocol V0 on Tempo Mainnet (chain ID 4217), using pathUSD as the quote token.

**Architecture:** Fork the existing Base deployment scripts into Tempo-specific variants under `script/tempo/`. No Solidity contract changes. Core + hooks + 2 compatible extensions + LP locker. Skip ETH-dependent extensions and MEV modules.

**Tech Stack:** Foundry (Solidity 0.8.28), Safe v1.4.1 (canonical CREATE2), Uniswap V4

---

### Task 1: Create branch and restore deployment scripts

**Files:**
- Restore: `script/00_DeployCore.s.sol` (from git commit `2a8452e`)
- Restore: `script/01_DeployHooks.s.sol`
- Restore: `script/02_DeployExtensions.s.sol`
- Restore: `script/03a_DeployMev.s.sol`
- Restore: `script/03b_DeployLpLocker.s.sol`
- Restore: `script/04_ConfigureAllowlists.s.sol`
- Restore: `script/05_TransferOwnership.s.sol`

- [ ] **Step 1: Create the branch**

```bash
cd /Users/ceo/Documents/development/liquid-protocol-v0
git checkout -b deploy/tempo-mainnet
```

- [ ] **Step 2: Restore Base deployment scripts from git history**

The original scripts were removed in a cleanup commit but are needed as reference and for Base redeployments.

```bash
git checkout 2a8452e -- script/00_DeployCore.s.sol script/01_DeployHooks.s.sol script/02_DeployExtensions.s.sol script/03a_DeployMev.s.sol script/03b_DeployLpLocker.s.sol script/04_ConfigureAllowlists.s.sol script/05_TransferOwnership.s.sol
```

- [ ] **Step 3: Commit restored scripts**

```bash
git add script/*.sol
git commit -m "chore: restore Base deployment scripts from 2a8452e"
```

---

### Task 2: Create `.env.tempo` template

**Files:**
- Create: `.env.tempo`

- [ ] **Step 1: Write the env template**

```bash
# ============================================================
# Liquid Protocol V0 — Tempo Mainnet Deployment (.env.tempo)
# ============================================================

# Deployer
DEPLOYER_PRIVATE_KEY=
OWNER_ADDRESS=                  # Tempo Safe address (from Phase P2)

# Verification
TEMPO_EXPLORER_API_KEY=

# RPC
TEMPO_RPC_URL=https://rpc.tempo.xyz

# ============================================================
# External Contracts (Tempo Mainnet)
# ============================================================
WETH=0x20C0000000000000000000000000000000000000
UNISWAP_V4_POOL_MANAGER=0x33620f62c5b9b2086dd6b62f4a297a9f30347029
UNISWAP_V4_POSITION_MANAGER=0x3fc79444f8eacc1894775493ff3fa41f1e35ce11
UNISWAP_UNIVERSAL_ROUTER=0xa2dc7d0266f0cc50b3eeaf36c9bfcecff1beea91
PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3
UNISWAP_V3_SWAP_ROUTER=0x6a3988d2366ad79917a2399f18a1a82b157470e1

# Protocol Config
LIQUID_PRESALE_FEE_RECIPIENT=

# ============================================================
# Safe Deployment (Phase P2)
# ============================================================
SAFE_OWNERS=
SAFE_THRESHOLD=

# ============================================================
# Phase 0 Outputs
# ============================================================
LIQUID_FACTORY=
LIQUID_FEE_LOCKER=
POOL_EXTENSION_ALLOWLIST=

# ============================================================
# Phase 1 Outputs
# ============================================================
LIQUID_HOOK_DYNAMIC_FEE_V2=
LIQUID_HOOK_STATIC_FEE_V2=

# ============================================================
# Phase 2 Outputs (Tempo subset)
# ============================================================
LIQUID_AIRDROP_V2=
LIQUID_VAULT=

# ============================================================
# Phase 3b Output
# ============================================================
LIQUID_LP_LOCKER_FEE_CONVERSION=
```

- [ ] **Step 2: Verify `.env.tempo` is gitignored**

```bash
grep -q '\.env' .gitignore && echo "OK: .env files gitignored" || echo "FAIL"
```

Expected: `OK: .env files gitignored`

- [ ] **Step 3: Commit**

```bash
git add .env.tempo
git commit -m "chore: add Tempo Mainnet env template"
```

Note: `.env.tempo` is a template with no secrets — safe to commit. The actual `.env` with keys is gitignored.

---

### Task 3: Update `foundry.toml` with Tempo chain config

**Files:**
- Modify: `foundry.toml`

- [ ] **Step 1: Add Tempo to the etherscan section**

Add after the existing `base_sepolia` entry:

```toml
tempo = { key = "${TEMPO_EXPLORER_API_KEY}", url = "https://explore.tempo.xyz/api", chain = 4217 }
```

- [ ] **Step 2: Verify config parses**

```bash
forge config
```

Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add foundry.toml
git commit -m "chore: add Tempo Mainnet explorer config to foundry.toml"
```

---

### Task 4: Write Safe deployment script

> **@gs required** — must provide Safe owner addresses and threshold before this script can be run.

**Files:**
- Create: `script/tempo/00_DeploySafe.s.sol`

- [ ] **Step 1: Write the Safe deployment script**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

interface ISafe {
    function setup(
        address[] calldata _owners,
        uint256 _threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
}

/// @notice Phase P2 (Tempo): Deploy a Safe proxy for admin ownership.
///         Safe singleton and factory are already deployed on Tempo at canonical addresses.
contract DeploySafe is Script {
    // Safe v1.4.1 canonical addresses (CREATE2 deterministic, same on all chains)
    address constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Parse comma-separated owner addresses
        string memory ownersRaw = vm.envString("SAFE_OWNERS");
        address[] memory owners = _parseAddresses(ownersRaw);
        uint256 threshold = vm.envUint("SAFE_THRESHOLD");

        require(owners.length >= threshold, "threshold exceeds owner count");
        require(threshold > 0, "threshold must be > 0");

        // Encode Safe.setup() call
        bytes memory initializer = abi.encodeCall(
            ISafe.setup,
            (
                owners,
                threshold,
                address(0), // to — no delegate call
                "", // data
                address(0), // fallbackHandler
                address(0), // paymentToken
                0, // payment
                payable(address(0)) // paymentReceiver
            )
        );

        vm.startBroadcast(deployerKey);

        address safe = ISafeProxyFactory(SAFE_PROXY_FACTORY).createProxyWithNonce(
            SAFE_SINGLETON,
            initializer,
            0 // saltNonce
        );

        vm.stopBroadcast();

        console.log("Safe deployed at:", safe);
        console.log("Owners:", owners.length);
        console.log("Threshold:", threshold);
        console.log("");
        console.log("Set OWNER_ADDRESS=%s in .env.tempo", safe);
    }

    function _parseAddresses(string memory csv) internal pure returns (address[] memory) {
        // Count commas to determine array size
        bytes memory b = bytes(csv);
        uint256 count = 1;
        for (uint256 i; i < b.length; i++) {
            if (b[i] == ",") count++;
        }

        address[] memory addrs = new address[](count);
        uint256 start;
        uint256 idx;
        for (uint256 i; i <= b.length; i++) {
            if (i == b.length || b[i] == ",") {
                bytes memory slice = new bytes(i - start);
                for (uint256 j = start; j < i; j++) {
                    slice[j - start] = b[j];
                }
                addrs[idx] = vm.parseAddress(string(slice));
                idx++;
                start = i + 1;
            }
        }
        return addrs;
    }
}
```

- [ ] **Step 2: Verify it compiles**

```bash
forge build --match-contract DeploySafe
```

Expected: Compilation succeeds.

- [ ] **Step 3: Commit**

```bash
git add script/tempo/00_DeploySafe.s.sol
git commit -m "feat: add Safe deployment script for Tempo Mainnet"
```

---

### Task 5: Write Tempo extensions deployment script

**Files:**
- Create: `script/tempo/02_DeployExtensions.s.sol`

- [ ] **Step 1: Write the Tempo-specific extensions script (only AirdropV2 + Vault)**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {LiquidAirdropV2} from "../../src/extensions/LiquidAirdropV2.sol";
import {LiquidVault} from "../../src/extensions/LiquidVault.sol";

/// @notice Phase 2 (Tempo): Deploy compatible extensions only.
///         Skips ETH-dependent extensions: UnivEthDevBuy (V3/V4),
///         PresaleEthToCreator, PresaleAllowlist.
contract DeployExtensionsTempo is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // From Phase 0
        address liquidFactory = vm.envAddress("LIQUID_FACTORY");

        vm.startBroadcast(deployerKey);

        LiquidAirdropV2 airdrop = new LiquidAirdropV2(liquidFactory);
        console.log("LiquidAirdropV2:", address(airdrop));

        LiquidVault vault = new LiquidVault(liquidFactory);
        console.log("LiquidVault:", address(vault));

        vm.stopBroadcast();
    }
}
```

- [ ] **Step 2: Verify it compiles**

```bash
forge build --match-contract DeployExtensionsTempo
```

Expected: Compilation succeeds.

- [ ] **Step 3: Commit**

```bash
git add script/tempo/02_DeployExtensions.s.sol
git commit -m "feat: add Tempo extensions deployment script (airdrop + vault only)"
```

---

### Task 6: Write Tempo allowlist configuration script

**Files:**
- Create: `script/tempo/04_ConfigureAllowlists.s.sol`

- [ ] **Step 1: Write the Tempo-specific allowlists script (no MEV, no ETH extensions)**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Liquid} from "../../src/Liquid.sol";

/// @notice Phase 4 (Tempo): Enable hooks, locker, and extensions on the Liquid factory.
///         Skips MEV modules (no MEV infra on Tempo) and ETH-dependent extensions.
contract ConfigureAllowlistsTempo is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        Liquid liquid = Liquid(vm.envAddress("LIQUID_FACTORY"));

        // Hooks (from Phase 1)
        address dynamicHook = vm.envAddress("LIQUID_HOOK_DYNAMIC_FEE_V2");
        address staticHook = vm.envAddress("LIQUID_HOOK_STATIC_FEE_V2");

        // LP Locker (from Phase 3b)
        address lpLocker = vm.envAddress("LIQUID_LP_LOCKER_FEE_CONVERSION");

        // Extensions (from Phase 2 — Tempo subset)
        address airdrop = vm.envAddress("LIQUID_AIRDROP_V2");
        address vault = vm.envAddress("LIQUID_VAULT");

        vm.startBroadcast(deployerKey);

        // Enable hooks
        liquid.setHook(dynamicHook, true);
        console.log("Enabled hook:", dynamicHook);
        liquid.setHook(staticHook, true);
        console.log("Enabled hook:", staticHook);

        // Enable locker for each hook
        liquid.setLocker(lpLocker, dynamicHook, true);
        console.log("Enabled locker for dynamic hook:", lpLocker);
        liquid.setLocker(lpLocker, staticHook, true);
        console.log("Enabled locker for static hook:", lpLocker);

        // Enable extensions (Tempo subset only)
        liquid.setExtension(airdrop, true);
        console.log("Enabled extension:", airdrop);
        liquid.setExtension(vault, true);
        console.log("Enabled extension:", vault);

        // No MEV modules on Tempo

        vm.stopBroadcast();

        console.log("Tempo allowlists configured.");
    }
}
```

- [ ] **Step 2: Verify it compiles**

```bash
forge build --match-contract ConfigureAllowlistsTempo
```

Expected: Compilation succeeds.

- [ ] **Step 3: Commit**

```bash
git add script/tempo/04_ConfigureAllowlists.s.sol
git commit -m "feat: add Tempo allowlist configuration script"
```

---

### Task 7: Write Tempo ownership transfer script

**Files:**
- Create: `script/tempo/05_TransferOwnership.s.sol`

- [ ] **Step 1: Write the Tempo-specific ownership transfer (no MEV, no presale)**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Phase 5 (Tempo): Transfer ownership of all ownable contracts to the Safe.
///         Excludes MEV and presale contracts (not deployed on Tempo).
contract TransferOwnershipTempo is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address newOwner = vm.envAddress("OWNER_ADDRESS");

        // Ownable contracts on Tempo
        address liquidFactory = vm.envAddress("LIQUID_FACTORY");
        address feeLocker = vm.envAddress("LIQUID_FEE_LOCKER");
        address poolExtAllowlist = vm.envAddress("POOL_EXTENSION_ALLOWLIST");
        address lpLocker = vm.envAddress("LIQUID_LP_LOCKER_FEE_CONVERSION");

        vm.startBroadcast(deployerKey);

        Ownable(liquidFactory).transferOwnership(newOwner);
        console.log("Transferred Liquid factory to:", newOwner);

        Ownable(feeLocker).transferOwnership(newOwner);
        console.log("Transferred LiquidFeeLocker to:", newOwner);

        Ownable(poolExtAllowlist).transferOwnership(newOwner);
        console.log("Transferred PoolExtensionAllowlist to:", newOwner);

        Ownable(lpLocker).transferOwnership(newOwner);
        console.log("Transferred LpLockerFeeConversion to:", newOwner);

        vm.stopBroadcast();

        console.log("All ownership transferred to Safe:", newOwner);
    }
}
```

- [ ] **Step 2: Verify it compiles**

```bash
forge build --match-contract TransferOwnershipTempo
```

Expected: Compilation succeeds.

- [ ] **Step 3: Commit**

```bash
git add script/tempo/05_TransferOwnership.s.sol
git commit -m "feat: add Tempo ownership transfer script"
```

---

### Task 8: Full build verification

**Files:**
- All `script/tempo/*.s.sol`
- All `src/**/*.sol`

- [ ] **Step 1: Run full build**

```bash
forge build
```

Expected: All contracts and scripts compile successfully.

- [ ] **Step 2: Run existing tests to confirm no regressions**

```bash
forge test
```

Expected: All tests pass. (Tests exercise Base deployment logic; Tempo scripts are config variants, not new logic.)

- [ ] **Step 3: Check formatting**

```bash
forge fmt --check
```

Expected: No formatting violations. If any, fix with `forge fmt`.

---

### Task 9: Update README with Tempo deployment section

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add Tempo Mainnet section to README**

Add after the Base Mainnet deployment section:

```markdown
## Tempo Mainnet (Chain ID: 4217)

**Status:** Pending deployment

**Quote Token:** pathUSD (`0x20C0000000000000000000000000000000000000`) — Tempo has no native ETH/WETH.

| Contract | Address |
|----------|---------|
| Liquid | _pending_ |
| LiquidFeeLocker | _pending_ |
| LiquidPoolExtensionAllowlist | _pending_ |
| LiquidHookDynamicFeeV2 | _pending_ |
| LiquidHookStaticFeeV2 | _pending_ |
| LiquidAirdropV2 | _pending_ |
| LiquidVault | _pending_ |
| LiquidLpLockerFeeConversion | _pending_ |
| Admin Safe | _pending_ |

**Not deployed on Tempo:**
- LiquidUniv4EthDevBuy, LiquidUniv3EthDevBuy, LiquidPresaleEthToCreator, LiquidPresaleAllowlist (require native ETH)
- LiquidSniperAuctionV2, LiquidMevDescendingFees, LiquidSniperUtilV2 (no MEV infrastructure on Tempo)

**Deployment scripts:** `script/tempo/`
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add Tempo Mainnet deployment section to README"
```

---

### Task 10: Bridge funds to Tempo

> **@gs required** — needs treasury/deployer wallet access to bridge USDC from Base.

**No code changes.** Manual operational step.

- [ ] **Step 1: Bridge USDC from Base to Tempo via Stargate**

Go to Stargate UI or call the Base Stargate pool directly:
- Base Stargate Pool (EID 30184): `0x27a16dc786820B16E5c9028b75B99F6f604b5d26`
- Destination: Tempo (LZ Endpoint ID `30410`)
- Result: USDC.e on Tempo at `0x20C000000000000000000000b9537d11c60E8b50`

- [ ] **Step 2: Swap some USDC.e for pathUSD on Tempo's enshrined stablecoin DEX**

pathUSD is needed as the default fee token for contract deployments.

- [ ] **Step 3: Confirm deployer wallet has sufficient pathUSD balance on Tempo**

```bash
cast balance --rpc-url https://rpc.tempo.xyz --erc20 0x20C0000000000000000000000000000000000000 <DEPLOYER_ADDRESS>
```

---

### Task 11: Deploy Safe on Tempo

> **@gs required** — must provide owner addresses and confirm threshold.

- [ ] **Step 1: Set Safe env vars in `.env`**

```bash
SAFE_OWNERS=0xOwner1,0xOwner2,0xOwner3
SAFE_THRESHOLD=2
```

- [ ] **Step 2: Run the Safe deployment script**

```bash
source .env.tempo
forge script script/tempo/00_DeploySafe.s.sol:DeploySafe \
    --rpc-url $TEMPO_RPC_URL \
    --broadcast \
    --verify \
    --verifier-url "https://explore.tempo.xyz/api" \
    -vvvv
```

- [ ] **Step 3: Record the Safe address in `.env.tempo`**

Set `OWNER_ADDRESS=<deployed Safe address>`

---

### Task 12: Deploy Phase 0 — Core contracts

> **@gs required** — broadcast requires deployer key.

- [ ] **Step 1: Run Phase 0 deployment**

```bash
source .env.tempo
forge script script/00_DeployCore.s.sol:DeployCore \
    --rpc-url $TEMPO_RPC_URL \
    --broadcast \
    --verify \
    --verifier-url "https://explore.tempo.xyz/api" \
    -vvvv
```

- [ ] **Step 2: Record outputs in `.env.tempo`**

Set `LIQUID_FACTORY`, `LIQUID_FEE_LOCKER`, `POOL_EXTENSION_ALLOWLIST` from console output.

---

### Task 13: Deploy Phase 1 — Hooks (CREATE2 salt mining)

> **@gs required** — broadcast requires deployer key. Salt mining may take a few minutes.

- [ ] **Step 1: Run Phase 1 deployment**

```bash
source .env.tempo
forge script script/01_DeployHooks.s.sol:DeployHooks \
    --rpc-url $TEMPO_RPC_URL \
    --broadcast \
    --verify \
    --verifier-url "https://explore.tempo.xyz/api" \
    -vvvv
```

- [ ] **Step 2: Record outputs in `.env.tempo`**

Set `LIQUID_HOOK_DYNAMIC_FEE_V2`, `LIQUID_HOOK_STATIC_FEE_V2` from console output.

---

### Task 14: Deploy Phase 2 — Extensions (Tempo subset)

> **@gs required** — broadcast requires deployer key.

- [ ] **Step 1: Run Phase 2 Tempo deployment**

```bash
source .env.tempo
forge script script/tempo/02_DeployExtensions.s.sol:DeployExtensionsTempo \
    --rpc-url $TEMPO_RPC_URL \
    --broadcast \
    --verify \
    --verifier-url "https://explore.tempo.xyz/api" \
    -vvvv
```

- [ ] **Step 2: Record outputs in `.env.tempo`**

Set `LIQUID_AIRDROP_V2`, `LIQUID_VAULT` from console output.

---

### Task 15: Deploy Phase 3b — LP Locker

> **@gs required** — broadcast requires deployer key. Uses reduced optimizer runs.

- [ ] **Step 1: Run Phase 3b deployment**

```bash
source .env.tempo
FOUNDRY_PROFILE=lplocker forge script script/03b_DeployLpLocker.s.sol:DeployLpLocker \
    --rpc-url $TEMPO_RPC_URL \
    --broadcast \
    --verify \
    --verifier-url "https://explore.tempo.xyz/api" \
    -vvvv
```

- [ ] **Step 2: Record output in `.env.tempo`**

Set `LIQUID_LP_LOCKER_FEE_CONVERSION` from console output.

---

### Task 16: Deploy Phase 4 — Configure allowlists

> **@gs required** — broadcast requires deployer key.

- [ ] **Step 1: Run Phase 4 Tempo configuration**

```bash
source .env.tempo
forge script script/tempo/04_ConfigureAllowlists.s.sol:ConfigureAllowlistsTempo \
    --rpc-url $TEMPO_RPC_URL \
    --broadcast \
    -vvvv
```

---

### Task 17: Deploy Phase 5 — Transfer ownership to Safe

> **@gs required** — broadcast requires deployer key. Irreversible — double-check Safe address.

- [ ] **Step 1: Confirm Safe address is correct**

```bash
cast call --rpc-url https://rpc.tempo.xyz $OWNER_ADDRESS "getThreshold()(uint256)"
```

Expected: Returns the threshold number (e.g., `2`).

- [ ] **Step 2: Run Phase 5 Tempo ownership transfer**

```bash
source .env.tempo
forge script script/tempo/05_TransferOwnership.s.sol:TransferOwnershipTempo \
    --rpc-url $TEMPO_RPC_URL \
    --broadcast \
    -vvvv
```

---

### Task 18: Verify all contracts on Tempo explorer

- [ ] **Step 1: Check verification status for each deployed contract**

```bash
for addr in $LIQUID_FACTORY $LIQUID_FEE_LOCKER $POOL_EXTENSION_ALLOWLIST \
    $LIQUID_HOOK_DYNAMIC_FEE_V2 $LIQUID_HOOK_STATIC_FEE_V2 \
    $LIQUID_AIRDROP_V2 $LIQUID_VAULT $LIQUID_LP_LOCKER_FEE_CONVERSION; do
    echo "Checking $addr..."
    cast etherscan-source --chain 4217 $addr > /dev/null 2>&1 && echo "  Verified" || echo "  NOT verified"
done
```

- [ ] **Step 2: Re-verify any unverified contracts manually**

```bash
forge verify-contract <ADDRESS> <CONTRACT_NAME> \
    --chain 4217 \
    --verifier-url "https://explore.tempo.xyz/api" \
    --etherscan-api-key $TEMPO_EXPLORER_API_KEY
```

---

### Task 19: Update README with deployed addresses

- [ ] **Step 1: Replace `_pending_` placeholders in README.md with actual addresses**

- [ ] **Step 2: Commit and push**

```bash
git add README.md .env.tempo
git commit -m "docs: add Tempo Mainnet deployed contract addresses"
git push -u origin deploy/tempo-mainnet
```
