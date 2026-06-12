// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ComputePresaleFactory} from "../src/extensions/ComputePresaleFactory.sol";
import {ComputePresaleVault} from "../src/extensions/ComputePresaleVault.sol";
import {Test} from "forge-std/Test.sol";

contract ComputePresaleFactoryTest is Test {
    ComputePresaleFactory factory;

    address liquidFactory = makeAddr("liquidFactory");
    address depositToken = makeAddr("depositToken");
    address agentWallet = makeAddr("agentWallet");
    address deployer = makeAddr("deployer");

    uint256 constant LOCK_DURATION = 30 days;
    uint256 constant DEPOSIT_WINDOW = 7 days;

    function setUp() public {
        factory = new ComputePresaleFactory();
    }

    // ── computeAddress predicts correctly ────────────────────────────────────

    function test_computeAddress_matchesDeployed() public {
        bytes32 salt = factory.buildSalt(deployer, 0);

        address predicted = factory.computeAddress(
            deployer, salt, liquidFactory, depositToken, agentWallet, LOCK_DURATION, DEPOSIT_WINDOW
        );

        vm.prank(deployer);
        address deployed = factory.deployVault(
            salt, liquidFactory, depositToken, agentWallet, LOCK_DURATION, DEPOSIT_WINDOW
        );

        assertEq(predicted, deployed);
    }

    function test_computeAddress_vvvMode() public {
        bytes32 salt = factory.buildSalt(deployer, 1);
        address predicted = factory.computeAddress(
            deployer, salt, liquidFactory, depositToken, agentWallet, 0, DEPOSIT_WINDOW
        );
        assertFalse(predicted == address(0));
    }

    function test_computeAddress_deterministicForSameParams() public {
        bytes32 salt = factory.buildSalt(deployer, 2);
        address a = factory.computeAddress(
            deployer, salt, liquidFactory, depositToken, agentWallet, LOCK_DURATION, DEPOSIT_WINDOW
        );
        address b = factory.computeAddress(
            deployer, salt, liquidFactory, depositToken, agentWallet, LOCK_DURATION, DEPOSIT_WINDOW
        );
        assertEq(a, b);
    }

    function test_computeAddress_diffSalt_diffAddress() public {
        bytes32 salt0 = factory.buildSalt(deployer, 0);
        bytes32 salt1 = factory.buildSalt(deployer, 1);
        address a = factory.computeAddress(
            deployer, salt0, liquidFactory, depositToken, agentWallet, LOCK_DURATION, DEPOSIT_WINDOW
        );
        address b = factory.computeAddress(
            deployer, salt1, liquidFactory, depositToken, agentWallet, LOCK_DURATION, DEPOSIT_WINDOW
        );
        assertTrue(a != b);
    }

    function test_computeAddress_sameSalt_diffDeployer_diffAddress() public {
        address other = makeAddr("other");
        bytes32 salt = factory.buildSalt(deployer, 0);
        address a = factory.computeAddress(
            deployer, salt, liquidFactory, depositToken, agentWallet, LOCK_DURATION, DEPOSIT_WINDOW
        );
        address b = factory.computeAddress(
            other, salt, liquidFactory, depositToken, agentWallet, LOCK_DURATION, DEPOSIT_WINDOW
        );
        assertTrue(a != b);
    }

    // ── deployVault ──────────────────────────────────────────────────────────

    function test_deployVault_setsImmutables() public {
        bytes32 salt = factory.buildSalt(deployer, 0);
        vm.prank(deployer);
        address vault = factory.deployVault(
            salt, liquidFactory, depositToken, agentWallet, LOCK_DURATION, DEPOSIT_WINDOW
        );

        ComputePresaleVault v = ComputePresaleVault(vault);
        assertEq(address(v.factory()), liquidFactory);
        assertEq(address(v.depositToken()), depositToken);
        assertEq(v.agentWallet(), agentWallet);
        assertEq(v.lockDuration(), LOCK_DURATION);
        assertEq(v.depositWindow(), DEPOSIT_WINDOW);
    }

    function test_deployVault_emitsEvent() public {
        bytes32 salt = factory.buildSalt(deployer, 0);
        address predicted = factory.computeAddress(
            deployer, salt, liquidFactory, depositToken, agentWallet, LOCK_DURATION, DEPOSIT_WINDOW
        );

        vm.expectEmit(true, true, true, true);
        emit ComputePresaleFactory.VaultDeployed(
            factory.effectiveSalt(deployer, salt),
            predicted,
            depositToken,
            agentWallet,
            LOCK_DURATION,
            DEPOSIT_WINDOW
        );
        vm.prank(deployer);
        factory.deployVault(
            salt, liquidFactory, depositToken, agentWallet, LOCK_DURATION, DEPOSIT_WINDOW
        );
    }

    function test_deployVault_recordsInMapping() public {
        bytes32 salt = factory.buildSalt(deployer, 0);
        vm.prank(deployer);
        address vault = factory.deployVault(
            salt, liquidFactory, depositToken, agentWallet, LOCK_DURATION, DEPOSIT_WINDOW
        );
        assertEq(factory.vaultAt(factory.effectiveSalt(deployer, salt)), vault);
    }

    function test_revert_saltAlreadyUsed() public {
        bytes32 salt = factory.buildSalt(deployer, 0);
        vm.prank(deployer);
        factory.deployVault(
            salt, liquidFactory, depositToken, agentWallet, LOCK_DURATION, DEPOSIT_WINDOW
        );

        vm.expectRevert(ComputePresaleFactory.SaltAlreadyUsed.selector);
        vm.prank(deployer);
        factory.deployVault(
            salt, liquidFactory, depositToken, agentWallet, LOCK_DURATION, DEPOSIT_WINDOW
        );
    }

    function test_revert_zeroAddress_factory() public {
        bytes32 salt = factory.buildSalt(deployer, 0);
        vm.expectRevert(ComputePresaleFactory.ZeroAddress.selector);
        factory.deployVault(
            salt, address(0), depositToken, agentWallet, LOCK_DURATION, DEPOSIT_WINDOW
        );
    }

    function test_revert_zeroAddress_depositToken() public {
        bytes32 salt = factory.buildSalt(deployer, 0);
        vm.expectRevert(ComputePresaleFactory.ZeroAddress.selector);
        factory.deployVault(
            salt, liquidFactory, address(0), agentWallet, LOCK_DURATION, DEPOSIT_WINDOW
        );
    }

    // ── buildSalt ────────────────────────────────────────────────────────────

    function test_buildSalt_differentDeployers_differentSalt() public {
        address other = makeAddr("other");
        bytes32 s1 = factory.buildSalt(deployer, 0);
        bytes32 s2 = factory.buildSalt(other, 0);
        assertTrue(s1 != s2);
    }

    function test_buildSalt_sameDeployer_differentNonce_differentSalt() public {
        bytes32 s1 = factory.buildSalt(deployer, 0);
        bytes32 s2 = factory.buildSalt(deployer, 1);
        assertTrue(s1 != s2);
    }

    // ── Multiple deployments, different salts ─────────────────────────────────

    function test_deployTwo_differentSalts() public {
        bytes32 salt0 = factory.buildSalt(deployer, 0);
        bytes32 salt1 = factory.buildSalt(deployer, 1);

        vm.prank(deployer);
        address vault0 =
            factory.deployVault(salt0, liquidFactory, depositToken, agentWallet, 0, DEPOSIT_WINDOW);
        vm.prank(deployer);
        address vault1 = factory.deployVault(
            salt1, liquidFactory, depositToken, agentWallet, LOCK_DURATION, DEPOSIT_WINDOW
        );

        assertTrue(vault0 != vault1);
        assertEq(factory.vaultAt(factory.effectiveSalt(deployer, salt0)), vault0);
        assertEq(factory.vaultAt(factory.effectiveSalt(deployer, salt1)), vault1);

        // VVV vault has lockDuration 0, DIEM vault has 30 days
        assertEq(ComputePresaleVault(vault0).lockDuration(), 0);
        assertEq(ComputePresaleVault(vault1).lockDuration(), LOCK_DURATION);
    }
}
