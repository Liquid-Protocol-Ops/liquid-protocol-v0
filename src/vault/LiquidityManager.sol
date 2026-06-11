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

    enum Action {
        ADD,
        REMOVE,
        COLLECT_FEES
    }

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
        IPoolManagerLM(poolManager)
            .unlock(abi.encode(CallbackData({action: action, liquidity: liquidity})));
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
        (int256 callerDelta,) = IPoolManagerLM(poolManager)
            .modifyLiquidity(
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
