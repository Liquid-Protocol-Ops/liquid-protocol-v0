// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Script, console} from "forge-std/Script.sol";

/// @notice Standalone SWAP_EXACT_IN_SINGLE through Robinhood Chain's forked Universal
///         Router, which uses a NON-STANDARD 6-field ExactInputSingleParams struct
///         (extra `minHopPriceX36` before `hookData`). Canonical v4-periphery has 5 fields.
///         Encoding the 6-field layout with minHopPriceX36=0 is exactly the fix the
///         redeployed LiquidLpLockerFeeConversion needs on 4663. This script validates it live.
///
/// Env: DEPLOYER_PRIVATE_KEY, UNIVERSAL_ROUTER, PERMIT2, TOKEN_IN, TOKEN_OUT, HOOK,
///      AMOUNT_IN (wei), optional FEE (default 0x800000 dynamic), TICK_SPACING (default 60)
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        payable;
}

contract RhSwapExactIn is Script {
    // Robinhood's forked IV4Router struct: extra `minHopPriceX36` vs canonical v4-periphery.
    struct RhExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36; // <-- Robinhood addition; 0 disables the per-hop price check
        bytes hookData;
    }

    // Command / action IDs (unchanged from standard UR on this chain)
    uint8 constant V4_SWAP = 0x10;
    uint8 constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 constant SETTLE_ALL = 0x0c;
    uint8 constant TAKE_ALL = 0x0f;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address ur = vm.envAddress("UNIVERSAL_ROUTER");
        address permit2 = vm.envAddress("PERMIT2");
        address tokenIn = vm.envAddress("TOKEN_IN");
        address tokenOut = vm.envAddress("TOKEN_OUT");
        address hook = vm.envAddress("HOOK");
        uint128 amountIn = uint128(vm.envUint("AMOUNT_IN"));
        uint24 fee = uint24(vm.envOr("FEE", uint256(0x800000)));
        int24 tickSpacing = int24(uint24(vm.envOr("TICK_SPACING", uint256(60))));

        (address c0, address c1) = tokenIn < tokenOut ? (tokenIn, tokenOut) : (tokenOut, tokenIn);
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hook)
        });

        bytes memory commands = abi.encodePacked(V4_SWAP);
        bytes memory actions = abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            RhExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: tokenIn < tokenOut,
                amountIn: amountIn,
                amountOutMinimum: 0,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(tokenIn, uint256(amountIn)); // SETTLE_ALL
        params[2] = abi.encode(tokenOut, uint256(0)); // TAKE_ALL (min 0)
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        address me = vm.addr(pk);
        uint256 outBefore = IERC20(tokenOut).balanceOf(me);

        vm.startBroadcast(pk);
        SafeERC20.forceApprove(IERC20(tokenIn), permit2, amountIn);
        IPermit2(permit2).approve(tokenIn, ur, amountIn, uint48(block.timestamp + 3600));
        IUniversalRouter(ur).execute(commands, inputs, block.timestamp + 3600);
        vm.stopBroadcast();

        uint256 outAfter = IERC20(tokenOut).balanceOf(me);
        console.log("tokenIn  spent:", amountIn);
        console.log("tokenOut recv :", outAfter - outBefore);
    }
}
