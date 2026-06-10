# wstDIEM Vault — v6 Production Launch (Base mainnet)

**Live:** 2026-06-10 · **Chain:** Base (8453) · **Owner:** Safe multisig `0x872c561f699B42977c093F0eD8b4C9a431280c6c` · **Status:** deployed, Basescan-verified, markets **unseeded**

---

## What it is

**wstDIEM** is a liquid, transferable ERC-4626 wrapper for staked DIEM (Venice's inference-staking asset) on Base. You deposit DIEM, the vault stakes it inside Venice, and you receive **wstDIEM** — a share token whose exchange rate is a one-way ratchet that appreciates as Venice inference revenue and protocol fees accrue. wstDIEM stays liquid (tradeable, composable) and can be used as collateral in dedicated Morpho lending markets.

Think wstETH, but for Venice inference yield instead of ETH staking.

## What launched in v6

A complete, clean redeployment of the vault stack — deployed in a single transaction sequence, ownership handed to the Safe on completion, and **all contracts verified on Basescan**:

| Contract | Address |
|---|---|
| **InferenceVault** (wstDIEM token) | [`0xe49FA849cB37b0e7A42B2335e333fb99474167ba`](https://basescan.org/address/0xe49fa849cb37b0e7a42b2335e333fb99474167ba) |
| **Router** (deposit/exit/leverage) | [`0x74ad4532133Ba538945a5371D249560E66CC7c71`](https://basescan.org/address/0x74ad4532133ba538945a5371d249560e66cc7c71) |
| **FeeRouter** | [`0xa13a6e75d696bAceB38236389eeFD6eCa5FD4ED3`](https://basescan.org/address/0xa13a6e75d696baceb38236389eefd6eca5fd4ed3) |
| **WstDIEMHook** (Uniswap V4, dynamic fee) | [`0xf010A31BBD4B501b4232b1945EC18584Ff9B5080`](https://basescan.org/address/0xf010a31bbd4b501b4232b1945ec18584ff9b5080) |
| **WstDiemVvvOracle** (Morpho, on-chain TWAP) | [`0x9E982637f26aAaAd0bfDBe3c6c1846120C4E5A62`](https://basescan.org/address/0x9e982637f26aaaad0bfdbe3c6c1846120c4e5a62) |
| **WstDiemDiemOracle** (Morpho, vault NAV) | [`0xAF29776f93FE0bf21282bF792A52AC212f20F45c`](https://basescan.org/address/0xaf29776f93fe0bf21282bf792a52ac212f20f45c) |
| **Curve DIEM/wstDIEM** | [`0x21c33a1Bb5f6Eb43563e1fB9e7AA1D4E90C1A0CD`](https://basescan.org/address/0x21c33a1bb5f6eb43563e1fb9e7aa1d4e90c1a0cd) |
| **LiquidityManager** (V4 LP, Safe-controlled) | [`0xbA4129d3718f32Ed48343d40CfAf6Be9096D086b`](https://basescan.org/address/0xba4129d3718f32ed48343d40cfaf6be9096d086b) |
| AgentTGERegistry | [`0xb13830e7f72Eef167A7F188285feBa5f7C1198Ef`](https://basescan.org/address/0xb13830e7f72eef167a7f188285feba5f7c1198ef) |
| SurplusStakingWrapper | [`0x1A74750eb49c2f6C8C44B9eadaE5C55C7941F271`](https://basescan.org/address/0x1a74750eb49c2f6c8c44b9eadae5c55c7941f271) |
| InferenceProduct | [`0xE43c4B1930531360c3924F72e9395e9c5bC4a5F3`](https://basescan.org/address/0xe43c4b1930531360c3924f72e9395e9c5bc4a5f3) |

**Markets created (Morpho Blue):** wstDIEM/VVV (62.5% LLTV) and wstDIEM/DIEM (86% LLTV, leverage loop).
**Secondary market:** Uniswap V4 wstDIEM/WETH dynamic-fee hooked pool + Curve DIEM/wstDIEM.

## What's notable about this deploy

v6 isn't just a redeploy — it's the version that ships the things that make the vault safe to run:

- **Correctly-priced V4 pool.** The pool is initialized at a price derived from an **on-chain anchor** (vault rate × Aerodrome DIEM/VVV TWAP × Chainlink ETH/USD). The deploy script *refuses to initialize* if the supplied price drifts more than ~3% from that anchor — a hard guard against the mispricing that can otherwise brick a fresh V4 pool. Launch price: ~1.35 wstDIEM/WETH (~$1,180/wstDIEM).
- **A hardened collateral oracle.** DIEM has no liquid USD market — its only deep pool is DIEM/VVV on Aerodrome — so the collateral oracle prices wstDIEM in **VVV**, fully on-chain. A pre-launch security review caught that a short TWAP window was manipulable on a single shallow pool; v6 ships a **~12-hour TWAP** plus a **staleness guard** that fails closed if the price data goes stale. No `DIEM = $1` assumptions anywhere.
- **Multisig-owned from birth.** Every upgradeable parameter is owned by the Safe; the deployer key was single-use, funded from treasury, and holds nothing now.
- **Inflation-attack guarded.** A seed position is burned at genesis so the classic ERC-4626 first-depositor attack is uneconomical.
- **Verified & open.** All eleven contracts are source-verified on Basescan.

## Honest status

- **Markets are unseeded.** No lending liquidity is supplied yet, so borrowing/leverage is not live — deposits mint wstDIEM, but the Morpho markets aren't usable until seeded.
- **Unaudited beyond internal review.** The vault code is new. It passed an internal + agent-assisted security review (which is *why* the oracle was hardened pre-launch), but a third-party audit is planned before scaling external TVL. Use accordingly.

## What's next

1. Source DIEM and **seed liquidity** (Curve, the V4 pool, and the Morpho markets) to turn on exits and borrowing.
2. **Third-party audit** before meaningful TVL.
3. Vault **UI** (deposit / borrow / portfolio) and SDK integration.
4. Agent inference-funding integration (agents earn fees → wstDIEM → inference credits).

---

*wstDIEM is experimental DeFi. It is not a deposit, savings product, or guaranteed yield, and you can lose funds. Nothing here is financial advice. See the vault Terms & Conditions before depositing.*
