# wstDIEM Liquid Inference Vault — Base Mainnet Addresses

**Last updated:** 2026-06-12 — **v6 LIVE**; venue adapters redeployed with the MOG-541 `routeYield(minDiemOut)` fix. v5 superseded.
**Chain:** Base mainnet (chain 8453)
**Owner (Safe):** `0x872c561f699B42977c093F0eD8b4C9a431280c6c`

---

## Core Stack (v6 — LIVE 2026-06-10, owner Safe) ✅

Clean redeploy via `DeployV6.s.sol`: hardened VVV oracle (granularity 24 + 2h staleness guard), correctly-priced hooked V4 pool (init tick 3017), no deprecated USDC/WETH oracles. Inflation-guarded (0.01 wstDIEM → address(1)). Markets created but UNSEEDED.

| Contract | Address | Basescan |
|----------|---------|---------|
| InferenceVault (wstDIEM v6) | `0xe49FA849cB37b0e7A42B2335e333fb99474167ba` | [view](https://basescan.org/address/0xe49fa849cb37b0e7a42b2335e333fb99474167ba) |
| Router | `0x74ad4532133Ba538945a5371D249560E66CC7c71` | [view](https://basescan.org/address/0x74ad4532133ba538945a5371d249560e66cc7c71) |
| FeeRouter | `0xa13a6e75d696bAceB38236389eeFD6eCa5FD4ED3` | [view](https://basescan.org/address/0xa13a6e75d696baceb38236389eefd6eca5fd4ed3) |
| WstDIEMHook (dynamic fee) | `0xf010A31BBD4B501b4232b1945EC18584Ff9B5080` | [view](https://basescan.org/address/0xf010a31bbd4b501b4232b1945ec18584ff9b5080) |
| WstDiemVvvOracle (62.5% mkt) | `0x9E982637f26aAaAd0bfDBe3c6c1846120C4E5A62` | [view](https://basescan.org/address/0x9e982637f26aaaad0bfdbe3c6c1846120c4e5a62) |
| WstDiemDiemOracle (86% mkt) | `0xAF29776f93FE0bf21282bF792A52AC212f20F45c` | [view](https://basescan.org/address/0xaf29776f93fe0bf21282bf792a52ac212f20f45c) |
| Curve DIEM/wstDIEM | `0x21c33a1Bb5f6Eb43563e1fB9e7AA1D4E90C1A0CD` | [view](https://basescan.org/address/0x21c33a1bb5f6eb43563e1fb9e7aa1d4e90c1a0cd) |
| LiquidityManager (Safe-controlled) | `0xbA4129d3718f32Ed48343d40CfAf6Be9096D086b` | [view](https://basescan.org/address/0xba4129d3718f32ed48343d40cfaf6be9096d086b) |
| AgentTGERegistry | `0xb13830e7f72Eef167A7F188285feBa5f7C1198Ef` | [view](https://basescan.org/address/0xb13830e7f72eef167a7f188285feba5f7c1198ef) |
| SurplusStakingWrapper | `0x1A74750eb49c2f6C8C44B9eadaE5C55C7941F271` | [view](https://basescan.org/address/0x1a74750eb49c2f6c8c44b9eadae5c55c7941f271) |
| InferenceProduct | `0xE43c4B1930531360c3924F72e9395e9c5bC4a5F3` | [view](https://basescan.org/address/0xe43c4b1930531360c3924f72e9395e9c5bc4a5f3) |
| Treasury (fees, Splits) | `0x2AfE303f4AbD285631872c5A971e5D32fBF1E087` | — |

**v6 Morpho markets** (created, unseeded): wstDIEM/VVV 62.5% (oracle `0x9E98…`) + wstDIEM/DIEM 86% (oracle `0xAF29…`), IRM `0x46415998…`. **V4 pool:** WETH/wstDIEM, DYNAMIC_FEE_FLAG, tickSpacing 60, hook `0xf010…5080`, init tick 3017. Deploy: `docs/vault/V6_DEPLOY_RUNBOOK.md`; deployer `0x428Fac…` (single-use). Post-deploy TODO: Basescan verify, rotate veniceSigner, seed liquidity, cross-repo propagation.

## Venue Adapters (v6 — LIVE 2026-06-12) ✅

Redeployed with the MOG-541 `routeYield(minDiemOut)` slippage floor and registered on the v6 vault (`isVenueAdapter = true`). Keeper `0x988CE72d` is operator + authorized settler on both. The old `amountOutMinimum:0` adapters are deregistered.

| Contract | Address | Basescan |
|----------|---------|---------|
| AntSeedAdapter | `0xed98A5f4F3AcFd0752A81FDd03DD28b7A44A18b7` | [view](https://basescan.org/address/0xed98a5f4f3acfd0752a81fdd03dd28b7a44a18b7) |
| SurplusAdapter | `0x91b3E39Ef6335D97876AdB4448A998c7cbD3885F` | [view](https://basescan.org/address/0x91b3e39ef6335d97876adb4448a998c7cbd3885f) |

> **X402Adapter is not redeployed for v6** — the v5 `0xC3C3…` is unregistered on the v6 vault. Only AntSeed + Surplus are live.

---

## Core Stack (v5 — SUPERSEDED by v6)

| Contract | Address | Basescan |
|----------|---------|---------|
| InferenceVault (wstDIEM) | `0xb9f23c33FfD2213f31C0cFb6c9e2fDf525a9Dd2D` | [view](https://basescan.org/address/0xb9f23c33ffd2213f31c0cfb6c9e2fdf525a9dd2d) |
| FeeRouter | `0x3b8d968DCca09E319fac7Df741804Af5644E3a60` | [view](https://basescan.org/address/0x3b8d968dcca09e319fac7df741804af5644e3a60) |
| Router | `0x6fF481F4B3B0E2ADa548D454F7011D1ed51532B6` | [view](https://basescan.org/address/0x6ff481f4b3b0e2ada548d454f7011d1ed51532b6) |
| AgentTGERegistry | `0x09a4227935FF15b261533238F79935CCcA0e7941` | [view](https://basescan.org/address/0x09a4227935ff15b261533238f79935ccca0e7941) |
| SurplusStakingWrapper | `0x04fAc3e264bD05478Ffc1Caa25394403f8eBc7d7` | [view](https://basescan.org/address/0x04fac3e264bd05478ffc1caa25394403f8ebc7d7) |
| InferenceProduct | `0x8620304D28c162E2D2Ae3bF279516DAc368D6879` | [view](https://basescan.org/address/0x8620304d28c162e2d2ae3bf279516dac368d6879) |

## Venue Adapters (v5 — SUPERSEDED)

| Contract | Address | Basescan |
|----------|---------|---------|
| AntSeedAdapter | `0xE9C2BE3ab25E97Ef4364c505202016106Bec6a6e` | [view](https://basescan.org/address/0xe9c2be3ab25e97ef4364c505202016106bec6a6e) |
| SurplusAdapter | `0xB67A86Ab50e30d7509eeD205Fc01A70758B227Db` | [view](https://basescan.org/address/0xb67a86ab50e30d7509eed205fc01a70758b227db) |
| X402Adapter | `0xC3C3CaC663f88304a38Cb9C4e9c02bB57DB00142` | [view](https://basescan.org/address/0xc3c3cac663f88304a38cb9c4e9c02bb57db00142) |

## Morpho Markets (v5)

| Market | Oracle | LLTV | Basescan |
|--------|--------|------|---------|
| wstDIEM/DIEM (leverage loop) | `0xB1B192fc0190bA15F4EC76BF6032123bc688F76D` | 86% | [view](https://basescan.org/address/0xb1b192fc0190ba15f4ec76bf6032123bc688f76d) |
| wstDIEM/USDC | `0x7F3eAb9863d4f5a1d34d89f7b802C0eA2469b51a` | 62.5% — DEPRECATED (MOG-542, do not use) | [view](https://basescan.org/address/0x7f3eab9863d4f5a1d34d89f7b802c0ea2469b51a) |
| wstDIEM/WETH | `0x73FddCCBB524b04b43EdED9C4d20C061DE291F07` | 62.5% — DEPRECATED (MOG-542, do not use) | [view](https://basescan.org/address/0x73fddccbb524b04b43eded9c4d20c061de291f07) |
| wstDIEM/DIEM (77% LLTV) | `0xE762e8011D453853638D1978398df8b1D383A2D9` | 77% | — |
| wstDIEM/VVV (on-chain TWAP, MOG-544) | `0xC76e2fe5176B432035Def5362023a8DF36bEE94E` | 62.5% | [view](https://basescan.org/address/0xc76e2fe5176b432035def5362023a8df36bee94e) |

> **wstDIEM/USDC and wstDIEM/WETH markets are DEPRECATED** (MOG-542/549): their oracles price wstDIEM collateral with a hardcoded DIEM=$1, which is wrong (DIEM ≈ $1,450). They are unseeded and must not be supplied to or borrowed from. The wstDIEM/VVV market (fully on-chain oracle) is the canonical lending venue.
>
> **MOG-549 sweep result:** "$1" appears in two roles. As an *inference entitlement* ($1/DIEM/day — `AgentTGERegistry` tier allocations, `InferenceProduct` capacity) it is CORRECT (Venice's real mechanic; sale price is a separate owner param `pricePerDiemDayUSDC=0.8e6`). As a *collateral market price* it is WRONG — but only the two oracles above + the V4 pool init (MOG-548) used it that way. `FeeRouter`/adapters/`Router` convert at market (`amountOutMinimum:0`), carrying no $1 assumption.

**wstDIEM/VVV market** (created 2026-06-05, deployer v6): ID `0xab0345699b8e7a86763b6adbf165c6cd367d11d8e6d875c0f1a20861d8f4f8c8` — collateral wstDIEM, loan **liquid VVV** `0xacfE6019…`, oracle `0xC76e2fe5…`, IRM `0x46415998…`. Oracle is fully on-chain (`vault rate × Aerodrome DIEM→VVV TWAP`, granularity 2 ≈ ~1h); immutable. **Unseeded — do NOT supply borrowable VVV / open borrows until the liquidation path (wstDIEM→DIEM via Curve→VVV via Aerodrome) has depth (MOG-536); size caps to the ~$6M Aerodrome v2 pool.**

## Liquidity Pools (v5)

| Pool | Address |
|------|---------|
| Curve DIEM/wstDIEM StableSwap | `0xB9c7F62e4EeC145bFa1C6bBc5fFdFf246181FdA2` |
| Uniswap V4 WETH/wstDIEM (0.3%) | Pool in `0x498581fF718922c3f8e6A244956aF099B2652b2b` (PoolManager) |

## External Dependencies (Base mainnet)

| Protocol | Address | Used for |
|----------|---------|---------|
| DIEM token | `0xF4d97F2da56e8c3098f3a8D538DB630A2606a024` | Vault asset; built-in `stake()`/`unstake()` |
| VVV token (liquid ERC-20) | `0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf` | `depositVVV` input; wstDIEM/VVV Morpho loan token; Aerodrome DIEM/VVV pair. **Use this as `vvv` — not sVVV.** |
| VVV staking → sVVV (non-transferrable) | `0x321b7ff75154472B18EDb199033fF4D116F340Ff` | `stake()` → sVVV → `mintDiem()` → DIEM. Cannot be a Morpho loan token / oracle pool token. |
| Aerodrome DIEM/VVV pool (volatile v2) | `0xbB345D35450BF9Ee76F3D2cE214E8e7AC5e1071d` | `quote(DIEM,1e18,n)` TWAP source for `WstDiemVvvOracle` (~$6M; token0=VVV, token1=DIEM) |
| Uniswap V3 SwapRouter02 | `0x2626664c2603336E57B271c5C0b26F421741e481` | WETH/USDC→DIEM swaps |
| Uniswap V4 PoolManager | `0x498581fF718922c3f8e6A244956aF099B2652b2b` | WETH/wstDIEM pool |
| Morpho Blue | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` | Leverage markets |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | Adapter settlement |

## Deployer & Governance

| Role | Address | 1Password |
|------|---------|---------|
| Safe (owner) | `0x872c561f699B42977c093F0eD8b4C9a431280c6c` | SK1: `liq-safe-signer-1` (mog.capital), SK2: `liq-safe-signer-2` (Personal) |
| Deployer v6 | `0xf04822e5B0E76A34aeeA936c79B4439f794b8Be1` | `op://Personal/wstDIEM v6 Deployer EOA/credential` (item `rhuh6s2tocpjzdi7kvvnjrps7i`) |
| Deployer v5 (legacy) | `0x10900528c57BBCe07C223B25Ae9bB66966274b5D` | `el4qwixmdot757dpxcqgfo43qe` (mog.capital) |
| Keeper EOA | `0x988CE72d127b8A06821BBb3708897dBdc0D66f2f` | `~/.splits/config.json` key.privateKey |
| veniceSigner | `0x10900528c57BBCe07C223B25Ae9bB66966274b5D` | Same as deployer v5 — rotate to Privy wallet before production |

## Splits Funding Accounts (Base mainnet)

| Account | Address | Purpose |
|---------|---------|---------|
| wstdiem-deployer | `0xf4DB2a7B6902924EFCd8270d23B205969EfF3316` | Deployment gas budget — proposes ETH to deployer v6 EOA |
| wstdiem-keeper | `0x102368E997ced4b94d093813B3c1F5fB1F15f4B1` | Keeper gas budget — funds `0x988C…6f2f` |

## Old Vault (v4 — withdrawals pending June 18)

| Contract | Address | Status |
|----------|---------|--------|
| InferenceVault v4 | `0x4751BA2b09374C1929FC01734a166e3c8cd75810` | `initiateEnableWithdrawals()` called 2026-06-04; enable on 2026-06-18 (MOG-520) |
