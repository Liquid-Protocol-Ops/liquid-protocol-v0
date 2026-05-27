// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script, console} from "forge-std/Script.sol";

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
    function add_liquidity(uint256[] calldata amounts, uint256 min_mint_amount)
        external
        returns (uint256);
    function get_virtual_price() external view returns (uint256);
}

contract DeployCurvePool is Script {
    address constant CURVE_FACTORY = 0xd2002373543Ce3527023C75e7518C274A51ce712;
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;

    // wstDIEM address set after Phase A deploy
    address immutable WSTDIEM;

    constructor(address wstDIEM) {
        WSTDIEM = wstDIEM;
    }

    /// @notice Deploy the pool without broadcast.
    /// @dev The Curve NG factory has a msg.sender == tx.origin guard (EOA-only).
    ///      When called from forge script, vm.startBroadcast() satisfies this.
    ///      When called from tests, use vm.startPrank(alice, alice) before calling deployPool().
    function deployPool() public returns (address pool) {
        address[] memory coins = new address[](2);
        coins[0] = DIEM;
        coins[1] = WSTDIEM;

        uint8[] memory assetTypes = new uint8[](2);
        // asset_type 0 = standard ERC-20  (DIEM)
        // asset_type 3 = ERC4626 vault     (wstDIEM — Curve natively calls convertToAssets(1e18))
        assetTypes[0] = 0;
        assetTypes[1] = 3;

        // For asset_type 3 (ERC4626), method_ids and oracles must be zero — Curve handles natively.
        bytes4[] memory methodIds = new bytes4[](2);
        address[] memory oracles = new address[](2);

        pool = ICurveStableSwapNGFactory(CURVE_FACTORY)
            .deploy_plain_pool(
                "DIEM/wstDIEM", // name   (String[32]: 12 chars, within limit)
                "wstDIEM-LP", // symbol (String[10]: 10 chars — Vyper hard limit)
                coins,
                300, // A = 300 (high amplification; DIEM and wstDIEM near-peg)
                30_000_000, // fee = 30bps / 0.3% (30e6 / 1e10)
                8 * 10 ** 10, // off-peg fee multiplier = 8x
                600, // MA window = 600s (10 min)
                0, // implementation_idx = 0 (standard)
                assetTypes,
                methodIds,
                oracles
            );

        console.log("Curve DIEM/wstDIEM pool deployed at:", pool);
        return pool;
    }

    function run() external returns (address pool) {
        vm.startBroadcast();
        pool = deployPool();
        vm.stopBroadcast();
    }
}
