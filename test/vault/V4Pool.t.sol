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
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
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
        vault =
            new InferenceVault(DIEM, makeAddr("treasury"), makeAddr("veniceSigner"), address(this));

        address hookAddr = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG));
        deployCodeTo(
            "WstDIEMHook.sol:WstDIEMHook", abi.encode(IPoolManager(POOL_MANAGER), vault), hookAddr
        );
        hook = WstDIEMHook(hookAddr);
        (c0, c1) = WETH < address(vault) ? (WETH, address(vault)) : (address(vault), WETH);

        // Init the hooked pool at tick 0 (1:1) for deterministic test math.
        IPoolManager(POOL_MANAGER).initialize(_key(), TickMath.getSqrtPriceAtTick(0));

        router = new Router(address(vault), WETH, VVV, VVV_STAKING, address(0), address(this));
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
        // Only the liquidity delta is needed here; the token amounts are pre-funded by _seed.
        (,, int256 liq) = abi.decode(data, (uint256, uint256, int256));
        (BalanceDelta delta,) = IPoolManager(POOL_MANAGER)
            .modifyLiquidity(
                _key(),
                IPoolManager.ModifyLiquidityParams({
                    tickLower: -887_220, tickUpper: 887_220, liquidityDelta: liq, salt: bytes32(0)
                }),
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
