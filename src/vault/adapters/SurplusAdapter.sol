// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseInferenceAdapter} from "./BaseInferenceAdapter.sol";

/// @title  SurplusAdapter
/// @notice Venue adapter for Surplus Intelligence (surplusintelligence.ai) —
///         an AI inference marketplace. Operators list Venice DIEM capacity;
///         buyers pay USDC. Surplus Intelligence calls receiveSettlement() to
///         push net USDC after deducting its platform fee.
contract SurplusAdapter is BaseInferenceAdapter {
    constructor(address _vault, address _usdc, address _swapRouter, address initialOwner)
        BaseInferenceAdapter(_vault, _usdc, _swapRouter, initialOwner)
    {}

    function inferenceName() external pure override returns (string memory) {
        return "Surplus Intelligence";
    }
}
