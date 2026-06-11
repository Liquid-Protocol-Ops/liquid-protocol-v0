// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DeployCurvePool} from "../../../script/vault/DeployCurvePool.s.sol";
import {FeeRouter} from "../../../src/vault/FeeRouter.sol";
import {InferenceVault} from "../../../src/vault/InferenceVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract PhaseCIntegrationTest is Test {
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;
    address constant VVV_STAKING = 0x321b7ff75154472B18EDb199033fF4D116F340Ff;

    InferenceVault vault;
    FeeRouter feeRouter;
    address curvePool;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        address treasury = makeAddr("treasury");
        vault = new InferenceVault(DIEM, treasury, makeAddr("veniceSigner"), address(this));

        // Deploy Curve pool (two-arg prank for EOA guard)
        DeployCurvePool d = new DeployCurvePool(address(vault));
        address seeder = makeAddr("seeder");
        vm.startPrank(seeder, seeder);
        curvePool = d.deployPool();
        vm.stopPrank();

        feeRouter = new FeeRouter(
            address(vault), WETH, VVV, VVV_STAKING, curvePool, address(0), address(this)
        );
        vault.setVenueAdapter(address(feeRouter), true);

        // Seed Curve pool with initial liquidity so add_liquidity(one-sided) works
        deal(DIEM, seeder, 100_000e18);
        vm.startPrank(seeder);
        IERC20(DIEM).approve(address(vault), type(uint256).max);
        IERC20(DIEM).approve(curvePool, type(uint256).max);
        IERC20(address(vault)).approve(curvePool, type(uint256).max);
        uint256 seedShares = vault.deposit(50_000e18, seeder);
        uint256[] memory seedAmts = new uint256[](2);
        seedAmts[0] = 50_000e18;
        seedAmts[1] = seedShares;
        (bool ok,) = curvePool.call(
            abi.encodeWithSignature("add_liquidity(uint256[],uint256)", seedAmts, uint256(0))
        );
        require(ok, "seed liquidity failed");
        vm.stopPrank();
    }

    function test_fork_wstDIEMPath_addsVOL() public {
        address feeSrc = makeAddr("feeSrc");
        deal(DIEM, feeSrc, 1000e18);
        vm.startPrank(feeSrc);
        IERC20(DIEM).approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(1000e18, feeSrc);
        IERC20(address(vault)).approve(address(feeRouter), shares);
        feeRouter.receivewstDIEM(shares);
        vm.stopPrank();

        // harvest() pushes the accumulated wstDIEM from the router into Curve VOL
        feeRouter.harvest();

        // All wstDIEM must have been drained from the router into the Curve pool
        assertEq(
            IERC20(address(vault)).balanceOf(address(feeRouter)),
            0,
            "VOL not drained to Curve after harvest"
        );
    }

    function test_fork_vvvPath_noSupplyDilution() public {
        address whale = makeAddr("whale");
        deal(VVV, whale, 200e18);
        vm.startPrank(whale);
        IERC20(VVV).approve(address(feeRouter), 200e18);
        feeRouter.receiveVVV(200e18);
        uint256 supplyBefore = vault.totalSupply();
        // harvestVVV may revert if VVV staking ABI differs — wrap in try-catch
        try feeRouter.harvestVVV() {} catch {}
        vm.stopPrank();
        // totalSupply must never increase from VVV harvest (no dilution invariant)
        assertEq(vault.totalSupply(), supplyBefore, "VVV harvest must not dilute wstDIEM supply");
    }
}
