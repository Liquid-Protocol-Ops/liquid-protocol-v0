// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LiquidToken} from "../LiquidToken.sol";

import {ILiquid} from "../interfaces/ILiquid.sol";

import {ILiquidLpLocker} from "../interfaces/ILiquidLpLocker.sol";
import {ILiquidMevModule} from "../interfaces/ILiquidMevModule.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {ILiquidHookV2PoolExtension} from "./interfaces/ILiquidHookV2PoolExtension.sol";
import {ILiquidPoolExtensionAllowlist} from "./interfaces/ILiquidPoolExtensionAllowlist.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ILiquidHook} from "../interfaces/ILiquidHook.sol";
import {ILiquidHookV2} from "./interfaces/ILiquidHookV2.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BalanceDelta, add, sub, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

abstract contract LiquidHookV2 is BaseHook, ILiquidHookV2 {
    string public constant PROTOCOL = "Liquid Protocol";
    using TickMath for int24;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using StateLibrary for *;

    uint24 public constant MAX_LP_FEE = 100_000; // LP fee capped at 10%
    uint24 public constant MAX_MEV_LP_FEE = 800_000; // Max MEV LP fee at 80%
    uint256 public constant PROTOCOL_FEE_NUMERATOR = 200_000; // 20% of the imposed LP fee
    int128 public constant FEE_DENOMINATOR = 1_000_000; // Uniswap 100% fee

    uint24 public protocolFee;

    address public immutable factory;
    ILiquidPoolExtensionAllowlist public immutable poolExtensionAllowlist;
    address public immutable weth;

    mapping(PoolId => bool) public liquidIsToken0;
    mapping(PoolId => address) public locker;

    // mev module pool variables
    uint256 public constant MAX_MEV_MODULE_DELAY = 2 minutes;
    mapping(PoolId => address) public mevModule;
    mapping(PoolId => bool) public mevModuleEnabled;
    mapping(PoolId => uint256) public poolCreationTimestamp;

    // pool extension pool variables
    mapping(PoolId => address) public poolExtension;
    mapping(PoolId => bool) public poolExtensionSetup;

    modifier onlyFactory() {
        if (msg.sender != factory) {
            revert OnlyFactory();
        }
        _;
    }

    constructor(
        address _poolManager,
        address _factory,
        address _poolExtensionAllowlist,
        address _weth
    ) BaseHook(IPoolManager(_poolManager)) {
        factory = _factory;
        poolExtensionAllowlist = ILiquidPoolExtensionAllowlist(_poolExtensionAllowlist);
        weth = _weth;
    }

    // function to for inheriting hooks to set fees in _beforeSwap hook
    function _setFee(PoolKey calldata poolKey, IPoolManager.SwapParams calldata swapParams)
        internal
        virtual
    {
        return;
    }

    // function to set the protocol fee to 20% of the lp fee
    function _setProtocolFee(uint24 lpFee) internal {
        protocolFee = uint24(uint256(lpFee) * PROTOCOL_FEE_NUMERATOR / uint128(FEE_DENOMINATOR));
    }

    // function to for inheriting hooks to set process data in during initialization flow
    function _initializeFeeData(PoolKey memory poolKey, bytes memory feeData) internal virtual {
        return;
    }

    function _initializePoolExtensionData(
        PoolKey memory poolKey,
        address _poolExtension,
        bytes memory poolExtensionData
    ) internal virtual {
        if (_poolExtension != address(0)) {
            // check that the pool extension is enabled
            if (!poolExtensionAllowlist.enabledExtensions(_poolExtension)) {
                revert PoolExtensionNotEnabled();
            }

            ILiquidHookV2PoolExtension(_poolExtension).initializePreLockerSetup(
                poolKey, liquidIsToken0[poolKey.toId()], poolExtensionData
            );
            poolExtension[poolKey.toId()] = _poolExtension;
        }
        return;
    }

    // function for the factory to initialize a pool
    function initializePool(
        address liquid,
        address pairedToken,
        int24 tickIfToken0IsLiquid,
        int24 tickSpacing,
        address _locker,
        address _mevModule,
        bytes calldata poolData
    ) public onlyFactory returns (PoolKey memory) {
        // initialize the pool
        PoolKey memory poolKey =
            _initializePool(liquid, pairedToken, tickIfToken0IsLiquid, tickSpacing, poolData);

        // set the locker config
        locker[poolKey.toId()] = _locker;

        // set the mev module
        mevModule[poolKey.toId()] = _mevModule;

        emit PoolCreatedFactory({
            pairedToken: pairedToken,
            liquid: liquid,
            poolId: poolKey.toId(),
            tickIfToken0IsLiquid: tickIfToken0IsLiquid,
            tickSpacing: tickSpacing,
            locker: _locker,
            mevModule: _mevModule
        });

        emit PoolExtensionRegistered(poolKey.toId(), poolExtension[poolKey.toId()]);

        return poolKey;
    }

    // function to let anyone initialize a pool
    //
    // this is allow tokens not created by the factory to be used with this hook
    //
    // note: these pools do not have lp locker auto-claim, pool extensions, or mev module functionality
    function initializePoolOpen(
        address liquid,
        address pairedToken,
        int24 tickIfToken0IsLiquid,
        int24 tickSpacing,
        bytes calldata poolData
    ) public returns (PoolKey memory) {
        // if able, we prefer that weth is not the liquid as our hook fee will only
        // collect fees on the paired token
        if (liquid == weth) {
            revert WethCannotBeLiquid();
        }

        PoolKey memory poolKey =
            _initializePool(liquid, pairedToken, tickIfToken0IsLiquid, tickSpacing, poolData);

        // check that the pool's extension was not set
        //
        // non-factory pools have no way of triggering the initializePostLockerSetup step
        // and in general will lack fees to do things with
        if (poolExtension[poolKey.toId()] != address(0)) {
            revert OnlyFactoryPoolsCanHaveExtensions();
        }

        emit PoolCreatedOpen(
            pairedToken, liquid, poolKey.toId(), tickIfToken0IsLiquid, tickSpacing
        );

        return poolKey;
    }

    // common actions for initializing a pool
    function _initializePool(
        address liquid,
        address pairedToken,
        int24 tickIfToken0IsLiquid,
        int24 tickSpacing,
        bytes calldata poolData
    ) internal virtual returns (PoolKey memory) {
        // ensure that the pool is not an ETH pool
        if (pairedToken == address(0) || liquid == address(0)) {
            revert ETHPoolNotAllowed();
        }

        // determine if liquid is token0
        bool token0IsLiquid = liquid < pairedToken;

        // create the pool key
        PoolKey memory _poolKey = PoolKey({
            currency0: Currency.wrap(token0IsLiquid ? liquid : pairedToken),
            currency1: Currency.wrap(token0IsLiquid ? pairedToken : liquid),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(this))
        });

        // Set the storage helpers
        liquidIsToken0[_poolKey.toId()] = token0IsLiquid;

        // initialize the pool
        int24 startingTick = token0IsLiquid ? tickIfToken0IsLiquid : -tickIfToken0IsLiquid;
        uint160 initialPrice = startingTick.getSqrtPriceAtTick();
        poolManager.initialize(_poolKey, initialPrice);

        // set the pool creation timestamp
        poolCreationTimestamp[_poolKey.toId()] = block.timestamp;

        // decode the pool data into user extension data and pool data
        PoolInitializationData memory poolInitializationData =
            abi.decode(poolData, (PoolInitializationData));

        // initialize fee data
        _initializeFeeData(_poolKey, poolInitializationData.feeData);

        // initialize pool extension data
        _initializePoolExtensionData(
            _poolKey, poolInitializationData.extension, poolInitializationData.extensionData
        );

        return _poolKey;
    }

    // enable the mev module once the pool's deployment is complete
    //
    // note: this is done separate from the initializePool to allow for
    // extensions to take pool actions
    function initializeMevModule(PoolKey calldata poolKey, bytes calldata mevModuleData)
        external
        onlyFactory
    {
        // initialize the mev module
        ILiquidMevModule(mevModule[poolKey.toId()]).initialize(poolKey, mevModuleData);

        // give pool extension, if it exists, chance to check other configured settings
        if (poolExtension[poolKey.toId()] != address(0)) {
            ILiquidHookV2PoolExtension(poolExtension[poolKey.toId()]).initializePostLockerSetup(
                poolKey, locker[poolKey.toId()], liquidIsToken0[poolKey.toId()]
            );
            // set the pool extension setup to true
            poolExtensionSetup[poolKey.toId()] = true;
        }

        // enable the mev module
        mevModuleEnabled[poolKey.toId()] = true;
    }

    // checks if a mev module is operational and turns it off if needed
    function mevModuleOperational(PoolId poolId) public returns (bool) {
        if (!mevModuleEnabled[poolId]) {
            return false;
        } else if (block.timestamp >= poolCreationTimestamp[poolId] + MAX_MEV_MODULE_DELAY) {
            // mev module has expired
            mevModuleEnabled[poolId] = false;
            emit MevModuleDisabled(poolId);
            return false;
        }

        // mev module is operational
        return true;
    }

    // function to allow the mev module to change the fee for a swap
    function mevModuleSetFee(PoolKey calldata poolKey, uint24 fee) external {
        // only the assigned mev module for a poolkey can update the fee
        if (mevModule[poolKey.toId()] != msg.sender) {
            revert Unauthorized();
        }

        // skip if the mev module is not operational
        if (!mevModuleOperational(poolKey.toId())) {
            return;
        }

        // skip if the mev module is trying to set the fee higher than the max MEV fee
        if (fee > MAX_MEV_LP_FEE) {
            return;
        }

        // check to see if the fee is higher than the currently set LP fee,
        // we only want to update if it is higher than the pool's normal fee behavior
        (,,, uint24 currentLpFee) = StateLibrary.getSlot0(poolManager, poolKey.toId());
        if (fee <= currentLpFee) {
            return;
        }

        // update the fee for the swap
        IPoolManager(poolManager).updateDynamicLPFee(poolKey, fee);
        _setProtocolFee(fee);

        emit MevModuleSetFee(poolKey.toId(), fee);
    }

    function _runMevModule(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata swapData
    ) internal {
        if (mevModuleOperational(poolKey.toId())) {
            // decode the swap data for the pool extension
            PoolSwapData memory poolSwapData;
            if (swapData.length > 0) {
                poolSwapData = abi.decode(swapData, (PoolSwapData));
            } else {
                poolSwapData = PoolSwapData({
                    mevModuleSwapData: new bytes(0),
                    poolExtensionSwapData: new bytes(0)
                });
            }

            // if the mev module is enabled  call it
            bool disableMevModule = ILiquidMevModule(mevModule[poolKey.toId()]).beforeSwap(
                poolKey, swapParams, liquidIsToken0[poolKey.toId()], poolSwapData.mevModuleSwapData
            );

            // disable the mevModule if the module requests it
            if (disableMevModule) {
                mevModuleEnabled[poolKey.toId()] = false;
                emit MevModuleDisabled(poolKey.toId());
            }
        }
    }

    function _runPoolExtension(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        address sender,
        BalanceDelta delta,
        bytes calldata swapData
    ) internal {
        // only run the pool extension if it exists, is setup, and the sender is not the locker.
        // we don't want to run it when the locker is swapping because it will run the
        // extension code before the user's swap is complete
        if (
            poolExtension[poolKey.toId()] != address(0) && poolExtensionSetup[poolKey.toId()]
                && sender != locker[poolKey.toId()]
        ) {
            // decode the swap data for the pool extension
            PoolSwapData memory poolSwapData;
            if (swapData.length > 0) {
                poolSwapData = abi.decode(swapData, (PoolSwapData));
            } else {
                poolSwapData = PoolSwapData({
                    mevModuleSwapData: new bytes(0),
                    poolExtensionSwapData: new bytes(0)
                });
            }

            try this._runPoolExtensionHelper(
                poolKey, swapParams, delta, poolSwapData.poolExtensionSwapData
            ) {
                emit PoolExtensionSuccess(poolKey.toId());
            } catch {
                emit PoolExtensionFailed(poolKey.toId(), swapParams);
            }
        }
    }

    function _runPoolExtensionHelper(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata swapData
    ) external {
        if (msg.sender != address(this)) {
            revert OnlyThis();
        }

        ILiquidHookV2PoolExtension(poolExtension[poolKey.toId()]).afterSwap(
            poolKey, swapParams, delta, liquidIsToken0[poolKey.toId()], swapData
        );
    }

    function _lpLockerFeeClaim(PoolKey calldata poolKey) internal {
        // if this wasn't initialized to claim fees, skip the claim
        if (locker[poolKey.toId()] == address(0)) {
            return;
        }

        // determine the token
        address token = liquidIsToken0[poolKey.toId()]
            ? Currency.unwrap(poolKey.currency0)
            : Currency.unwrap(poolKey.currency1);

        // trigger the fee claim
        ILiquidLpLocker(locker[poolKey.toId()]).collectRewardsWithoutUnlock(token);
    }

    function _hookFeeClaim(PoolKey calldata poolKey) internal {
        // determine the fee token
        Currency feeCurrency =
            liquidIsToken0[poolKey.toId()] ? poolKey.currency1 : poolKey.currency0;

        // get the fees stored from the previous swap in the pool manager
        uint256 fee = poolManager.balanceOf(address(this), feeCurrency.toId());

        if (fee == 0) {
            return;
        }

        // burn the fee
        poolManager.burn(address(this), feeCurrency.toId(), fee);

        // take the fee
        poolManager.take(feeCurrency, factory, fee);

        emit ClaimProtocolFees(Currency.unwrap(feeCurrency), fee);
    }

    function _beforeSwap(
        address,
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata swapData
    ) internal virtual override returns (bytes4, BeforeSwapDelta delta, uint24) {
        // set the fee for this swap
        _setFee(poolKey, swapParams);

        // trigger hook fee claim
        _hookFeeClaim(poolKey);

        // trigger the LP locker fee claim
        _lpLockerFeeClaim(poolKey);

        // run the mev module, can update the fee for the swap
        _runMevModule(poolKey, swapParams, swapData);

        // variables to determine how to collect protocol fee
        bool token0IsLiquid = liquidIsToken0[poolKey.toId()];
        bool swappingForLiquid = swapParams.zeroForOne != token0IsLiquid;
        bool isExactInput = swapParams.amountSpecified < 0;

        // case: specified amount paired in, unspecified amount liquid out
        // want to: keep amountIn the same, take fee on amountIn
        // how: we modulate the specified amount being swapped DOWN, and
        // transfer the difference into the hook's account before making the swap
        if (isExactInput && swappingForLiquid) {
            // since we're taking the protocol fee before the LP swap, we want to
            // take a slightly smaller amount to keep the taken LP/protocol fee at the 20% ratio,
            // this also helps us match the ExactOutput swappingForLiquid scenario
            uint128 scaledProtocolFee = uint128(protocolFee) * 1e18 / (1_000_000 + protocolFee);
            int128 fee = int128(swapParams.amountSpecified * -int128(scaledProtocolFee) / 1e18);

            delta = toBeforeSwapDelta(fee, 0);
            poolManager.mint(
                address(this),
                token0IsLiquid ? poolKey.currency1.toId() : poolKey.currency0.toId(),
                uint256(int256(fee))
            );
        }

        // case: specified amount paired out, unspecified amount liquid in
        // want to: increase amountOut by fee and take it
        // how: we modulate the specified amount out UP, and transfer it
        // into the hook's account
        if (!isExactInput && !swappingForLiquid) {
            // we increase the protocol fee here because we want to better match
            // the ExactOutput !swappingForLiquid scenario
            uint128 scaledProtocolFee = uint128(protocolFee) * 1e18 / (1_000_000 - protocolFee);
            int128 fee = int128(swapParams.amountSpecified * int128(scaledProtocolFee) / 1e18);
            delta = toBeforeSwapDelta(fee, 0);

            poolManager.mint(
                address(this),
                token0IsLiquid ? poolKey.currency1.toId() : poolKey.currency0.toId(),
                uint256(int256(fee))
            );
        }

        return (BaseHook.beforeSwap.selector, delta, 0);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata swapData
    ) internal override returns (bytes4, int128 unspecifiedDelta) {
        // variables to determine how to collect protocol fee
        bool token0IsLiquid = liquidIsToken0[poolKey.toId()];
        bool swappingForLiquid = swapParams.zeroForOne != token0IsLiquid;
        bool isExactInput = swapParams.amountSpecified < 0;

        // case: specified amount liquid in, unspecified amount paired out
        // want to: take fee on amount out
        // how: the change in unspecified delta is debited to the swaps account post swap,
        // in this case the amount out given to the swapper is decreased
        if (isExactInput && !swappingForLiquid) {
            // grab non-liquid amount out
            int128 amountOut = token0IsLiquid ? delta.amount1() : delta.amount0();
            // take fee from it
            unspecifiedDelta = amountOut * int24(protocolFee) / FEE_DENOMINATOR;
            poolManager.mint(
                address(this),
                token0IsLiquid ? poolKey.currency1.toId() : poolKey.currency0.toId(),
                uint256(int256(unspecifiedDelta))
            );

            // subtract the protocol fee from the positive delta to account for the protocol fee
            // (positive for the swapper means amount owed to the swapper)
            if (delta.amount0() > 0) {
                delta = sub(delta, toBalanceDelta(unspecifiedDelta, 0));
            } else {
                delta = sub(delta, toBalanceDelta(0, unspecifiedDelta));
            }
        }

        // case: specified amount liquid out, unspecified amount paired in
        // want to: take fee on amount in
        // how: the change in unspecified delta is debited to the swapper's account post swap,
        // in this case the amount taken from the swapper's account is increased
        if (!isExactInput && swappingForLiquid) {
            // grab non-liquid amount in
            int128 amountIn = token0IsLiquid ? delta.amount1() : delta.amount0();
            // take fee from amount int
            unspecifiedDelta = amountIn * -int24(protocolFee) / FEE_DENOMINATOR;
            poolManager.mint(
                address(this),
                token0IsLiquid ? poolKey.currency1.toId() : poolKey.currency0.toId(),
                uint256(int256(unspecifiedDelta))
            );

            // subtract the protocol fee from the negative delta to account for the protocol fee
            // (negative for the swapper means amount owed to the pool)
            if (delta.amount0() < 0) {
                delta = sub(delta, toBalanceDelta(unspecifiedDelta, 0));
            } else {
                delta = sub(delta, toBalanceDelta(0, unspecifiedDelta));
            }
        }

        // modify deltas to account for when the protocol fee is taken in beforeSwap,
        // the amount being returned to the user is the amount specified in the swap params
        // and not what is returned in the swap deltas (which contains the protocol fee)
        if (isExactInput && swappingForLiquid || !isExactInput && !swappingForLiquid) {
            if (liquidIsToken0[poolKey.toId()]) {
                delta = toBalanceDelta(delta.amount0(), int128(swapParams.amountSpecified));
            } else {
                delta = toBalanceDelta(int128(swapParams.amountSpecified), delta.amount1());
            }
        }

        // run the pool extension
        _runPoolExtension(poolKey, swapParams, sender, delta, swapData);

        return (BaseHook.afterSwap.selector, unspecifiedDelta);
    }

    // prevent initializations that don't start via our initializePool functions
    function _beforeInitialize(address, PoolKey calldata, uint160)
        internal
        virtual
        override
        returns (bytes4)
    {
        revert UnsupportedInitializePath();
    }

    // prevent liquidity adds during mev module operation
    function _beforeAddLiquidity(
        address,
        PoolKey calldata poolKey,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal virtual override returns (bytes4) {
        if (mevModuleOperational(poolKey.toId())) {
            revert MevModuleEnabled();
        }

        return BaseHook.beforeAddLiquidity.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ILiquidHook).interfaceId
            || interfaceId == type(ILiquidHookV2).interfaceId;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
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
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
