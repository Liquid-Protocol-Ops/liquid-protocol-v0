# wstDIEM v6 — Clean Redeploy Runbook (path C)

Single-use-EOA deploy funded from Splits. `DeployV6.s.sol` deploys the full **fixed** v6 stack
(hardened oracle, correctly-priced hooked V4 pool, no deprecated USDC/WETH oracles), wires it,
and hands ownership to the Safe in one script. The fork dry-run is green (`26571c7`).

## Addresses

| | |
|---|---|
| Fresh deployer EOA | `0x428Fac40C9f92aA35131256Dba95A7bAF4966311` (1P Personal: **wstDIEM v6-redeploy Deployer EOA**, field `credential`) |
| Safe (owner of all contracts) | `0x872c561f699B42977c093F0eD8b4C9a431280c6c` |
| Treasury (fee recipient) | operator choice — recommend the **Treasury** Splits `0x2AfE303f4AbD285631872c5A971e5D32fBF1E087` (or the Safe) |
| Funding source | **wstDIEM-seed** Splits `0x47d1F0EB7D4d76DC84C6a1Fb577f5447456a9d04` (holds 4.62 DIEM + 5.95 WETH) |

## Step 1 — Fund the deployer (sign the Splits proposal)

Proposal `d47408d5-65e6-4a42-88d0-f3d1263640e8` (created) sends the deployer **0.01 DIEM** (inflation-guard
seed) + unwraps **0.005 WETH→ETH** and forwards it for gas (deploy gas est ~0.00033 ETH).

Sign: https://teams.splits.org/accounts/0x47d1F0EB7D4d76DC84C6a1Fb577f5447456a9d04?transactionId=d47408d5-65e6-4a42-88d0-f3d1263640e8

Confirm after signing:
```bash
cast call 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024 "balanceOf(address)(uint256)" \
  0x428Fac40C9f92aA35131256Dba95A7bAF4966311 --rpc-url $BASE_RPC_URL   # expect 0.01e18
cast balance 0x428Fac40C9f92aA35131256Dba95A7bAF4966311 --rpc-url $BASE_RPC_URL  # expect ~0.005 ETH
```

> Production liquidity seeding (Curve / V4 LP / Morpho supply) is SEPARATE and post-deploy — its own
> Splits proposals, funded by the DIEM you're sourcing (MOG-547). The deploy itself only needs the
> 0.01 DIEM inflation guard + gas above.

## Step 2 — Pick the V4 init price (anchor inputs)

The script derives an expected tick on-chain (vault rate × Aerodrome DIEM/VVV TWAP × Chainlink ETH/USD)
and rejects a supplied `SQRT_PRICE_X96` more than 300 ticks (~3%) off it. Get the live numbers from a
dry-run, then set the price:

```bash
export BASE_RPC_URL="https://base-mainnet.g.alchemy.com/v2/<alchemy-key>"
# Dry-run (impersonate a DIEM holder; logs the live 'expected tick'):
TREASURY_ADDRESS=0x2AfE303f4AbD285631872c5A971e5D32fBF1E087 \
SAFE_ADDRESS=0x872c561f699B42977c093F0eD8b4C9a431280c6c \
SQRT_PRICE_X96=87260000000000000000000000000 VVV_USD_E8=<current VVV/USD, 8-dec e.g. 1500000000> \
forge script script/vault/DeployV6.s.sol --tc DeployV6 --rpc-url $BASE_RPC_URL \
  --sender 0xbB345D35450BF9Ee76F3D2cE214E8e7AC5e1071d --unlocked
```
Read the logged **expected tick**, then compute the matching sqrtPrice:
```bash
cast call 0x... # or: SQRT_PRICE_X96 = TickMath.getSqrtPriceAtTick(expectedTick)
# quick: python -c "import math; t=<expectedTick>; print(int((1.0001**(t/2))*(2**96)))"
```
Set `SQRT_PRICE_X96` to that value and `VVV_USD_E8` to the current VVV/USD (8-dec). Re-run the dry-run;
confirm `expected tick ≈ supplied tick` and the script completes (`_verify` passes).

## Step 3 — Broadcast the deploy

```bash
PK=$(op item get "wstDIEM v6-redeploy Deployer EOA" --vault Personal --fields credential --reveal | tr -d '[:space:]')
ETHERSCAN=$(op item get ggwsiftg2sspnxai22vkbj2yea --field credential --reveal)

DEPLOYER_PK="$PK" \
TREASURY_ADDRESS=0x2AfE303f4AbD285631872c5A971e5D32fBF1E087 \
SAFE_ADDRESS=0x872c561f699B42977c093F0eD8b4C9a431280c6c \
SQRT_PRICE_X96=<from step 2> VVV_USD_E8=<from step 2> \
forge script script/vault/DeployV6.s.sol --tc DeployV6 --rpc-url $BASE_RPC_URL \
  --broadcast --verify --etherscan-api-key "$ETHERSCAN"
```
Forge sends each deploy/call as a separate tx from the EOA (the Curve factory's `tx.origin==msg.sender`
guard is satisfied; the hook CREATE2-mines to a `0x…1080` address). The script self-verifies ownership
= Safe and Router wiring before completing, and prints every address.

## Step 4 — Post-deploy

1. Record the printed addresses from the broadcast log.
2. Verify on-chain: `cast call <vault> "owner()(address)"` == Safe; `<router> "wstDiemV4Hooks()(address)"` == hook;
   `<router> "v4Pool()(address)"` == `0x498581fF…`; V4 pool slot0 tick ≈ expected.
3. Rotate `veniceSigner` from the deployer to the production keeper/Privy wallet (`vault.setVeniceSigner`, Safe-signed).
4. Update `docs/vault/mainnet-addresses.md` + the repo `CLAUDE.md` address tables (mark v5 superseded by v6).
5. Cross-repo: propagate the new addresses/ABIs into `liquid-sdk`, `liquid-website` (the `/vault` UI), `deploy-autonomous`, `agent-autonomopoly` (the Router's 4-arg `setSwapFees` ABI also changes).
6. Seed liquidity (Curve / V4 LP via `LiquidityManager` / Morpho supply) as separate, signable Splits proposals — gated on liquidation depth (MOG-536) and sized to pool depth.

## Notes

- The deployer holds nothing after the deploy (ownership → Safe). For maximum hygiene you may regenerate
  the deployer key before broadcasting (it is single-use); update the 1P item and the funding proposal recipient if you do.
- The vault `src/vault/**` is new and unaudited beyond the internal review (MOG-532); a third-party audit
  is recommended before scaling external TVL. The frontend T&C makes this explicit.
