// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {InferenceVault} from "../../src/vault/InferenceVault.sol";
import {LiquidityManager, PoolKeyLM} from "../../src/vault/LiquidityManager.sol";
import {WstDIEMHook} from "../../src/vault/WstDIEMHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
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
        vault =
            new InferenceVault(DIEM, makeAddr("treasury"), makeAddr("veniceSigner"), address(this));

        address hookAddr = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG));
        deployCodeTo(
            "WstDIEMHook.sol:WstDIEMHook", abi.encode(IPoolManager(POOL_MANAGER), vault), hookAddr
        );
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
            POOL_MANAGER,
            c0,
            c1,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60,
            -887_220,
            887_220,
            hookAddr,
            address(this)
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
