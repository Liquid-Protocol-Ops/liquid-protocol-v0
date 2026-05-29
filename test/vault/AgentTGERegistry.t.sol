// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AgentTGERegistry} from "../../src/vault/AgentTGERegistry.sol";
import {IAgentTGERegistry} from "../../src/vault/interfaces/IAgentTGERegistry.sol";
import {Test} from "forge-std/Test.sol";

contract AgentTGERegistryTest is Test {
    AgentTGERegistry registry;
    address feeRouter = makeAddr("feeRouter");
    address agent = makeAddr("agent");
    address owner = address(this);

    function setUp() public {
        registry = new AgentTGERegistry(feeRouter, owner);
    }

    function test_register_setsActive() public {
        registry.register(agent, IAgentTGERegistry.Tier.Bronze);
        IAgentTGERegistry.Commitment memory c = registry.getCommitment(agent);
        assertTrue(c.active);
        assertEq(uint8(c.tier), uint8(IAgentTGERegistry.Tier.Bronze));
    }

    function test_isEligible_trueAfterRegister() public {
        registry.register(agent, IAgentTGERegistry.Tier.Silver);
        assertTrue(registry.isEligible(agent));
    }

    function test_recordFeeReceipt_resetsTimer() public {
        registry.register(agent, IAgentTGERegistry.Tier.Bronze);
        vm.warp(block.timestamp + 10 days);
        vm.prank(feeRouter);
        registry.recordFeeReceipt(agent);
        IAgentTGERegistry.Commitment memory c = registry.getCommitment(agent);
        assertEq(c.lastFeeReceiptAt, block.timestamp);
    }

    function test_recordFeeReceipt_onlyFeeRouter() public {
        registry.register(agent, IAgentTGERegistry.Tier.Bronze);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        registry.recordFeeReceipt(agent);
    }

    function test_markDormant_after30Days() public {
        registry.register(agent, IAgentTGERegistry.Tier.Bronze);
        vm.warp(block.timestamp + 31 days);
        registry.markDormant(agent);
        assertFalse(registry.isEligible(agent));
    }

    function test_markDormant_before30Days_reverts() public {
        registry.register(agent, IAgentTGERegistry.Tier.Bronze);
        vm.warp(block.timestamp + 29 days);
        vm.expectRevert();
        registry.markDormant(agent);
    }

    function test_terminate_deactivates() public {
        registry.register(agent, IAgentTGERegistry.Tier.Bronze);
        vm.prank(agent);
        registry.terminate();
        assertFalse(registry.getCommitment(agent).active);
    }
}
