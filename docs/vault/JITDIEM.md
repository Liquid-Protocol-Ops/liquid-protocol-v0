# jitDIEM

jitDIEM is the instant-DIEM tranche for wstDIEM-denominated launches. It is one contract that is both an ERC-4626 vault of DIEM (jitDIEM shares) and the Uniswap V4 hook for a DIEM/wstDIEM pool. The pool's curve is never used: `beforeSwap` prices every fill against wstDIEM NAV and fills it from jitDIEM's own balances.

Full design spec: https://claude.ai/artifact/CvakRGakpAB4DXqxhquae9

## Why

Launch tokens paired against wstDIEM earn Venice inference yield on their quote reserve, and launchpad buys grow the wstDIEM vault. But wstDIEM has no instant redemption, so sellers need an instant wstDIEM → DIEM exit at a fair price. jitDIEM provides it without a static LP that would drift from NAV and leak value to arbitrage.

## How a swap fills

| Direction | Price | Filled from |
|---|---|---|
| Buy (DIEM → wstDIEM), jitDIEM below its DIEM target | spot NAV + 0.05% | jitDIEM's wstDIEM inventory (refills its DIEM with no queue) |
| Buy, otherwise or for the remainder | the vault's own deposit price | new stake into wstDIEM |
| Sell (wstDIEM → DIEM) | growth-capped NAV × (1 − fee), fee 1% at/above target rising to 5% | jitDIEM's idle DIEM; reverts below a 5% idle floor |

Sell pricing uses `min(spot, lastNav × (1 + 50%/yr × min(elapsed, 1 day)))`, so a donation that inflates wstDIEM NAV can move the sell price by at most ~0.14%, below the 1% minimum fee. A NAV drop of more than 1% halts sells until the owner calls `resetNav()`.

## Upkeep

Keeper-optional. Claim conversion runs at the start of every swap; redemption requests and claims run in `afterSwap` at most once an hour. `rebalance()` and `sync()` are permissionless backstops. jitDIEM holds at most one redemption request in the vault's open batch (each request takes one of the batch's 50 slots).

## Launch-fee share in DIEM

`jitDIEMFeeConverter` is set as a reward recipient with `FeeIn.Paired` on wstDIEM-paired launches. `convert()` (permissionless) claims its wstDIEM from `LiquidFeeLocker` and redeems it through the vault queue with jitDIEM as receiver; jitDIEM's `sync()` vests the DIEM to holders over 3 days. Redeeming (rather than selling into jitDIEM's own pool) is what makes it new DIEM liquidity.

## Deploy

```bash
forge script script/vault/DeployJitDiem.s.sol \
  --rpc-url "$BASE_RPC_URL" --private-key "$DEPLOYER_PK" --broadcast --verify
```

The script mines the hook salt, deploys jitDIEM with the deployer as owner, initializes the pool at NAV, seeds 0.01 DIEM of dead shares (deployer must hold it), deploys the converter, and starts the ownership transfer to the Safe. Then the Safe calls `jitDIEM.acceptOwnership()` and `setGuardian(...)`.

## Status

New and unaudited. Tests: `test/vault/jitDIEM.t.sol` (fork; requires `BASE_RPC_URL`) — including a round trip against the live wstDIEM vault and an end-to-end run of the deploy script. The custom-curve hook must be on Uniswap's routing allowlist before aggregators route through it.
