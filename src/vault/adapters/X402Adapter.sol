// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseInferenceAdapter} from "./BaseInferenceAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title  X402Adapter
/// @notice Venue adapter for X402 (x402.org) — the HTTP 402 micropayment standard
///         for AI inference. Buyers pay USDC per inference call on-chain.
///
/// Two settlement paths:
///   1. recordX402Settlement(amount) — permissionless; any X402 payer pushes USDC
///      directly. Caller must have approved this contract for usdcAmount.
///   2. receiveSettlement(amount)    — restricted to authorizedSettler (inherited);
///      used by the X402 settlement contract or keeper.
///
/// Both accumulate USDC here. routeYield() (onlyOperator) swaps and credits vault.
contract X402Adapter is BaseInferenceAdapter {
    using SafeERC20 for IERC20;

    constructor(address _vault, address _usdc, address _swapRouter, address initialOwner)
        BaseInferenceAdapter(_vault, _usdc, _swapRouter, initialOwner)
    {}

    function inferenceName() external pure override returns (string memory) {
        return "X402";
    }

    /// @notice Permissionless settlement — any X402 payer may push USDC directly.
    ///         Caller must have pre-approved this contract for usdcAmount.
    function recordX402Settlement(uint256 usdcAmount) external {
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcAmount);
        emit SettlementReceived(usdcAmount);
    }
}
