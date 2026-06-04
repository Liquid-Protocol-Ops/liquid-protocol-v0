// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {InferenceVault} from "../../src/vault/InferenceVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console} from "forge-std/Test.sol";

interface ICurveStableSwapNGFactory {
    function deploy_plain_pool(
        string calldata name,
        string calldata symbol,
        address[] calldata coins,
        uint256 A,
        uint256 fee,
        uint256 offpeg_fee_multiplier,
        uint256 ma_exp_time,
        uint256 implementation_idx,
        uint8[] calldata asset_types,
        bytes4[] calldata method_ids,
        address[] calldata oracles
    ) external returns (address);
}

interface ICurvePool {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function add_liquidity(uint256[] calldata amounts, uint256 min_mint_amount)
        external
        returns (uint256);
    function get_virtual_price() external view returns (uint256);
    function balances(uint256 i) external view returns (uint256);
}

contract CurvePoolTest is Test {
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;
    address constant CURVE_FACTORY = 0xd2002373543Ce3527023C75e7518C274A51ce712;

    InferenceVault vault;
    ICurvePool pool;
    address treasury = makeAddr("treasury");
    // alice acts as the EOA deployer — factory requires msg.sender == tx.origin
    address alice = makeAddr("alice");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        vault = new InferenceVault(DIEM, treasury, makeAddr("veniceSigner"), address(this));

        // Build pool deployment params.
        // asset_type 0 = standard ERC-20 (DIEM)
        // asset_type 3 = ERC4626 vault   (wstDIEM — Curve calls convertToAssets(1e18) natively)
        address[] memory coins = new address[](2);
        coins[0] = DIEM;
        coins[1] = address(vault);

        uint8[] memory assetTypes = new uint8[](2);
        assetTypes[0] = 0;
        assetTypes[1] = 3;

        // For asset_type 3 (ERC4626): method_ids and oracles are zero — Curve handles natively.
        bytes4[] memory methodIds = new bytes4[](2);
        address[] memory oracles = new address[](2);

        // The factory has an assert msg.sender == tx.origin guard (EOA-only).
        // vm.startPrank(addr, addr) sets both msg.sender AND tx.origin to addr.
        vm.startPrank(alice, alice);
        address poolAddr = ICurveStableSwapNGFactory(CURVE_FACTORY)
            .deploy_plain_pool(
                "DIEM/wstDIEM", // name   (String[32]: 12 chars)
                "wstDIEM-LP", // symbol (String[10]: 10 chars — Vyper hard limit)
                coins,
                300, // A = 300
                30_000_000, // fee = 30bps / 0.3% in 1e10 units
                8 * 10 ** 10, // off-peg fee multiplier = 8x
                600, // MA window = 600s (10 min)
                0, // implementation_idx = 0 (standard)
                assetTypes,
                methodIds,
                oracles
            );
        vm.stopPrank();

        pool = ICurvePool(poolAddr);
        console.log("Curve DIEM/wstDIEM pool deployed at:", poolAddr);

        deal(DIEM, alice, 100_000e18);
        vm.prank(alice);
        IERC20(DIEM).approve(address(pool), type(uint256).max);
        vm.prank(alice);
        IERC20(DIEM).approve(address(vault), type(uint256).max);
        vm.prank(alice);
        IERC20(address(vault)).approve(address(pool), type(uint256).max);
    }

    function test_curvePool_deploys() public view {
        assertGt(uint160(address(pool)), 0, "pool deployed");
    }

    function test_curvePool_addLiquidity() public {
        vm.startPrank(alice);
        uint256 shares = vault.deposit(10_000e18, alice);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10_000e18; // DIEM
        amounts[1] = shares; // wstDIEM

        uint256 lp = pool.add_liquidity(amounts, 0);
        assertGt(lp, 0, "LP tokens minted");
        vm.stopPrank();
    }

    function test_curvePool_swap_wstDIEM_to_DIEM() public {
        vm.startPrank(alice);
        uint256 shares = vault.deposit(20_000e18, alice);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10_000e18;
        amounts[1] = shares / 2;
        pool.add_liquidity(amounts, 0);

        uint256 diemOut = pool.exchange(1, 0, shares / 4, 0); // wstDIEM -> DIEM
        assertGt(diemOut, 0, "swap returned DIEM");
        vm.stopPrank();
    }
}
