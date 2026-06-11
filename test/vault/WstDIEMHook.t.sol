// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {InferenceVault} from "../../src/vault/InferenceVault.sol";
import {WstDIEMHook} from "../../src/vault/WstDIEMHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Test} from "forge-std/Test.sol";

contract WstDIEMHookTest is Test {
    // Base mainnet addresses
    address constant V4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;

    WstDIEMHook hook;
    InferenceVault vault;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));

        vault =
            new InferenceVault(DIEM, makeAddr("treasury"), makeAddr("veniceSigner"), address(this));

        // Derive the flagged hook address.
        // BEFORE_SWAP_FLAG = 1 << 7  = 0x0080
        // AFTER_INITIALIZE_FLAG = 1 << 12 = 0x1000
        // Combined mask = 0x1080 = 4224
        address hookAddr = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG));

        // Deploy the hook directly at the flagged address so BaseHook's
        // validateHookAddress() succeeds in the constructor.
        // vm.etch-after-deploy does not work because the constructor reverts
        // when deployed to a non-flagged address.
        deployCodeTo(
            "WstDIEMHook.sol:WstDIEMHook",
            abi.encode(IPoolManager(V4_POOL_MANAGER), vault),
            hookAddr
        );
        hook = WstDIEMHook(hookAddr);
    }

    // -----------------------------------------------------------------------
    // Permission tests
    // -----------------------------------------------------------------------

    function test_hookPermissions() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();
        assertTrue(perms.beforeSwap, "beforeSwap required");
        assertTrue(perms.afterInitialize, "afterInitialize required");
        assertFalse(perms.beforeInitialize, "beforeInitialize not needed");
        assertFalse(perms.afterSwap, "afterSwap not needed");
        assertFalse(perms.beforeSwapReturnDelta, "beforeSwapReturnDelta not set");
    }

    // -----------------------------------------------------------------------
    // Fee constant tests
    // -----------------------------------------------------------------------

    function test_normalFee() public view {
        // FEE_NORMAL = 500 pips = 0.05 %
        assertEq(hook.FEE_NORMAL(), 500, "FEE_NORMAL must be 500 pips (0.05 %)");
    }

    function test_highFee() public view {
        // FEE_HIGH = 10_000 pips = 1 %
        assertEq(hook.FEE_HIGH(), 10_000, "FEE_HIGH must be 10_000 pips (1 %)");
    }

    // -----------------------------------------------------------------------
    // Vault reference
    // -----------------------------------------------------------------------

    function test_vaultReference() public view {
        assertEq(address(hook.vault()), address(vault), "vault address mismatch");
    }

    // -----------------------------------------------------------------------
    // Override flag tests
    // -----------------------------------------------------------------------

    function test_beforeSwapReturnsOverrideFlag() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(vault)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        vm.prank(V4_POOL_MANAGER);
        (,, uint24 fee) = hook.beforeSwap(
            address(this),
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0
            }),
            ""
        );
        assertTrue(fee & LPFeeLibrary.OVERRIDE_FEE_FLAG != 0, "override flag must be set");
        assertEq(
            fee & ~LPFeeLibrary.OVERRIDE_FEE_FLAG, hook.FEE_NORMAL(), "underlying fee = FEE_NORMAL"
        );
    }
}
