// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseInferenceAdapter} from "./BaseInferenceAdapter.sol";

/// @title  GondolaAdapter
/// @notice Venue adapter for Gondola (gondola-ai.com), a marketplace for Venice
///         inference from staked DIEM. Sellers list a Venice inference key and
///         are paid USDC per request. Gondola pays out by plain USDC transfer to
///         the seller's payout address, so this adapter is set as that address:
///         no receiveSettlement() call is involved, and routeYield(minDiemOut)
///         swaps whatever USDC has arrived.
contract GondolaAdapter is BaseInferenceAdapter {
    constructor(address _vault, address _usdc, address _swapRouter, address initialOwner)
        BaseInferenceAdapter(_vault, _usdc, _swapRouter, initialOwner)
    {}

    function inferenceName() external pure override returns (string memory) {
        return "Gondola";
    }
}
