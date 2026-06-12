// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ComputePresaleFactory} from "../src/extensions/ComputePresaleFactory.sol";
import {ComputePresaleVault} from "../src/extensions/ComputePresaleVault.sol";
import {ILiquid} from "../src/interfaces/ILiquid.sol";
import {ILiquidExtension} from "../src/interfaces/ILiquidExtension.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Test} from "forge-std/Test.sol";

// ── Regression tests for GHSA-6566-6rm7-j9p3 ──────────────────────────────────
//
// Each test mirrors a finding from the advisory's proof-of-concept and asserts the
// FIXED behaviour: the previously-exploitable path now reverts or stays solvent.

// ── Mock tokens ───────────────────────────────────────────────────────────────

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Finding #1: transfer/transferFrom return false without reverting or moving funds.
contract FalseReturningToken is ERC20 {
    constructor() ERC20("False", "FALSE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// @dev Finding #2: burns a 2% fee on every transfer; recipient receives amount * 98 / 100.
contract FeeOnTransferToken is ERC20 {
    uint256 public constant FEE_BPS = 200; // 2%

    constructor() ERC20("FeeOnTransfer", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _feeAdjusted(uint256 amount) internal pure returns (uint256 net, uint256 fee) {
        fee = (amount * FEE_BPS) / 10_000;
        net = amount - fee;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        (uint256 net, uint256 fee) = _feeAdjusted(amount);
        _burn(msg.sender, fee);
        return super.transfer(to, net);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        (uint256 net, uint256 fee) = _feeAdjusted(amount);
        _spendAllowance(from, msg.sender, amount);
        _burn(from, fee);
        _transfer(from, to, net);
        return true;
    }
}

// ── Mock Liquid factory ───────────────────────────────────────────────────────

contract MockLiquidFactory {
    function bootstrapVault(address vault, address agentToken, uint256 extensionSupply) external {
        IERC20(agentToken).approve(vault, extensionSupply);
        ILiquid.DeploymentConfig memory config;
        PoolKey memory key;
        ILiquidExtension(vault).receiveTokens(config, key, agentToken, extensionSupply, 0);
    }
}

// ── Suite ─────────────────────────────────────────────────────────────────────

contract ComputePresaleSecurityTest is Test {
    MockLiquidFactory liquidFactory;

    address agentWallet = makeAddr("agent");
    address depositor1 = makeAddr("depositor1");
    address depositor2 = makeAddr("depositor2");
    address attacker = makeAddr("attacker");
    address victim = makeAddr("victim");

    uint256 constant DEPOSIT_WINDOW = 7 days;
    uint256 constant LOCK_DURATION = 30 days;
    uint256 constant TOKEN_SUPPLY = 10_000_000_000e18;

    function setUp() public {
        liquidFactory = new MockLiquidFactory();
    }

    function _deployAndBootstrap(address depositToken, address agentToken, uint256 lockDuration)
        internal
        returns (ComputePresaleVault vault)
    {
        vault = new ComputePresaleVault(
            address(liquidFactory), depositToken, agentWallet, lockDuration, DEPOSIT_WINDOW
        );
        MockERC20(agentToken).mint(address(liquidFactory), TOKEN_SUPPLY);
        vm.prank(address(liquidFactory));
        liquidFactory.bootstrapVault(address(vault), agentToken, TOKEN_SUPPLY);
    }

    // Finding #1 — SafeERC20 now reverts when a deposit token returns false.
    function test_fix_falseReturningToken_depositReverts() public {
        FalseReturningToken depositToken = new FalseReturningToken();
        MockERC20 agentToken = new MockERC20();
        ComputePresaleVault vault =
            _deployAndBootstrap(address(depositToken), address(agentToken), 0);

        uint256 amount = 100e18;
        depositToken.mint(depositor1, amount);

        vm.startPrank(depositor1);
        depositToken.approve(address(vault), amount);
        // safeTransferFrom reverts on a false return value instead of crediting unbacked shares.
        vm.expectRevert();
        vault.deposit(amount);
        vm.stopPrank();

        assertEq(vault.deposited(depositor1), 0, "no credit on failed transfer");
        assertEq(vault.totalDeposited(), 0, "accounting untouched");
    }

    // Finding #2 — fee-on-transfer deposits credit the received delta; vault stays solvent.
    function test_fix_feeOnTransfer_solventWithdraw() public {
        FeeOnTransferToken depositToken = new FeeOnTransferToken();
        MockERC20 agentToken = new MockERC20();
        ComputePresaleVault vault =
            _deployAndBootstrap(address(depositToken), address(agentToken), LOCK_DURATION);

        uint256 amount = 100e18;
        uint256 net = (amount * 98) / 100; // 98e18 actually arrives per deposit

        depositToken.mint(depositor1, amount);
        depositToken.mint(depositor2, amount);

        vm.startPrank(depositor1);
        depositToken.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();

        vm.startPrank(depositor2);
        depositToken.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();

        // Books now match the real (net) balance held by the vault.
        assertEq(vault.totalDeposited(), 2 * net, "credits measured delta, not requested");
        assertEq(vault.deposited(depositor1), net);
        assertEq(depositToken.balanceOf(address(vault)), vault.totalDeposited(), "vault is solvent");

        vm.warp(vault.lockExpiry() + 1);

        // Both withdrawals succeed — no last-withdrawer insolvency.
        vm.prank(depositor1);
        vault.withdrawDepositToken();
        vm.prank(depositor2);
        vault.withdrawDepositToken();

        assertEq(depositToken.balanceOf(address(vault)), 0, "vault fully drained, no shortfall");
    }

    // Finding #3 — depositToken == launched token is rejected at initialization.
    function test_fix_depositTokenEqualsLaunchToken_reverts() public {
        MockERC20 sharedToken = new MockERC20();
        ComputePresaleVault vault = new ComputePresaleVault(
            address(liquidFactory), address(sharedToken), agentWallet, 0, DEPOSIT_WINDOW
        );

        sharedToken.mint(address(liquidFactory), TOKEN_SUPPLY);
        vm.prank(address(liquidFactory));
        vm.expectRevert(ComputePresaleVault.DepositTokenCollision.selector);
        liquidFactory.bootstrapVault(address(vault), address(sharedToken), TOKEN_SUPPLY);

        assertFalse(vault.initialized(), "vault never initializes on collision");
    }

    // Finding #4 — salt front-run can no longer brick a victim's launch address.
    function test_fix_saltFrontRun_doesNotBrick() public {
        ComputePresaleFactory factory = new ComputePresaleFactory();
        address depositTok = address(new MockERC20());
        address junkDepositTok = address(new MockERC20());

        bytes32 salt = factory.buildSalt(victim, 1);
        address predicted = factory.computeAddress(
            victim, salt, address(liquidFactory), depositTok, victim, 0, DEPOSIT_WINDOW
        );
        assertEq(predicted.code.length, 0, "nothing deployed yet");

        // Attacker front-runs with the SAME salt — but it is namespaced to the attacker.
        vm.prank(attacker);
        address attackerVault = factory.deployVault(
            salt, address(liquidFactory), junkDepositTok, attacker, 0, DEPOSIT_WINDOW
        );
        assertTrue(attackerVault != predicted, "attacker cannot occupy victim's address");

        // Victim's own deploy still succeeds and lands at the precomputed address.
        vm.prank(victim);
        address victimVault = factory.deployVault(
            salt, address(liquidFactory), depositTok, victim, 0, DEPOSIT_WINDOW
        );
        assertEq(victimVault, predicted, "victim deploys at the address it committed to");
        assertGt(predicted.code.length, 0, "victim launch address is live (not bricked)");
    }
}
