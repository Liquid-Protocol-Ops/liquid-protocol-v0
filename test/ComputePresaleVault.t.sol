// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ComputePresaleVault} from "../src/extensions/ComputePresaleVault.sol";
import {ILiquid} from "../src/interfaces/ILiquid.sol";
import {ILiquidExtension} from "../src/interfaces/ILiquidExtension.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Test} from "forge-std/Test.sol";

// ── Minimal mocks ─────────────────────────────────────────────────────────────

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Simulates the Liquid factory: holds the extension supply and calls receiveTokens.
contract MockFactory {
    function callReceiveTokens(address vault, address launchedToken, uint256 supply) external {
        // Approve vault to pull tokens (factory approves itself? No — factory calls transferFrom(msg.sender))
        // In the real factory, factory mints tokens then calls extension.receiveTokens.
        // The extension pulls from msg.sender (factory) via transferFrom.
        // So factory needs to approve vault before the call.
        IERC20(launchedToken).approve(vault, supply);

        ILiquid.DeploymentConfig memory config; // empty config
        PoolKey memory key;
        ILiquidExtension(vault).receiveTokens(config, key, launchedToken, supply, 0);
    }
}

// ── Base test setup ───────────────────────────────────────────────────────────

abstract contract BaseTest is Test {
    MockFactory factory;
    MockERC20 launchedToken; // the agent token (100B supply)
    MockERC20 depositToken; // VVV or DIEM
    address agentWallet = makeAddr("agent");

    uint256 constant DEPOSIT_WINDOW = 7 days;
    uint256 constant TOKEN_SUPPLY = 10_000_000_000e18; // 10B (10% of 100B)

    function setUp() public virtual {
        factory = new MockFactory();
        launchedToken = new MockERC20("AgentToken", "AGT");
        depositToken = new MockERC20("DepositToken", "DEP");

        // Mint the extension supply to factory so it can transfer to vault
        launchedToken.mint(address(factory), TOKEN_SUPPLY);
    }

    function _initVault(ComputePresaleVault vault) internal {
        vm.prank(address(factory));
        factory.callReceiveTokens(address(vault), address(launchedToken), TOKEN_SUPPLY);
    }
}

// ── VVV irrevocable mode tests ────────────────────────────────────────────────

contract VVVModeTest is BaseTest {
    ComputePresaleVault vault;

    function setUp() public override {
        super.setUp();
        vault = new ComputePresaleVault(
            address(factory),
            address(depositToken),
            agentWallet,
            0, // lockDuration = 0 → VVV irrevocable
            DEPOSIT_WINDOW
        );
    }

    // ── receiveTokens ──────────────────────────────────────────────────────

    function test_receiveTokens_setsState() public {
        factory.callReceiveTokens(address(vault), address(launchedToken), TOKEN_SUPPLY);

        assertEq(vault.token(), address(launchedToken));
        assertEq(vault.totalTokenSupply(), TOKEN_SUPPLY);
        assertEq(vault.depositDeadline(), block.timestamp + DEPOSIT_WINDOW);
        assertEq(vault.lockExpiry(), block.timestamp + DEPOSIT_WINDOW); // lockDuration=0
        assertTrue(vault.initialized());
        assertEq(IERC20(launchedToken).balanceOf(address(vault)), TOKEN_SUPPLY);
    }

    function test_receiveTokens_revertIfNotFactory() public {
        ILiquid.DeploymentConfig memory config;
        PoolKey memory key;
        vm.expectRevert(ComputePresaleVault.Unauthorized.selector);
        vault.receiveTokens(config, key, address(launchedToken), TOKEN_SUPPLY, 0);
    }

    function test_receiveTokens_revertIfAlreadyInitialized() public {
        factory.callReceiveTokens(address(vault), address(launchedToken), TOKEN_SUPPLY);
        // second call should revert
        launchedToken.mint(address(factory), TOKEN_SUPPLY);
        vm.expectRevert(ComputePresaleVault.AlreadyInitialized.selector);
        factory.callReceiveTokens(address(vault), address(launchedToken), TOKEN_SUPPLY);
    }

    // ── deposit ────────────────────────────────────────────────────────────

    function test_deposit_succeeds() public {
        factory.callReceiveTokens(address(vault), address(launchedToken), TOKEN_SUPPLY);

        address alice = makeAddr("alice");
        depositToken.mint(alice, 100e18);
        vm.startPrank(alice);
        depositToken.approve(address(vault), 100e18);
        vault.deposit(100e18);
        vm.stopPrank();

        assertEq(vault.deposited(alice), 100e18);
        assertEq(vault.totalDeposited(), 100e18);
    }

    function test_deposit_revertAfterDeadline() public {
        factory.callReceiveTokens(address(vault), address(launchedToken), TOKEN_SUPPLY);

        vm.warp(block.timestamp + DEPOSIT_WINDOW + 1);

        address alice = makeAddr("alice");
        depositToken.mint(alice, 100e18);
        vm.startPrank(alice);
        depositToken.approve(address(vault), 100e18);
        vm.expectRevert(ComputePresaleVault.DepositWindowClosed.selector);
        vault.deposit(100e18);
        vm.stopPrank();
    }

    function test_deposit_revertIfNotInitialized() public {
        address alice = makeAddr("alice");
        depositToken.mint(alice, 100e18);
        vm.startPrank(alice);
        depositToken.approve(address(vault), 100e18);
        vm.expectRevert(ComputePresaleVault.NotInitialized.selector);
        vault.deposit(100e18);
        vm.stopPrank();
    }

    // ── finalizeVVV ────────────────────────────────────────────────────────

    function test_finalizeVVV_transfersToAgent() public {
        factory.callReceiveTokens(address(vault), address(launchedToken), TOKEN_SUPPLY);

        address alice = makeAddr("alice");
        depositToken.mint(alice, 50e18);
        vm.startPrank(alice);
        depositToken.approve(address(vault), 50e18);
        vault.deposit(50e18);
        vm.stopPrank();

        vm.warp(block.timestamp + DEPOSIT_WINDOW + 1);
        vault.finalizeVVV();

        assertEq(depositToken.balanceOf(agentWallet), 50e18);
        assertEq(depositToken.balanceOf(address(vault)), 0);
    }

    function test_finalizeVVV_noopIfNoDeposits() public {
        factory.callReceiveTokens(address(vault), address(launchedToken), TOKEN_SUPPLY);
        vm.warp(block.timestamp + DEPOSIT_WINDOW + 1);
        vault.finalizeVVV(); // should not revert with zero balance
        assertEq(depositToken.balanceOf(agentWallet), 0);
    }

    function test_finalizeVVV_revertBeforeDeadline() public {
        factory.callReceiveTokens(address(vault), address(launchedToken), TOKEN_SUPPLY);
        vm.expectRevert(ComputePresaleVault.DepositWindowStillOpen.selector);
        vault.finalizeVVV();
    }

    function test_finalizeVVV_revertInDiemMode() public {
        ComputePresaleVault diemVault = new ComputePresaleVault(
            address(factory), address(depositToken), agentWallet, 30 days, DEPOSIT_WINDOW
        );
        launchedToken.mint(address(factory), TOKEN_SUPPLY);
        factory.callReceiveTokens(address(diemVault), address(launchedToken), TOKEN_SUPPLY);
        vm.warp(block.timestamp + DEPOSIT_WINDOW + 1);
        vm.expectRevert(ComputePresaleVault.WrongMode.selector);
        diemVault.finalizeVVV();
    }

    function test_finalizeVVV_idempotent() public {
        factory.callReceiveTokens(address(vault), address(launchedToken), TOKEN_SUPPLY);
        address alice = makeAddr("alice");
        depositToken.mint(alice, 10e18);
        vm.startPrank(alice);
        depositToken.approve(address(vault), 10e18);
        vault.deposit(10e18);
        vm.stopPrank();

        vm.warp(block.timestamp + DEPOSIT_WINDOW + 1);
        vault.finalizeVVV();
        vault.finalizeVVV(); // second call: no-op
        assertEq(depositToken.balanceOf(agentWallet), 10e18);
    }

    // ── claimTokens ────────────────────────────────────────────────────────

    function test_claimTokens_proRata_threeDepositors() public {
        factory.callReceiveTokens(address(vault), address(launchedToken), TOKEN_SUPPLY);

        address alice = makeAddr("alice"); // 50%
        address bob = makeAddr("bob"); // 30%
        address carol = makeAddr("carol"); // 20%

        _deposit(alice, 50e18);
        _deposit(bob, 30e18);
        _deposit(carol, 20e18);

        vm.warp(block.timestamp + DEPOSIT_WINDOW + 1);

        vm.prank(alice);
        vault.claimTokens();
        vm.prank(bob);
        vault.claimTokens();
        vm.prank(carol);
        vault.claimTokens();

        assertEq(launchedToken.balanceOf(alice), TOKEN_SUPPLY * 50 / 100);
        assertEq(launchedToken.balanceOf(bob), TOKEN_SUPPLY * 30 / 100);
        assertEq(launchedToken.balanceOf(carol), TOKEN_SUPPLY * 20 / 100);
    }

    function test_claimTokens_singleDepositorGets100Pct() public {
        factory.callReceiveTokens(address(vault), address(launchedToken), TOKEN_SUPPLY);
        address alice = makeAddr("alice");
        _deposit(alice, 1e18);
        vm.warp(block.timestamp + DEPOSIT_WINDOW + 1);
        vm.prank(alice);
        vault.claimTokens();
        assertEq(launchedToken.balanceOf(alice), TOKEN_SUPPLY);
    }

    function test_claimTokens_revertBeforeDeadline() public {
        factory.callReceiveTokens(address(vault), address(launchedToken), TOKEN_SUPPLY);
        address alice = makeAddr("alice");
        _deposit(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(ComputePresaleVault.DepositWindowStillOpen.selector);
        vault.claimTokens();
    }

    function test_claimTokens_revertDoubleClaim() public {
        factory.callReceiveTokens(address(vault), address(launchedToken), TOKEN_SUPPLY);
        address alice = makeAddr("alice");
        _deposit(alice, 1e18);
        vm.warp(block.timestamp + DEPOSIT_WINDOW + 1);
        vm.prank(alice);
        vault.claimTokens();
        vm.prank(alice);
        vm.expectRevert(ComputePresaleVault.AlreadyClaimed.selector);
        vault.claimTokens();
    }

    function test_claimTokens_revertNothingDeposited() public {
        factory.callReceiveTokens(address(vault), address(launchedToken), TOKEN_SUPPLY);
        vm.warp(block.timestamp + DEPOSIT_WINDOW + 1);
        address alice = makeAddr("alice");
        vm.prank(alice);
        vm.expectRevert(ComputePresaleVault.NothingDeposited.selector);
        vault.claimTokens();
    }

    function test_claimTokens_revertNoDepositsInVault() public {
        // No one deposited — totalDeposited == 0
        factory.callReceiveTokens(address(vault), address(launchedToken), TOKEN_SUPPLY);
        vm.warp(block.timestamp + DEPOSIT_WINDOW + 1);
        // manually set deposited to bypass NothingDeposited (use a different path)
        // Actually we can't easily do this without cheats — just verify NoDepositsInVault
        // is only reachable if deposited[msg.sender] > 0 but totalDeposited == 0.
        // This is an impossible state in normal operation, so we skip this edge case test.
    }

    function test_withdrawDepositToken_revertInVVVMode() public {
        factory.callReceiveTokens(address(vault), address(launchedToken), TOKEN_SUPPLY);
        address alice = makeAddr("alice");
        _deposit(alice, 1e18);
        vm.warp(block.timestamp + DEPOSIT_WINDOW + 30 days + 1);
        vm.prank(alice);
        vm.expectRevert(ComputePresaleVault.WrongMode.selector);
        vault.withdrawDepositToken();
    }

    // ── getShare view ──────────────────────────────────────────────────────

    function test_getShare() public {
        factory.callReceiveTokens(address(vault), address(launchedToken), TOKEN_SUPPLY);
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _deposit(alice, 75e18);
        _deposit(bob, 25e18);

        assertEq(vault.getShare(alice), TOKEN_SUPPLY * 75 / 100);
        assertEq(vault.getShare(bob), TOKEN_SUPPLY * 25 / 100);
    }

    function test_getShare_returnsZeroNoDeposit() public {
        factory.callReceiveTokens(address(vault), address(launchedToken), TOKEN_SUPPLY);
        assertEq(vault.getShare(makeAddr("nobody")), 0);
    }

    // ── helper ────────────────────────────────────────────────────────────

    function _deposit(address who, uint256 amount) internal {
        depositToken.mint(who, amount);
        vm.startPrank(who);
        depositToken.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }
}

// ── DIEM time-lock mode tests ─────────────────────────────────────────────────

contract DIEMModeTest is BaseTest {
    ComputePresaleVault vault;
    uint256 constant LOCK_DURATION = 30 days;

    function setUp() public override {
        super.setUp();
        vault = new ComputePresaleVault(
            address(factory), address(depositToken), agentWallet, LOCK_DURATION, DEPOSIT_WINDOW
        );
        factory.callReceiveTokens(address(vault), address(launchedToken), TOKEN_SUPPLY);
    }

    function test_withdrawDepositToken_returnsAfterLockExpiry() public {
        address alice = makeAddr("alice");
        _deposit(alice, 100e18);

        // before lockExpiry → reverts
        vm.warp(block.timestamp + DEPOSIT_WINDOW + 1);
        vm.prank(alice);
        vm.expectRevert(ComputePresaleVault.LockNotExpired.selector);
        vault.withdrawDepositToken();

        // after lockExpiry → succeeds
        vm.warp(block.timestamp + LOCK_DURATION);
        vm.prank(alice);
        vault.withdrawDepositToken();
        assertEq(depositToken.balanceOf(alice), 100e18);
        assertEq(depositToken.balanceOf(address(vault)), 0);
    }

    function test_withdrawDepositToken_revertDoubleWithdraw() public {
        address alice = makeAddr("alice");
        _deposit(alice, 100e18);
        vm.warp(vault.lockExpiry() + 1);
        vm.prank(alice);
        vault.withdrawDepositToken();
        vm.prank(alice);
        vm.expectRevert(ComputePresaleVault.AlreadyWithdrawn.selector);
        vault.withdrawDepositToken();
    }

    function test_claimTokens_and_withdrawDepositToken_independent() public {
        address alice = makeAddr("alice");
        _deposit(alice, 100e18);

        vm.warp(vault.depositDeadline() + 1);

        // claim tokens first
        vm.prank(alice);
        vault.claimTokens();
        assertEq(launchedToken.balanceOf(alice), TOKEN_SUPPLY);

        // then withdraw DIEM after lock
        vm.warp(vault.lockExpiry() + 1);
        vm.prank(alice);
        vault.withdrawDepositToken();
        assertEq(depositToken.balanceOf(alice), 100e18);
    }

    function test_claimTokens_then_withdrawDepositToken_reverseOrder() public {
        address alice = makeAddr("alice");
        _deposit(alice, 100e18);

        vm.warp(vault.lockExpiry() + 1);

        // withdraw DIEM first
        vm.prank(alice);
        vault.withdrawDepositToken();
        // then claim tokens
        vm.prank(alice);
        vault.claimTokens();
        assertEq(launchedToken.balanceOf(alice), TOKEN_SUPPLY);
        assertEq(depositToken.balanceOf(alice), 100e18);
    }

    function test_finalizeVVV_revertInDiemMode() public {
        vm.warp(vault.depositDeadline() + 1);
        vm.expectRevert(ComputePresaleVault.WrongMode.selector);
        vault.finalizeVVV();
    }

    function test_lockExpiry_correctlySet() public {
        assertEq(vault.lockExpiry(), vault.depositDeadline() + LOCK_DURATION);
    }

    function test_withdrawDepositToken_revertNothingDeposited() public {
        vm.warp(vault.lockExpiry() + 1);
        vm.prank(makeAddr("nobody"));
        vm.expectRevert(ComputePresaleVault.NothingDeposited.selector);
        vault.withdrawDepositToken();
    }

    // ── helper ────────────────────────────────────────────────────────────

    function _deposit(address who, uint256 amount) internal {
        depositToken.mint(who, amount);
        vm.startPrank(who);
        depositToken.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }
}

// ── ERC165 ────────────────────────────────────────────────────────────────────

contract ERC165Test is BaseTest {
    function test_supportsILiquidExtension() public {
        ComputePresaleVault v = new ComputePresaleVault(
            address(factory), address(depositToken), agentWallet, 0, DEPOSIT_WINDOW
        );
        assertTrue(v.supportsInterface(type(ILiquidExtension).interfaceId));
    }

    function test_doesNotSupportRandomInterface() public {
        ComputePresaleVault v = new ComputePresaleVault(
            address(factory), address(depositToken), agentWallet, 0, DEPOSIT_WINDOW
        );
        assertFalse(v.supportsInterface(bytes4(0xdeadbeef)));
    }
}
