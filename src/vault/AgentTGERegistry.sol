// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAgentTGERegistry} from "./interfaces/IAgentTGERegistry.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract AgentTGERegistry is IAgentTGERegistry, Ownable {
    uint256 public constant DORMANCY_WINDOW = 30 days;

    // Bronze=500, Silver=2000, Gold=5000 (USD/day in 6-dec fixed point)
    uint256[3] public tierAllocations = [500e6, 2000e6, 5000e6];

    address public feeRouter;
    mapping(address => Commitment) private _commitments;

    error NotFeeRouter();
    error NotRegistered();
    error AlreadyRegistered();
    error TooSoonToMarkDormant();

    event AgentRegistered(address indexed agent, Tier tier, uint256 dailyAllocationUSD);
    event AgentTerminated(address indexed agent);
    event AgentDormant(address indexed agent);
    event FeeReceiptRecorded(address indexed agent, uint256 timestamp);

    constructor(address _feeRouter, address initialOwner) Ownable(initialOwner) {
        feeRouter = _feeRouter;
    }

    function register(address agent, Tier tier) external onlyOwner {
        if (_commitments[agent].active) revert AlreadyRegistered();
        uint256 alloc = tierAllocations[uint8(tier)];
        _commitments[agent] = Commitment({
            agent: agent,
            dailyAllocationUSD: alloc,
            tier: tier,
            lastFeeReceiptAt: block.timestamp,
            active: true
        });
        emit AgentRegistered(agent, tier, alloc);
    }

    function terminate() external {
        _commitments[msg.sender].active = false;
        emit AgentTerminated(msg.sender);
    }

    function markDormant(address agent) external {
        Commitment storage c = _commitments[agent];
        if (!c.active) revert NotRegistered();
        if (block.timestamp < c.lastFeeReceiptAt + DORMANCY_WINDOW) revert TooSoonToMarkDormant();
        c.active = false;
        emit AgentDormant(agent);
    }

    function recordFeeReceipt(address agent) external {
        if (msg.sender != feeRouter) revert NotFeeRouter();
        _commitments[agent].lastFeeReceiptAt = block.timestamp;
        emit FeeReceiptRecorded(agent, block.timestamp);
    }

    function getCommitment(address agent) external view returns (Commitment memory) {
        return _commitments[agent];
    }

    function isEligible(address agent) external view returns (bool) {
        Commitment storage c = _commitments[agent];
        return c.active && (block.timestamp < c.lastFeeReceiptAt + DORMANCY_WINDOW);
    }
}
