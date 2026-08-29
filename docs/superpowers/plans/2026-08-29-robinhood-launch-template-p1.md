# Robinhood Launch Template P1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the P1 deliverables of the Robinhood launch template: MC→tick math, the `TopTraderRewardPool` phase contract, the parameterized launch + salt-mine scripts, and unit + 4663 fork tests.

**Architecture:** A pure `TickCalc` library converts USD market-cap targets to pool ticks (FullMath ratio → OZ sqrt → TickMath). A `RobinhoodConfig` library owns the 7-position breakout-ladder constants and builds the factory `DeploymentConfig`, shared by the launch script and the fork test (DRY). `TopTraderRewardPool` is the launch's sole fee recipient: BONDING phase accrues SPY and pays keeper-posted monthly top-3 awards; a permissionless spot-tick `migrate()` latches to MIGRATED (stub pot → protocol treasury), after which `sweep()` forwards everything to the creator.

**Tech Stack:** Solidity 0.8.28 / Foundry v1.5.1 (pinned — `forge fmt` differs across versions), v4-core (TickMath, FullMath), v4-periphery (StateView), OpenZeppelin (Math.sqrt, SafeERC20). Repo: liquid-protocol-v0, branch `feat/robinhood-4663-deploy`.

**Spec:** `docs/superpowers/specs/2026-08-29-robinhood-launch-template-design.md`

## Global Constraints

- Chain: Robinhood Chain, chainId **4663**. RPC `https://rpc.mainnet.chain.robinhood.com` (fork tests read env `RH_RPC_URL`, skip when unset).
- Token supply is factory-hardcoded: **100_000_000_000e18** (`Liquid.sol:44 TOKEN_SUPPLY`). Whole-token count = 1e11.
- Ladder (supply bps / MC boundaries USD): **[600, 2200, 2400, 2000, 1400, 900, 500]** across **start($25k default) → $2M → $4M → $16M → $256M → $4B → $65.536B → maxUsableTick**. Bps sum exactly 10_000.
- Tick spacing **60**; all boundary ticks snapped toward −∞; top boundary = `(MAX_TICK / 60) * 60` = **887_220**.
- Dynamic fee config: `baseFee 20_000` (2%), `maxLpFee 50_000` (5%), `feeControlNumerator 500_000_000`, `referenceTickFilterPeriod 3600`, `resetPeriod 86_400`, `resetTickFilter 500`, `decayFilterBps 9_000`. (`FEE_CONTROL_DENOMINATOR = 1e10`; fee caps at 5% when the vol accumulator reaches ≈775 ticks.)
- MEV module config: `startingFee 500_000` → `endingFee 20_000`, `secondsToDecay 120`.
- 4663 addresses (verbatim from spec §1 + DEPLOYMENTS-4663.md): factory `0x65c40274A1a2178A5140F80fcd6Fe7eFB954e6C2`, dynamic hook `0xDEe7DCdcF599306D3C29E8Dd0e6F4C9c4B6f68CC`, MEV module `0xD86416EEDb067213Df7336662b3fa3B3A1A5e205`, **v2** locker `0x4AB39080B54121136fEfFf86857641F40dA6b964` (v1 reverts on RH's forked router — never use it), SPY `0x117cc2133c37B721F49dE2A7a74833232B3B4C0C`, StateView `0xF3334192D15450CDd385C8b70E03f9A6bd9E673B`, protocol treasury (RH Safe) `0xF0E1D993E7ec19a1E83e6288bBE531A2C5ce4131`.
- Reward split: **60/30/10** to top-3, rounding remainder to the 1st-place amount. Award cooldown `MIN_AWARD_INTERVAL = 25 days`.
- Formatting: run `~/.foundry/bin/forge fmt` before every commit (CI runs `fmt --check`; Foundry pin matters).
- All forge/cast invocations use full path `~/.foundry/bin/`.
- Import remappings: check `remappings.txt` / `foundry.toml` before writing imports — the repo uses `@uniswap/v4-core/src/...` (see `src/Liquid.sol`); confirm the OpenZeppelin prefix with `grep -r "openzeppelin" remappings.txt foundry.toml` and match it.

---

### Task 1: TickCalc library

**Files:**
- Create: `script/lib/TickCalc.sol`
- Test: `test/script/TickCalc.t.sol`

**Interfaces:**
- Consumes: v4-core `TickMath`, `FullMath`; OZ `Math`.
- Produces: `TickCalc.tickForMc(uint256 mcUsdE8, uint256 spyUsdE8, int24 spacing) → int24`, `TickCalc.maxUsableTick(int24 spacing) → int24`, `TickCalc.snapDown(int24 tick, int24 spacing) → int24`. Task 2 consumes nothing from this; Tasks 3–4 consume all three functions.

- [ ] **Step 1: Write the failing test**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TickCalc} from "../../script/lib/TickCalc.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

contract TickCalcTest is Test {
    // Reference vector: SPY=$650.00 (650e8), supply 1e11 tokens, spacing 60.
    // python3: floor(ln(mc/(1e11*650))/ln(1.0001)) snapped down to 60.
    uint256 constant SPY_E8 = 650e8;

    function test_referenceVector_spy650() public pure {
        int24[7] memory expected =
            [int24(-216_840), -172_980, -166_080, -152_220, -124_500, -97_020, -69_000];
        uint256[7] memory mcE8 = [
            uint256(25_000e8), 2_000_000e8, 4_000_000e8, 16_000_000e8,
            256_000_000e8, 4_000_000_000e8, 65_536_000_000e8
        ];
        for (uint256 i = 0; i < 7; i++) {
            int24 got = TickCalc.tickForMc(mcE8[i], SPY_E8, 60);
            // integer sqrt may land one snap lower than the float reference
            assertLe(got, expected[i], "tick above float reference");
            assertGe(got, expected[i] - 60, "tick more than one snap below reference");
        }
    }

    function test_snapDown_negativeAndPositive() public pure {
        assertEq(TickCalc.snapDown(-172_976, 60), -172_980);
        assertEq(TickCalc.snapDown(-172_980, 60), -172_980);
        assertEq(TickCalc.snapDown(121, 60), 60);
        assertEq(TickCalc.snapDown(0, 60), 0);
    }

    function test_maxUsableTick() public pure {
        assertEq(TickCalc.maxUsableTick(60), 887_220);
    }

    function test_monotone_inMc() public pure {
        // strictly non-decreasing ticks for increasing MC
        int24 prev = TickCalc.tickForMc(25_000e8, SPY_E8, 60);
        uint256[6] memory mcs = [
            uint256(2_000_000e8), 4_000_000e8, 16_000_000e8,
            256_000_000e8, 4_000_000_000e8, 65_536_000_000e8
        ];
        for (uint256 i = 0; i < 6; i++) {
            int24 t = TickCalc.tickForMc(mcs[i], SPY_E8, 60);
            assertGt(t, prev);
            prev = t;
        }
    }

    function test_roundtrip_priceBracketsTick() public pure {
        // invariant: sqrtPrice(tick) <= sqrt(ratio) < sqrtPrice(tick + spacing)
        uint256 mcE8 = 2_000_000e8;
        int24 t = TickCalc.tickForMc(mcE8, SPY_E8, 60);
        uint256 ratioX192 = FullMath.mulDiv(mcE8, 1 << 192, 100_000_000_000 * SPY_E8);
        uint160 lower = TickMath.getSqrtPriceAtTick(t);
        uint160 upper = TickMath.getSqrtPriceAtTick(t + 60);
        assertLe(uint256(lower) * uint256(lower), ratioX192);
        assertGt(uint256(upper) * uint256(upper), ratioX192);
    }
}
```

Note on `test_roundtrip`: `lower * lower` overflows uint256 for large positive ticks but not at these deeply negative ticks (sqrtPriceX96 ≈ 1.4e19 → square ≈ 2e38, fine). Keep the roundtrip test to negative-tick inputs only.

- [ ] **Step 2: Run test to verify it fails**

Run: `~/.foundry/bin/forge test --match-path test/script/TickCalc.t.sol -v`
Expected: FAIL to compile — `TickCalc.sol` not found.

- [ ] **Step 3: Write the implementation**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice USD market-cap target → pool tick, for SPY-paired Liquid launches.
/// Price convention: the launched token is currency0 (salt-mined to sort below
/// SPY), so pool price = SPY per TOKEN = MC_usd / (SUPPLY_TOKENS × SPY_usd).
/// Both tokens are 18-decimals, so the wei ratio equals the whole-token ratio.
library TickCalc {
    /// Factory-hardcoded supply (Liquid.sol TOKEN_SUPPLY), in whole tokens.
    uint256 internal constant SUPPLY_TOKENS = 100_000_000_000;

    /// @param mcUsdE8  market-cap target, USD × 1e8
    /// @param spyUsdE8 SPY/USD price, × 1e8
    /// @param spacing  pool tick spacing; result snaps toward -infinity
    function tickForMc(uint256 mcUsdE8, uint256 spyUsdE8, int24 spacing)
        internal
        pure
        returns (int24)
    {
        // price × 2^192; the 1e8 scale cancels between numerator and denominator
        uint256 ratioX192 = FullMath.mulDiv(mcUsdE8, 1 << 192, SUPPLY_TOKENS * spyUsdE8);
        uint160 sqrtPriceX96 = uint160(Math.sqrt(ratioX192));
        return snapDown(TickMath.getTickAtSqrtPrice(sqrtPriceX96), spacing);
    }

    function maxUsableTick(int24 spacing) internal pure returns (int24) {
        return (TickMath.MAX_TICK / spacing) * spacing;
    }

    function snapDown(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 snapped = (tick / spacing) * spacing;
        if (tick < 0 && tick % spacing != 0) snapped -= spacing;
        return snapped;
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `~/.foundry/bin/forge test --match-path test/script/TickCalc.t.sol -v`
Expected: PASS (5 tests). If `test_referenceVector` is off by more than one snap, debug the ratio units before touching the tolerance — the e8 scales must cancel exactly.

- [ ] **Step 5: Commit**

```bash
~/.foundry/bin/forge fmt && git add script/lib/TickCalc.sol test/script/TickCalc.t.sol && git commit -m "feat(4663): TickCalc — MC target to pool tick for SPY-paired launches"
```

---

### Task 2: TopTraderRewardPool contract

**Files:**
- Create: `src/periphery/TopTraderRewardPool.sol`
- Test: `test/periphery/TopTraderRewardPool.t.sol`

**Interfaces:**
- Consumes: OZ `IERC20`/`SafeERC20`.
- Produces (Tasks 3–4 rely on these exact signatures):
  - `constructor(address spy_, address creator_, address treasury_, address keeper_, int24 migrationTick_, address stateView_)`
  - `setPool(bytes32 poolId_)` — deployer-only, one-shot
  - `awardMonth(address[3] calldata winners)` — keeper-only, BONDING-only, 25-day cooldown
  - `migrate()` — permissionless spot-tick latch
  - `sweep(address token)` — MIGRATED-only, forwards to creator
  - `setKeeper(address)` — creator-only
  - views: `migrated() → bool`, `poolId() → bytes32`, `migrationTick() → int24`, `keeper() → address`

- [ ] **Step 1: Write the failing tests**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TopTraderRewardPool} from "../../src/periphery/TopTraderRewardPool.sol";

contract MockSpy {
    string public constant name = "SPY";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract MockStateView {
    int24 public tick;

    function setTick(int24 t) external {
        tick = t;
    }

    function getSlot0(bytes32) external view returns (uint160, int24, uint24, uint24) {
        return (0, tick, 0, 0);
    }
}

contract TopTraderRewardPoolTest is Test {
    MockSpy spy;
    MockStateView sv;
    TopTraderRewardPool pool;

    address creator = address(0xC0FFEE);
    address treasury = address(0x7EA);
    address keeper = address(0xKEE); // replace with address(0xCafe) — 0xKEE is not hex; use address(0xBEEF)
    int24 constant MIGRATION_TICK = -172_980;
    bytes32 constant POOL_ID = keccak256("pool");

    address w1 = address(0x111);
    address w2 = address(0x222);
    address w3 = address(0x333);

    function setUp() public {
        spy = new MockSpy();
        sv = new MockStateView();
        sv.setTick(-216_840); // below migration threshold
        keeper = address(0xBEEF);
        pool = new TopTraderRewardPool(
            address(spy), creator, treasury, keeper, MIGRATION_TICK, address(sv)
        );
        pool.setPool(POOL_ID);
    }

    // ── awardMonth ──
    function test_award_splits_60_30_10_remainderToFirst() public {
        spy.mint(address(pool), 1001); // forces a remainder
        vm.prank(keeper);
        pool.awardMonth([w1, w2, w3]);
        assertEq(spy.balanceOf(w2), 300);
        assertEq(spy.balanceOf(w3), 100);
        assertEq(spy.balanceOf(w1), 601); // 600 + remainder 1
        assertEq(spy.balanceOf(address(pool)), 0);
    }

    function test_award_onlyKeeper() public {
        spy.mint(address(pool), 100);
        vm.expectRevert(TopTraderRewardPool.NotKeeper.selector);
        pool.awardMonth([w1, w2, w3]);
    }

    function test_award_cooldown() public {
        spy.mint(address(pool), 100);
        vm.startPrank(keeper);
        pool.awardMonth([w1, w2, w3]);
        spy.mint(address(pool), 100);
        vm.expectRevert(TopTraderRewardPool.AwardTooSoon.selector);
        pool.awardMonth([w1, w2, w3]);
        vm.warp(block.timestamp + 25 days);
        pool.awardMonth([w1, w2, w3]); // succeeds after cooldown
        vm.stopPrank();
    }

    function test_award_rejectsZeroAndDuplicateWinners() public {
        spy.mint(address(pool), 100);
        vm.startPrank(keeper);
        vm.expectRevert(TopTraderRewardPool.BadWinners.selector);
        pool.awardMonth([address(0), w2, w3]);
        vm.expectRevert(TopTraderRewardPool.BadWinners.selector);
        pool.awardMonth([w1, w1, w3]);
        vm.stopPrank();
    }

    function test_award_revertsWhenEmptyPot() public {
        vm.prank(keeper);
        vm.expectRevert(TopTraderRewardPool.EmptyPot.selector);
        pool.awardMonth([w1, w2, w3]);
    }

    // ── migrate ──
    function test_migrate_revertsBelowThreshold() public {
        vm.expectRevert(TopTraderRewardPool.BelowMigrationTick.selector);
        pool.migrate();
    }

    function test_migrate_latchesAndSweepsPotToTreasury() public {
        spy.mint(address(pool), 500);
        sv.setTick(MIGRATION_TICK); // exactly at threshold: succeeds (>=)
        pool.migrate();
        assertTrue(pool.migrated());
        assertEq(spy.balanceOf(treasury), 500);
        vm.expectRevert(TopTraderRewardPool.AlreadyMigrated.selector);
        pool.migrate();
    }

    function test_award_blockedAfterMigration() public {
        sv.setTick(MIGRATION_TICK + 60);
        pool.migrate();
        spy.mint(address(pool), 100);
        vm.prank(keeper);
        vm.expectRevert(TopTraderRewardPool.AlreadyMigrated.selector);
        pool.awardMonth([w1, w2, w3]);
    }

    // ── sweep ──
    function test_sweep_onlyAfterMigration_forwardsToCreator() public {
        spy.mint(address(pool), 250);
        vm.expectRevert(TopTraderRewardPool.NotMigrated.selector);
        pool.sweep(address(spy));
        sv.setTick(MIGRATION_TICK);
        pool.migrate(); // sweeps the 250 to treasury
        spy.mint(address(pool), 77); // post-migration fee arrival
        pool.sweep(address(spy));
        assertEq(spy.balanceOf(creator), 77);
    }

    // ── admin ──
    function test_setPool_onceAndDeployerOnly() public {
        vm.expectRevert(TopTraderRewardPool.PoolAlreadySet.selector);
        pool.setPool(keccak256("other"));
        TopTraderRewardPool fresh = new TopTraderRewardPool(
            address(spy), creator, treasury, keeper, MIGRATION_TICK, address(sv)
        );
        vm.prank(address(0xDEAD));
        vm.expectRevert(TopTraderRewardPool.NotDeployer.selector);
        fresh.setPool(POOL_ID);
    }

    function test_setKeeper_creatorOnly() public {
        vm.prank(creator);
        pool.setKeeper(address(0xABCD));
        assertEq(pool.keeper(), address(0xABCD));
        vm.expectRevert(TopTraderRewardPool.NotCreator.selector);
        pool.setKeeper(address(0x1));
    }

    function test_migrate_requiresPoolSet() public {
        TopTraderRewardPool fresh = new TopTraderRewardPool(
            address(spy), creator, treasury, keeper, MIGRATION_TICK, address(sv)
        );
        sv.setTick(MIGRATION_TICK);
        vm.expectRevert(TopTraderRewardPool.PoolNotSet.selector);
        fresh.migrate();
    }
}
```

(Fix the noted `address(0xKEE)` typo when transcribing — the setUp assigns `keeper = address(0xBEEF)` anyway; delete the bad initializer line.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `~/.foundry/bin/forge test --match-path test/periphery/TopTraderRewardPool.t.sol -v`
Expected: compile FAIL — contract not found.

- [ ] **Step 3: Write the implementation**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IStateViewMin {
    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
}

/// @notice Phase-aware LP-fee recipient for Robinhood-template launches.
///
/// BONDING (pre-$2M MC): SPY fee inflows accrue as the month's pot; the keeper
/// posts the month's top-3 traders by realized PnL and the pot pays 60/30/10.
/// migrate() is a permissionless ONE-WAY latch: once the pool's spot tick is at
/// or above the deploy-time $2M-MC tick, the stub pot sweeps to the protocol
/// treasury and the contract becomes a passthrough.
/// MIGRATED: sweep(token) forwards the full balance of any token to the creator.
///
/// Trust notes (v1, per spec §4): winner selection is off-chain keeper trust;
/// the spot-tick trigger is deliberate (owner decision) and a single-block wick
/// can latch migration early.
contract TopTraderRewardPool {
    using SafeERC20 for IERC20;

    error NotKeeper();
    error NotCreator();
    error NotDeployer();
    error NotMigrated();
    error AlreadyMigrated();
    error AwardTooSoon();
    error BadWinners();
    error EmptyPot();
    error PoolAlreadySet();
    error PoolNotSet();
    error BelowMigrationTick();

    event MonthAwarded(address[3] winners, uint256 pot, uint256[3] amounts);
    event Migrated(int24 tickAtMigration, uint256 potSweptToTreasury);
    event Swept(address indexed token, uint256 amount);
    event KeeperChanged(address indexed keeper);
    event PoolSet(bytes32 indexed poolId);

    uint256 public constant MIN_AWARD_INTERVAL = 25 days;

    IERC20 public immutable spy;
    address public immutable creator;
    address public immutable treasury;
    int24 public immutable migrationTick;
    IStateViewMin public immutable stateView;
    address public immutable deployer;

    address public keeper;
    bytes32 public poolId;
    bool public migrated;
    uint256 public lastAwardAt;

    constructor(
        address spy_,
        address creator_,
        address treasury_,
        address keeper_,
        int24 migrationTick_,
        address stateView_
    ) {
        spy = IERC20(spy_);
        creator = creator_;
        treasury = treasury_;
        keeper = keeper_;
        migrationTick = migrationTick_;
        stateView = IStateViewMin(stateView_);
        deployer = msg.sender;
    }

    /// @notice One-shot pool binding, called by the launch script after
    ///         deployToken (the poolId needs the token address).
    function setPool(bytes32 poolId_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (poolId != bytes32(0)) revert PoolAlreadySet();
        poolId = poolId_;
        emit PoolSet(poolId_);
    }

    function setKeeper(address keeper_) external {
        if (msg.sender != creator) revert NotCreator();
        keeper = keeper_;
        emit KeeperChanged(keeper_);
    }

    /// @notice Pay the month's pot to the top-3 rPNL traders, 60/30/10.
    ///         Remainder dust goes to 1st place.
    function awardMonth(address[3] calldata winners) external {
        if (msg.sender != keeper) revert NotKeeper();
        if (migrated) revert AlreadyMigrated();
        if (block.timestamp < lastAwardAt + MIN_AWARD_INTERVAL && lastAwardAt != 0) {
            revert AwardTooSoon();
        }
        if (
            winners[0] == address(0) || winners[1] == address(0) || winners[2] == address(0)
                || winners[0] == winners[1] || winners[0] == winners[2] || winners[1] == winners[2]
        ) revert BadWinners();

        uint256 pot = spy.balanceOf(address(this));
        if (pot == 0) revert EmptyPot();

        uint256 second = pot * 3000 / 10_000;
        uint256 third = pot * 1000 / 10_000;
        uint256 first = pot - second - third;

        lastAwardAt = block.timestamp;
        spy.safeTransfer(winners[0], first);
        spy.safeTransfer(winners[1], second);
        spy.safeTransfer(winners[2], third);
        emit MonthAwarded(winners, pot, [first, second, third]);
    }

    /// @notice Permissionless one-way latch at the $2M-MC tick (spot).
    function migrate() external {
        if (migrated) revert AlreadyMigrated();
        if (poolId == bytes32(0)) revert PoolNotSet();
        (, int24 tick,,) = stateView.getSlot0(poolId);
        if (tick < migrationTick) revert BelowMigrationTick();

        migrated = true;
        uint256 pot = spy.balanceOf(address(this));
        if (pot > 0) spy.safeTransfer(treasury, pot);
        emit Migrated(tick, pot);
    }

    /// @notice Post-migration passthrough: forward any token to the creator.
    function sweep(address token) external {
        if (!migrated) revert NotMigrated();
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(creator, bal);
        emit Swept(token, bal);
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `~/.foundry/bin/forge test --match-path test/periphery/TopTraderRewardPool.t.sol -v`
Expected: PASS (11 tests). The MockSpy has no revert-on-failure semantics; that is fine — SafeERC20 handles the bool return.

- [ ] **Step 5: Commit**

```bash
~/.foundry/bin/forge fmt && git add src/periphery/TopTraderRewardPool.sol test/periphery/TopTraderRewardPool.t.sol && git commit -m "feat(4663): TopTraderRewardPool — bonding-phase fee pot with top-3 rPNL awards + migration latch"
```

---

### Task 3: RobinhoodConfig library + launch and salt-mine scripts

**Files:**
- Create: `script/lib/RobinhoodConfig.sol`
- Create: `script/LaunchRobinhoodTemplate.s.sol`
- Create: `script/MineRobinhoodSalt.s.sol`

**Interfaces:**
- Consumes: `TickCalc` (Task 1), `TopTraderRewardPool` (Task 2), `ILiquid` structs, `ILiquidHookDynamicFee.PoolDynamicConfigVars`, `ILiquidHookV2.PoolInitializationData`, `ILiquidMevDescendingFees.FeeConfig`, `ILiquidLpLockerFeeConversion` (all import paths per `script/LaunchSpying.s.sol` — copy its import block verbatim and extend).
- Produces: `RobinhoodConfig.Params` struct and `RobinhoodConfig.build(Params) → (ILiquid.DeploymentConfig, int24 migrationTick)`; Task 4's fork test calls `build` with the same values the script reads from env.

- [ ] **Step 1: Write `script/lib/RobinhoodConfig.sol`**

Copy the import block from `script/LaunchSpying.s.sol` (ILiquid, ILiquidHookV2, ILiquidHookDynamicFee, ILiquidMevDescendingFees, ILiquidLpLockerFeeConversion) and add `TickCalc`.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// … imports per LaunchSpying.s.sol, plus:
import {TickCalc} from "./TickCalc.sol";

/// @notice Builds the spec §2/§3 breakout-ladder DeploymentConfig for a
///         SPY-paired Robinhood-template launch. Shared by the launch script
///         and the 4663 fork test so both exercise identical config.
library RobinhoodConfig {
    int24 internal constant TICK_SPACING = 60;

    struct Params {
        string name;
        string symbol;
        bytes32 salt;          // pre-mined: token must sort below pairedToken
        address tokenAdmin;    // creator
        address hook;          // LiquidHookDynamicFeeV2
        address pairedToken;   // SPY
        address locker;        // v2 fee-conversion locker ONLY
        address mevModule;     // LiquidMevDescendingFees
        address rewardRecipient; // the TopTraderRewardPool
        uint256 startMcUsdE8;  // default 25_000e8
        uint256 spyUsdE8;      // live SPY/USD × 1e8 at deploy
        uint256 chainId;       // 4663
    }

    function ladderBps() internal pure returns (uint16[7] memory bps) {
        bps = [uint16(600), 2200, 2400, 2000, 1400, 900, 500];
    }

    /// MC boundaries above the start tick, USD × 1e8 (spec §2).
    function boundariesUsdE8() internal pure returns (uint256[6] memory b) {
        b = [
            uint256(2_000_000e8),
            4_000_000e8,
            16_000_000e8,
            256_000_000e8,
            4_000_000_000e8,
            65_536_000_000e8
        ];
    }

    function build(Params memory p)
        internal
        pure
        returns (ILiquid.DeploymentConfig memory config, int24 migrationTick)
    {
        uint16[7] memory bps = ladderBps();
        uint256[6] memory bounds = boundariesUsdE8();

        // 8 tick edges: start, 6 MC boundaries, max
        int24[] memory edges = new int24[](8);
        edges[0] = TickCalc.tickForMc(p.startMcUsdE8, p.spyUsdE8, TICK_SPACING);
        for (uint256 i = 0; i < 6; i++) {
            edges[i + 1] = TickCalc.tickForMc(bounds[i], p.spyUsdE8, TICK_SPACING);
        }
        edges[7] = TickCalc.maxUsableTick(TICK_SPACING);
        migrationTick = edges[1]; // $2M

        int24[] memory tickLower = new int24[](7);
        int24[] memory tickUpper = new int24[](7);
        uint16[] memory positionBps = new uint16[](7);
        for (uint256 i = 0; i < 7; i++) {
            tickLower[i] = edges[i];
            tickUpper[i] = edges[i + 1];
            positionBps[i] = bps[i];
            require(tickUpper[i] > tickLower[i], "degenerate rung"); // SPY-price sanity
        }

        address[] memory rewardAdmins = new address[](1);
        rewardAdmins[0] = p.tokenAdmin;
        address[] memory rewardRecipients = new address[](1);
        rewardRecipients[0] = p.rewardRecipient;
        uint16[] memory rewardBps = new uint16[](1);
        rewardBps[0] = 10_000;

        ILiquidLpLockerFeeConversion.FeeIn[] memory prefs =
            new ILiquidLpLockerFeeConversion.FeeIn[](1);
        prefs[0] = ILiquidLpLockerFeeConversion.FeeIn.Paired;
        bytes memory feeData =
            abi.encode(ILiquidLpLockerFeeConversion.LpFeeConversionInfo({feePreference: prefs}));

        // spec §3: 2% floor, 5% cap, volatility term ON
        bytes memory feeVars = abi.encode(
            ILiquidHookDynamicFee.PoolDynamicConfigVars({
                baseFee: 20_000,
                maxLpFee: 50_000,
                referenceTickFilterPeriod: 3600,
                resetPeriod: 86_400,
                resetTickFilter: 500,
                feeControlNumerator: 500_000_000,
                decayFilterBps: 9_000
            })
        );
        bytes memory poolData = abi.encode(
            ILiquidHookV2.PoolInitializationData({extension: address(0), extensionData: "", feeData: feeVars})
        );
        bytes memory mevData = abi.encode(
            ILiquidMevDescendingFees.FeeConfig({
                startingFee: 500_000,
                endingFee: 20_000,
                secondsToDecay: 120
            })
        );

        config = ILiquid.DeploymentConfig({
            tokenConfig: ILiquid.TokenConfig({
                tokenAdmin: p.tokenAdmin,
                name: p.name,
                symbol: p.symbol,
                salt: p.salt,
                image: "",
                metadata: "",
                context: "",
                originatingChainId: p.chainId
            }),
            poolConfig: ILiquid.PoolConfig({
                hook: p.hook,
                pairedToken: p.pairedToken,
                tickIfToken0IsLiquid: edges[0],
                tickSpacing: TICK_SPACING,
                poolData: poolData
            }),
            lockerConfig: ILiquid.LockerConfig({
                locker: p.locker,
                rewardAdmins: rewardAdmins,
                rewardRecipients: rewardRecipients,
                rewardBps: rewardBps,
                tickLower: tickLower,
                tickUpper: tickUpper,
                positionBps: positionBps,
                lockerData: feeData
            }),
            mevModuleConfig: ILiquid.MevModuleConfig({mevModule: p.mevModule, mevModuleData: mevData}),
            extensionConfigs: new ILiquid.ExtensionConfig[](0)
        });
    }
}
```

(Check `ILiquid.TokenConfig`/`MevModuleConfig` field order against `script/LaunchSpying.s.sol` when transcribing — copy that file's literal struct construction style. If `TokenConfig.originatingChainId` is `uint256` keep `p.chainId`; the SPYING script is authoritative.)

- [ ] **Step 2: Write `script/LaunchRobinhoodTemplate.s.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Liquid} from "../src/Liquid.sol";
import {RobinhoodConfig} from "./lib/RobinhoodConfig.sol";
import {TopTraderRewardPool} from "../src/periphery/TopTraderRewardPool.sol";
import {ILiquid} from "../src/interfaces/ILiquid.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// Launch a Robinhood-template token per the 2026-08-29 spec:
/// SPY-paired, dynamic fee 2→5%, 7-position breakout ladder, LP fees routed
/// to a TopTraderRewardPool ($2M-MC migration latch).
///
/// env (see spec §1 for addresses):
///   DEPLOYER_PRIVATE_KEY  broadcast key
///   TOKEN_NAME / TOKEN_SYMBOL
///   TOKEN_SALT            uint, pre-mined via MineRobinhoodSalt.s.sol
///   SPY_USD_E8            live SPY/USD × 1e8 (operator-confirmed)
///   START_MC_USD_E8       optional, default 25_000e8
///   KEEPER_ADDRESS        monthly rPNL award poster
///   LIQUID_FACTORY / LIQUID_HOOK_DYNAMIC_FEE_V2 / LIQUID_MEV_DESCENDING_FEES
///   LOCKER_V2             0x4AB39080B54121136fEfFf86857641F40dA6b964 (NEVER v1)
///   SPY_TOKEN             0x117cc2133c37B721F49dE2A7a74833232B3B4C0C
///   STATE_VIEW            0xF3334192D15450CDd385C8b70E03f9A6bd9E673B
///   TREASURY              0xF0E1D993E7ec19a1E83e6288bBE531A2C5ce4131 (RH Safe)
contract LaunchRobinhoodTemplate is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address spy = vm.envAddress("SPY_TOKEN");

        require(block.chainid == 4663, "wrong chain");
        require(IERC20Metadata(spy).decimals() == 18, "SPY decimals != 18 — TickCalc assumes 18");

        RobinhoodConfig.Params memory p = RobinhoodConfig.Params({
            name: vm.envString("TOKEN_NAME"),
            symbol: vm.envString("TOKEN_SYMBOL"),
            salt: bytes32(vm.envUint("TOKEN_SALT")),
            tokenAdmin: deployer,
            hook: vm.envAddress("LIQUID_HOOK_DYNAMIC_FEE_V2"),
            pairedToken: spy,
            locker: vm.envAddress("LOCKER_V2"),
            mevModule: vm.envAddress("LIQUID_MEV_DESCENDING_FEES"),
            rewardRecipient: address(0), // filled after pool deploy below
            startMcUsdE8: vm.envOr("START_MC_USD_E8", uint256(25_000e8)),
            spyUsdE8: vm.envUint("SPY_USD_E8"),
            chainId: block.chainid
        });

        vm.startBroadcast(pk);

        // 1. reward pool first — it must exist as rewardRecipient at deployToken
        (, int24 migrationTick) = RobinhoodConfig.build(p); // pre-compute for constructor
        TopTraderRewardPool rewardPool = new TopTraderRewardPool(
            spy,
            deployer, // creator
            vm.envAddress("TREASURY"),
            vm.envAddress("KEEPER_ADDRESS"),
            migrationTick,
            vm.envAddress("STATE_VIEW")
        );
        p.rewardRecipient = address(rewardPool);
        (ILiquid.DeploymentConfig memory config,) = RobinhoodConfig.build(p);

        // 2. deploy token + pool + ladder through the factory
        address factory = vm.envAddress("LIQUID_FACTORY");
        if (Liquid(factory).deprecated()) Liquid(factory).setDeprecated(false);
        address token = Liquid(factory).deployToken(config);

        // 3. bind the pool id (dynamic-fee pools use the DYNAMIC_FEE_FLAG fee)
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token),
            currency1: Currency.wrap(spy),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: RobinhoodConfig.TICK_SPACING,
            hooks: IHooks(config.poolConfig.hook)
        });
        rewardPool.setPool(keccak256(abi.encode(key)));

        vm.stopBroadcast();

        console.log("token:", token);
        console.log("rewardPool:", address(rewardPool));
        console.log("migrationTick:", migrationTick);
        console.log("startTick:", config.poolConfig.tickIfToken0IsLiquid);
    }
}
```

Note: `require(token < spy)` sanity is implied by the mined salt; add `require(token < spy, "salt not mined: token is currency1");` right after `deployToken`. If `keccak256(abi.encode(key))` does not match the live pool in the Task 4 fork test, read how `LiquidHookV2.initializePool` constructs the `PoolKey` (grep `src/hooks/LiquidHookV2.sol` for `PoolKey(`) and mirror it exactly — the fee flag is the likely difference.

- [ ] **Step 3: Write `script/MineRobinhoodSalt.s.sol`**

Copy `script/MineSpyingSalt.s.sol` wholesale with these changes: contract name `MineRobinhoodSalt`; read `factory`, `admin` (deployer address), `pairedToken`, `TOKEN_NAME`, `TOKEN_SYMBOL` from env (`vm.envAddress`/`vm.envString`) instead of hardcoding; keep `supply = 100_000_000_000e18` and the `uint256(4663)` originating-chain literal; the loop and `vm.computeCreate2Address` stay identical, comparing `predicted < pairedToken`.

- [ ] **Step 4: Compile everything**

Run: `~/.foundry/bin/forge build`
Expected: clean compile. Fix import-path/struct-field mismatches against `LaunchSpying.s.sol` (the authoritative reference for every ILiquid struct literal).

- [ ] **Step 5: Commit**

```bash
~/.foundry/bin/forge fmt && git add script/lib/RobinhoodConfig.sol script/LaunchRobinhoodTemplate.s.sol script/MineRobinhoodSalt.s.sol && git commit -m "feat(4663): Robinhood launch template — breakout ladder config + launch/salt scripts"
```

---

### Task 4: 4663 fork test

**Files:**
- Create: `test/integration/RobinhoodTemplate4663.t.sol`

**Interfaces:**
- Consumes: `RobinhoodConfig.build`, `TopTraderRewardPool`, `Liquid.deployToken`, StateView at `0xF3334192D15450CDd385C8b70E03f9A6bd9E673B`, live factory/hook/locker/SPY addresses from Global Constraints.
- Produces: nothing downstream; this is the end-to-end gate before any broadcast.

- [ ] **Step 1: Write the fork test**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Liquid} from "../../src/Liquid.sol";
import {ILiquid} from "../../src/interfaces/ILiquid.sol";
import {RobinhoodConfig} from "../../script/lib/RobinhoodConfig.sol";
import {TopTraderRewardPool} from "../../src/periphery/TopTraderRewardPool.sol";
import {LiquidToken} from "../../src/LiquidToken.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IStateViewFork {
    function getSlot0(bytes32) external view returns (uint160, int24, uint24, uint24);
}

contract RobinhoodTemplate4663Test is Test {
    address constant FACTORY = 0x65c40274A1a2178A5140F80fcd6Fe7eFB954e6C2;
    address constant HOOK = 0xDEe7DCdcF599306D3C29E8Dd0e6F4C9c4B6f68CC;
    address constant MEV = 0xD86416EEDb067213Df7336662b3fa3B3A1A5e205;
    address constant LOCKER_V2 = 0x4AB39080B54121136fEfFf86857641F40dA6b964;
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant STATE_VIEW = 0xF3334192D15450CDd385C8b70E03f9A6bd9E673B;
    address constant TREASURY = 0xF0E1D993E7ec19a1E83e6288bBE531A2C5ce4131;

    address deployer = makeAddr("deployer");
    address keeper = makeAddr("keeper");
    uint256 constant SPY_USD_E8 = 650e8;

    function setUp() public {
        string memory rpc = vm.envOr("RH_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0);
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 4663, "not robinhood chain");
    }

    function _mineSalt(RobinhoodConfig.Params memory p) internal view returns (bytes32) {
        bytes32 initHash = keccak256(
            abi.encodePacked(
                type(LiquidToken).creationCode,
                abi.encode(p.name, p.symbol, uint256(100_000_000_000e18), p.tokenAdmin, "", "", "", uint256(4663))
            )
        );
        for (uint256 i = 1; i < 5_000_000; i++) {
            bytes32 derived = keccak256(abi.encode(p.tokenAdmin, bytes32(i)));
            if (vm.computeCreate2Address(derived, initHash, FACTORY) < SPY) return bytes32(i);
        }
        revert("no salt");
    }

    function test_fork_endToEnd_ladderAndRewardPool() public {
        assertEq(IERC20Metadata(SPY).decimals(), 18, "SPY decimals drifted from assumption");

        RobinhoodConfig.Params memory p = RobinhoodConfig.Params({
            name: "robinhood template test",
            symbol: "RHTEST",
            salt: bytes32(0),
            tokenAdmin: deployer,
            hook: HOOK,
            pairedToken: SPY,
            locker: LOCKER_V2,
            mevModule: MEV,
            rewardRecipient: address(0),
            startMcUsdE8: 25_000e8,
            spyUsdE8: SPY_USD_E8,
            chainId: 4663
        });
        p.salt = _mineSalt(p);

        (, int24 migrationTick) = RobinhoodConfig.build(p);
        vm.startPrank(deployer);
        TopTraderRewardPool pool =
            new TopTraderRewardPool(SPY, deployer, TREASURY, keeper, migrationTick, STATE_VIEW);
        p.rewardRecipient = address(pool);
        (ILiquid.DeploymentConfig memory config,) = RobinhoodConfig.build(p);

        if (Liquid(FACTORY).deprecated()) {
            vm.stopPrank();
            vm.prank(Liquid(FACTORY).owner());
            Liquid(FACTORY).setDeprecated(false);
            vm.startPrank(deployer);
        }
        address token = Liquid(FACTORY).deployToken(config);
        assertTrue(token < SPY, "token must be currency0");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token),
            currency1: Currency.wrap(SPY),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });
        bytes32 poolId = keccak256(abi.encode(key));
        pool.setPool(poolId);
        vm.stopPrank();

        // pool live at the computed start tick
        (uint160 sqrtPrice, int24 tick,,) = IStateViewFork(STATE_VIEW).getSlot0(poolId);
        assertGt(sqrtPrice, 0, "pool not initialized at computed poolId — check PoolKey fee flag");
        assertEq(tick, config.poolConfig.tickIfToken0IsLiquid, "init tick mismatch");

        // migration latch: below threshold on the live fork
        vm.expectRevert(TopTraderRewardPool.BelowMigrationTick.selector);
        pool.migrate();

        // ladder geometry sanity: 7 rungs, ascending, bps sum 10_000
        uint256 bpsSum;
        for (uint256 i = 0; i < 7; i++) {
            assertLt(config.lockerConfig.tickLower[i], config.lockerConfig.tickUpper[i]);
            if (i > 0) assertEq(config.lockerConfig.tickLower[i], config.lockerConfig.tickUpper[i - 1]);
            bpsSum += config.lockerConfig.positionBps[i];
        }
        assertEq(bpsSum, 10_000);
        assertEq(config.lockerConfig.tickUpper[6], 887_220);

        // density declines monotonically above the wall (spec §2): bps/tickspan
        // rung 2 (index 1) is the wall; check indexes 1..6 strictly decreasing
        uint256 prevDensityE18 = type(uint256).max;
        for (uint256 i = 1; i < 7; i++) {
            uint256 span = uint256(int256(config.lockerConfig.tickUpper[i] - config.lockerConfig.tickLower[i]));
            uint256 d = uint256(config.lockerConfig.positionBps[i]) * 1e18 / span;
            assertLt(d, prevDensityE18, "density must decline above the wall");
            prevDensityE18 = d;
        }
    }
}
```

- [ ] **Step 2: Run without RPC to confirm skip**

Run: `~/.foundry/bin/forge test --match-path test/integration/RobinhoodTemplate4663.t.sol -v`
Expected: test SKIPPED (no `RH_RPC_URL`).

- [ ] **Step 3: Run against the live fork**

Run: `RH_RPC_URL=https://rpc.mainnet.chain.robinhood.com ~/.foundry/bin/forge test --match-path test/integration/RobinhoodTemplate4663.t.sol -vv`
Expected: PASS. Known failure modes and their fixes:
- `pool not initialized at computed poolId` → the hook builds the PoolKey with a different fee value; grep `PoolKey(` in `src/hooks/LiquidHookV2.sol` and mirror it in BOTH the fork test and `LaunchRobinhoodTemplate.s.sol` step-3 key.
- `deployToken` reverts on allowlist → the dynamic hook/locker pair may need `setLocker`/allowlist enabling for this combination; check `DEPLOYMENTS-4663.md` Phase-4 notes and prank the factory owner (`Liquid(FACTORY).owner()`) to enable, mirroring what SPYING needed.
- Salt loop slow on fork → raise the bound only if it actually reverts; 5M iterations of computeCreate2Address is memory-only and fast.

- [ ] **Step 4: Run the FULL repo suite (regression gate)**

Run: `~/.foundry/bin/forge test`
Expected: everything green that was green before this branch (vault fork tests need `BASE_RPC_URL`; skip behavior unchanged).

- [ ] **Step 5: Commit**

```bash
~/.foundry/bin/forge fmt && git add test/integration/RobinhoodTemplate4663.t.sol && git commit -m "test(4663): end-to-end fork test — template ladder + reward pool against live factory"
```

---

### Task 5: Wrap-up

**Files:**
- Modify: `docs/superpowers/specs/2026-08-29-robinhood-launch-template-design.md` (status line only)

- [ ] **Step 1: Flip spec status** — change `**Status:** design approved in-session (Gordon), pending spec review` to `**Status:** P1 implemented (contract + template + tests) — see docs/superpowers/plans/2026-08-29-robinhood-launch-template-p1.md`.

- [ ] **Step 2: fmt + full suite one last time**

Run: `~/.foundry/bin/forge fmt --check && ~/.foundry/bin/forge test`
Expected: no formatting diffs; suite green.

- [ ] **Step 3: Commit and push**

```bash
git add -A docs/ && git commit -m "docs(4663): mark Robinhood template P1 implemented" && git push origin feat/robinhood-4663-deploy
```

**NOT in scope for P1** (explicit, per spec §6): the rPNL keeper (P2), the website `[ROBINHOOD]` section (P3), and any mainnet **broadcast** — broadcasting the template requires the deploy-safety-reviewer agent pass first (spec §7).
