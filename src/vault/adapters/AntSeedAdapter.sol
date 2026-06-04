// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseInferenceAdapter} from "./BaseInferenceAdapter.sol";

/// @title  AntSeedAdapter
/// @notice Venue adapter for AntSeed (antseed.ai) — an AI inference marketplace
///         that uses Venice AI's DIEM staking. Operators list inference capacity;
///         buyers pay USDC. AntSeed calls receiveSettlement() to push net USDC
///         to this adapter after deducting its platform fee.
///
/// @dev    AntSeed issue #627: Venice stakes are registered to the proxy contract
///         (vault address), not the operator wallet. AntSeed's marketplace UI may
///         show the vault as "unstaked" — this is a display issue only. Capacity
///         is live and backed by vault's stakedInfos.amountStaked on DIEM.
contract AntSeedAdapter is BaseInferenceAdapter {
    constructor(address _vault, address _usdc, address _swapRouter, address initialOwner)
        BaseInferenceAdapter(_vault, _usdc, _swapRouter, initialOwner)
    {}

    function inferenceName() external pure override returns (string memory) {
        return "AntSeed";
    }
}
