# wstDIEM Deposit and Exit Guide

**Chain:** Base mainnet (chain ID 8453)
**InferenceVault (wstDIEM token):** `0x4751BA2b09374C1929FC01734a166e3c8cd75810`
**Router v8:** `0x6f5FF03a91cb1703B7CB8d85572f990bcB04273D`
**Curve DIEM/wstDIEM:** `0x39A4b4779C71E1A18d500627639682c9583Ee86f`

---

## What is wstDIEM?

wstDIEM is a freely transferable ERC-20 token that represents a share of the wstDIEM vault's staked DIEM position. Yield accrues passively — you do not need to stake, claim, or take any action after depositing. Your wstDIEM tokens simply become redeemable for more DIEM over time as inference revenue is credited to the vault.

It is directly analogous to wstETH: the token count in your wallet stays constant; the DIEM redeemable per token increases.

---

## Exchange Rate

The exchange rate is defined by:

```
DIEM per wstDIEM = totalAssets() / totalSupply()
```

where `totalAssets()` = idle DIEM + stakedAmount + unstakingAmount.

Every call to `vault.creditDIEM(amount)` increases `totalAssets()` without minting new shares, causing the rate to rise. The rate is strictly monotonically increasing (it never decreases).

To read the current rate:
```bash
# How much DIEM does 1 wstDIEM redeem for? (returns 18-dec integer)
cast call 0x4751BA2b09374C1929FC01734a166e3c8cd75810 \
  "convertToAssets(uint256)(uint256)" 1000000000000000000 \
  --rpc-url $BASE_RPC
```

---

## Deposit Fee

| TVL at time of deposit | Fee |
|----------------------|-----|
| < 5,000,000 DIEM | 10 bps (0.10%) |
| >= 5,000,000 DIEM | 50 bps (0.50%) |

The fee is captured by minting a small number of additional shares to the treasury. Your received shares already reflect the net amount after the fee — no separate deduction step.

---

## Path 1: Deposit DIEM Directly

The simplest path. Deposit DIEM, receive wstDIEM.

**Step 1 — Approve the vault to spend your DIEM:**
```bash
cast send 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024 \
  "approve(address,uint256)" \
  0x4751BA2b09374C1929FC01734a166e3c8cd75810 \
  <diem_amount_18dec> \
  --rpc-url $BASE_RPC --private-key $YOUR_PK
```

**Step 2 — Deposit and receive wstDIEM:**
```bash
cast send 0x4751BA2b09374C1929FC01734a166e3c8cd75810 \
  "deposit(uint256,address)(uint256)" \
  <diem_amount_18dec> <your_address> \
  --rpc-url $BASE_RPC --private-key $YOUR_PK
```

**Preview shares before depositing:**
```bash
cast call 0x4751BA2b09374C1929FC01734a166e3c8cd75810 \
  "previewDeposit(uint256)(uint256)" <diem_amount_18dec> \
  --rpc-url $BASE_RPC
```

---

## Path 2: Deposit WETH via Router

The Router swaps WETH → DIEM (Uniswap V3 1% pool) then deposits to the vault. Use this if you hold WETH rather than DIEM.

**Step 1 — Approve Router to spend your WETH:**
```bash
cast send 0x4200000000000000000000000000000000000006 \
  "approve(address,uint256)" \
  0x6f5FF03a91cb1703B7CB8d85572f990bcB04273D \
  <weth_amount_18dec> \
  --rpc-url $BASE_RPC --private-key $YOUR_PK
```

**Step 2 — Call depositWETH (set minWstDIEM to your slippage tolerance):**
```bash
cast send 0x6f5FF03a91cb1703B7CB8d85572f990bcB04273D \
  "depositWETH(uint256,uint256,address)(uint256)" \
  <weth_amount_18dec> <min_wstdiem_18dec> <your_address> \
  --rpc-url $BASE_RPC --private-key $YOUR_PK
```

Set `minWstDIEM` to your minimum acceptable shares (e.g., 98% of the expected output). The call reverts with `SlippageExceeded` if the output falls short.

---

## Path 3: Deposit VVV via Router

VVV is staked → sVVV, then `mintDiem` is called to produce DIEM, which is deposited into the vault. Note: sVVV is non-transferable, so you must send VVV (not sVVV) to the Router.

**Step 1 — Approve Router to spend your VVV:**
```bash
cast send 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf \
  "approve(address,uint256)" \
  0x6f5FF03a91cb1703B7CB8d85572f990bcB04273D \
  <vvv_amount_18dec> \
  --rpc-url $BASE_RPC --private-key $YOUR_PK
```

**Step 2 — Call depositVVV:**
```bash
cast send 0x6f5FF03a91cb1703B7CB8d85572f990bcB04273D \
  "depositVVV(uint256,uint256,address)(uint256)" \
  <vvv_amount_18dec> <min_wstdiem_18dec> <your_address> \
  --rpc-url $BASE_RPC --private-key $YOUR_PK
```

The DIEM output from `mintDiem` depends on the current VVV/DIEM protocol rate. Set `minWstDIEM` accordingly.

---

## Withdrawals from the Vault

Direct vault withdrawals require two conditions to both be true:
1. **14-day governance timelock:** The Safe owner must call `initiateEnableWithdrawals()`, wait 14 days, then call `enableWithdrawals()`. This is a one-time unlock.
2. **Idle DIEM available:** `maxWithdraw` is capped to the idle (unstaked) DIEM balance. Most DIEM is staked; the owner must call `initiateUnstake(amount)` then wait 24h before idle DIEM becomes available.

For most users, the preferred exit paths are the Router (V4 pool) or Curve pool, both described below.

To check your maximum withdrawable amount:
```bash
cast call 0x4751BA2b09374C1929FC01734a166e3c8cd75810 \
  "maxWithdraw(address)(uint256)" <your_address> \
  --rpc-url $BASE_RPC
```

---

## Exit Path 1: Router.exitToWETH (V4 Pool)

Sells wstDIEM into the V4 wstDIEM/WETH pool (0.3% fee) via the Uniswap V4 `unlockCallback` pattern. This is the primary on-chain exit for meaningful size.

**Step 1 — Approve Router to spend your wstDIEM:**
```bash
cast send 0x4751BA2b09374C1929FC01734a166e3c8cd75810 \
  "approve(address,uint256)" \
  0x6f5FF03a91cb1703B7CB8d85572f990bcB04273D \
  <wstdiem_amount_18dec> \
  --rpc-url $BASE_RPC --private-key $YOUR_PK
```

**Step 2 — Call exitToWETH:**
```bash
cast send 0x6f5FF03a91cb1703B7CB8d85572f990bcB04273D \
  "exitToWETH(uint256,uint256,address)(uint256)" \
  <wstdiem_amount_18dec> <min_weth_18dec> <your_address> \
  --rpc-url $BASE_RPC --private-key $YOUR_PK
```

The call reverts with `SlippageExceeded` if WETH output is below `minWETH`.

---

## Exit Path 2: Curve DIEM/wstDIEM StableSwap

The Curve pool provides lower-slippage exits for wstDIEM → DIEM. This is best for users who want DIEM rather than WETH, or for smaller amounts where the StableSwap curve offers better pricing.

**Pool:** `0x39A4b4779C71E1A18d500627639682c9583Ee86f`
**Fee:** approximately 0.04%
**Indices:** DIEM = 0, wstDIEM = 1

```bash
# Approve Curve pool to spend wstDIEM
cast send 0x4751BA2b09374C1929FC01734a166e3c8cd75810 \
  "approve(address,uint256)" \
  0x39A4b4779C71E1A18d500627639682c9583Ee86f \
  <wstdiem_amount_18dec> \
  --rpc-url $BASE_RPC --private-key $YOUR_PK

# Exchange wstDIEM (index 1) for DIEM (index 0)
cast send 0x39A4b4779C71E1A18d500627639682c9583Ee86f \
  "exchange(int128,int128,uint256,uint256)(uint256)" \
  1 0 <wstdiem_amount_18dec> <min_diem_out_18dec> \
  --rpc-url $BASE_RPC --private-key $YOUR_PK
```

Note: the Curve pool exchange rate will reflect a small premium/discount versus the vault's `convertToAssets` rate depending on pool balance and recent trades.

---

## Borrowing Against wstDIEM on Morpho

wstDIEM can be supplied as collateral on Morpho Blue to borrow DIEM, USDC, or WETH.

| Market | Loan | Max LTV (LLTV) | Liquidation LTV |
|--------|------|----------------|-----------------|
| wstDIEM / DIEM | DIEM | 86% | 86% |
| wstDIEM / USDC | USDC | 62.5% | 62.5% |
| wstDIEM / WETH | WETH | 62.5% | 62.5% |

**Morpho Blue:** `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb`

Basic pattern (using the Morpho Blue interface directly):
```solidity
// 1. Approve Morpho to spend your wstDIEM
IERC20(wstDIEM).approve(morpho, collateralAmount);

// 2. Supply collateral
IMorpho(morpho).supplyCollateral(marketParams, collateralAmount, onBehalf, hex"");

// 3. Borrow against it
IMorpho(morpho).borrow(marketParams, borrowAmount, 0, onBehalf, receiver);
```

Always keep your LTV well below the LLTV. Morpho uses oracles based on the vault's `convertToAssets` rate, so the collateral value in the oracle rises as yield accrues.

---

## Reading Your Position

```bash
# wstDIEM balance (18 dec)
cast call 0x4751BA2b09374C1929FC01734a166e3c8cd75810 \
  "balanceOf(address)(uint256)" <your_address> \
  --rpc-url $BASE_RPC

# DIEM value of your wstDIEM (18 dec)
cast call 0x4751BA2b09374C1929FC01734a166e3c8cd75810 \
  "convertToAssets(uint256)(uint256)" <your_wstdiem_balance> \
  --rpc-url $BASE_RPC

# Current vault TVL
cast call 0x4751BA2b09374C1929FC01734a166e3c8cd75810 \
  "totalAssets()(uint256)" --rpc-url $BASE_RPC

# Current total wstDIEM supply
cast call 0x4751BA2b09374C1929FC01734a166e3c8cd75810 \
  "totalSupply()(uint256)" --rpc-url $BASE_RPC
```

---

## Security Properties

- **DIEM never leaves the vault.** All deposited DIEM is staked via `DIEM.stake()`. No external protocol (other than Venice's staking contract) holds your DIEM.
- **No upgrade proxy.** InferenceVault is a plain Ownable ERC-4626 contract. The owner (Safe) can configure parameters but cannot upgrade the bytecode.
- **Withdrawal gate.** Direct withdrawals require a 14-day on-chain timelock, giving depositors time to exit via secondary markets before liquidity is redistributed.
- **Inflation attack protection.** The vault uses a `+1` virtual offset in `_convertToShares` / `_convertToAssets` and mints fee shares to the treasury (not transferring fee assets out), preventing the classic ERC-4626 inflation attack on first deposit.
- **EIP-4626 compliant.** `previewDeposit`, `previewMint`, `maxWithdraw`, `maxRedeem` all correctly account for the deposit fee and withdrawal gate, so compliant integrations will not encounter unexpected reverts.
