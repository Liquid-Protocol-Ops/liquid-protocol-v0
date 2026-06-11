# wstDIEM Mainnet Smoke Test — Splits-Funded Plan (MOG-536)

**Status:** draft, 2026-06-08. Goal: validate the seed → market flows on Base mainnet
with *thin* amounts, funded from the Splits `wstDIEM-seed` vault. Fork rehearsal is done
(`test/vault/integration/VvvMarketLifecycle.t.sol`, 4 tests green) — this is the small
real-money confirmation before production seeding (which is gated on DIEM sourcing, MOG-547).

## Capital on hand (Base mainnet, 2026-06-08)

| Account | Holds |
|---------|-------|
| Splits `wstDIEM-seed` `0x47d1F0EB…` | **5.95 WETH + 4.624 DIEM** (the seed source) |
| Splits Treasury / deployer / keeper vaults | empty |
| v6 deployer EOA `0xf04822e5…` | **0.05 ETH** (only native gas on hand) |
| Safe `0x872c…`, keeper EOA `0x988C…` | ~0 ETH |

Owner will add **up to ~20 DIEM at launch** — but the smoke test runs on the ~4.6 DIEM
available now.

## Blocker 0 — gas bootstrap

Nothing can execute without native ETH. Two unknowns to settle first:

1. **How is Splits-vault execution gas paid?** If Splits relays/sponsors signer txs, the
   `wstDIEM-seed` vault can transfer/act gaslessly. If the signer pays, the keeper EOA
   (`0x988C…`, registered signer) needs ETH. **Verify before relying on Splits transfers.**
2. If signer-paid: `v6 deployer EOA (0.05 ETH) → ~0.01 ETH to keeper EOA` (and keep the
   rest) to bootstrap. Base gas is ~0.00001 ETH/tx, so 0.05 ETH covers the whole test.

Note: **seeding pools is permissionless** — it does *not* need the Safe. So we do **not**
need to top up the Safe for the smoke test; only the executor (keeper or deployer EOA).

## Execution model (pick one)

- **(A) Executor EOA (simplest for smoke test):** `wstDIEM-seed` transfers DIEM + WETH to
  an executor EOA (deployer or keeper); the EOA runs the seed steps. Capital briefly leaves
  the vault.
- **(B) Splits custom-tx (better custody, for production):** the `wstDIEM-seed` vault itself
  runs approve + add_liquidity / supply via `transactions_create_custom`, signed by the
  keeper. Keeps custody in the vault; more steps. Recommended for the production seed, MOG-536.

For the smoke test use **(A)**.

## Steps (thin amounts, model A)

All amounts are deliberately tiny — this proves the *flows on mainnet*, not depth.

1. **Bootstrap gas** (Blocker 0).
2. **Move seed capital:** `wstDIEM-seed` → executor EOA: ~3 DIEM + ~2 WETH.
3. **Mint wstDIEM:** executor deposits ~2 DIEM into vault v5 → ~1.95 wstDIEM (2.5% deposit fee).
4. **Seed Curve** (`0xB9c7F62e…`, currently empty): `add_liquidity([1 DIEM, ~1 wstDIEM], 0)`.
   Gives the liquidation hop a sliver of *real* depth + confirms the NG pool accepts the
   ERC4626 asset type live. coin0=DIEM, coin1=wstDIEM.
5. **Seed Uniswap V4** wstDIEM/WETH (optional this round): add a small position
   (~0.5 wstDIEM + price-matched WETH) via `InitPools.s.sol`. Needed for Router `exitToWETH`;
   can defer if focusing on the lending market.
6. **Morpho VVV market — borrow leg (optional, needs VVV):** we hold only 0.08 VVV. To test a
   borrow+repay, either (a) buy a little VVV with WETH on Aerodrome (thin), supply ~100 VVV as
   lender, post the ~1 wstDIEM as collateral, borrow a few VVV, repay; or (b) defer the borrow
   leg until VVV is on hand. The fork rehearsal already proved borrow + liquidation + unwind,
   so (b) is acceptable for a first smoke test.
7. **Verify:** Curve `balances()` non-zero; vault `totalAssets`/rate sane; (if 6 ran) Morpho
   `position`/`market` reflect the borrow; then unwind/repay to return capital to the vault.

## Explicitly NOT in scope (gated)

- **Opening real borrows / supplying production VVV** — gated on liquidation-path *depth*
  (live Curve + Aerodrome), not just routing (MOG-536), and on DIEM sourcing (MOG-547).
- **Production-size seeding** — waits on the ~20 DIEM launch seed + a DIEM sourcing strategy.

## Open decisions for the owner

1. Splits execution-gas mechanics (relayer vs signer-paid) — determines Blocker 0.
2. Execution model A vs B for the smoke test.
3. Whether to include the V4 seed (step 5) and the VVV borrow leg (step 6) now, or defer.
4. Exact thin amounts (defaults above are ~1–3 DIEM / ~1–2 WETH).
