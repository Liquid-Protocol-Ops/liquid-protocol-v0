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
///
/// Fee-claim runbook: LP fees do not arrive here automatically. The hook
/// auto-collects them into the LiquidFeeLocker escrow per swap
/// (`collectRewardsWithoutUnlock` → `storeFees(pool, SPY, amount)`), but
/// nothing pushes them from that escrow into this contract's own balance.
/// Anyone may permissionlessly call `LiquidFeeLocker.claim(address(pool), SPY)`
/// to move the escrowed SPY into the pot — the keeper does this before every
/// `awardMonth` (an empty pot reverts `EmptyPot`). `collectRewards(token)` on
/// the LP locker is only needed as a manual fallback if the hook's per-swap
/// auto-collection was skipped (e.g. inside the MEV-module window).
///
/// currency0 precondition: `migrate()`'s spot-tick comparison assumes the
/// launched token is `currency0` and SPY is `currency1` in the bound
/// `poolId` — guaranteed by the mined launch salt (`token < SPY`), not
/// re-checked here.
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
    error ZeroAddress();

    event MonthAwarded(address[3] winners, uint256 pot, uint256[3] amounts);
    event Migrated(int24 tickAtMigration, uint256 potOwedTreasury);
    event TreasurySettled(uint256 amount, uint256 remaining);
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
    /// @notice SPY owed to the treasury after migration (settled separately
    ///         from the latch so a reverting transfer can never brick it).
    uint256 public treasuryPot;

    constructor(
        address spy_,
        address creator_,
        address treasury_,
        address keeper_,
        int24 migrationTick_,
        address stateView_
    ) {
        if (
            spy_ == address(0) || creator_ == address(0) || treasury_ == address(0)
                || keeper_ == address(0) || stateView_ == address(0)
        ) revert ZeroAddress();
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

    /// @notice Permissionless one-way latch at the $2M-MC tick (spot). The
    ///         latch NEVER transfers — the stub pot is recorded as owed to the
    ///         treasury and settled via settleTreasury(), so a reverting SPY
    ///         transfer cannot brick migration.
    function migrate() external {
        if (migrated) revert AlreadyMigrated();
        if (poolId == bytes32(0)) revert PoolNotSet();
        (, int24 tick,,) = stateView.getSlot0(poolId);
        if (tick < migrationTick) revert BelowMigrationTick();

        migrated = true;
        treasuryPot = spy.balanceOf(address(this));
        emit Migrated(tick, treasuryPot);
    }

    /// @notice Settle the recorded migration pot to the treasury. Anyone may
    ///         call; retryable until fully settled.
    function settleTreasury() external {
        if (!migrated) revert NotMigrated();
        uint256 owed = treasuryPot;
        if (owed == 0) return;
        uint256 bal = spy.balanceOf(address(this));
        uint256 amt = owed <= bal ? owed : bal;
        treasuryPot = owed - amt;
        if (amt > 0) spy.safeTransfer(treasury, amt);
        emit TreasurySettled(amt, treasuryPot);
    }

    /// @notice Post-migration passthrough: forward any token to the creator.
    ///         SPY sweeps exclude the unsettled treasury pot — that portion
    ///         belongs to the treasury, not the creator.
    function sweep(address token) external {
        if (!migrated) revert NotMigrated();
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (token == address(spy)) {
            uint256 reserved = treasuryPot <= bal ? treasuryPot : bal;
            bal -= reserved;
        }
        IERC20(token).safeTransfer(creator, bal);
        emit Swept(token, bal);
    }
}
