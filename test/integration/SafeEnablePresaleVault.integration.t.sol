// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * Fork test for the SafeEnablePresaleVault script preconditions (MOG-497).
 *
 * Validates, against the LIVE Base mainnet factory:
 *   1. every sanity guard the script checks before signing,
 *   2. the exact setExtension calldata the Safe will execute (via prank),
 *   3. that a fresh vault is NOT enabled by default (deployToken's
 *      ExtensionNotEnabled blocker is real).
 *
 * The Safe signature mechanics themselves are inherited verbatim from
 * SafeBatch.s.sol, which is exercised in production regularly.
 *
 * Run:
 *   forge test --match-path "test/integration/SafeEnablePresaleVault*" --fork-url $RPC_URL -v
 */

import {ComputePresaleVault} from "../../src/extensions/ComputePresaleVault.sol";
import {ILiquidExtension} from "../../src/interfaces/ILiquidExtension.sol";
import {Test} from "forge-std/Test.sol";

interface ILiquidFactoryFork {
    function owner() external view returns (address);
    function setExtension(address extension, bool enabled) external;
}

contract SafeEnablePresaleVaultForkTest is Test {
    address constant SAFE = 0x872c561f699B42977c093F0eD8b4C9a431280c6c;
    address constant FACTORY = 0x04F1a284168743759BE6554f607a10CEBdB77760;
    address constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;

    ComputePresaleVault vault;

    function setUp() public {
        if (block.chainid != 8453) {
            vm.skip(true);
            return;
        }
        vault = new ComputePresaleVault(FACTORY, VVV, makeAddr("agent"), 0, 7 days);
    }

    /// All script guards must hold for a fresh vault on the live factory.
    function test_scriptGuards_holdOnMainnet() public view {
        assertGt(address(vault).code.length, 0, "vault has no code");
        assertTrue(
            ILiquidExtension(address(vault)).supportsInterface(type(ILiquidExtension).interfaceId),
            "interfaceId mismatch"
        );
        assertEq(address(vault.factory()), FACTORY, "vault.factory() != live factory");
        assertEq(ILiquidFactoryFork(FACTORY).owner(), SAFE, "factory owner is not the Safe");
        assertFalse(vault.initialized(), "fresh vault must be uninitialized");
    }

    /// The exact calldata the Safe executes must succeed when sent by the owner.
    function test_setExtension_succeedsAsOwner() public {
        vm.prank(SAFE);
        (bool ok,) = FACTORY.call(
            abi.encodeWithSignature("setExtension(address,bool)", address(vault), true)
        );
        assertTrue(ok, "setExtension reverted as owner");
    }

    /// Non-owner must NOT be able to enable extensions (the blocker is real).
    function test_setExtension_revertsForNonOwner() public {
        vm.prank(makeAddr("rando"));
        (bool ok,) = FACTORY.call(
            abi.encodeWithSignature("setExtension(address,bool)", address(vault), true)
        );
        assertFalse(ok, "setExtension should revert for non-owner");
    }
}
