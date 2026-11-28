// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IInferenceVaultQueue} from "./interfaces/IInferenceVaultQueue.sol";

/// @title  jitDIEM
/// @notice An ERC-4626 vault of DIEM that is also the Uniswap v4 hook for the DIEM/wstDIEM pool.
///
///         The pool has no AMM curve. The hook prices every swap itself against wstDIEM's NAV
///         (custom accounting via beforeSwapReturnDelta), using jitDIEM's own balances as inventory:
///
///         BUY  (DIEM -> wstDIEM): filled at NAV. If jitDIEM is below its DIEM target it first sells
///              its own wstDIEM inventory at NAV * (1 + buyInventoryFee) - restoring its DIEM instantly,
///              no queue. Any remainder is deposited (staked) into wstDIEM at the vault's own price.
///              Depth is effectively unlimited (bounded by wstDIEM maxDeposit).
///         SELL (wstDIEM -> DIEM): filled from jitDIEM's idle DIEM at NAV * (1 - sellFee), where sellFee
///              rises quadratically as idle DIEM falls below target. Price is bounded to
///              [NAV*(1-maxSellFee), NAV*(1-minSellFee)]. The wstDIEM received is held (it keeps
///              accruing inference yield) and is redeemed through the wstDIEM queue when needed.
///
///         jitDIEM holders earn: sell spreads, inventory buy spreads, wstDIEM yield on inventory,
///         and any rewards (e.g. a share of launch-pool fees) sent to this contract, vested linearly.
contract jitDIEM is ERC4626, Ownable2Step, ReentrancyGuardTransient, IUnlockCallback {
    using SafeERC20 for IERC20;
    using TransientStateLibrary for IPoolManager;

    // ------------------------------------------------------------------ constants
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;
    /// @dev Below this, a buy remainder is too small to deposit; it is kept by the vault as spread.
    uint256 internal constant DEPOSIT_DUST = 1e9;

    // ------------------------------------------------------------------ errors
    error NotPoolManager();
    error NotGuardian();
    error WrongPool();
    error PoolAlreadyInitialized();
    error NotAuthorizedToInitialize();
    error NoDirectLiquidity();
    error InsufficientLiquidity();
    error NavCircuitBreaker();
    error SwapsPaused();
    error ManagerUnlocked();
    error BadParams();
    error AmountTooLarge();

    // ------------------------------------------------------------------ events
    event Sold(
        address indexed sender, uint256 wstIn, uint256 diemOut, uint256 feeBps, uint256 navWad
    );
    event Bought(
        address indexed sender,
        uint256 diemIn,
        uint256 wstOut,
        uint256 wstFromInventory,
        uint256 navWad
    );
    event RedeemRequested(uint256 indexed requestId, uint256 shares, uint256 diem);
    event RedeemClaimed(uint256 indexed requestId, uint256 diem);
    event Staked(uint256 diem, uint256 shares);
    event RewardsVested(uint256 diemValue, uint256 newLockedProfit);
    event ParamsSet(Params p);
    event PausedSet(bool buys, bool sells);
    event GuardianSet(address guardian);
    event NavReset(uint256 navWad);

    // ------------------------------------------------------------------ config
    struct Params {
        uint16 minSellFeeBps; // sell fee when idle DIEM >= target
        uint16 maxSellFeeBps; // sell fee as idle DIEM -> 0
        uint16 buyInventoryFeeBps; // premium over NAV when buyers are filled from jitDIEM inventory
        uint16 targetIdleBps; // target idle DIEM as share of gross assets
        uint16 floorIdleBps; // sells revert if they would push idle DIEM below this share
        uint16 rebalanceBandBps; // hysteresis band around target before redeeming / staking
        uint16 exitFeeBps; // jitDIEM withdrawal fee (kept by the vault; anti-sandwich)
        uint16 maxNavDropBps; // sells halt if NAV falls more than this vs. last observation
        uint32 maxNavGrowthBpsPerYear; // cap on how fast the NAV used for SELL pricing may rise
        uint32 rewardVestingPeriod; // seconds over which detected rewards are released
        uint32 maintainInterval; // min seconds between in-swap maintenance runs
        uint32 navGrowthWindow; // max seconds of NAV-cap headroom that can build up while nobody calls the contract
        bool autoMaintain; // run claim/redeem maintenance in afterSwap
    }

    IPoolManager public immutable poolManager;
    IInferenceVaultQueue public immutable wst;
    IERC20 internal immutable _diem;
    Currency internal immutable cDiem;
    Currency internal immutable cWst;
    bool internal immutable diemIsCurrency0;

    Params public params;
    address public guardian;
    bool public buysPaused;
    bool public sellsPaused;

    PoolId public poolId;
    bool public poolInitialized;

    /// @notice DIEM held (ERC-20 balance + PoolManager ERC-6909 claims) that the vault has accounted for.
    uint256 public trackedDIEM;
    /// @notice wstDIEM held (ERC-20 balance + ERC-6909 claims) that the vault has accounted for.
    uint256 public trackedwstDIEM;
    /// @notice DIEM owed to this vault by queued wstDIEM redemptions.
    uint256 public pendingRedeemDIEM;
    uint256[] public pendingIds;
    uint256 public pendingHead;

    uint256 public lockedProfit;
    uint64 public lastLockTime;
    uint256 public lastNav;
    uint64 public lastNavTime;
    uint64 public lastMaintain;

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyGuardianOrOwner() {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardian();
        _;
    }

    constructor(
        IPoolManager _poolManager,
        IInferenceVaultQueue _wst,
        address _owner,
        Params memory _params
    ) ERC20("jitDIEM", "jitDIEM") ERC4626(IERC20(_wst.asset())) Ownable(_owner) {
        poolManager = _poolManager;
        wst = _wst;
        _diem = IERC20(_wst.asset());
        cDiem = Currency.wrap(address(_diem));
        cWst = Currency.wrap(address(_wst));
        diemIsCurrency0 = address(_diem) < address(_wst);

        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());

        _setParams(_params);
        lastNav = _wst.convertToAssets(WAD);
        lastNavTime = uint64(block.timestamp);
        _diem.forceApprove(address(_wst), type(uint256).max);
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // =================================================================== HOOK CALLBACKS

    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (poolInitialized) revert PoolAlreadyInitialized();
        if (sender != owner()) revert NotAuthorizedToInitialize();
        (Currency c0, Currency c1) = diemIsCurrency0 ? (cDiem, cWst) : (cWst, cDiem);
        if (
            Currency.unwrap(key.currency0) != Currency.unwrap(c0)
                || Currency.unwrap(key.currency1) != Currency.unwrap(c1)
                || address(key.hooks) != address(this) || key.fee != 0
        ) revert WrongPool();
        poolId = key.toId();
        poolInitialized = true;
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        revert NoDirectLiquidity();
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata sp,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();

        _convertClaims();

        bool exactIn = sp.amountSpecified < 0;
        uint256 specified = exactIn ? uint256(-sp.amountSpecified) : uint256(sp.amountSpecified);
        bool diemIn = (sp.zeroForOne == diemIsCurrency0);

        (uint256 amountIn, uint256 amountOut) =
            diemIn ? _buy(sender, exactIn, specified) : _sell(sender, exactIn, specified);

        BeforeSwapDelta d = exactIn
            ? toBeforeSwapDelta(_i128(amountIn), -_i128(amountOut))
            : toBeforeSwapDelta(-_i128(amountOut), _i128(amountIn));
        return (IHooks.beforeSwap.selector, d, 0);
    }

    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        Params memory p = params;
        if (p.autoMaintain && block.timestamp >= uint256(lastMaintain) + p.maintainInterval) {
            _maintain(false);
        }
        return (IHooks.afterSwap.selector, 0);
    }

    /// @dev Used by `rebalance()` to convert ERC-6909 claims into real tokens outside of a swap.
    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        _convertClaims();
        return "";
    }

    // =================================================================== PRICING

    /// @notice NAV used to price SELLS and value inventory: spot NAV, but never allowed to rise faster
    ///         than maxNavGrowthBpsPerYear since the last observation. A donation that inflates
    ///         wstDIEM's convertToAssets therefore cannot be cashed out against jitDIEM.
    function navConservative() public view returns (uint256) {
        return _navCons(wst.convertToAssets(WAD));
    }

    function _navCons(uint256 spot) internal view returns (uint256) {
        uint256 last = lastNav;
        if (last == 0) return spot;
        // Headroom is capped at navGrowthWindow seconds of growth, so it cannot build up during quiet periods.
        uint256 dt = block.timestamp - lastNavTime;
        if (dt > params.navGrowthWindow) dt = params.navGrowthWindow;
        uint256 cap =
            last + Math.mulDiv(last, uint256(params.maxNavGrowthBpsPerYear) * dt, BPS * YEAR);
        return spot < cap ? spot : cap;
    }

    function _observeNav() internal returns (uint256 spot, uint256 cons) {
        spot = wst.convertToAssets(WAD);
        // A tripped breaker is sticky: lastNav is not lowered until the owner calls resetNav().
        if (_navBreakerTripped(spot)) return (spot, spot);
        cons = _navCons(spot);
        if (cons != lastNav) {
            lastNav = cons;
            lastNavTime = uint64(block.timestamp);
        } else if (cons == spot) {
            lastNavTime = uint64(block.timestamp);
        }
    }

    function _navBreakerTripped(uint256 spot) internal view returns (bool) {
        return spot * BPS < lastNav * (BPS - params.maxNavDropBps);
    }

    /// @notice Gross DIEM value of everything the vault holds (before locked-profit deduction).
    function grossAssets() public view returns (uint256) {
        return _gross(navConservative());
    }

    function _gross(uint256 rate) internal view returns (uint256) {
        return trackedDIEM + pendingRedeemDIEM + Math.mulDiv(trackedwstDIEM, rate, WAD);
    }

    /// @notice Sell fee in bps for removing `out` DIEM when the vault holds `idle` DIEM out of `gross` total.
    ///         Evaluated at the trade's midpoint idle level (approximates the integral of the fee curve).
    function sellFeeBps(uint256 idle, uint256 out, uint256 gross) public view returns (uint256) {
        Params memory p = params;
        uint256 target = Math.mulDiv(gross, p.targetIdleBps, BPS);
        uint256 half = out / 2;
        uint256 mid = idle > half ? idle - half : 0;
        if (target == 0 || mid >= target) return p.minSellFeeBps;
        uint256 x = Math.mulDiv(target - mid, BPS, target, Math.Rounding.Ceil); // depletion 0..BPS
        return p.minSellFeeBps
            + Math.mulDiv(
            uint256(p.maxSellFeeBps - p.minSellFeeBps) * x, x, BPS * BPS, Math.Rounding.Ceil
        );
    }

    // =================================================================== SWAP LOGIC

    /// @dev wstDIEM -> DIEM. Paid from jitDIEM's idle DIEM at conservative NAV minus a dynamic fee.
    function _sell(address sender, bool exactIn, uint256 specified)
        internal
        returns (uint256 wstIn, uint256 diemOut)
    {
        if (sellsPaused) revert SwapsPaused();
        uint256 spot = wst.convertToAssets(WAD);
        if (_navBreakerTripped(spot)) revert NavCircuitBreaker();
        (, uint256 rate) = _observeNav();

        uint256 gross = _gross(rate);
        uint256 idle = trackedDIEM;
        uint256 fee;
        if (exactIn) {
            wstIn = specified;
            uint256 atNav = Math.mulDiv(wstIn, rate, WAD);
            // fee from an upper-bound estimate of the output (conservative: fee is never under-charged)
            fee = sellFeeBps(idle, Math.mulDiv(atNav, BPS - params.minSellFeeBps, BPS), gross);
            diemOut = Math.mulDiv(wstIn, rate * (BPS - fee), WAD * BPS);
        } else {
            diemOut = specified;
            fee = sellFeeBps(idle, diemOut, gross);
            wstIn = Math.mulDiv(diemOut, WAD * BPS, rate * (BPS - fee), Math.Rounding.Ceil);
        }
        if (diemOut == 0) revert InsufficientLiquidity();
        if (diemOut > idle || idle - diemOut < Math.mulDiv(gross, params.floorIdleBps, BPS)) {
            revert InsufficientLiquidity();
        }

        _takeIn(cWst, wstIn);
        trackedwstDIEM += wstIn;
        _payOut(cDiem, diemOut);
        trackedDIEM -= diemOut;

        emit Sold(sender, wstIn, diemOut, fee, rate);
    }

    /// @dev DIEM -> wstDIEM. Inventory first (only while jitDIEM is below its DIEM target), then stake.
    function _buy(address sender, bool exactIn, uint256 specified)
        internal
        returns (uint256 diemIn, uint256 wstOut)
    {
        if (buysPaused) revert SwapsPaused();
        (uint256 spot, uint256 rate) = _observeNav();

        uint256 inv;
        if (
            !_navBreakerTripped(spot)
                && trackedDIEM < Math.mulDiv(_gross(rate), params.targetIdleBps, BPS)
        ) {
            inv = trackedwstDIEM;
        }
        // Buyers pay spot NAV (never the capped NAV) plus the inventory premium.
        uint256 px = spot * (BPS + params.buyInventoryFeeBps); // DIEM per wstDIEM, scaled by WAD*BPS

        uint256 fromInv;
        uint256 diemToInv;
        uint256 diemToStake;
        if (exactIn) {
            diemIn = specified;
            uint256 maxShares = Math.mulDiv(diemIn, WAD * BPS, px);
            fromInv = maxShares < inv ? maxShares : inv;
            diemToInv = fromInv == maxShares
                ? diemIn
                : Math.mulDiv(fromInv, px, WAD * BPS, Math.Rounding.Ceil);
            diemToStake = diemIn - diemToInv;
            if (diemToStake > 0 && diemToStake < DEPOSIT_DUST && fromInv > 0) {
                diemToInv = diemIn; // dust kept by the vault
                diemToStake = 0;
            }
        } else {
            wstOut = specified;
            fromInv = wstOut < inv ? wstOut : inv;
            diemToInv = Math.mulDiv(fromInv, px, WAD * BPS, Math.Rounding.Ceil);
            uint256 sharesToMint = wstOut - fromInv;
            diemToStake = sharesToMint > 0 ? wst.previewMint(sharesToMint) : 0;
            diemIn = diemToInv + diemToStake;
        }

        // 1) receive the buyer's DIEM (real tokens if the PoolManager holds them, else ERC-6909 claims)
        _takeIn(cDiem, diemIn);
        trackedDIEM += diemIn;

        // 2) stake the remainder into wstDIEM (needs real DIEM)
        uint256 staked;
        if (diemToStake > 0) {
            if (_diem.balanceOf(address(this)) < diemToStake) revert InsufficientLiquidity();
            if (exactIn) {
                staked = wst.deposit(diemToStake, address(this));
            } else {
                staked = wstOut - fromInv;
                wst.mint(staked, address(this));
            }
            trackedDIEM -= diemToStake;
            emit Staked(diemToStake, staked);
        }
        if (exactIn) wstOut = fromInv + staked;
        if (wstOut == 0) revert InsufficientLiquidity();

        // 3) deliver wstDIEM: freshly staked shares + inventory (real first, claims after)
        uint256 realWst = wst.balanceOf(address(this));
        uint256 realPart = fromInv + staked;
        uint256 claimPart;
        if (realPart > realWst) {
            claimPart = realPart - realWst;
            realPart = realWst;
        }
        if (realPart > 0) {
            poolManager.sync(cWst);
            IERC20(address(wst)).safeTransfer(address(poolManager), realPart);
            poolManager.settle();
        }
        if (claimPart > 0) poolManager.burn(address(this), cWst.toId(), claimPart);
        trackedwstDIEM -= fromInv;

        emit Bought(sender, diemIn, wstOut, fromInv, spot);
    }

    function _takeIn(Currency c, uint256 amount) internal {
        if (c.balanceOf(address(poolManager)) >= amount) {
            poolManager.take(c, address(this), amount);
        } else {
            // The swapper settles after the hook runs (e.g. first hop from a wallet): hold claims instead.
            poolManager.mint(address(this), c.toId(), amount);
        }
    }

    function _payOut(Currency c, uint256 amount) internal {
        uint256 bal = IERC20(Currency.unwrap(c)).balanceOf(address(this));
        uint256 real = bal < amount ? bal : amount;
        if (real > 0) {
            poolManager.sync(c);
            IERC20(Currency.unwrap(c)).safeTransfer(address(poolManager), real);
            poolManager.settle();
        }
        if (amount > real) poolManager.burn(address(this), c.toId(), amount - real);
    }

    /// @dev Burn ERC-6909 claims for real tokens wherever the PoolManager can pay. Requires an unlocked manager.
    function _convertClaims() internal {
        _convertClaim(cDiem);
        _convertClaim(cWst);
    }

    function _convertClaim(Currency c) internal {
        uint256 claims = poolManager.balanceOf(address(this), c.toId());
        if (claims == 0) return;
        uint256 avail = c.balanceOf(address(poolManager));
        uint256 amt = claims < avail ? claims : avail;
        if (amt == 0) return;
        poolManager.burn(address(this), c.toId(), amt);
        poolManager.take(c, address(this), amt);
    }

    // =================================================================== MAINTENANCE (keeper-optional)

    /// @notice Permissionless upkeep: converts claims, claims matured redemptions, vests rewards,
    ///         requests wstDIEM redemptions when idle DIEM is below band, stakes idle DIEM above band.
    function rebalance() external nonReentrant {
        if (poolManager.isUnlocked()) revert ManagerUnlocked();
        poolManager.unlock("");
        _observeNav();
        _claimMatured(10);
        _sync();
        _maintain(true);
    }

    /// @notice Permissionless: account for any tokens sent to the vault (e.g. launch-fee rewards) and vest them.
    function sync() external nonReentrant {
        if (poolManager.isUnlocked()) revert ManagerUnlocked();
        _observeNav();
        _claimMatured(10);
        _sync();
    }

    function _maintain(bool allowStake) internal {
        lastMaintain = uint64(block.timestamp);
        _claimMatured(3);

        uint256 rate = _navCons(wst.convertToAssets(WAD));
        uint256 gross = _gross(rate);
        uint256 target = Math.mulDiv(gross, params.targetIdleBps, BPS);
        uint256 band = Math.mulDiv(gross, params.rebalanceBandBps, BPS);
        uint256 idleish = trackedDIEM + pendingRedeemDIEM;

        if (idleish + band < target && !_hasOpenRequest()) {
            uint256 realWst = wst.balanceOf(address(this));
            if (realWst > trackedwstDIEM) realWst = trackedwstDIEM;
            uint256 want = Math.mulDiv(target - idleish, WAD, rate);
            uint256 shares = want < realWst ? want : realWst;
            uint256 minShares;
            try wst.minRedeemShares() returns (uint256 m) {
                minShares = m;
            } catch {}
            if (shares > 0 && shares >= minShares) {
                try wst.requestRedeem(shares, address(this)) returns (uint256 id) {
                    uint256 owed;
                    try wst.requestStatus(id) returns (
                        address, uint256 d, uint32, uint64, bool, bool
                    ) {
                        owed = d;
                    } catch {
                        owed = Math.mulDiv(shares, wst.convertToAssets(WAD), WAD);
                    }
                    trackedwstDIEM -= shares;
                    pendingRedeemDIEM += owed;
                    pendingIds.push(id);
                    emit RedeemRequested(id, shares, owed);
                } catch {}
            }
        } else if (allowStake && trackedDIEM > target + band) {
            uint256 excess = trackedDIEM - target;
            uint256 real = _diem.balanceOf(address(this));
            if (excess > real) excess = real;
            if (excess >= DEPOSIT_DUST) {
                try wst.deposit(excess, address(this)) returns (uint256 shares) {
                    trackedDIEM -= excess;
                    trackedwstDIEM += shares;
                    emit Staked(excess, shares);
                } catch {}
            }
        }
    }

    /// @dev The live vault gives every requestRedeem its own slot in a 50-slot batch and never merges them.
    ///      Hold at most one request in the batch that is still open (not yet flushed).
    function _hasOpenRequest() internal view returns (bool) {
        uint256 n = pendingIds.length;
        if (n == pendingHead) return false;
        try wst.requestStatus(pendingIds[n - 1]) returns (
            address, uint256, uint32, uint64 unlockAt, bool, bool
        ) {
            return unlockAt == 0;
        } catch {
            return true;
        }
    }

    function _claimMatured(uint256 maxN) internal {
        uint256 head = pendingHead;
        uint256 end = pendingIds.length;
        for (uint256 i; i < maxN && head < end; ++i) {
            uint256 id = pendingIds[head];
            uint256 owed;
            bool settled;
            bool claimed;
            try wst.requestStatus(id) returns (
                address, uint256 d, uint32, uint64, bool s_, bool c_
            ) {
                (owed, settled, claimed) = (d, s_, c_);
            } catch {
                break;
            }
            if (!claimed) {
                if (!settled) break;
                try wst.claimRedeem(id) {}
                catch {
                    break;
                }
            }
            // claimed now (by us) or earlier by a third party: DIEM is in our balance either way
            pendingRedeemDIEM -= owed;
            trackedDIEM += owed;
            emit RedeemClaimed(id, owed);
            ++head;
        }
        pendingHead = head;
    }

    /// @dev Detect untracked inflows (rewards, donations) and vest them; absorb any shortfall as a loss.
    function _sync() internal {
        uint256 rate = navConservative();
        uint256 reward;
        uint256 actualDiem =
            _diem.balanceOf(address(this)) + poolManager.balanceOf(address(this), cDiem.toId());
        if (actualDiem > trackedDIEM) reward += actualDiem - trackedDIEM;
        trackedDIEM = actualDiem;
        uint256 actualWst =
            wst.balanceOf(address(this)) + poolManager.balanceOf(address(this), cWst.toId());
        if (actualWst > trackedwstDIEM) {
            reward += Math.mulDiv(actualWst - trackedwstDIEM, rate, WAD);
        }
        trackedwstDIEM = actualWst;
        if (reward > 0) {
            lockedProfit = _lockedNow() + reward;
            lastLockTime = uint64(block.timestamp);
            emit RewardsVested(reward, lockedProfit);
        }
    }

    function _lockedNow() internal view returns (uint256) {
        uint256 period = params.rewardVestingPeriod;
        uint256 elapsed = block.timestamp - lastLockTime;
        if (period == 0 || elapsed >= period) return 0;
        return Math.mulDiv(lockedProfit, period - elapsed, period);
    }

    // =================================================================== ERC-4626 (jitDIEM LP side)

    function totalAssets() public view override returns (uint256) {
        uint256 g = _gross(navConservative());
        uint256 l = _lockedNow();
        return g > l ? g - l : 0;
    }

    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        returns (uint256)
    {
        _beforeLp();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        _beforeLp();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        nonReentrant
        returns (uint256)
    {
        _beforeLp();
        return super.withdraw(assets, receiver, owner_);
    }

    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        nonReentrant
        returns (uint256)
    {
        _beforeLp();
        return super.redeem(shares, receiver, owner_);
    }

    /// @notice Exit without waiting on the wstDIEM queue: pro-rata idle DIEM, the rest of the value in wstDIEM
    ///         (valued at spot NAV, so remaining holders are never diluted).
    function redeemInKind(uint256 shares, address receiver, address owner_)
        external
        nonReentrant
        returns (uint256 diemOut, uint256 wstOut)
    {
        _beforeLp();
        uint256 assets = previewRedeem(shares);
        if (msg.sender != owner_) _spendAllowance(owner_, msg.sender, shares);
        diemOut = Math.mulDiv(_realDiem(), shares, totalSupply());
        if (diemOut > assets) diemOut = assets;
        wstOut = Math.mulDiv(assets - diemOut, WAD, wst.convertToAssets(WAD));
        if (wstOut > _realWst()) revert InsufficientLiquidity();
        _burn(owner_, shares);
        trackedDIEM -= diemOut;
        trackedwstDIEM -= wstOut;
        if (diemOut > 0) _diem.safeTransfer(receiver, diemOut);
        if (wstOut > 0) IERC20(address(wst)).safeTransfer(receiver, wstOut);
        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    function maxWithdraw(address owner_) public view override returns (uint256) {
        uint256 a = previewRedeem(balanceOf(owner_));
        uint256 avail = _realDiem();
        return a < avail ? a : avail;
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        uint256 bal = balanceOf(owner_);
        uint256 avail = _realDiem();
        if (previewRedeem(bal) <= avail) return bal;
        uint256 s = previewWithdraw(avail);
        return s > 0 ? s - 1 : 0;
    }

    /// @dev Exit fee (OpenZeppelin ERC4626Fees pattern); the fee stays in the vault for remaining holders.
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 fee = Math.mulDiv(assets, params.exitFeeBps, BPS, Math.Rounding.Ceil);
        return super.previewWithdraw(assets + fee);
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        uint256 assets = super.previewRedeem(shares);
        uint256 fee =
            Math.mulDiv(assets, params.exitFeeBps, params.exitFeeBps + BPS, Math.Rounding.Ceil);
        return assets - fee;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
    {
        super._deposit(caller, receiver, assets, shares);
        trackedDIEM += assets;
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner_,
        uint256 assets,
        uint256 shares
    ) internal override {
        trackedDIEM -= assets;
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    function _beforeLp() internal {
        // No LP entry/exit mid-unlock: balances can include unsettled ERC-6909 claims.
        if (poolManager.isUnlocked()) revert ManagerUnlocked();
        _observeNav();
        _claimMatured(3);
        _sync();
    }

    function _realDiem() internal view returns (uint256) {
        uint256 b = _diem.balanceOf(address(this));
        return b < trackedDIEM ? b : trackedDIEM;
    }

    function _realWst() internal view returns (uint256) {
        uint256 b = wst.balanceOf(address(this));
        return b < trackedwstDIEM ? b : trackedwstDIEM;
    }

    // =================================================================== VIEWS

    function idleRatioBps() external view returns (uint256) {
        uint256 g = grossAssets();
        return g == 0 ? 0 : Math.mulDiv(trackedDIEM, BPS, g);
    }

    function pendingCount() external view returns (uint256) {
        return pendingIds.length - pendingHead;
    }

    // =================================================================== ADMIN

    function setParams(Params calldata p) external onlyOwner {
        _setParams(p);
    }

    function _setParams(Params memory p) internal {
        if (
            p.maxSellFeeBps > 1000 || p.minSellFeeBps > p.maxSellFeeBps
                || p.buyInventoryFeeBps > 100 || p.targetIdleBps > 9500
                || p.floorIdleBps >= p.targetIdleBps || p.rebalanceBandBps > p.targetIdleBps
                || p.exitFeeBps > 100 || p.maxNavDropBps == 0 || p.maxNavDropBps > 2000
                || p.maxNavGrowthBpsPerYear > 20_000 || p.rewardVestingPeriod > 30 days
                || p.navGrowthWindow == 0 || p.navGrowthWindow > 7 days
        ) revert BadParams();
        params = p;
        emit ParamsSet(p);
    }

    function setGuardian(address g) external onlyOwner {
        guardian = g;
        emit GuardianSet(g);
    }

    function setPaused(bool buys, bool sells) external onlyGuardianOrOwner {
        // guardian may only pause; unpausing requires the owner
        if (msg.sender != owner() && ((buysPaused && !buys) || (sellsPaused && !sells))) {
            revert NotGuardian();
        }
        buysPaused = buys;
        sellsPaused = sells;
        emit PausedSet(buys, sells);
    }

    /// @notice Accept the current spot NAV after a legitimate markdown tripped the breaker.
    function resetNav() external onlyOwner {
        lastNav = wst.convertToAssets(WAD);
        lastNavTime = uint64(block.timestamp);
        emit NavReset(lastNav);
    }

    // =================================================================== utils

    function _i128(uint256 x) internal pure returns (int128) {
        if (x > uint256(uint128(type(int128).max))) revert AmountTooLarge();
        // forge-lint: disable-next-line(unsafe-typecast)
        return int128(int256(x));
    }
}
