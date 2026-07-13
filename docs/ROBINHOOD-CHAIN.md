# Liquid Protocol on Robinhood Chain (4663)

Full launchpad deployment guide for **Robinhood Chain mainnet** — deploying the
protocol, launching tokens, and collecting fees. Deployed 2026-07-12/13.

- **Chain:** Robinhood Chain, chainId **4663**, gas token **ETH**, 100 ms blocks,
  FCFS sequencing (no priority fees), **Uniswap-v4-only** (no v3).
- **RPC:** `https://rpc.mainnet.chain.robinhood.com`
- **Explorer / verifier:** [Blockscout](https://robinhoodchain.blockscout.com)
  (`--verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/`)
- **Owner (governance):** **Safe** `0xF0E1D993E7ec19a1E83e6288bBE531A2C5ce4131`
  (Safe v1.4.1, threshold 1). Owns every Ownable protocol contract and is the
  team-fee recipient. Signers: deployer `0x4e68600Ba1F1D6C65B05b9287237D51a61F9A47A`
  + `0x49f69cA2F34567901a137b289F2ff0e677d8d49c`.
- **Deployer / operator:** `0x4e68600Ba1F1D6C65B05b9287237D51a61F9A47A`
  (1Password `mog.capital` → "Liquid 4663 deployer"). Deployed the protocol and is
  a Safe signer, so — with threshold 1 — it can still execute any owner op via a
  single-sig Safe transaction. It also remains the per-token **reward admin**.

> ⚠️ **Read [§4 The forked Universal Router](#4-the-forked-universal-router-critical)
> before touching fees or swaps.** It is the single most important 4663-specific
> gotcha and it changes which LP-locker you must use.

---

## 1. Addresses

### Liquid protocol

| Contract | Address |
|---|---|
| Factory (`Liquid.sol`) | `0x65c40274A1a2178A5140F80fcd6Fe7eFB954e6C2` |
| Fee Locker | `0xBd81F5d3a761929e3e93D5d3Ab6aB83960B7dE62` |
| **LP Locker Fee Conversion — USE THIS** (fixed for RH router) | `0x4AB39080B54121136fEfFf86857641F40dA6b964` |
| LP Locker Fee Conversion — **superseded** (buggy swap ABI) | `0xfc696955e903ba08ac5c1f8dc2729d0cb465f287` |
| Hook — Dynamic Fee V2 | `0xDee7DcDCf599306D3c29e8dd0E6F4C9c4b6F68Cc` |
| Hook — Static Fee V2 | `0x6DF2567312B4ACF7C1817be08F101E5e693a28cC` |
| MEV Descending Fees | `0xd86416EEdb067213dF7336662b3fa3B3a1a5E205` |
| Sniper Auction V2 | `0x583EF5F916d646546191c8cDc0BBE7EBC57FFF20` |
| Sniper Util V2 | `0xfFc72D9831B593B75023C3D74a41baD659ACFeFF` |
| Airdrop V2 | `0x702A24D567314Bac4e945B9515F40154f55ACE37` |
| Vault | `0xAfB4eC12693AEb6D6bff5A69d03462893F592380` |
| Univ4 ETH Dev Buy | `0xddD1F6FA6484B84092e9439bFa4EF15bFd1492f6` |
| Presale ETH to Creator | `0xC68Cb2FA7c4EAc5c339d8265CFa56c6b813AB0dd` |
| Presale Allowlist | `0x19f2Db24c16b169e288122704aAa053537958116` |
| Pool Extension Allowlist | `0x35a8eC5ac73631F6Be54eD417B982152a5952f31` |

### External (Uniswap v4 + tokens)

| Contract | Address |
|---|---|
| Pool Manager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| Position Manager | `0x58daec3116aae6D93017bAAea7749052E8a04fA7` |
| Universal Router (**forked — see §4**) | `0x8876789976dEcBfCbBbe364623C63652db8C0904` |
| Quoter | `0x8dc178efb8111bb0973dd9d722ebeff267c98f94` |
| StateView | `0xf3334192d15450cdd385c8b70e03f9a6bd9e673b` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |

Also available in the SDK — see [§7](#7-sdk-usage).

---

## 2. Deploying the protocol from scratch

Phased Foundry scripts under `script/`. Set the environment first:

```bash
export RH_RPC_URL=https://rpc.mainnet.chain.robinhood.com
export DEPLOYER_PRIVATE_KEY="$(op read 'op://mog.capital/Liquid 4663 deployer/credential')"
export OWNER_ADDRESS=0x4e68600Ba1F1D6C65B05b9287237D51a61F9A47A
export LIQUID_PRESALE_FEE_RECIPIENT=$OWNER_ADDRESS
export UNISWAP_V4_POOL_MANAGER=0x8366a39CC670B4001A1121B8F6A443A643e40951
export UNISWAP_V4_POSITION_MANAGER=0x58daec3116aae6D93017bAAea7749052E8a04fA7
export UNISWAP_UNIVERSAL_ROUTER=0x8876789976dEcBfCbBbe364623C63652db8C0904
export PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3
export WETH=0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
cast chain-id --rpc-url $RH_RPC_URL   # MUST print 4663 before any --broadcast
```

Run the phases in order, exporting each phase's printed addresses before the next:

| Phase | Script | Notes |
|---|---|---|
| Core | `00_DeployCore.s.sol` | factory, fee locker, pool-extension allowlist |
| Hooks | `01_DeployHooks.s.sol` | dynamic + static fee hooks |
| Extensions | `02_DeployExtensions.s.sol` | vault, airdrop, dev-buy, presale. **V3 dev-buy auto-skips** when `UNISWAP_V3_SWAP_ROUTER` is unset (no v3 on 4663) |
| MEV | `03a_DeployMev.s.sol` | sniper auction + util, descending fees |
| LP locker | `03b_DeployLpLocker.s.sol` | **must build with `FOUNDRY_PROFILE=lplocker`** (see §5) |
| Config | `04_ConfigureAllowlists.s.sol` | enables hooks/lockers/extensions/MEV on the factory |
| Ownership | `05_TransferOwnership.s.sol` | **skip** — owner is already the deployer EOA |

Then **authorize the LP locker on the Fee Locker** — a manual step the phased
scripts do NOT perform, and skipping it breaks fee collection *and* trading (§5):

```bash
cast send $LIQUID_FEE_LOCKER "addDepositor(address)" $LIQUID_LP_LOCKER_FEE_CONVERSION \
  --rpc-url $RH_RPC_URL --private-key "$DEPLOYER_PRIVATE_KEY"
```

Verify on Blockscout with
`forge verify-contract <addr> <Name> --chain-id 4663 --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/`
(set a dummy `ETHERSCAN_API_KEY_1=blockscout` to satisfy `foundry.toml` parsing).

---

## 3. Launching a token

Reference scripts: `LaunchEthPair.s.sol` (paired vs WETH) and `LaunchSpying.s.sol`
(paired vs a tokenized equity). Both mirror the SDK's default deploy config: a
dynamic-fee hook, single-sided token liquidity, descending-fee MEV module, and a
`FeeIn.Paired` LP-locker reward preference.

**Token must sort below the paired token** so it becomes `currency0` (the liquid,
single-sided side). Mine `tokenConfig.salt` for this with `MineEthPairSalt.s.sol`
(the factory CREATE2 salt is `keccak256(abi.encode(tokenAdmin, tokenConfig.salt))`):

```bash
PAIRED_TOKEN=0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73 \
TOKEN_NAME=mytoken TOKEN_SYMBOL=MTK \
LIQUID_FACTORY=0x65c40274A1a2178A5140F80fcd6Fe7eFB954e6C2 \
DEPLOYER_ADDRESS=0x4e68600Ba1F1D6C65B05b9287237D51a61F9A47A \
forge script script/MineEthPairSalt.s.sol            # prints TOKEN_SALT
```

Then launch, pointing `LP_LOCKER` at the **fixed** locker `0x4AB3…`:

```bash
LIQUID_FACTORY=0x65c40274A1a2178A5140F80fcd6Fe7eFB954e6C2 \
LIQUID_HOOK_DYNAMIC_FEE_V2=0xDee7DcDCf599306D3c29e8dd0E6F4C9c4b6F68Cc \
LIQUID_MEV_DESCENDING_FEES=0xd86416EEdb067213dF7336662b3fa3B3a1a5E205 \
LP_LOCKER=0x4AB39080B54121136fEfFf86857641F40dA6b964 \
PAIRED_TOKEN=0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73 \
TOKEN_NAME=mytoken TOKEN_SYMBOL=MTK TOKEN_SALT=<mined> \
forge script script/LaunchEthPair.s.sol --rpc-url $RH_RPC_URL --broadcast
```

The factory ships **deprecated** (deployments disabled); the launch scripts call
`setDeprecated(false)` once if needed. Every token is a fixed 100 B × 1e18 supply;
100 % is deposited as single-sided liquidity (deployer keeps only dust).

---

## 4. The forked Universal Router (CRITICAL)

Robinhood Chain's Universal Router `0x8876…` is a **customized fork** (verified on
Blockscout). It adds per-hop min-price protection, which inserts an extra field
into every Uniswap-v4 swap-param struct:

| | Canonical v4-periphery | Robinhood's fork |
|---|---|---|
| `ExactInputSingleParams` | poolKey, zeroForOne, amountIn, amountOutMinimum, **hookData** | poolKey, zeroForOne, amountIn, amountOutMinimum, **`minHopPriceX36`**, hookData |

Any contract that builds a v4 router swap with the **standard 5-field** struct
encodes one word short of what the router expects; the field misalignment sends
`hookData` to a garbage offset and the call **reverts empty at ~2 076 gas inside
`unlockCallback`**, before the pool swap runs. The Commands/Actions IDs are
unchanged (`V4_SWAP=0x10`, `SWAP_EXACT_IN_SINGLE=0x06`, `SETTLE_ALL=0x0c`,
`TAKE_ALL=0x0f`) — only the struct ABI differs. The Quoter uses the standard
interface and bypasses the router, so quoting a swap succeeds even when routing it
reverts — do not treat a good quote as proof the swap will land.

**Fix:** encode the **6-field** struct with `minHopPriceX36 = 0` (disables the
per-hop check). This is baked into:
- the LP locker `0x4AB3…` (`LiquidLpLockerFeeConversion._uniSwapLocked`, so its
  Paired fee-conversion works), and
- `script/RhSwapExactIn.s.sol` — a standalone, reusable exact-in swap you can use
  for manual conversions or dev-buys on 4663.

The **original locker `0xfc69…` is superseded**: it encodes the 5-field struct, so
its Paired conversion reverts. It stays enabled only so tokens launched against it
before the fix can still collect via `FeeIn.Both`. **Launch new tokens against
`0x4AB3…`.** (The fixed locker is a 4663-only build — its encoding would revert on
a standard v4 chain like Base.)

---

## 5. Fee collection & the mandatory locker wiring

### The three-step locker rule

A LP locker needs **three** things before tokens launched against it can trade and
collect, or trading breaks:

1. **Deploy** the locker (`03b_DeployLpLocker.s.sol`, `FOUNDRY_PROFILE=lplocker`).
2. **`setLocker(locker, hook, true)`** on the factory, once per hook.
3. **`addDepositor(locker)`** on the Fee Locker `0xBd81…`.

Step 3 is easy to forget (it is not in the phased scripts). The hook **auto-collects
fees on every swap** via `collectRewardsWithoutUnlock` → `storeFees`; if the locker
is not an authorized Fee-Locker depositor, `storeFees` reverts `Unauthorized`
(`0x82b42900`). That **bricks sells** on the token once the MEV window closes (buys
still pass because there is nothing to store yet). Symptom: `collectRewards` and
sell swaps revert `Unauthorized`; fix is a one-time `addDepositor`.

### Collecting & claiming

Fees accrue in the Fee Locker per reward recipient. To sweep and claim:

```bash
# 1. collect (accrues fees into the Fee Locker; converts token→paired for FeeIn.Paired)
cast send $LP_LOCKER "collectRewards(address)" $TOKEN --rpc-url $RH_RPC_URL --private-key "$PK"
# 2. claim what was stored (permissionless — always pays the feeOwner)
cast send $FEE_LOCKER "claim(address,address)" $FEE_OWNER $PAID_TOKEN --rpc-url $RH_RPC_URL --private-key "$PK"
# read a claimable balance:
cast call $FEE_LOCKER "feesToClaim(address,address)(uint256)" $FEE_OWNER $PAID_TOKEN --rpc-url $RH_RPC_URL
```

- **`FeeIn.Paired`** converts the token-side fees to the paired token via the router
  (needs the fixed locker on 4663) → you claim only the paired token.
- **`FeeIn.Both`** skips the conversion swap and stores both tokens as-is → you claim
  both. Use this to recover fees from tokens stuck on the old locker.
- Reward admins can switch preference: `updateFeePreference(token, rewardIndex, feeIn)`
  (`FeeIn { Both=0, Paired=1, Liquid=2 }`).

### The EIP-170 size caveat (`FOUNDRY_PROFILE=lplocker`)

The 6-field-swap fix pushes `LiquidLpLockerFeeConversion` over the 24 576-byte
runtime limit at the default optimizer setting. The `lplocker` profile compiles it
at `optimizer_runs = 10` → 24 561 bytes. Always build/deploy/verify the locker with
`FOUNDRY_PROFILE=lplocker`.

---

## 6. Validation (2026-07-13)

The fixed locker was validated end-to-end with a throwaway launch `ELT`
(`0x06f25d40108E31e7F7787412180216c87bCfF7f0`) paired vs WETH, `FeeIn.Paired`:
buy (WETH→ELT) → sell (ELT→WETH, accrues token-side fees) → `collectRewards(ELT)`,
which ran the **ELT→WETH conversion swap through the forked router to completion**
(real `Swap` event, ~140 k gas — vs the old locker's empty revert at 2 076 gas),
then stored + claimed WETH with the ELT-side balance fully converted. The
`addDepositor` gap in §5 was discovered by this validation.

> ⚠️ **ELT launched at a high market cap (~230 WETH ≈ $0.8M).** `LaunchEthPair.s.sol`
> reused SPYING's start tick `-198720`, but that tick was calibrated for a paired
> unit worth ~$600 (tokenized SPY); WETH (~$3.5k) is ~6× more valuable, so the same
> tick yields ~6× the MC. This was harmless for a throwaway validation, but **real
> WETH-paired launches must recompute the start tick for the target MC**:
> `tick = ln(MC_target / (supply × ETH_usd)) / ln(1.0001)`, snapped to the tick
> spacing (60). Don't copy `-198720` for an ETH-paired launch.

---

## 7. SDK usage

The [`liquid-sdk`](../../../ops/liquid-protocol-ops/sdk) exports Robinhood Chain as
a supported chain:

```ts
import { getChainConfig, robinhoodChain, ADDRESSES_ROBINHOOD } from "liquid-sdk";
import { createWalletClient, http } from "viem";

const { chain, addresses, external } = getChainConfig(4663);
const wallet = createWalletClient({ chain, transport: http() });
// addresses.LP_LOCKER_FEE_CONVERSION === 0x4AB3… (the fixed locker)
```

`getChainConfig(chainId)` returns `{ chain, addresses, external }` for `8453`
(Base) or `4663` (Robinhood). `LiquidSDK` is **chain-parametrized**: pass
`chainId` in `LiquidSDKConfig` (defaults to `8453`, so Base callers are
unchanged) and it resolves the chain + address sets for you:

```ts
const sdk = new LiquidSDK({ publicClient, walletClient, chainId: 4663 });
// deployToken/collectRewards/etc. now target Robinhood Chain automatically
```

The SDK does not build any Uniswap v4 router swap client-side (the dev-buy just
ABI-encodes the extension's own config for the on-chain extension to execute), so
the forked-router `minHopPriceX36` concern (§4) does not apply at the SDK layer —
on 4663 the SDK simply resolves to the fork-fixed locker and the 4663 dev-buy
extension address.

---

## 8. Governance & ownership

As of 2026-07-13, ownership and the protocol treasury are held by a **Safe**:
`0xF0E1D993E7ec19a1E83e6288bBE531A2C5ce4131` (v1.4.1, **threshold 1**; signers:
deployer `0x4e68…` + `0x49f6…`).

**Owned by the Safe** (all `transferOwnership`'d from the deployer): factory,
fee locker, pool-extension allowlist, **both** LP lockers (`0x4AB3…` and `0xfc69…`),
sniper auction, presale-eth-to-creator. The hooks, vault, airdrop, MEV modules,
sniper util, dev-buy and presale allowlist are not `Ownable`.

**Running owner ops now requires a Safe transaction** — `setDeprecated`,
`setLocker`, `setHook`, `setExtension`, `setMevModule`, `addDepositor` (fee locker),
`claimTeamFees`, `setTeamFeeRecipient`, etc. With threshold 1 the deployer can build
and execute these single-handed via the Safe (Safe UI, or `execTransaction`). Update
the §2 deploy flow and §5 locker-wiring steps accordingly: `addDepositor` / `setLocker`
for any future locker must be sent from the Safe, not the deployer EOA.

**Treasury:** the Safe is the `teamFeeRecipient` and holds all fees swept to date
(SPY, WETH, and SPYING/ELT balances).

**⚠ Follow-up — future LP fees:** per-token **reward recipients are still the
deployer EOA**, so LP fees from existing tokens keep accruing to the deployer's
`feesToClaim` balance (not the Safe). The deployer is still the per-token **reward
admin**, so it can retarget them with
`updateRewardRecipient(token, rewardIndex, safe)` on the relevant locker (this is a
reward-admin call, not an owner call — no Safe tx needed). New launches can set
`rewardRecipients = [safe]` directly in the launch config.
