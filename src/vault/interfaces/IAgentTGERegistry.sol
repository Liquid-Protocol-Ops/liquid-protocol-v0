// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IAgentTGERegistry {
    enum Tier {
        Bronze,
        Silver,
        Gold
    }

    struct Commitment {
        address agent;
        uint256 dailyAllocationUSD; // 6-decimal fixed point
        Tier tier;
        uint256 lastFeeReceiptAt;
        bool active;
    }

    function register(address agent, Tier tier) external;
    function terminate() external;
    function markDormant(address agent) external;
    function recordFeeReceipt(address agent) external;
    function getCommitment(address agent) external view returns (Commitment memory);
    function isEligible(address agent) external view returns (bool);
}
