// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * ComputePresaleVault end-to-end integration test.
 *
 * Forks Base mainnet and runs the full presale lifecycle against:
 *   - Real VVV ERC-20 token (0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf)
 *   - Real DIEM ERC-20 token (0xF4d97F2da56e8c3098f3a8D538DB630A2606a024)
 *
 * The Liquid factory is mocked (full factory setup is out of scope here);
 * the mock calls receiveTokens() directly as the factory would.
 *
 * Run:
 *   forge test --match-path "test/integration/*.t.sol" --fork-url $RPC_URL -v
 *
 * Requires RPC_URL env var pointing to a Base mainnet RPC endpoint.
 */

import {ComputePresaleFactory} from "../../src/extensions/ComputePresaleFactory.sol";
import {ComputePresaleVault} from "../../src/extensions/ComputePresaleVault.sol";
import {ILiquid} from "../../src/interfaces/ILiquid.sol";
import {ILiquidExtension} from "../../src/interfaces/ILiquidExtension.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Test} from "forge-std/Test.sol";

// ── Mock contracts ────────────────────────────────────────────────────────────

contract MockAgentToken is ERC20 {
    constructor() ERC20("AgentToken", "AGT") {
        _mint(msg.sender, 100_000_000_000e18); // 100B supply
    }
}

/// @dev Simulates the Liquid factory calling receiveTokens() after minting extension tokens.
contract MockLiquidFactory {
    function bootstrapVault(address vault, address agentToken, uint256 extensionSupply) external {
        IERC20(agentToken).approve(vault, extensionSupply);
        ILiquid.DeploymentConfig memory config;
        PoolKey memory key;
        ILiquidExtension(vault).receiveTokens(config, key, agentToken, extensionSupply, 0);
    }
}

// ── Base integration test ─────────────────────────────────────────────────────

abstract contract BaseIntegration is Test {
    // ── Real Base mainnet token addresses ─────────────────────────────────────
    address constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;
    address constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;

    MockLiquidFactory liquidFactory;
    MockAgentToken agentToken;

    address agentWallet = makeAddr("agent");
    address depositor1 = makeAddr("depositor1");
    address depositor2 = makeAddr("depositor2");

    uint256 constant DEPOSIT_WINDOW = 7 days;
    uint256 constant TOKEN_SUPPLY = 10_000_000_000e18; // 10B (10%)

    function setUp() public virtual {
        // Skip when not running against a Base mainnet fork.
        // Run with: forge test --match-path "test/integration/*.t.sol" --fork-url $RPC_URL
        if (block.chainid != 8453) {
            vm.skip(true);
            return;
        }
        liquidFactory = new MockLiquidFactory();
        agentToken = new MockAgentToken();

        // Fund mock factory with extension supply
        deal(address(agentToken), address(liquidFactory), TOKEN_SUPPLY);
    }

    function _fundVVV(address who, uint256 amount) internal {
        deal(VVV, who, amount);
    }

    function _fundDIEM(address who, uint256 amount) internal {
        deal(DIEM, who, amount);
    }
}

// ── VVV irrevocable mode integration ─────────────────────────────────────────

contract VVVIrrevocableIntegration is BaseIntegration {
    ComputePresaleVault vault;

    function setUp() public override {
        super.setUp();
        vault = new ComputePresaleVault(
            address(liquidFactory),
            VVV,
            agentWallet,
            0, // lockDuration = 0 → VVV irrevocable
            DEPOSIT_WINDOW
        );

        // Factory bootstraps vault with token supply
        vm.prank(address(liquidFactory));
        liquidFactory.bootstrapVault(address(vault), address(agentToken), TOKEN_SUPPLY);
    }

    function test_lifecycle_vvv() public {
        uint256 depositAmount = 1e18; // 1 VVV

        // ── 1. Depositors acquire and deposit VVV ──
        _fundVVV(depositor1, depositAmount);
        _fundVVV(depositor2, depositAmount);

        vm.startPrank(depositor1);
        IERC20(VVV).approve(address(vault), depositAmount);
        vault.deposit(depositAmount);
        vm.stopPrank();

        vm.startPrank(depositor2);
        IERC20(VVV).approve(address(vault), depositAmount);
        vault.deposit(depositAmount);
        vm.stopPrank();

        assertEq(vault.totalDeposited(), depositAmount * 2);
        assertEq(vault.deposited(depositor1), depositAmount);
        assertEq(vault.deposited(depositor2), depositAmount);
        assertEq(IERC20(VVV).balanceOf(address(vault)), depositAmount * 2);

        // ── 2. Window closes ──
        vm.warp(vault.depositDeadline() + 1);

        // ── 3. Agent calls finalizeVVV() — VVV flows to agentWallet ──
        vm.prank(agentWallet);
        vault.finalizeVVV();

        assertEq(IERC20(VVV).balanceOf(agentWallet), depositAmount * 2);
        assertEq(IERC20(VVV).balanceOf(address(vault)), 0);

        // ── 4. Depositors claim tokens pro-rata ──
        vm.prank(depositor1);
        vault.claimTokens();
        vm.prank(depositor2);
        vault.claimTokens();

        // Equal deposits → equal allocations (50/50)
        assertEq(IERC20(address(agentToken)).balanceOf(depositor1), TOKEN_SUPPLY / 2);
        assertEq(IERC20(address(agentToken)).balanceOf(depositor2), TOKEN_SUPPLY / 2);

        // Vault is empty (or has at most 1 wei dust)
        assertLe(IERC20(address(agentToken)).balanceOf(address(vault)), 1);
    }

    function test_finalizeVVV_revert_beforeDeadline() public {
        _fundVVV(depositor1, 1e18);
        vm.startPrank(depositor1);
        IERC20(VVV).approve(address(vault), 1e18);
        vault.deposit(1e18);
        vm.stopPrank();

        vm.expectRevert(ComputePresaleVault.DepositWindowStillOpen.selector);
        vm.prank(agentWallet);
        vault.finalizeVVV();
    }

    function test_deposit_revert_afterDeadline() public {
        _fundVVV(depositor1, 1e18);
        vm.warp(vault.depositDeadline() + 1);

        vm.startPrank(depositor1);
        IERC20(VVV).approve(address(vault), 1e18);
        vm.expectRevert(ComputePresaleVault.DepositWindowClosed.selector);
        vault.deposit(1e18);
        vm.stopPrank();
    }

    function test_lifecycle_noDeposits_agentGetsNothing() public {
        vm.warp(vault.depositDeadline() + 1);

        // finalizeVVV with zero deposits — VVV balance is 0, sends 0
        vm.prank(agentWallet);
        vault.finalizeVVV();
        assertEq(IERC20(VVV).balanceOf(agentWallet), 0);

        // No one can claim (depositor1 never deposited, NothingDeposited fires first)
        vm.expectRevert(ComputePresaleVault.NothingDeposited.selector);
        vm.prank(depositor1);
        vault.claimTokens();
    }

    function test_vvv_doubleClaim_reverts() public {
        uint256 depositAmount = 1e18;

        // Deposit VVV
        _fundVVV(depositor1, depositAmount);
        vm.startPrank(depositor1);
        IERC20(VVV).approve(address(vault), depositAmount);
        vault.deposit(depositAmount);
        vm.stopPrank();

        // Warp past deadline and finalize
        vm.warp(vault.depositDeadline() + 1);
        vm.prank(agentWallet);
        vault.finalizeVVV();

        // First claim succeeds
        vm.prank(depositor1);
        vault.claimTokens();
        assertEq(IERC20(address(agentToken)).balanceOf(depositor1), TOKEN_SUPPLY);

        // Second claim reverts with AlreadyClaimed
        vm.expectRevert(ComputePresaleVault.AlreadyClaimed.selector);
        vm.prank(depositor1);
        vault.claimTokens();
    }

    function test_vvv_withdrawDepositToken_reverts_wrongMode() public {
        uint256 depositAmount = 1e18;

        // Deposit VVV
        _fundVVV(depositor1, depositAmount);
        vm.startPrank(depositor1);
        IERC20(VVV).approve(address(vault), depositAmount);
        vault.deposit(depositAmount);
        vm.stopPrank();

        // Warp past deadline
        vm.warp(vault.depositDeadline() + 1);

        // VVV mode does not support withdrawDepositToken — must revert with WrongMode
        vm.expectRevert(ComputePresaleVault.WrongMode.selector);
        vm.prank(depositor1);
        vault.withdrawDepositToken();
    }
}

// ── DIEM time-lock mode integration ──────────────────────────────────────────

contract DIEMTimeLockIntegration is BaseIntegration {
    ComputePresaleVault vault;
    uint256 constant LOCK_DURATION = 30 days;

    function setUp() public override {
        super.setUp();
        vault = new ComputePresaleVault(
            address(liquidFactory), DIEM, agentWallet, LOCK_DURATION, DEPOSIT_WINDOW
        );

        vm.prank(address(liquidFactory));
        liquidFactory.bootstrapVault(address(vault), address(agentToken), TOKEN_SUPPLY);
    }

    function test_lifecycle_diem() public {
        uint256 dep1 = 1000e18; // 1,000 DIEM
        uint256 dep2 = 3000e18; // 3,000 DIEM

        // ── 1. Deposit DIEM ──
        _fundDIEM(depositor1, dep1);
        _fundDIEM(depositor2, dep2);

        vm.startPrank(depositor1);
        IERC20(DIEM).approve(address(vault), dep1);
        vault.deposit(dep1);
        vm.stopPrank();

        vm.startPrank(depositor2);
        IERC20(DIEM).approve(address(vault), dep2);
        vault.deposit(dep2);
        vm.stopPrank();

        assertEq(vault.totalDeposited(), dep1 + dep2);

        // ── 2. Window closes, claim tokens (25% / 75% split) ──
        vm.warp(vault.depositDeadline() + 1);

        vm.prank(depositor1);
        vault.claimTokens();
        vm.prank(depositor2);
        vault.claimTokens();

        assertEq(IERC20(address(agentToken)).balanceOf(depositor1), TOKEN_SUPPLY / 4);
        assertEq(IERC20(address(agentToken)).balanceOf(depositor2), TOKEN_SUPPLY * 3 / 4);

        // ── 3. Lock not yet expired — withdrawDiem reverts ──
        vm.warp(vault.lockExpiry() - 1);
        vm.expectRevert(ComputePresaleVault.LockNotExpired.selector);
        vm.prank(depositor1);
        vault.withdrawDepositToken();

        // ── 4. Lock expires — both depositors recover full DIEM ──
        vm.warp(vault.lockExpiry() + 1);

        vm.prank(depositor1);
        vault.withdrawDepositToken();
        vm.prank(depositor2);
        vault.withdrawDepositToken();

        assertEq(IERC20(DIEM).balanceOf(depositor1), dep1);
        assertEq(IERC20(DIEM).balanceOf(depositor2), dep2);

        // ── 5. DIEM mode: finalizeVVV reverts ──
        vm.expectRevert(ComputePresaleVault.WrongMode.selector);
        vm.prank(agentWallet);
        vault.finalizeVVV();
    }

    function test_withdrawDepositToken_revert_nothingDeposited() public {
        // depositor1 never deposited, so NothingDeposited
        vm.warp(vault.lockExpiry() + 1);
        vm.expectRevert(ComputePresaleVault.NothingDeposited.selector);
        vm.prank(depositor1);
        vault.withdrawDepositToken();
    }

    function test_diem_doubleWithdraw_reverts() public {
        uint256 depositAmount = 1000e18;

        // Deposit DIEM
        _fundDIEM(depositor1, depositAmount);
        vm.startPrank(depositor1);
        IERC20(DIEM).approve(address(vault), depositAmount);
        vault.deposit(depositAmount);
        vm.stopPrank();

        // Warp past deposit window and lock expiry
        vm.warp(vault.lockExpiry() + 1);

        // First withdraw succeeds
        vm.prank(depositor1);
        vault.withdrawDepositToken();
        assertEq(IERC20(DIEM).balanceOf(depositor1), depositAmount);

        // Second withdraw reverts with AlreadyWithdrawn
        vm.expectRevert(ComputePresaleVault.AlreadyWithdrawn.selector);
        vm.prank(depositor1);
        vault.withdrawDepositToken();
    }
}

// ── CREATE2 factory integration ───────────────────────────────────────────────

contract FactoryIntegration is BaseIntegration {
    ComputePresaleFactory factory;

    function setUp() public override {
        super.setUp();
        factory = new ComputePresaleFactory();
    }

    function test_factory_deployAndBootstrap_vvvMode() public {
        bytes32 salt = factory.buildSalt(address(this), 0);

        // Predict address before deploying
        address predicted = factory.computeAddress(
            address(this), salt, address(liquidFactory), VVV, agentWallet, 0, DEPOSIT_WINDOW
        );

        // Deploy vault
        address vaultAddr =
            factory.deployVault(salt, address(liquidFactory), VVV, agentWallet, 0, DEPOSIT_WINDOW);
        assertEq(predicted, vaultAddr);

        // Bootstrap with tokens
        deal(address(agentToken), address(liquidFactory), TOKEN_SUPPLY);
        vm.prank(address(liquidFactory));
        liquidFactory.bootstrapVault(vaultAddr, address(agentToken), TOKEN_SUPPLY);

        ComputePresaleVault vault = ComputePresaleVault(vaultAddr);
        assertTrue(vault.initialized());
        assertEq(IERC20(address(agentToken)).balanceOf(vaultAddr), TOKEN_SUPPLY);

        // Deposit 1 VVV from depositor1
        _fundVVV(depositor1, 1e18);
        vm.startPrank(depositor1);
        IERC20(VVV).approve(vaultAddr, 1e18);
        vault.deposit(1e18);
        vm.stopPrank();

        // Advance past deadline, finalize, claim
        vm.warp(vault.depositDeadline() + 1);
        vm.prank(agentWallet);
        vault.finalizeVVV();
        vm.prank(depositor1);
        vault.claimTokens();

        assertEq(IERC20(VVV).balanceOf(agentWallet), 1e18);
        assertEq(IERC20(address(agentToken)).balanceOf(depositor1), TOKEN_SUPPLY);
    }

    function test_factory_revert_duplicateSalt() public {
        bytes32 salt = factory.buildSalt(address(this), 0);
        factory.deployVault(salt, address(liquidFactory), VVV, agentWallet, 0, DEPOSIT_WINDOW);

        vm.expectRevert(ComputePresaleFactory.SaltAlreadyUsed.selector);
        factory.deployVault(salt, address(liquidFactory), VVV, agentWallet, 0, DEPOSIT_WINDOW);
    }
}
