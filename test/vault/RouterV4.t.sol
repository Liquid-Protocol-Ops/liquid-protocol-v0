// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {InferenceVault} from "../../src/vault/InferenceVault.sol";
import {Router} from "../../src/vault/Router.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Test} from "forge-std/Test.sol";

// Minimal LP helper — adds full-range liquidity to the V4 pool inside an unlock callback.
contract V4LiquidityHelper {
    IPoolManager immutable pm;

    constructor(address _pm) {
        pm = IPoolManager(_pm);
    }

    function addLiquidity(
        PoolKey calldata key,
        int256 liquidityDelta,
        address weth,
        address wstDiem,
        uint256 wethAmount,
        uint256 wstDiemAmount
    ) external {
        // Transfer tokens here first so the callback can settle
        IERC20(weth).transferFrom(msg.sender, address(this), wethAmount);
        IERC20(wstDiem).transferFrom(msg.sender, address(this), wstDiemAmount);

        pm.unlock(abi.encode(key, liquidityDelta, weth, wstDiem, wethAmount, wstDiemAmount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (
            PoolKey memory key,
            int256 liquidityDelta,
            address weth,
            address wstDiem,
            uint256 wethAmount,
            uint256 wstDiemAmount
        ) = abi.decode(data, (PoolKey, int256, address, address, uint256, uint256));

        // Full-range position (tickSpacing=60)
        (BalanceDelta delta,) = pm.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887_220,
                tickUpper: 887_220,
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );

        // Settle currency0 (WETH) if we owe it
        if (delta.amount0() < 0) {
            uint256 owed = uint256(-int256(delta.amount0()));
            pm.sync(Currency.wrap(weth));
            IERC20(weth).transfer(address(pm), owed);
            pm.settle();
        }
        // Settle currency1 (wstDIEM) if we owe it
        if (delta.amount1() < 0) {
            uint256 owed = uint256(-int256(delta.amount1()));
            pm.sync(Currency.wrap(wstDiem));
            IERC20(wstDiem).transfer(address(pm), owed);
            pm.settle();
        }

        return "";
    }
}

contract RouterV4Test is Test {
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;
    address constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;
    address constant VVV_STAKING = 0x321b7ff75154472B18EDb199033fF4D116F340Ff;
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

    // Deployed active contracts
    address constant VAULT_ADDR = 0xa6076Ac24f21A9c526d6d32774d66cBB804Cf649;
    bytes32 constant V4_POOL_ID =
        0x43da55144439c36976064cdf90cc24402a07b7be6d37987b7673f1f481bd1f15;

    Router router;
    InferenceVault vault;
    V4LiquidityHelper lpHelper;

    address alice = makeAddr("alice");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));

        vault = InferenceVault(VAULT_ADDR);

        // Deploy fresh Router v6 pointing at the live vault
        router = new Router(VAULT_ADDR, WETH, VVV, VVV_STAKING, address(0), address(this));
        router.setV4Pool(POOL_MANAGER);
        // v4PoolId removed from Router — PoolKey is reconstructed from immutables in unlockCallback

        lpHelper = new V4LiquidityHelper(POOL_MANAGER);

        // Fund alice
        deal(WETH, alice, 10e18);
        deal(DIEM, alice, 1000e18);
        deal(VVV, alice, 100e18);

        vm.startPrank(alice);
        IERC20(WETH).approve(address(router), type(uint256).max);
        IERC20(VVV).approve(address(router), type(uint256).max);
        IERC20(DIEM).approve(VAULT_ADDR, type(uint256).max);
        vm.stopPrank();
    }

    // Seed V4 pool with liquidity, returns the wstDIEM used
    function _seedV4Liquidity() internal returns (uint256 wstDiemSeeded) {
        // Alice deposits DIEM to get wstDIEM for LP
        vm.prank(alice);
        uint256 wstDiemShares = vault.deposit(100e18, alice);

        // Approve LP helper for both tokens
        vm.startPrank(alice);
        IERC20(WETH).approve(address(lpHelper), 5e18);
        IERC20(VAULT_ADDR).approve(address(lpHelper), wstDiemShares);
        vm.stopPrank();

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(VAULT_ADDR),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.prank(alice);
        lpHelper.addLiquidity(key, 1e18, WETH, VAULT_ADDR, 5e18, wstDiemShares);

        return wstDiemShares;
    }

    // ── depositWETH ───────────────────────────────────────────────────────

    function test_depositWETH_mintsWstDIEM() public {
        vm.prank(alice);
        uint256 shares = router.depositWETH(1e18, 0, alice);
        assertGt(shares, 0, "depositWETH must mint wstDIEM");
    }

    function test_depositWETH_stakesInVenice() public {
        uint256 totalBefore = vault.totalAssets();

        vm.prank(alice);
        router.depositWETH(1e18, 0, alice);

        // All DIEM acquired via V3 swap must be staked — vault holds none idle
        assertEq(IERC20(DIEM).balanceOf(VAULT_ADDR), 0, "vault must hold no idle DIEM");
        assertGt(vault.totalAssets(), totalBefore, "totalAssets must increase");
    }

    function test_depositWETH_slippage() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("SlippageExceeded()"));
        router.depositWETH(1e18, type(uint256).max, alice);
    }

    // ── depositVVV ────────────────────────────────────────────────────────

    function test_depositVVV_mintsWstDIEM() public {
        vm.prank(alice);
        uint256 shares = router.depositVVV(10e18, 0, alice);
        assertGt(shares, 0);
    }

    // ── exitToWETH (requires V4 liquidity) ───────────────────────────────

    function test_exitToWETH_withLiquidity() public {
        _seedV4Liquidity();

        // Alice deposits more DIEM to get wstDIEM for exit test
        vm.prank(alice);
        uint256 wstDiemIn = vault.deposit(10e18, alice);

        uint256 wethBefore = IERC20(WETH).balanceOf(alice);

        vm.startPrank(alice);
        IERC20(VAULT_ADDR).approve(address(router), wstDiemIn);
        uint256 wethOut = router.exitToWETH(wstDiemIn, 0, alice);
        vm.stopPrank();

        assertGt(wethOut, 0, "exitToWETH must return WETH");
        assertGt(IERC20(WETH).balanceOf(alice), wethBefore, "alice WETH balance must increase");
    }

    function test_exitToWETH_revertWithoutPool() public {
        // Fresh router with no v4Pool set
        Router freshRouter =
            new Router(VAULT_ADDR, WETH, VVV, VVV_STAKING, address(0), address(this));

        vm.prank(alice);
        vault.deposit(10e18, alice);
        uint256 shares = vault.balanceOf(alice);

        vm.startPrank(alice);
        IERC20(VAULT_ADDR).approve(address(freshRouter), shares);
        vm.expectRevert(abi.encodeWithSignature("PoolNotSet()"));
        freshRouter.exitToWETH(shares, 0, alice);
        vm.stopPrank();
    }

    // ── Full cycle: WETH → wstDIEM → WETH ────────────────────────────────

    function test_fullCycle_depositAndExit() public {
        _seedV4Liquidity();

        uint256 wethStart = IERC20(WETH).balanceOf(alice);

        // Deposit 1 WETH → wstDIEM
        vm.prank(alice);
        uint256 shares = router.depositWETH(1e18, 0, alice);

        // Exit wstDIEM → WETH
        vm.startPrank(alice);
        IERC20(VAULT_ADDR).approve(address(router), shares);
        uint256 wethOut = router.exitToWETH(shares, 0, alice);
        vm.stopPrank();

        uint256 wethEnd = IERC20(WETH).balanceOf(alice);

        assertGt(wethOut, 0, "must receive WETH on exit");
        // Round-trip: wethEnd should be close to wethStart - fees
        // (1 WETH in, minus V3 fee + V4 fee + deposit fee + slippage)
        assertGt(wethEnd, wethStart - 1e18, "round-trip loss must be within 100%");
    }
}
