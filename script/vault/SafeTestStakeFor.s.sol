// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

// Live test of the stakeFor architecture:
//   Safe swaps 1 WETH -> DIEM via V3
//   Safe calls DIEM.stakeFor(keeperEOA, diemReceived)
//   Verifies stakedInfos[keeper] increased
//
// If this succeeds, the new InferenceVault design is proven:
//   vault deposits can go directly to keeper's Venice budget.

interface ISafe {
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 nonce
    ) external view returns (bytes32);
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool);
    function nonce() external view returns (uint256);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface ISwapRouterV3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata) external returns (uint256);
}

interface IDIEM is IERC20 {
    function stakeFor(address to, uint256 amount) external;
    function stakedInfos(address) external view returns (uint256, uint256, uint256);
}

contract SafeTestStakeFor is Script {
    address constant SAFE = 0x872c561f699B42977c093F0eD8b4C9a431280c6c;
    address constant KEEPER = 0x32fDdfB0eeC6c638d5C8b7cabF3bE9065478e90E;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;
    address constant V3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant ZERO = address(0);
    uint256 constant WETH_IN = 1e18; // 1 WETH

    address constant SK2_ADDR = 0x6FDDe67e9c545AcdcE17944bf8f9988E1f88aa9E;
    address constant SK1_ADDR = 0x8f60eB404a5CA868f37bc798ec4c54FA0dcCFC9F;

    uint256 sk1;
    uint256 sk2;

    function setUp() public {
        sk1 = uint256(vm.envBytes32("SAFE_SK1"));
        sk2 = uint256(vm.envBytes32("SAFE_SK2"));
        require(vm.addr(sk1) == SK1_ADDR, "SK1 mismatch");
        require(vm.addr(sk2) == SK2_ADDR, "SK2 mismatch");
    }

    function run() external {
        vm.startBroadcast(vm.envUint("EXECUTOR_PK"));

        // State before
        (uint256 keeperStakedBefore,,) = IDIEM(DIEM).stakedInfos(KEEPER);
        console.log("Keeper sDIEM before:", keeperStakedBefore);
        console.log("Safe WETH balance:", IERC20(WETH).balanceOf(SAFE));

        // Tx 1: WETH.approve(V3Router, 1 WETH)
        _execSafe(WETH, abi.encodeWithSignature("approve(address,uint256)", V3_ROUTER, WETH_IN));
        console.log("Tx1: WETH approved to V3 Router");

        // Tx 2: Swap 1 WETH -> DIEM, Safe receives DIEM
        bytes memory swapData = abi.encodeWithSelector(
            ISwapRouterV3.exactInputSingle.selector,
            ISwapRouterV3.ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: DIEM,
                fee: 10_000,
                recipient: SAFE,
                amountIn: WETH_IN,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        _execSafe(V3_ROUTER, swapData);
        uint256 diemReceived = IERC20(DIEM).balanceOf(SAFE);
        console.log("Tx2: Swapped 1 WETH -> DIEM. Safe DIEM balance:", diemReceived);

        // Tx 3: DIEM.stakeFor(keeper, diemReceived)
        // This is the key test: does the DIEM contract support staking
        // FROM the Safe's liquid DIEM INTO the keeper's Venice account?
        _execSafe(DIEM, abi.encodeWithSignature("stakeFor(address,uint256)", KEEPER, diemReceived));
        console.log("Tx3: stakeFor(keeper, diemReceived) executed");

        // Verify: keeper should now have sDIEM
        (uint256 keeperStakedAfter,,) = IDIEM(DIEM).stakedInfos(KEEPER);
        console.log("Keeper sDIEM after:", keeperStakedAfter);
        console.log("Delta:", keeperStakedAfter - keeperStakedBefore);

        if (keeperStakedAfter > keeperStakedBefore) {
            console.log("SUCCESS: stakeFor works! vault.sDIEM = inference budget is achievable.");
        } else {
            console.log("FAIL: stakeFor did not increase keeper stakedInfos.");
        }

        vm.stopBroadcast();
    }

    function _execSafe(address to, bytes memory data) internal {
        uint256 nonce = ISafe(SAFE).nonce();
        bytes32 h = ISafe(SAFE).getTransactionHash(to, 0, data, 0, 0, 0, 0, ZERO, ZERO, nonce);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(sk2, h);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(sk1, h);
        bool ok = ISafe(SAFE)
            .execTransaction(
                to,
                0,
                data,
                0,
                0,
                0,
                0,
                ZERO,
                payable(ZERO),
                abi.encodePacked(r2, s2, v2, r1, s1, v1)
            );
        require(ok, "SafeTx failed");
    }
}
