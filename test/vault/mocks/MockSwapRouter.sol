// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @dev Mock Uniswap V3 SwapRouter02 for adapter unit tests.
///      exactInput pulls USDC from caller and mints DIEM to recipient at a 1e12
///      multiplier (1 USDC-6dec = 1 DIEM-18dec). Path bytes are ignored.
///      Enforces amountOutMinimum with the real V3 router's "Too little received"
///      revert string so slippage-floor tests exercise production behavior.
///      ExactInputParams ABI matches BaseInferenceAdapter's ISwapRouterV3Hop so
///      the selector resolves correctly.
contract MockSwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    address public immutable usdc;
    address public immutable diem;

    constructor(address _usdc, address _diem) {
        usdc = _usdc;
        diem = _diem;
    }

    function exactInput(ExactInputParams calldata params) external returns (uint256 amountOut) {
        IERC20(usdc).transferFrom(msg.sender, address(this), params.amountIn);
        amountOut = params.amountIn * 1e12; // 1 USDC (1e6) → 1 DIEM (1e18)
        require(amountOut >= params.amountOutMinimum, "Too little received");
        IMintable(diem).mint(params.recipient, amountOut);
    }
}
