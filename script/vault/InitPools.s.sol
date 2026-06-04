// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

interface IPoolManager {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }
    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external returns (int24 tick);
}

interface ICurvePool {
    function add_liquidity(uint256[] calldata amounts, uint256 min_mint_amount)
        external
        returns (uint256);
    function coins(uint256 i) external view returns (address);
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract InitPools is Script {
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;
    // v4 live deployment (2026-06-01)
    address constant WSTDIEM = 0x4751BA2b09374C1929FC01734a166e3c8cd75810;
    address constant CURVE_DIEM_WSTDIEM = 0x39A4b4779C71E1A18d500627639682c9583Ee86f;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);

        // V4 wstDIEM/WETH pool
        // wstDIEM (0x3394) < WETH (0x4200), so currency0=wstDIEM, currency1=WETH
        // sqrtPriceX96 = sqrt(WETH per wstDIEM) * 2^96, computed from current DIEM/WETH V3 rate
        IPoolManager.PoolKey memory key = IPoolManager.PoolKey({
            currency0: WSTDIEM, currency1: WETH, fee: 3000, tickSpacing: 60, hooks: address(0)
        });

        int24 tick =
            IPoolManager(POOL_MANAGER).initialize(key, 71_527_173_991_668_645_734_723_354_624);
        console.log("V4 wstDIEM/WETH pool initialized at tick:", uint256(int256(tick)));

        // Seed Curve DIEM/wstDIEM pool
        uint256 diemBal = IERC20(DIEM).balanceOf(deployer);
        uint256 wstDiemBal = IERC20(WSTDIEM).balanceOf(deployer);

        if (diemBal > 0 && wstDiemBal > 0) {
            IERC20(DIEM).approve(CURVE_DIEM_WSTDIEM, diemBal);
            IERC20(WSTDIEM).approve(CURVE_DIEM_WSTDIEM, wstDiemBal);
            uint256[] memory amounts = new uint256[](2);
            amounts[0] = diemBal;
            amounts[1] = wstDiemBal;
            uint256 lpMinted = ICurvePool(CURVE_DIEM_WSTDIEM).add_liquidity(amounts, 0);
            console.log("Curve seeded, LP minted:", lpMinted);
        }

        vm.stopBroadcast();
    }
}
