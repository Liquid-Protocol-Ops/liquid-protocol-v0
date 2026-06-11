// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IInferenceVault} from "./interfaces/IInferenceVault.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

/// @title WstDIEMHook
/// @notice Uniswap V4 hook for the wstDIEM/WETH pool.
///         Applies a dynamic LP fee based on wstDIEM NAV deviation from pool price.
///         Full TWAP-oracle integration is deferred to WP-5; this ships the stub that
///         always returns FEE_NORMAL so the hook flags and permissions are correct.
///
/// @dev Pool MUST be initialised with LPFeeLibrary.DYNAMIC_FEE_FLAG as the fee tier.
///      The fee returned from _beforeSwap is OR'd with LPFeeLibrary.OVERRIDE_FEE_FLAG
///      so V4 actually applies it per-swap. What remains for WP-5 is the NAV/TWAP-based
///      fee selection in _currentFee() (currently a stub returning FEE_NORMAL).
///
///      Hook address lower bits must satisfy:
///          BEFORE_SWAP_FLAG      (bit 7)  = 0x0080
///          AFTER_INITIALIZE_FLAG (bit 12) = 0x1000
///      Combined mask: 0x1080 = 4224
contract WstDIEMHook is BaseHook {
    IInferenceVault public immutable vault;

    /// @notice Fee in pips (1e-6) applied under normal conditions (5 bps = 0.05 %)
    uint24 public constant FEE_NORMAL = 500;

    /// @notice Fee in pips applied when wstDIEM price deviates >2 % from NAV (100 bps = 1 %)
    uint24 public constant FEE_HIGH = 10_000;

    constructor(IPoolManager _poolManager, IInferenceVault _vault) BaseHook(_poolManager) {
        vault = _vault;
    }

    // -----------------------------------------------------------------------
    // Hook permissions
    // -----------------------------------------------------------------------

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -----------------------------------------------------------------------
    // Hook callbacks (internal virtuals — dispatched by BaseHook externals)
    // -----------------------------------------------------------------------

    /// @dev Records pool initialisation. Placeholder for NAV oracle seeding (WP-5).
    function _afterInitialize(address, PoolKey calldata, uint160, int24)
        internal
        pure
        override
        returns (bytes4)
    {
        return BaseHook.afterInitialize.selector;
    }

    /// @dev Computes the dynamic fee for every swap. The returned fee is OR'd with
    ///      LPFeeLibrary.OVERRIDE_FEE_FLAG so V4 applies it on the DYNAMIC_FEE_FLAG pool.
    ///      TODO WP-5: derive the fee *value* from NAV vs pool TWAP — compare
    ///      vault.convertToAssets(1e18) against pool TWAP and return FEE_HIGH when
    ///      deviation exceeds 200 bps, FEE_NORMAL otherwise.
    function _beforeSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) internal pure override returns (bytes4, BeforeSwapDelta, uint24) {
        uint24 fee = _currentFee() | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    /// @dev Stub oracle — returns FEE_NORMAL until WP-5 TWAP integration.
    function _currentFee() internal pure returns (uint24) {
        // WP-5 TODO: derive fee from vault NAV vs pool TWAP price
        return FEE_NORMAL;
    }
}
