# wstDIEM Deposit and Exit Guide

**Chain:** Base mainnet (chain ID 8453)
**InferenceVault (wstDIEM token):** `0xe49FA849cB37b0e7A42B2335e333fb99474167ba`
**Router:** `0x74ad4532133Ba538945a5371D249560E66CC7c71`
**Curve DIEM/wstDIEM:** `0x21c33a1Bb5f6Eb43563e1fB9e7AA1D4E90C1A0CD`

---

## Deposit Paths

### Path A — Direct DIEM deposit (cheapest)

Requirements: hold DIEM on Base.

```solidity
// 1. Approve vault
IERC20(DIEM).approve(vault, amount);

// 2. Deposit — stakes immediately, mints wstDIEM
InferenceVault(vault).deposit(amount, receiver);
// OR to buy an exact share count:
InferenceVault(vault).mint(shares, receiver);
```

Fee: 2.5% (250 bps), flat. Taken from depositor assets, minted to treasury as wstDIEM shares.

### Path B — WETH deposit (via Router)

Requirements: hold WETH on Base.

```solidity
IERC20(WETH).approve(router, wethAmount);
Router(router).depositWETH(wethAmount, minWstDiemOut, receiver);
```

Swaps WETH→DIEM via Uniswap V3 (1% pool), then deposits. Additional cost: ~1% Uniswap fee.

### Path C — VVV deposit (via Router)

Requirements: hold VVV on Base.

```solidity
IERC20(VVV).approve(router, vvvAmount);
Router(router).depositVVV(vvvAmount, minWstDiemOut, receiver);
```

Stakes VVV for sVVV inside the Router, calls `mintDiem`, deposits. Gas-intensive but uses VVV directly.

### Path E — Leveraged deposit (via Router, Morpho)

Enter a leveraged wstDIEM position in one transaction. Max ~4.35x at 77% LTV.

```solidity
IERC20(DIEM).approve(router, diemAmount);
// targetLTV: e.g. 0.7e18 for 70% (safe), 0.77e18 for max
// minWstOut: slippage guard on total wstDIEM collateral
Router(router).loopDeposit(diemAmount, targetLTV, minWstOut);
```

Requires DIEM supply-side liquidity in the Morpho wstDIEM/DIEM market. Check Morpho `availableLiquidity` before calling.

### Path D — Referral deposit (via SurplusStakingWrapper)

```solidity
IERC20(DIEM).approve(wrapper, amount);
SurplusStakingWrapper(wrapper).stakeForUser(user, amount, referralCode);
```

Identical economics to Path A but records referral on-chain.

---

## Exit Paths

Withdrawal from the vault is async (Venice unstaking has a ~24h cooldown). There is also a synchronous Curve exit for small amounts.

### Async exit — full DIEM redemption (canonical)

```solidity
// Step 1: burn shares, queue DIEM (instantaneous)
uint256 requestId = vault.requestRedeem(shares, receiver);

// Step 2: after 1 day (or batch of 50 fills), anyone can flush
vault.flush();

// Step 3: after ~24h Venice cooldown, anyone can settle
vault.settle();

// Step 4: anyone can claim — sends DIEM to stored receiver
vault.claimRedeem(requestId);
```

Steps 2–4 are permissionless. The keeper runs them automatically; you can also call them yourself.

### Sync exit — wstDIEM→DIEM via Curve (fast, small amounts)

Sells wstDIEM for DIEM at ~1:rate on the Curve StableSwap. No cooldown. Subject to pool depth and small slippage.

```solidity
// Approve Curve pool
IERC20(wstDIEM).approve(curve, wstDiemAmount);
// Swap index 1 (wstDIEM) for index 0 (DIEM)
ICurveStableNG(curve).exchange(1, 0, wstDiemAmount, minDiemOut);
```

### Sync exit — wstDIEM→WETH via Router + V4

```solidity
IERC20(wstDIEM).approve(router, wstDiemAmount);
Router(router).exitToWETH(wstDiemAmount, minWethOut, receiver);
```

Sells wstDIEM for WETH in the Uniswap V4 pool (0.3% fee). Immediate, no cooldown.

---

## Withdrawal Queue Details

- **Batch size:** max 50 users per batch
- **Batch open window:** minimum 1 day (configurable by Safe, max 7 days)
- **Early flush:** if batch reaches 50 users, flush is available immediately
- **Venice cooldown:** ~24h after flush before settle can be called
- **Minimum redeem:** set by Safe (`minRedeemShares`); default prevents dust griefing
- **Rate locked at request time:** `requestRedeem` snapshots the DIEM amount at current rate; rate changes between request and claim do not affect your redemption amount

---

## Checking Your Position

```solidity
// Share balance
uint256 shares = IERC20(wstDIEM).balanceOf(you);

// Current DIEM value of your shares
uint256 diemValue = vault.convertToAssets(shares);

// Pending redemption requests
uint256[] memory ids = vault.getRedeemRequests(you);

// Current exchange rate (DIEM per wstDIEM, 18 decimals)
uint256 rate = vault.convertToAssets(1e18);
```

---

## Leverage Loop (advanced)

Single-transaction leveraged wstDIEM position via Morpho flash loan:

```solidity
// diemAmount: your initial DIEM
// targetLTV: e.g. 0.7e18 for 70% LTV (max ~77%)
// minWstOut: slippage guard on wstDIEM received
IERC20(DIEM).approve(router, diemAmount);
Router(router).loopDeposit(diemAmount, targetLTV, minWstOut);
```

To unwind:
```solidity
// wstAmount: collateral to withdraw
// borrowRepay: Morpho borrow to repay
// minDiemOut: slippage guard
Router(router).unloopDeposit(wstAmount, borrowRepay, minDiemOut);
```
