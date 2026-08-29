// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {PathKey} from "@uniswap/v4-periphery/src/libraries/PathKey.sol";
import {Script, console2} from "forge-std/Script.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        payable;
}

/// @notice The Robinhood Chain (4663) Universal Router is a customized fork:
///         its `ExactInputParams` carries an extra `minHopPriceX36` array
///         (per-hop min-price protection) that canonical v4-periphery lacks.
///         Encoding the canonical 5-field struct against it corrupts the
///         calldata offset and reverts empty (see DEPLOYMENTS-4663.md). This
///         local interface matches the fork; `minHopPriceX36` is passed as an
///         all-zero array (protection off; slippage is enforced by
///         `amountOutMinimum` from the live Quoter instead).
interface IV4RouterRH {
    struct ExactInputParams {
        Currency currencyIn;
        PathKey[] path;
        uint256[] minHopPriceX36;
        uint128 amountIn;
        uint128 amountOutMinimum;
    }
}

/// @title RobinhoodDevBuy
/// @notice Dev-buy for a Robinhood-template launch: native-ETH exact-in
///         multi-hop `ETH -> USDG -> SPY -> TOKEN` through the forked Universal
///         Router, output delivered to the sender. The final hop is the
///         template's SPY-paired dynamic-fee pool, so its PathKey carries the
///         dynamic-fee flag + hook. Slippage floored from the live v4 Quoter.
///
/// Quote-first: run WITHOUT `--broadcast` (and without a key) to prove the
/// route and print the expected TOKEN out — a zero quote means the route or a
/// hop's params are wrong, and nothing is signed. Set `EXECUTE=true` and pass
/// `PRIVATE_KEY` with `--broadcast` to actually buy.
///
/// This is also the backend the website "deploy a meme" console's optional
/// dev-buy will call.
///
/// Env:
///   TOKEN          launched token address (must sort below SPY => currency0)
///   ETH_IN         wei to spend
///   TOKEN_HOOK     dynamic-fee hook (default 0xdee7dcdc… — LiquidHookDynamicFeeV2)
///   TOKEN_TS       target pool tick spacing (default 60)
///   USDG_SPY_FEE   USDG/SPY pool fee (default 3000)
///   USDG_SPY_TS    USDG/SPY pool tick spacing (default 60)
///   ETH_USDG_FEE   default 500     ETH_USDG_TS default 10
///   SLIPPAGE_BPS   optional; default 500 (5%)
///   EXECUTE        "true" to broadcast; otherwise quote-only
///   PRIVATE_KEY    required only when EXECUTE=true
contract RobinhoodDevBuy is Script {
    address constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    IV4Quoter constant QUOTER = IV4Quoter(0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94);
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant DEFAULT_HOOK = 0xDee7DcDCf599306D3c29e8dd0E6F4C9c4b6F68Cc;

    bytes1 constant V4_SWAP = 0x10;
    uint8 constant SWAP_EXACT_IN = 0x07;
    uint8 constant SETTLE_ALL = 0x0c;
    uint8 constant TAKE_ALL = 0x0f;

    function run() external {
        address token = vm.envAddress("TOKEN");
        uint256 ethIn = vm.envUint("ETH_IN");
        address hook = vm.envOr("TOKEN_HOOK", DEFAULT_HOOK);
        int24 tokenTs = int24(int256(vm.envOr("TOKEN_TS", uint256(60))));
        uint24 usdgSpyFee = uint24(vm.envOr("USDG_SPY_FEE", uint256(3000)));
        int24 usdgSpyTs = int24(int256(vm.envOr("USDG_SPY_TS", uint256(60))));
        uint24 ethUsdgFee = uint24(vm.envOr("ETH_USDG_FEE", uint256(500)));
        int24 ethUsdgTs = int24(int256(vm.envOr("ETH_USDG_TS", uint256(10))));
        uint256 slippageBps = vm.envOr("SLIPPAGE_BPS", uint256(500));

        require(token < SPY, "TOKEN must be currency0 (< SPY)");
        require(ethIn > 0, "ETH_IN = 0");
        require(slippageBps <= 2000, "slippage > 20% - refuse");

        PathKey[] memory path = new PathKey[](3);
        path[0] = PathKey(Currency.wrap(USDG), ethUsdgFee, ethUsdgTs, IHooks(address(0)), "");
        path[1] = PathKey(Currency.wrap(SPY), usdgSpyFee, usdgSpyTs, IHooks(address(0)), "");
        // final hop into the template pool: dynamic fee + hook
        path[2] =
            PathKey(Currency.wrap(token), LPFeeLibrary.DYNAMIC_FEE_FLAG, tokenTs, IHooks(hook), "");

        (uint256 expectedOut,) = QUOTER.quoteExactInput(
            IV4Quoter.QuoteExactParams({
                exactCurrency: Currency.wrap(address(0)), path: path, exactAmount: uint128(ethIn)
            })
        );
        require(expectedOut > 0, "quote returned 0 - route/params wrong or pool dry");
        uint256 minOut = (expectedOut * (10_000 - slippageBps)) / 10_000;

        console2.log("route: ETH -> USDG -> SPY -> TOKEN");
        console2.log("ETH in (wei):", ethIn);
        console2.log("expected TOKEN out:", expectedOut);
        console2.log("min TOKEN out:", minOut);

        if (!vm.envOr("EXECUTE", false)) {
            console2.log("QUOTE ONLY - set EXECUTE=true with --broadcast to buy");
            return;
        }

        IV4RouterRH.ExactInputParams memory sp = IV4RouterRH.ExactInputParams({
            currencyIn: Currency.wrap(address(0)),
            path: path,
            minHopPriceX36: new uint256[](3),
            amountIn: uint128(ethIn),
            amountOutMinimum: uint128(minOut)
        });

        bytes memory actions = abi.encodePacked(SWAP_EXACT_IN, SETTLE_ALL, TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(sp);
        params[1] = abi.encode(Currency.wrap(address(0)), ethIn);
        params[2] = abi.encode(Currency.wrap(token), minOut);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        bytes memory commands = abi.encodePacked(V4_SWAP);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        console2.log("buyer:", vm.addr(pk));
        vm.startBroadcast(pk);
        IUniversalRouter(UNIVERSAL_ROUTER).execute{value: ethIn}(
            commands, inputs, block.timestamp + 300
        );
        vm.stopBroadcast();
        console2.log("dev-buy broadcast complete");
    }
}
