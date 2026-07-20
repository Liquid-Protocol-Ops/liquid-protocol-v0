# Liquid Protocol — Robinhood Chain (4663) Deployment

Deployed 2026-07-12 from branch `feat/robinhood-4663-deploy`. Full launchpad
(everything except the V3 dev-buy — Robinhood Chain is Uniswap-V4-only).

- **Owner (governance):** **Safe** `0xF0E1D993E7ec19a1E83e6288bBE531A2C5ce4131`
  (v1.4.1, threshold 1; signers: deployer + `0x49f69cA2F34567901a137b289F2ff0e677d8d49c`).
  All 7 Ownable contracts + `teamFeeRecipient` transferred to it 2026-07-13. Owner ops
  now need a Safe tx (deployer can sign alone). See `docs/ROBINHOOD-CHAIN.md` §8.
- **Deployer / operator:** `0x4e68600Ba1F1D6C65B05b9287237D51a61F9A47A`
  (key: 1Password `mog.capital` → "Liquid 4663 deployer"). Safe signer + per-token reward admin.
- **Fee recipient / treasury:** the Safe. All fees swept to it 2026-07-13.
- Total gas spent: ~0.0017 ETH. Explorer: https://robinhoodchain.blockscout.com

## Addresses

| Contract | Address |
|---|---|
| Liquid (factory) | `0x65c40274a1a2178a5140f80fcd6fe7efb954e6c2` |
| LiquidFeeLocker | `0xbd81f5d3a761929e3e93d5d3ab6ab83960b7de62` |
| LiquidPoolExtensionAllowlist | `0x35a8ec5ac73631f6be54ed417b982152a5952f31` |
| LiquidHookDynamicFeeV2 | `0xdee7dcdcf599306d3c29e8dd0e6f4c9c4b6f68cc` |
| LiquidHookStaticFeeV2 | `0x6df2567312b4acf7c1817be08f101e5e693a28cc` |
| LiquidAirdropV2 | `0x702a24d567314bac4e945b9515f40154f55ace37` |
| LiquidVault | `0xafb4ec12693aeb6d6bff5a69d03462893f592380` |
| LiquidUniv4EthDevBuy | `0xddd1f6fa6484b84092e9439bfa4ef15bfd1492f6` |
| LiquidPresaleEthToCreator | `0xc68cb2fa7c4eac5c339d8265cfa56c6b813ab0dd` |
| LiquidPresaleAllowlist | `0x19f2db24c16b169e288122704aaa053537958116` |
| LiquidSniperAuctionV2 | `0x583ef5f916d646546191c8cdc0bbe7ebc57fff20` |
| LiquidMevDescendingFees | `0xd86416eedb067213df7336662b3fa3b3a1a5e205` |
| LiquidSniperUtilV2 | `0xffc72d9831b593b75023c3d74a41bad659acfeff` |
| LiquidLpLockerFeeConversion (v1, buggy swap ABI) | `0xfc696955e903ba08ac5c1f8dc2729d0cb465f287` |
| LiquidLpLockerFeeConversion (v2, fixed for RH router) | `0x4AB39080B54121136fEfFf86857641F40dA6b964` |

## Notes

- **V3 dev-buy skipped** — no Uniswap V3 on 4663 (V4 dev-buy covers it). Scripts
  `02`/`04` skip it automatically when `UNISWAP_V3_SWAP_ROUTER` is unset.
- **Phase 5 (transfer ownership) — DONE 2026-07-13** to Safe `0xF0E1D993…` (the
  `05` script covers 6 contracts; the old locker `0xfc69…` was transferred separately).
- **LiquidLpLockerFeeConversion** must be compiled with `FOUNDRY_PROFILE=lplocker`
  (100 runs) — at the default 20k runs it's 27,681 bytes, over EIP-170. At 100
  runs it's 24,571.
- Allowlists configured (Phase 4): both hooks, the LP locker (per hook), the 4
  extensions, and both MEV modules enabled on the factory.
- **Blockscout verification** — the fixed LP locker `0x4AB3…` is **verified**
  (verify the `lplocker`-profile build with `FOUNDRY_PROFILE=lplocker
  forge verify-contract <addr> <Name> --compiler-version 0.8.28 --chain-id 4663
  --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
  --constructor-args <abi-encoded>`; Blockscout can 503/queue transiently — retry).
  The remaining core/hook/extension contracts can be verified the same way (default
  profile) when convenient — indexing lag can require a couple retries.
- Uniswap V4 infra used: PoolManager `0x8366a39C…`, PositionManager `0x58da…`,
  Universal Router `0x8876…`, Permit2 `0x0000…78BA3`, WETH `0x0Bd7…`.

## Fee collection — REQUIRED post-deploy step (was missing, now fixed 2026-07-12)

The phased scripts (00–04) do **not** authorize the LP locker to deposit into
the FeeLocker. This is a manual `DEPLOY.md:175` checklist item that was skipped,
which made **all** `collectRewards` calls revert `Unauthorized` (`0x82b42900`)
at the final `storeFees` step (fees collect from the pool fine, but can't be
handed to the escrow you claim from).

Fixed 2026-07-12 with a single owner tx (global — covers every token launched
through this factory):

```bash
cast send $LIQUID_FEE_LOCKER "addDepositor(address)" $LIQUID_LP_LOCKER_FEE_CONVERSION \
  --rpc-url $RH --private-key "$(op read 'op://mog.capital/Liquid 4663 deployer/credential')"
# tx 0x11014cd76848b25c0593fd97b30ccbd634d428c0cac06f1470ff1057ae1ead0b
# allowedDepositors[0xfc69…] = true
```

Claim flow (per launched token): `collectRewards(token)` on the LP locker
`0xfc69…` → `claim(feeOwner, token)` on the FeeLocker `0xbd81…`.

### SPYING launches (paired vs tokenized SPY `0x117cc2…`)

| Token | Order | Fee pref | Status |
|---|---|---|---|
| `0xe3F6FA5492D874199757278dd000937baD3BC6A2` (v1, wrong order) | SPYING = currency1 | Paired (SPY) | **Claimed** — 0.02235 SPY collected (tx `0xf2cfd343…`) + claimed to deployer (tx `0xea3a5deb…`). |
| `0x01c4942839F4FC08034ee86eA88295FC8E6e8515` (v2, correct: SPYING/SPY) | SPYING = currency0 | Paired (SPY) | **Blocked — open decision.** Accrued ~267,383 SPYING + ~0.09 SPY. Paired conversion swaps the SPYING side → SPY through the **Universal Router `0x8876…`**, and that call reverts empty at ~2076 gas inside the router's `unlockCallback` — *before* the pool swap runs. NOT a liquidity/pool/slippage issue: the Quoter `0x8dc1…` simulates the identical swap fine (267,383 SPYING → 0.000625 SPY, minOut was 0). **Root cause (confirmed):** Robinhood Chain's Universal Router `0x8876…` (verified on Blockscout) is a *customized fork* that adds a `minHopPriceX36` field to the V4 swap-param structs (per-hop min-price protection: `V4TooLittleReceivedPerHopSingle`, `InvalidHopPriceLength`). Its `IV4Router.ExactInputSingleParams` = {poolKey, zeroForOne, amountIn, amountOutMinimum, **minHopPriceX36**, hookData} (6 fields). Canonical Uniswap v4-periphery — which the Liquid LP-locker (and every standard integrator) compiles against — has 5 fields (no `minHopPriceX36`). The locker encodes 5 fields; the router decodes 6; the inserted field shifts `hookData` to a garbage offset → out-of-bounds calldata read → empty revert at ~2076 gas, *before* `poolManager.swap`. Not liquidity/pool/slippage/hook: the Quoter `0x8dc1…` (standard ABI, bypasses the router) simulates the swap fine → 0.000625 SPY out. V1 claimed fine because its fees were all SPY (paired = no conversion swap = router never touched). Not Liquid-specific — affects any standard V4 integrator swapping through the UR on 4663.

**RESOLVED 2026-07-13.** V2 fees recovered: switched to `Both` (`updateFeePreference` tx `0x0b9771e1…`), `collectRewards` (`0xf843d6e6…`), claimed 0.0903 SPY (`0xf32641ba…`) + 267,383 SPYING (`0xc41f19c7…`) to deployer, then converted the SPYING→SPY (0.000625 SPY) via `script/RhSwapExactIn.s.sol` using the 6-field encoding. Old locker `0xfc69…` stays enabled (needed for existing tokens' collection, `Both` only).

**Protocol fix shipped:** `LiquidLpLockerFeeConversion` patched (`_uniSwapLocked` now encodes the 6-field `RhExactInputSingleParams` with `minHopPriceX36=0`) and redeployed at **`0x4AB39080B54121136fEfFf86857641F40dA6b964`** (owner=deployer, router=`0x8876…`, 24,561 bytes at `optimizer_runs=10` — the fix pushed size past EIP-170 at 100 runs, so the `lplocker` profile is now `runs=10`). Enabled on the factory for both hooks (`setLocker` txs `0xf60b5d80…`, `0xc99e6838…`). **Future Paired-conversion launches must use the v2 locker `0x4AB3…`** (the v1 locker's Paired swap still reverts on the forked router). The v2 build is **4663-only** — its swap encoding would revert on a standard v4 chain (Base); do not deploy it elsewhere.

**⚠ Redeploying a locker requires `addDepositor` on the FeeLocker too** — this is easy to miss. The v2 locker also had to be authorized: `addDepositor(0x4AB3…)` on FeeLocker `0xbd81…` (tx `0x8c54e62d…`). Without it, the hook's per-swap auto-collect (`collectRewardsWithoutUnlock` → `storeFees`) reverts `Unauthorized`, which **bricks sells** on tokens launched against that locker once the MEV window closes (buys still work; the revert only fires when there are accrued fees to store). Order of ops for any new locker: deploy → `setLocker` per hook → **`addDepositor` on FeeLocker** → launch.

**Validated end-to-end 2026-07-13** with a throwaway launch `ethlockertest`/`ELT` `0x06f25d40108E31e7F7787412180216c87bCfF7f0` paired vs WETH, Paired pref, new locker. Bought (WETH→ELT), sold (ELT→WETH, accrues token-side fee), then `collectRewards(ELT)` (tx `0x53155b7d…`): the ELT→WETH conversion swap through the forked UR **executed fully** (real `Swap` event, ~140k gas — vs the old locker's empty revert at 2,076 gas), stored + claimed WETH (tx `0x47283aa7…`); ELT claimable ended at 0 (all converted). Scripts: `script/LaunchEthPair.s.sol`, `script/MineEthPairSalt.s.sol`, `script/RhSwapExactIn.s.sol`. |

## FUCKSTOCKS launch — first launch via the TS ladder engine (2026-07-20)

First production launch driven by the **TypeScript ladder engine** in
`liquid-sdk` (branch `feat/ladder-engine`, PR #94) instead of a forge script:
`buildLadder` → `mineTokenSalt` → `deployToken`, all via viem. Multi-position
Clanker-style liquidity ladder (7 positions), not a single wide position.

| Field | Value |
|---|---|
| Token | **`fuckstocks` / FUCKSTOCKS** `0x0A8528a6BDC4d30E5538e3205b1AD84D76838030` |
| Pair | WETH `0x0Bd7…` — FUCKSTOCKS = **currency0** (salt `0x07` mined with `admin=Safe` so it sorts below WETH) |
| Owner | Safe **`0xF0E1D993E7ec19a1E83e6288bBE531A2C5ce4131`** = tokenAdmin + rewardAdmins + rewardRecipients |
| Fees | `FeeIn.Paired` → all fees collected in **WETH** |
| Dynamic fee | **volatility-responsive**: baseFee 1% (10000), maxLpFee 5% (50000), **feeControlNumerator 400,000,000** ("aggressive" — ~5% by ±10% moves). Hook `0xDee7…`. First 4663 launch with a non-zero `feeControlNumerator` (all prior launches were flat). |
| MEV | descending 50% → 1% over 120s (`0xd864…`) |
| Locker | fixed 6-field `0x4AB39080B54121136fEfFf86857641F40dA6b964` |
| Ladder | `buildLadder({profile:"bell", positions:7, startMcUsd:40_000, topMcUsd:3_125_000_000, aggressiveness:0.8, pairedTokenUsd:1865})`. Deep **60.3% of supply at $5–25M MC** (band #4), shallow low, thin tail. start tick **-222660**, tickSpacing 60. |
| positionBps | `[118, 259, 1608, 6030, 1608, 259, 118]` (sum 10000) |
| tickLower | `[-222660, -206580, -190440, -174360, -158280, -142200, -126060]` |
| tickUpper | `[-206580, -190440, -174360, -158280, -142200, -126060, 887220]` (last = tail to max) |
| Deploy tx | `0x6e1110aed727c1f49ed86dc73295ba1dbdecf7fa4bc8b293ebbc51809a8b391a` (block 14721462, 4.98M gas, status 1) |

Validated post-deploy: pool slot0 tick = -222660 (matches intent), deployer
token balance = 0 (all supply laddered), tokenAdmin = Safe on-chain. Safety:
dry-run + on-chain `simulateContract` + `deploy-safety-reviewer` GO before
broadcast; chain-id re-asserted 4663; key read inline via
`op read 'op://mog.capital/Liquid 4663 deployer/credential'` (never on disk).

**First fees claimed (2026-07-20, same day as launch):** a sniper bought
FUCKSTOCKS during the descending-MEV window and paid **~0.4995 WETH** in LP fees.
The hook auto-collected most of it to the FeeLocker escrow for the Safe;
`collectRewards(FUCKSTOCKS)` (tx `0x8ea69a2503b2abf2137d552054611f360c566b5f1b4e563c67793c00645c056e`)
swept the ~0.00013 WETH residual, then `claim(Safe, WETH)` (tx
`0x4e6555d68f321cf6f732fb1e49868fd7aa520778ff8ad23e4feac0a0cd871ee2`) sent
0.4995 WETH to the Safe (Safe WETH balance 0.0505 → 0.5500). Because
`feePreference = Paired`, fees escrow under **WETH**, not the token —
`claim(feeOwner, WETH)`, and both `collectRewards`/`claim` are permissionless
(funds always route to the stored `feeOwner`), so the deployer can trigger them
without a Safe tx.

**Two engine bugs surfaced by this launch (fix in PR #94):**
1. `launchWithLadder` hardcodes `admin = deployer` in **both** the salt mining
   and `tokenAdmin`, so it cannot hand ownership to a Safe (the mined address
   wouldn't match the deployed one). Needs a `tokenAdmin` param threaded into
   `mineTokenSalt` + `deployParams`. Worked around here by calling the lower-level
   pieces directly.
2. `deployToken`'s default `poolData: "0x"` **empty-reverts** on the dynamic-fee
   hook — the hook requires the `PoolInitializationData{extension, extensionData,
   feeData}` wrapper. The README/code comment claiming `"0x" ⇒ hook applies its
   built-in default` is wrong. Default should be
   `buildDynamicFeePoolData(DEFAULT_DYNAMIC_FEE_VARS)`.
