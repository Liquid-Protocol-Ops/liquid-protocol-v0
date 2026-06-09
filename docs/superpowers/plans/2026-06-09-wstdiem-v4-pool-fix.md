# wstDIEM V4 Pool Fix + Oracle Deprecation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the mis-priced wstDIEM/WETH Uniswap V4 pool with a correctly-priced dynamic-fee pool using WstDIEMHook, and formally deprecate the two `DIEM=$1` Morpho oracles.

**Architecture:** Build + test all contracts and scripts locally first (Tasks 1–6, 11–12). Then a gated mainnet deploy sequence (Tasks 7–10) the operator triggers explicitly. The new pool uses a different PoolKey (`fee=DYNAMIC_FEE_FLAG`, `hooks=WstDIEMHook`) so it does not collide with the broken pool, which cannot be re-initialized.

**Tech Stack:** Solidity 0.8.28, Foundry (forge v1.5.1, viaIR, 20k runs, Cancun), Uniswap V4 (v4-core + v4-periphery libs), Morpho Blue, Base mainnet fork tests (`BASE_RPC_URL`).

**Spec:** `docs/superpowers/specs/2026-06-09-wstdiem-v4-pool-fix-design.md`

**Key addresses (Base mainnet):**
- InferenceVault v5 (wstDIEM): `0xb9f23c33FfD2213f31C0cFb6c9e2fDf525a9Dd2D`
- V4 PoolManager: `0x498581fF718922c3f8e6A244956aF099B2652b2b`
- WETH: `0x4200000000000000000000000000000000000006`
- DIEM: `0xF4d97F2da56e8c3098f3a8D538DB630A2606a024`
- Safe (owner): `0x872c561f699B42977c093F0eD8b4C9a431280c6c`
- WstDiemUsdcOracle (deprecate): `0x7F3eAb9863d4f5a1d34d89f7b802C0eA2469b51a`
- WstDiemWethOracle (deprecate): `0x73FddCCBB524b04b43EdED9C4d20C061DE291F07`
- Deployer v6: `0xf04822e5B0E76A34aeeA936c79B4439f794b8Be1`

**Foundry constants:**
- `DYNAMIC_FEE_FLAG = 0x800000` (8,388,608), `OVERRIDE_FEE_FLAG = 0x400000`, `MAX_LP_FEE = 1_000_000` — from `@uniswap/v4-core/src/libraries/LPFeeLibrary.sol`
- Hook flag mask `0x1080` = `Hooks.BEFORE_SWAP_FLAG (0x80) | Hooks.AFTER_INITIALIZE_FLAG (0x1000)`
- CREATE2 deployer (Foundry default, used by salted `new`): `0x4e59b44847b379578588920cA78FbF26c0B4956C`

**Run commands (full paths — tools not on default PATH):**
- Build: `~/.foundry/bin/forge build`
- Fork test: `BASE_RPC_URL=<alchemy-url> ~/.foundry/bin/forge test --match-path "test/vault/V4Pool.t.sol" -vvv`
- Format check: `~/.foundry/bin/forge fmt --check`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `src/vault/WstDIEMHook.sol` | Modify | Add `OVERRIDE_FEE_FLAG` to `_beforeSwap` return so dynamic fee actually applies |
| `src/vault/Router.sol` | Modify | Add settable `wstDiemV4Hooks`; allow `DYNAMIC_FEE_FLAG`; use hooks in `unlockCallback` PoolKey |
| `src/vault/LiquidityManager.sol` | Create | Parameterized add/remove/collect LP manager (promoted from script) |
| `script/vault/SafeManageV4LP.s.sol` | Modify | Import `LiquidityManager` from `src/vault/`; pass new PoolKey args |
| `script/vault/DeployWstDiemHook.s.sol` | Create | CREATE2 salt-mined hook deployment |
| `script/vault/InitV4Pool.s.sol` | Create | Initialize new pool at operator-supplied, on-chain-validated sqrtPriceX96 |
| `script/vault/DeployRouter.s.sol` | Modify | Point at v5 vault for redeploy |
| `script/vault/ConfigureRouterV4.s.sol` | Create | Safe tx: `setSwapFees(dynamic, hook)` + `setV4Pool` |
| `test/vault/WstDIEMHook.t.sol` | Modify | Assert `_beforeSwap` returns fee OR'd with `OVERRIDE_FEE_FLAG` |
| `test/vault/V4Pool.t.sol` | Create | Fork test: init hooked pool, add/remove/collect, swap with fee override |
| `test/vault/LiquidityManager.t.sol` | Create | Fork test: parameterized manager add → collect → remove |
| `src/vault/oracles/WstDiemUsdcOracle.sol` | Modify | `@custom:deprecated` NatSpec |
| `src/vault/oracles/WstDiemWethOracle.sol` | Modify | `@custom:deprecated` NatSpec |
| `docs/vault/mainnet-addresses.md` | Modify | Mark USDC/WETH markets deprecated |
| `CLAUDE.md` (repo root) | Modify | Update oracle table note |

---

# TRACK A — V4 Pool Fix

## Task 1: Fix WstDIEMHook dynamic-fee override

The hook's `_beforeSwap` returns `FEE_NORMAL` without `OVERRIDE_FEE_FLAG`. For a `DYNAMIC_FEE_FLAG` pool, V4 ignores any returned fee that lacks the override flag — so the stub never actually set a fee. This is the core bug fix.

**Files:**
- Modify: `src/vault/WstDIEMHook.sol`
- Test: `test/vault/WstDIEMHook.t.sol`

- [ ] **Step 1: Add the failing test**

Add to `test/vault/WstDIEMHook.t.sol` (the test calls `_beforeSwap` via a thin exposer since it's internal — add the exposer at the bottom of the test file, and a getter test that asserts the override flag is present in the returned fee):

```solidity
// Add import at top:
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

// Add test inside WstDIEMHookTest:
function test_beforeSwapReturnsOverrideFlag() public {
    // Call beforeSwap through the BaseHook external entrypoint (onlyPoolManager).
    PoolKey memory key = PoolKey({
        currency0: Currency.wrap(address(0)),
        currency1: Currency.wrap(address(vault)),
        fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
        tickSpacing: 60,
        hooks: IHooks(address(hook))
    });
    vm.prank(V4_POOL_MANAGER);
    (, , uint24 fee) = hook.beforeSwap(
        address(this),
        key,
        IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0}),
        ""
    );
    // Fee must carry the override flag, and the underlying fee must be FEE_NORMAL.
    assertTrue(fee & LPFeeLibrary.OVERRIDE_FEE_FLAG != 0, "override flag must be set");
    assertEq(fee & ~LPFeeLibrary.OVERRIDE_FEE_FLAG, hook.FEE_NORMAL(), "underlying fee = FEE_NORMAL");
}
```

Add the needed imports to the test file: `Currency`, `IHooks` (already present?), `IPoolManager` (present). Add `Currency` import:
```solidity
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
```

- [ ] **Step 2: Run test to verify it fails**

Run: `BASE_RPC_URL=<url> ~/.foundry/bin/forge test --match-test test_beforeSwapReturnsOverrideFlag -vvv`
Expected: FAIL — `override flag must be set` (current code returns bare `FEE_NORMAL`).

- [ ] **Step 3: Apply the fix**

In `src/vault/WstDIEMHook.sol`, uncomment the `LPFeeLibrary` import (line ~12) and OR the flag into the return:

```solidity
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
```

Change `_beforeSwap` return:
```solidity
function _beforeSwap(
    address,
    PoolKey calldata,
    IPoolManager.SwapParams calldata,
    bytes calldata
) internal pure override returns (bytes4, BeforeSwapDelta, uint24) {
    uint24 fee = _currentFee() | LPFeeLibrary.OVERRIDE_FEE_FLAG;
    return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `BASE_RPC_URL=<url> ~/.foundry/bin/forge test --match-test test_beforeSwapReturnsOverrideFlag -vvv`
Expected: PASS. Also run the full hook suite: `--match-path "test/vault/WstDIEMHook.t.sol"` — all pass.

- [ ] **Step 5: Commit**

```bash
cd ~/Documents/Mog-Capital/Liquid/protocol/liquid-protocol-v0
~/.foundry/bin/forge fmt
git add src/vault/WstDIEMHook.sol test/vault/WstDIEMHook.t.sol
git commit -m "fix(hook): OR OVERRIDE_FEE_FLAG into WstDIEMHook beforeSwap (MOG-548)"
```

---

## Task 2: Router — settable V4 hooks + dynamic fee

`unlockCallback` hardcodes `hooks: IHooks(address(0))`. To route `exitToWETH` through the hooked pool, add a settable `wstDiemV4Hooks` and allow `DYNAMIC_FEE_FLAG` in `setSwapFees`.

**Files:**
- Modify: `src/vault/Router.sol`
- Test: `test/vault/Router.t.sol`

- [ ] **Step 1: Add failing tests**

Add to `test/vault/Router.t.sol` (check existing imports; add `LPFeeLibrary` if missing). These are unit tests — Router constructor needs a vault/weth/vvv/staking/morpho; reuse the existing test's setUp pattern (it deploys a Router). Add:

```solidity
function test_setSwapFees_allowsDynamicFlagAndHooks() public {
    address hookAddr = makeAddr("hook");
    vm.prank(router.owner());
    router.setSwapFees(10_000, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, hookAddr);
    assertEq(router.wstDiemV4Fee(), LPFeeLibrary.DYNAMIC_FEE_FLAG);
    assertEq(router.wstDiemV4Hooks(), hookAddr);
    assertEq(router.wstDiemV4TickSpacing(), int24(60));
}

function test_setSwapFees_rejectsZeroV4Fee() public {
    vm.prank(router.owner());
    vm.expectRevert(bytes("invalid V4 fee"));
    router.setSwapFees(10_000, 0, 60, address(0));
}

function test_wstDiemV4Hooks_defaultsToZero() public view {
    assertEq(router.wstDiemV4Hooks(), address(0));
}
```

Add import to the test file if absent:
```solidity
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `BASE_RPC_URL=<url> ~/.foundry/bin/forge test --match-path "test/vault/Router.t.sol" --match-test "setSwapFees\|wstDiemV4Hooks" -vvv`
Expected: FAIL — `setSwapFees` arity is 3, `wstDiemV4Hooks()` does not exist (compile error / revert).

- [ ] **Step 3: Implement Router changes**

In `src/vault/Router.sol`:

(a) Add the import near the other v4 imports (after line 70):
```solidity
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
```

(b) Add storage after `int24 public wstDiemV4TickSpacing = 60;` (line ~105):
```solidity
// V4 wstDIEM/WETH pool hook address. address(0) = no hook. Owner-updatable.
address public wstDiemV4Hooks;
```

(c) Update the event (line ~145):
```solidity
event SwapFeesSet(
    uint24 diemV3Fee, uint24 wstDiemV4Fee, int24 wstDiemV4TickSpacing, address wstDiemV4Hooks
);
```

(d) In `unlockCallback`, change the PoolKey hooks field (line ~225) from `hooks: IHooks(address(0))` to:
```solidity
            hooks: IHooks(wstDiemV4Hooks)
```

(e) Replace `setSwapFees` (lines ~425-436) with:
```solidity
function setSwapFees(
    uint24 _diemV3Fee,
    uint24 _wstDiemV4Fee,
    int24 _wstDiemV4TickSpacing,
    address _wstDiemV4Hooks
) external onlyOwner {
    require(_diemV3Fee > 0 && _diemV3Fee <= 10_000, "invalid DIEM V3 fee");
    bool isDynamic = _wstDiemV4Fee == LPFeeLibrary.DYNAMIC_FEE_FLAG;
    require(
        (_wstDiemV4Fee > 0 && _wstDiemV4Fee <= LPFeeLibrary.MAX_LP_FEE) || isDynamic,
        "invalid V4 fee"
    );
    require(_wstDiemV4TickSpacing > 0, "invalid tick spacing");
    diemV3Fee = _diemV3Fee;
    wstDiemV4Fee = _wstDiemV4Fee;
    wstDiemV4TickSpacing = _wstDiemV4TickSpacing;
    wstDiemV4Hooks = _wstDiemV4Hooks;
    emit SwapFeesSet(_diemV3Fee, _wstDiemV4Fee, _wstDiemV4TickSpacing, _wstDiemV4Hooks);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `BASE_RPC_URL=<url> ~/.foundry/bin/forge test --match-path "test/vault/Router.t.sol" -vvv`
Expected: PASS (new + existing). Then `~/.foundry/bin/forge build` — clean compile.

- [ ] **Step 5: Commit**

```bash
~/.foundry/bin/forge fmt
git add src/vault/Router.sol test/vault/Router.t.sol
git commit -m "feat(router): settable V4 hooks addr + allow DYNAMIC_FEE_FLAG (MOG-548)"
```

---

## Task 3: Promote LiquidityManager to src/vault/

Move `LiquidityManager` out of `SafeManageV4LP.s.sol` into a parameterized source contract so it can be unit-tested and reused across pool configs.

**Files:**
- Create: `src/vault/LiquidityManager.sol`
- Test: `test/vault/LiquidityManager.t.sol`

- [ ] **Step 1: Write the contract**

Create `src/vault/LiquidityManager.sol`. Parameterize all PoolKey + tick fields via constructor (no hardcoded addresses/ticks). Logic is identical to the existing manager's add/remove/collect/grantOperator:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IPoolManagerLM {
    struct ModifyLiquidityParams {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
    }
    function unlock(bytes calldata data) external returns (bytes memory);
    function modifyLiquidity(
        PoolKeyLM calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (int256 callerDelta, int256 feesAccrued);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}

struct PoolKeyLM {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

interface IERC20LM {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title LiquidityManager
/// @notice Persistent V4 LP manager owned by a Safe. Holds the position; supports
///         add / remove / collect / grantOperator. Pool key + tick range are immutable
///         constructor args so one deploy targets exactly one pool/position.
contract LiquidityManager {
    address public immutable poolManager;
    address public immutable currency0;
    address public immutable currency1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    int24 public immutable tickLower;
    int24 public immutable tickUpper;
    address public immutable hooks;
    address public immutable safe;

    enum Action { ADD, REMOVE, COLLECT_FEES }

    struct CallbackData {
        Action action;
        uint128 liquidity;
    }

    error OnlySafe();
    error OnlyPoolManager();
    error AllowOperatorFailed();

    constructor(
        address _poolManager,
        address _currency0,
        address _currency1,
        uint24 _fee,
        int24 _tickSpacing,
        int24 _tickLower,
        int24 _tickUpper,
        address _hooks,
        address _safe
    ) {
        poolManager = _poolManager;
        currency0 = _currency0;
        currency1 = _currency1;
        fee = _fee;
        tickSpacing = _tickSpacing;
        tickLower = _tickLower;
        tickUpper = _tickUpper;
        hooks = _hooks;
        safe = _safe;
    }

    modifier onlySafe() {
        if (msg.sender != safe) revert OnlySafe();
        _;
    }

    function addLiquidity(uint128 liquidity) external onlySafe {
        _unlock(Action.ADD, liquidity);
        _returnExcess();
    }

    function removeLiquidity(uint128 liquidity) external onlySafe {
        _unlock(Action.REMOVE, liquidity);
        _returnExcess();
    }

    function collectFees() external onlySafe {
        _unlock(Action.COLLECT_FEES, 0);
        _returnExcess();
    }

    function grantOperator(address operator, bool allowed) external onlySafe {
        (bool ok,) = poolManager.call(
            abi.encodeWithSignature("allowOperator(address,bool)", operator, allowed)
        );
        if (!ok) revert AllowOperatorFailed();
    }

    function _key() internal view returns (PoolKeyLM memory) {
        return PoolKeyLM({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hooks
        });
    }

    function _unlock(Action action, uint128 liquidity) internal {
        IERC20LM(currency0).approve(poolManager, type(uint256).max);
        IERC20LM(currency1).approve(poolManager, type(uint256).max);
        IPoolManagerLM(poolManager).unlock(abi.encode(CallbackData({action: action, liquidity: liquidity})));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != poolManager) revert OnlyPoolManager();
        CallbackData memory cd = abi.decode(data, (CallbackData));

        int256 liquidityDelta;
        if (cd.action == Action.ADD) {
            liquidityDelta = int256(uint256(cd.liquidity));
        } else if (cd.action == Action.REMOVE) {
            liquidityDelta = -int256(uint256(cd.liquidity));
        } else {
            liquidityDelta = 0;
        }

        PoolKeyLM memory key = _key();
        (int256 callerDelta,) = IPoolManagerLM(poolManager).modifyLiquidity(
            key,
            IPoolManagerLM.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );

        int128 amount0 = int128(callerDelta >> 128);
        int128 amount1 = int128(callerDelta);

        if (amount0 > 0) {
            IPoolManagerLM(poolManager).take(currency0, address(this), uint256(uint128(amount0)));
        }
        if (amount1 > 0) {
            IPoolManagerLM(poolManager).take(currency1, address(this), uint256(uint128(amount1)));
        }
        if (amount0 < 0) {
            IPoolManagerLM(poolManager).sync(currency0);
            IERC20LM(currency0).transfer(poolManager, uint256(uint128(-amount0)));
            IPoolManagerLM(poolManager).settle();
        }
        if (amount1 < 0) {
            IPoolManagerLM(poolManager).sync(currency1);
            IERC20LM(currency1).transfer(poolManager, uint256(uint128(-amount1)));
            IPoolManagerLM(poolManager).settle();
        }
        return "";
    }

    function _returnExcess() internal {
        uint256 b0 = IERC20LM(currency0).balanceOf(address(this));
        uint256 b1 = IERC20LM(currency1).balanceOf(address(this));
        if (b0 > 0) IERC20LM(currency0).transfer(safe, b0);
        if (b1 > 0) IERC20LM(currency1).transfer(safe, b1);
    }
}
```

- [ ] **Step 2: Write the failing fork test**

Create `test/vault/LiquidityManager.t.sol`. It forks Base, deploys a fresh vault + hook (via `deployCodeTo` at the `0x1080` flagged address, same pattern as `WstDIEMHook.t.sol`), initializes a fresh hooked pool, deploys the manager with `safe = address(this)`, then exercises add → collect → remove. WETH is currency0 (`0x4200…` < any vault addr is NOT guaranteed — compute ordering in-test):

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {InferenceVault} from "../../src/vault/InferenceVault.sol";
import {WstDIEMHook} from "../../src/vault/WstDIEMHook.sol";
import {LiquidityManager, PoolKeyLM} from "../../src/vault/LiquidityManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Test} from "forge-std/Test.sol";

contract LiquidityManagerTest is Test {
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;

    InferenceVault vault;
    WstDIEMHook hook;
    LiquidityManager mgr;
    address c0;
    address c1;
    uint128 constant LIQ = 1e15;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        vault = new InferenceVault(DIEM, makeAddr("treasury"), makeAddr("veniceSigner"), address(this));

        address hookAddr = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG));
        deployCodeTo("WstDIEMHook.sol:WstDIEMHook", abi.encode(IPoolManager(POOL_MANAGER), vault), hookAddr);
        hook = WstDIEMHook(hookAddr);

        // Currency ordering: V4 requires currency0 < currency1.
        (c0, c1) = WETH < address(vault) ? (WETH, address(vault)) : (address(vault), WETH);

        // Initialize the hooked dynamic-fee pool at 1:1 (tick 0) for test simplicity.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        IPoolManager(POOL_MANAGER).initialize(key, TickMath.getSqrtPriceAtTick(0));

        mgr = new LiquidityManager(
            POOL_MANAGER, c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, -887_220, 887_220, hookAddr, address(this)
        );

        // Fund this contract (the "safe") with WETH + wstDIEM.
        deal(WETH, address(this), 10e18);
        deal(DIEM, address(this), 1000e18);
        IERC20(DIEM).approve(address(vault), type(uint256).max);
        vault.deposit(100e18, address(this));
    }

    function test_addThenRemoveReturnsTokens() public {
        // Pre-send both currencies to the manager, then add.
        IERC20(c0).transfer(address(mgr), 5e18);
        IERC20(c1).transfer(address(mgr), 50e18);
        mgr.addLiquidity(LIQ);

        uint256 safe0Before = IERC20(c0).balanceOf(address(this));
        uint256 safe1Before = IERC20(c1).balanceOf(address(this));
        mgr.removeLiquidity(LIQ);
        assertGt(IERC20(c0).balanceOf(address(this)), safe0Before, "c0 returned on remove");
        assertGt(IERC20(c1).balanceOf(address(this)), safe1Before, "c1 returned on remove");
    }

    function test_onlySafeModifier() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(LiquidityManager.OnlySafe.selector);
        mgr.addLiquidity(LIQ);
    }
}
```

- [ ] **Step 3: Run the test to verify it fails (then passes)**

Run: `BASE_RPC_URL=<url> ~/.foundry/bin/forge test --match-path "test/vault/LiquidityManager.t.sol" -vvv`
Expected first run: compile-clean, tests PASS (the contract from Step 1 is already correct). If `test_addThenRemoveReturnsTokens` fails on amounts, the liquidity (`LIQ=1e15`) may exceed funded tokens — lower `LIQ` or raise `deal` amounts until add succeeds. The goal: add then remove returns tokens to the safe.

- [ ] **Step 4: Refactor SafeManageV4LP.s.sol to import the source contract**

In `script/vault/SafeManageV4LP.s.sol`: delete the inline `LiquidityManager` contract (lines ~104-250) and `import {LiquidityManager} from "../../src/vault/LiquidityManager.sol";`. Update `deployManager()` to pass the new constructor args for the v5 hooked pool. Replace the old constants block:

```solidity
import {LiquidityManager} from "../../src/vault/LiquidityManager.sol";

// ...
contract SafeManageV4LP is Script {
    address constant SAFE = 0x872c561f699B42977c093F0eD8b4C9a431280c6c;
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant WSTDIEM = 0xb9f23c33FfD2213f31C0cFb6c9e2fDf525a9Dd2D; // v5
    address constant WETH = 0x4200000000000000000000000000000000000006;
    uint24 constant DYNAMIC_FEE = 0x800000;
    int24 constant TICK_SPACING = 60;
    int24 constant TICK_LOWER = -887_220; // full range
    int24 constant TICK_UPPER = 887_220;

    function deployManager() external {
        address hook = vm.envAddress("WSTDIEM_HOOK"); // deployed in Task 5
        (address c0, address c1) = WETH < WSTDIEM ? (WETH, WSTDIEM) : (WSTDIEM, WETH);
        vm.startBroadcast(vm.envUint("EXECUTOR_PK"));
        LiquidityManager mgr = new LiquidityManager(
            POOL_MANAGER, c0, c1, DYNAMIC_FEE, TICK_SPACING, TICK_LOWER, TICK_UPPER, hook, SAFE
        );
        console.log("LiquidityManager deployed:", address(mgr));
        vm.stopBroadcast();
    }
    // addLiquidity/removeLiquidity/collectFees/_execSafe/_loadSigners helpers unchanged,
    // except _execSafe targets now reference the new manager (no logic change).
}
```

Keep the existing `addLiquidity()` / `removeLiquidity()` / `collectFees()` / `_execSafe()` / `_loadSigners()` script functions — they call the manager by address and don't depend on the removed inline contract body.

- [ ] **Step 5: Build + commit**

```bash
~/.foundry/bin/forge build
~/.foundry/bin/forge fmt
git add src/vault/LiquidityManager.sol test/vault/LiquidityManager.t.sol script/vault/SafeManageV4LP.s.sol
git commit -m "feat(vault): promote LiquidityManager to src/, parameterized (MOG-548)"
```

---

## Task 4: V4 pool fork test (init + swap + fee override)

End-to-end fork test proving a hooked dynamic-fee pool can be initialized at a correct price, seeded, and swapped through with the hook's fee applied.

**Files:**
- Create: `test/vault/V4Pool.t.sol`

- [ ] **Step 1: Write the fork test**

Create `test/vault/V4Pool.t.sol`. Reuse `V4LiquidityHelper` pattern from `RouterV4.t.sol` (full-range add) but with the hooked dynamic-fee key. Deploy a fresh Router (Task 2 version), configure it with the hook, seed liquidity, and exit through it:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {InferenceVault} from "../../src/vault/InferenceVault.sol";
import {Router} from "../../src/vault/Router.sol";
import {WstDIEMHook} from "../../src/vault/WstDIEMHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Test} from "forge-std/Test.sol";

contract V4PoolTest is Test {
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;
    address constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;
    address constant VVV_STAKING = 0x321b7ff75154472B18EDb199033fF4D116F340Ff;

    InferenceVault vault;
    WstDIEMHook hook;
    Router router;
    address c0;
    address c1;
    address alice = makeAddr("alice");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        vault = new InferenceVault(DIEM, makeAddr("treasury"), makeAddr("veniceSigner"), address(this));

        address hookAddr = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG));
        deployCodeTo("WstDIEMHook.sol:WstDIEMHook", abi.encode(IPoolManager(POOL_MANAGER), vault), hookAddr);
        hook = WstDIEMHook(hookAddr);
        (c0, c1) = WETH < address(vault) ? (WETH, address(vault)) : (address(vault), WETH);

        // Init the hooked pool at tick 0 (1:1) for deterministic test math.
        IPoolManager(POOL_MANAGER).initialize(_key(), TickMath.getSqrtPriceAtTick(0));

        router = new Router(address(vault), WETH, VVV, VVV_STAKING, address(0));
        router.setV4Pool(POOL_MANAGER);
        router.setSwapFees(10_000, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, hookAddr);

        deal(WETH, alice, 50e18);
        deal(DIEM, alice, 5000e18);
        vm.startPrank(alice);
        IERC20(DIEM).approve(address(vault), type(uint256).max);
        IERC20(address(vault)).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _key() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    // Add full-range liquidity directly via an unlock callback on this test contract.
    function _seed(uint256 wethAmt, uint256 wstAmt, int256 liq) internal {
        deal(WETH, address(this), wethAmt);
        vm.prank(alice);
        vault.deposit(2000e18, alice);
        vm.prank(alice);
        IERC20(address(vault)).transfer(address(this), wstAmt);
        IPoolManager(POOL_MANAGER).unlock(abi.encode(wethAmt, wstAmt, liq));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == POOL_MANAGER, "only PM");
        (uint256 wethAmt, uint256 wstAmt, int256 liq) = abi.decode(data, (uint256, uint256, int256));
        (BalanceDelta delta,) = IPoolManager(POOL_MANAGER).modifyLiquidity(
            _key(),
            IPoolManager.ModifyLiquidityParams({tickLower: -887_220, tickUpper: 887_220, liquidityDelta: liq, salt: bytes32(0)}),
            ""
        );
        if (delta.amount0() < 0) {
            IPoolManager(POOL_MANAGER).sync(Currency.wrap(c0));
            IERC20(c0).transfer(POOL_MANAGER, uint256(-int256(delta.amount0())));
            IPoolManager(POOL_MANAGER).settle();
        }
        if (delta.amount1() < 0) {
            IPoolManager(POOL_MANAGER).sync(Currency.wrap(c1));
            IERC20(c1).transfer(POOL_MANAGER, uint256(-int256(delta.amount1())));
            IPoolManager(POOL_MANAGER).settle();
        }
        return "";
    }

    function test_exitToWETH_throughHookedPool() public {
        _seed(20e18, 200e18, 5e18);
        vm.prank(alice);
        uint256 wstIn = vault.deposit(10e18, alice);
        uint256 wethBefore = IERC20(WETH).balanceOf(alice);
        vm.prank(alice);
        uint256 wethOut = router.exitToWETH(wstIn, 0, alice);
        assertGt(wethOut, 0, "exit must return WETH through hooked pool");
        assertGt(IERC20(WETH).balanceOf(alice), wethBefore, "alice WETH increases");
    }
}
```

- [ ] **Step 2: Run the test**

Run: `BASE_RPC_URL=<url> ~/.foundry/bin/forge test --match-path "test/vault/V4Pool.t.sol" -vvv`
Expected: PASS. If `exitToWETH` reverts, check currency ordering (`c0/c1`) and that `router.wethIsCurrency0()` matches; the Router computes ordering from `WETH < vault` at construction, identical to this test.

- [ ] **Step 3: Commit**

```bash
~/.foundry/bin/forge fmt
git add test/vault/V4Pool.t.sol
git commit -m "test(vault): fork test for hooked dynamic-fee V4 pool exit (MOG-548)"
```

---

## Task 5: Hook deployment script (CREATE2 salt mining)

**Files:**
- Create: `script/vault/DeployWstDiemHook.s.sol`

- [ ] **Step 1: Write the deploy script**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {WstDIEMHook} from "../../src/vault/WstDIEMHook.sol";
import {IInferenceVault} from "../../src/vault/interfaces/IInferenceVault.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Script, console} from "forge-std/Script.sol";

contract DeployWstDiemHook is Script {
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant VAULT = 0xb9f23c33FfD2213f31C0cFb6c9e2fDf525a9Dd2D; // v5
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG); // 0x1080
        bytes memory args = abi.encode(IPoolManager(POOL_MANAGER), IInferenceVault(VAULT));
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(WstDIEMHook).creationCode, args);
        console.log("Mined hook address:", expected);
        console.logBytes32(salt);

        vm.startBroadcast(vm.envUint("DEPLOYER_PK"));
        WstDIEMHook hook = new WstDIEMHook{salt: salt}(IPoolManager(POOL_MANAGER), IInferenceVault(VAULT));
        vm.stopBroadcast();

        require(address(hook) == expected, "hook address mismatch");
        console.log("WstDIEMHook deployed:", address(hook));
        console.log("Export WSTDIEM_HOOK and use in InitV4Pool + ConfigureRouterV4 + SafeManageV4LP.");
    }
}
```

- [ ] **Step 2: Dry-run on a fork (no broadcast)**

Run (uses any funded key for simulation; `--sender` set to deployer v6):
```bash
DEPLOYER_PK=0x0000000000000000000000000000000000000000000000000000000000000001 \
BASE_RPC_URL=<url> ~/.foundry/bin/forge script script/vault/DeployWstDiemHook.s.sol \
  --rpc-url $BASE_RPC_URL --sender 0xf04822e5B0E76A34aeeA936c79B4439f794b8Be1
```
Expected: prints a "Mined hook address" ending in lower bits `0x1080` and a salt; simulation succeeds with `require(address(hook) == expected)` passing.

- [ ] **Step 3: Commit (script only — no mainnet deploy yet)**

```bash
~/.foundry/bin/forge fmt
git add script/vault/DeployWstDiemHook.s.sol
git commit -m "feat(script): CREATE2 salt-mined WstDIEMHook deploy (MOG-548)"
```

---

## Task 6: Pool init script (on-chain-anchored price guard)

The bug behind MOG-548 was a mis-set V4 price. A guard where the operator supplies *both* the price and the band that checks it is weak — a shared fat-finger passes. So this script derives an **expected** tick from on-chain reads (vault rate × Aerodrome DIEM/VVV TWAP × Chainlink ETH/USD) plus a **single** operator input (VVV/USD, the one leg with no on-chain feed), and requires the operator's supplied `SQRT_PRICE_X96` to land within `TOLERANCE_TICKS` of it. The operator's sqrtPrice (from their own off-chain tooling) is cross-checked against an independent on-chain path.

Price math (WETH = currency0, wstDIEM = currency1 ⇒ pool price = wstDIEM per WETH):
```
A = convertToAssets(1e18)        DIEM per wstDIEM   (1e18-scaled, on-chain)
Q = aero.quote(DIEM, 1e18, 2)    VVV  per DIEM      (1e18-scaled, on-chain TWAP)
E = chainlink ETH/USD            USD  per WETH      (1e8-scaled, on-chain)
V = VVV_USD_E8 (operator)        USD  per VVV       (1e8-scaled)

price (wstDIEM/WETH) = WETH_USD / wstDIEM_USD = (E/1e8) / (A·Q·V / 1e44)
priceX192 = price · 2^192 = mulDiv(E · 1e36, 2^192, A·Q·V)   // 512-bit mulDiv, no overflow
expectedSqrtX96 = sqrt(priceX192)                            // OZ Math.sqrt
expectedTick = getTickAtSqrtPrice(expectedSqrtX96)
```

**Files:**
- Create: `script/vault/InitV4Pool.s.sol`

- [ ] **Step 1: Write the init script**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Script, console} from "forge-std/Script.sol";

interface IVaultRate {
    function convertToAssets(uint256 shares) external view returns (uint256);
    function asset() external view returns (address); // DIEM
}

interface IAeroPool {
    function quote(address tokenIn, uint256 amountIn, uint256 granularity)
        external view returns (uint256);
}

interface IChainlink {
    function latestRoundData()
        external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IWethOracle {
    function ethUsdFeed() external view returns (address); // canonical Base ETH/USD feed
}

interface IPMInit {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }
    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external returns (int24 tick);
}

contract InitV4Pool is Script {
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant WSTDIEM = 0xb9f23c33FfD2213f31C0cFb6c9e2fDf525a9Dd2D; // v5
    address constant AERO_DIEM_VVV = 0xbB345D35450BF9Ee76F3D2cE214E8e7AC5e1071d;
    // Reuse the (deprecated) WETH oracle purely as an on-chain source of the canonical
    // Chainlink ETH/USD feed address — its immutable is still correct.
    address constant WETH_ORACLE = 0x73FddCCBB524b04b43EdED9C4d20C061DE291F07;
    uint24 constant DYNAMIC_FEE = 0x800000;
    int24 constant TICK_SPACING = 60;
    int24 constant TOLERANCE_TICKS = 300; // ~3% price tolerance

    function run() external {
        address hook = vm.envAddress("WSTDIEM_HOOK");
        uint160 sqrtPriceX96 = uint160(vm.envUint("SQRT_PRICE_X96"));
        uint256 vvvUsdE8 = vm.envUint("VVV_USD_E8"); // single operator price input, 1e8-scaled

        // On-chain reads
        address diem = IVaultRate(WSTDIEM).asset();
        uint256 a = IVaultRate(WSTDIEM).convertToAssets(1e18);        // DIEM/wstDIEM, 1e18
        uint256 q = IAeroPool(AERO_DIEM_VVV).quote(diem, 1e18, 2);    // VVV/DIEM, 1e18
        (, int256 ans,,,) = IChainlink(IWethOracle(WETH_ORACLE).ethUsdFeed()).latestRoundData();
        require(ans > 0, "bad ETH/USD");
        uint256 e = uint256(ans);                                     // USD/WETH, 1e8

        // expectedTick from independent on-chain path
        uint256 denom = a * q * vvvUsdE8;                             // 1e18·1e18·1e8 = 1e44 scale
        require(denom > 0, "zero denom");
        uint256 priceX192 = FullMath.mulDiv(e * 1e36, uint256(1) << 192, denom);
        uint160 expectedSqrt = uint160(Math.sqrt(priceX192));
        int24 expectedTick = TickMath.getTickAtSqrtPrice(expectedSqrt);
        int24 impliedTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        console.log("convertToAssets(1e18):", a);
        console.log("VVV/DIEM (1e18):", q);
        console.log("ETH/USD (1e8):", e);
        console.log("VVV/USD (1e8, operator):", vvvUsdE8);
        console.log("expected tick:");
        console.logInt(expectedTick);
        console.log("implied tick (supplied):");
        console.logInt(impliedTick);

        int24 diff = impliedTick > expectedTick ? impliedTick - expectedTick : expectedTick - impliedTick;
        require(diff <= TOLERANCE_TICKS, "supplied price deviates from on-chain anchor");

        (address c0, address c1) = WETH < WSTDIEM ? (WETH, WSTDIEM) : (WSTDIEM, WETH);
        IPMInit.PoolKey memory key = IPMInit.PoolKey({
            currency0: c0, currency1: c1, fee: DYNAMIC_FEE, tickSpacing: TICK_SPACING, hooks: hook
        });

        vm.startBroadcast(vm.envUint("DEPLOYER_PK"));
        int24 tick = IPMInit(POOL_MANAGER).initialize(key, sqrtPriceX96);
        vm.stopBroadcast();
        console.log("Pool initialized. Tick:");
        console.logInt(tick);
    }
}
```

- [ ] **Step 2: Dry-run on a fork — confirm the anchor computes and the guard rejects a bad price**

Run with a deliberately wrong `SQRT_PRICE_X96` (the old broken value, tick ~75,981) so the guard rejects it against the on-chain anchor. The `require` runs before `vm.startBroadcast`, so the script reverts at the guard without reaching `initialize`:
```bash
WSTDIEM_HOOK=0x0000000000000000000000000000000000001080 \
SQRT_PRICE_X96=3543191142285914205922034323214 VVV_USD_E8=1500000000 \
DEPLOYER_PK=0x0000000000000000000000000000000000000000000000000000000000000001 \
BASE_RPC_URL=<url> ~/.foundry/bin/forge script script/vault/InitV4Pool.s.sol --rpc-url $BASE_RPC_URL
```
Expected: logs the four on-chain/operator inputs, an `expected tick` in the low thousands, an `implied tick` ≈ 75,981, then **reverts** `supplied price deviates from on-chain anchor`. This proves the anchor is computed from chain state and catches a mispriced input. (If the Aerodrome `quote` reverts for insufficient observations, fall back to passing `Q` via env — but the live pool has ~9000 observations, so it should succeed.)

- [ ] **Step 3: Commit**

```bash
~/.foundry/bin/forge fmt
git add script/vault/InitV4Pool.s.sol
git commit -m "feat(script): InitV4Pool with on-chain-anchored price guard (MOG-548)"
```

---

## Task 7: Update DeployRouter for v5 vault

**Files:**
- Modify: `script/vault/DeployRouter.s.sol`

- [ ] **Step 1: Point the deploy at the v5 vault**

Replace the vault constant (line 13) `0x4751BA2b09374C1929FC01734a166e3c8cd75810` with the v5 vault:

```solidity
Router router = new Router(
    0xb9f23c33FfD2213f31C0cFb6c9e2fDf525a9Dd2D, // InferenceVault v5
    0x4200000000000000000000000000000000000006, // WETH
    0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf, // VVV
    0x321b7ff75154472B18EDb199033fF4D116F340Ff, // vvvStaking (sVVV)
    address(0) // morpho = Base default
);
router.transferOwnership(0x872c561f699B42977c093F0eD8b4C9a431280c6c);
```

- [ ] **Step 2: Build + commit**

```bash
~/.foundry/bin/forge build
git add script/vault/DeployRouter.s.sol
git commit -m "chore(script): point DeployRouter at v5 vault (MOG-548)"
```

---

## Task 8: Router V4 config script (Safe tx)

**Files:**
- Create: `script/vault/ConfigureRouterV4.s.sol`

- [ ] **Step 1: Write the Safe config script**

Models the `SafeBatch`/`_execSafe` signing pattern used by `SafeManageV4LP.s.sol` (SK ordering by address ascending). Two Safe txs against the redeployed Router: `setSwapFees(10_000, DYNAMIC_FEE_FLAG, 60, hook)` and `setV4Pool(POOL_MANAGER)`.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

interface ISafe {
    function getTransactionHash(
        address to, uint256 value, bytes calldata data, uint8 operation,
        uint256 safeTxGas, uint256 baseGas, uint256 gasPrice,
        address gasToken, address refundReceiver, uint256 nonce
    ) external view returns (bytes32);
    function execTransaction(
        address to, uint256 value, bytes calldata data, uint8 operation,
        uint256 safeTxGas, uint256 baseGas, uint256 gasPrice,
        address gasToken, address payable refundReceiver, bytes memory signatures
    ) external payable returns (bool);
    function nonce() external view returns (uint256);
}

contract ConfigureRouterV4 is Script {
    address constant SAFE = 0x872c561f699B42977c093F0eD8b4C9a431280c6c;
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    uint24 constant DYNAMIC_FEE = 0x800000;
    address constant ZERO = address(0);

    uint256 sk1;
    uint256 sk2;

    function run() external {
        address router = vm.envAddress("ROUTER"); // redeployed Router from Task 7
        address hook = vm.envAddress("WSTDIEM_HOOK");
        sk1 = uint256(vm.envBytes32("SAFE_SK1"));
        sk2 = uint256(vm.envBytes32("SAFE_SK2"));

        vm.startBroadcast(vm.envUint("EXECUTOR_PK"));
        _execSafe(router, abi.encodeWithSignature(
            "setSwapFees(uint24,uint24,int24,address)", uint24(10_000), DYNAMIC_FEE, int24(60), hook
        ));
        console.log("setSwapFees executed (dynamic fee + hook)");
        _execSafe(router, abi.encodeWithSignature("setV4Pool(address)", POOL_MANAGER));
        console.log("setV4Pool executed");
        vm.stopBroadcast();
    }

    function _execSafe(address to, bytes memory data) internal {
        uint256 nonce = ISafe(SAFE).nonce();
        bytes32 txHash = ISafe(SAFE).getTransactionHash(to, 0, data, 0, 0, 0, 0, ZERO, ZERO, nonce);
        address a1 = vm.addr(sk1);
        address a2 = vm.addr(sk2);
        uint256 lower = a1 < a2 ? sk1 : sk2;
        uint256 higher = a1 < a2 ? sk2 : sk1;
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(lower, txHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(higher, txHash);
        bytes memory sigs = abi.encodePacked(r1, s1, v1, r2, s2, v2);
        require(ISafe(SAFE).execTransaction(to, 0, data, 0, 0, 0, 0, ZERO, payable(ZERO), sigs), "SafeTx failed");
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
~/.foundry/bin/forge build
~/.foundry/bin/forge fmt
git add script/vault/ConfigureRouterV4.s.sol
git commit -m "feat(script): ConfigureRouterV4 Safe tx for dynamic-fee pool (MOG-548)"
```

---

# TRACK B — Oracle Deprecation

## Task 11: Deprecate oracle contracts + docs

**Files:**
- Modify: `src/vault/oracles/WstDiemUsdcOracle.sol`
- Modify: `src/vault/oracles/WstDiemWethOracle.sol`
- Modify: `docs/vault/mainnet-addresses.md`
- Modify: `CLAUDE.md` (repo root)

- [ ] **Step 1: Add `@custom:deprecated` NatSpec to both oracles**

Prepend above `contract WstDiemUsdcOracle {` (after the existing comment block):
```solidity
/// @custom:deprecated DIEM has no USD-liquid market; DIEM != $1 (it trades ~$1,450 as a
/// Venice inference perpetuity). This oracle mis-prices wstDIEM and its Morpho market is
/// unseeded. DO NOT supply or borrow. Canonical market: wstDIEM/VVV (WstDiemVvvOracle,
/// MOG-544). See MOG-542 / MOG-549.
```
Same block above `contract WstDiemWethOracle {` (adjust the first sentence: "...via a hardcoded DIEM=$1 term").

- [ ] **Step 2: Mark the markets deprecated in `docs/vault/mainnet-addresses.md`**

On the wstDIEM/USDC (line ~33) and wstDIEM/WETH (line ~34) rows, append to the LLTV cell or add a status: change `62.5%` → `62.5% — DEPRECATED (MOG-542, unseeded, do not use)`. Add a note below the table:
```markdown
> **wstDIEM/USDC and wstDIEM/WETH markets are DEPRECATED** (MOG-542/549): their oracles price wstDIEM collateral with a hardcoded DIEM=$1, which is wrong (DIEM ≈ $1,450). They are unseeded and must not be supplied to or borrowed from. The wstDIEM/VVV market (fully on-chain oracle) is the canonical lending venue.
>
> **MOG-549 sweep result:** "$1" appears in two roles. As an *inference entitlement* ($1/DIEM/day — `AgentTGERegistry` tier allocations, `InferenceProduct` capacity) it is CORRECT (Venice's real mechanic; sale price is a separate owner param `pricePerDiemDayUSDC=0.8e6`). As a *collateral market price* it is WRONG — but only the two oracles above + the V4 pool init (MOG-548) used it that way. `FeeRouter`/adapters/`Router` convert at market (`amountOutMinimum:0`), carrying no $1 assumption. Full checklist in the design spec.
```

- [ ] **Step 3: Update the root `CLAUDE.md` oracle table**

Find the two rows (`Morpho wstDIEM/USDC oracle (62.5% — DIEM=$1, see Security)` and the WETH equivalent) and change the parenthetical to `(DEPRECATED — MOG-542, do not use)`. In the "Live oracle caveat" Security bullet, append: "These two markets are now formally deprecated (MOG-549); the VVV market is canonical."

- [ ] **Step 4: Build (confirms NatSpec didn't break compile) + commit**

```bash
~/.foundry/bin/forge build
git add src/vault/oracles/WstDiemUsdcOracle.sol src/vault/oracles/WstDiemWethOracle.sol docs/vault/mainnet-addresses.md CLAUDE.md
git commit -m "docs(vault): deprecate DIEM=\$1 USDC/WETH oracles + markets (MOG-542/549)"
```

---

## Task 12: PR + local verification gate

**Files:** none (process)

- [ ] **Step 1: Full vault test suite passes**

Run: `BASE_RPC_URL=<url> ~/.foundry/bin/forge test --match-path "test/vault/**" -v`
Expected: all pass (existing 171 + new). Note any pre-existing failures unrelated to this change in the PR description.

- [ ] **Step 2: Format check**

Run: `~/.foundry/bin/forge fmt --check`
Expected: clean. (Foundry must be v1.5.1 per CLAUDE.md — `~/.foundry/bin/forge --version`.)

- [ ] **Step 3: Open PR**

```bash
git push -u origin <branch>
~/.local/bin/gh pr create --title "wstDIEM V4 pool fix + oracle deprecation (MOG-548/542/549)" \
  --body "Implements docs/superpowers/specs/2026-06-09-wstdiem-v4-pool-fix-design.md. Track A: new dynamic-fee hooked V4 pool, Router hooks support, promoted LiquidityManager, deploy scripts. Track B: deprecate DIEM=\$1 USDC/WETH oracles. Mainnet deploy (Tasks 9-10) gated on review."
```

---

# GATED MAINNET DEPLOY (Tasks 9–10) — operator-triggered only

> **Do not run these during automated plan execution.** They broadcast real transactions from deployer v6 / the Safe. Run only on explicit go-ahead, one at a time, verifying each on Basescan before the next.

## Task 9: Deploy hook + init pool (deployer v6)

- [ ] **Step 1: Fund deployer v6 if needed** — from wstdiem-deployer Splits `0xf4DB2a7B6902924EFCd8270d23B205969EfF3316`. Deployer v6 key: `op item get rhuh6s2tocpjzdi7kvvnjrps7i --field credential --reveal` (vault Personal).

- [ ] **Step 2: Deploy the hook**
```bash
PK=$(/opt/homebrew/bin/op item get rhuh6s2tocpjzdi7kvvnjrps7i --field credential --reveal | tr -d '[:space:]')
DEPLOYER_PK="$PK" BASE_RPC_URL=<url> ~/.foundry/bin/forge script script/vault/DeployWstDiemHook.s.sol \
  --rpc-url $BASE_RPC_URL --private-key "$PK" --broadcast --verify --etherscan-api-key <key>
```
Record the deployed hook address → `export WSTDIEM_HOOK=0x...`

- [ ] **Step 3: Compute sqrtPriceX96 off-chain** — using your trusted tooling (e.g. Uniswap SDK): price = wstDIEM-per-WETH = WETH_USD / (convertToAssets(1e18)/1e18 × DIEM_VVV_rate × VVV_USD); `sqrtPriceX96 = sqrt(price)·2^96`. Note the current VVV/USD spot (8-dec, e.g. `1530000000` for $15.30) for `VVV_USD_E8`. The script re-derives an on-chain anchor and rejects if your sqrtPrice is >300 ticks (~3%) off it, so both must agree.

- [ ] **Step 4: Initialize the pool**
```bash
WSTDIEM_HOOK=0x... SQRT_PRICE_X96=<computed> VVV_USD_E8=<vvv-usd-8dec> \
DEPLOYER_PK="$PK" BASE_RPC_URL=<url> ~/.foundry/bin/forge script script/vault/InitV4Pool.s.sol \
  --rpc-url $BASE_RPC_URL --private-key "$PK" --broadcast
```
Confirm logged `expected tick` ≈ `implied tick` before it broadcasts. Verify on Basescan post-init: slot0 tick matches the implied tick logged.

## Task 10: Redeploy Router + Safe config

- [ ] **Step 1: Redeploy Router** (deployer v6, ownership transfers to Safe in-script)
```bash
DEPLOYER_PK="$PK" BASE_RPC_URL=<url> ~/.foundry/bin/forge script script/vault/DeployRouter.s.sol \
  --rpc-url $BASE_RPC_URL --private-key "$PK" --broadcast --verify --etherscan-api-key <key>
```
Record → `export ROUTER=0x...`

- [ ] **Step 2: Configure Router via Safe** (signers: SK1 `mog.capital/liq-safe-signer-1`, SK2 `Personal/liq-safe-signer-2`)
```bash
ROUTER=0x... WSTDIEM_HOOK=0x... \
SAFE_SK1=<bytes32> SAFE_SK2=<bytes32> EXECUTOR_PK="$PK" BASE_RPC_URL=<url> \
~/.foundry/bin/forge script script/vault/ConfigureRouterV4.s.sol \
  --rpc-url $BASE_RPC_URL --broadcast
```

- [ ] **Step 3: Post-deploy verification**
  - `cast call $ROUTER "wstDiemV4Hooks()(address)"` == hook
  - `cast call $ROUTER "wstDiemV4Fee()(uint24)"` == 8388608
  - `cast call $ROUTER "v4Pool()(address)"` == PoolManager
  - Update `docs/vault/mainnet-addresses.md` with new Router + hook + pool ID
  - Update memory `project_wstdiem_vault.md` and CLAUDE.md address tables
  - Close MOG-548; close MOG-542 + MOG-549 with the audit-sweep checklist from the spec

---

## Self-Review Notes
- **Spec coverage:** A1→T1, A2→T5, A3→T2+T7+T8, A4→T6, A5→T3, A6→T4, B1→T11, B2→T11, B3→T10 step 3. All covered.
- **Type consistency:** `setSwapFees(uint24,uint24,int24,address)` used identically in Router (T2), tests (T2, T4), and ConfigureRouterV4 (T8). `WSTDIEM_HOOK` env var name consistent across T3/T5/T6/T8. `LiquidityManager` constructor arg order identical in T3 contract, T3 test, and SafeManageV4LP.
- **No mainnet side effects** in Tasks 1–8, 11–12 (build/test/script-write only). All broadcasts isolated to gated Tasks 9–10.
