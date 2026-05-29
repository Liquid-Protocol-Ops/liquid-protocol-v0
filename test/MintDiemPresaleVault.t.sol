// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MintDiemPresaleVault} from "../src/extensions/MintDiemPresaleVault.sol";
import {ILiquid} from "../src/interfaces/ILiquid.sol";
import {ILiquidExtension} from "../src/interfaces/ILiquidExtension.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Test} from "forge-std/Test.sol";

// ── Mocks ─────────────────────────────────────────────────────────────────────

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Factory simulates Liquid Protocol factory calling receiveTokens.
contract MockFactory {
    function callReceiveTokens(address vault, address _token, uint256 supply) external {
        IERC20(_token).approve(vault, supply);
        ILiquid.DeploymentConfig memory cfg;
        PoolKey memory key;
        ILiquidExtension(vault).receiveTokens(cfg, key, _token, supply, 0);
    }
}

/// @dev Staking mock: tracks sVVV balances and hosts mintDiem (real: on VVV_STAKING proxy).
/// Mock rate: 0.1 DIEM per sVVV. Real rate on Base mainnet (2026-05): ~0.00141 DIEM/sVVV
/// (getDiemAmountOut(1e18) ≈ 1.41e15 on 0x321b7ff...). For 100 DIEM at real rate: ~70,884 VVV.
contract StakingMock {
    mapping(address => uint256) public balanceOf;
    address public vvv;
    MockERC20 public diemMock;
    uint256 constant RATE = 1e17; // 0.1 DIEM per sVVV

    constructor(MockERC20 _diem) {
        diemMock = _diem;
    }

    function setVvv(address _vvv) external {
        vvv = _vvv;
    }

    function stake(address staker, uint256 amount) external {
        IERC20(vvv).transferFrom(msg.sender, address(this), amount);
        balanceOf[staker] += amount;
    }

    /// @dev Mirrors VVV_STAKING.mintDiem: burns sVVV from msg.sender, mints DIEM.
    function mintDiem(uint256 sVVVAmountToLock, uint256 minDiemAmountOut) external {
        require(balanceOf[msg.sender] >= sVVVAmountToLock, "insufficient sVVV");
        balanceOf[msg.sender] -= sVVVAmountToLock;
        uint256 diemOut = sVVVAmountToLock * RATE / 1e18;
        require(diemOut >= minDiemAmountOut, "slippage");
        diemMock.mint(msg.sender, diemOut);
    }

    function getDiemAmountOut(uint256 sVvvAmount) external pure returns (uint256) {
        return sVvvAmount * RATE / 1e18;
    }
}

/// @dev Plain VVV ERC-20 mock — no mintDiem (matches real VVV token).
contract VVVMock is ERC20 {
    constructor() ERC20("VVV", "VVV") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ── Base test contract ────────────────────────────────────────────────────────

abstract contract BaseTest is Test {
    StakingMock stakingMock;
    VVVMock vvvMock;
    MockERC20 diemMock;
    MockERC20 agentToken;
    MockFactory factory;

    MintDiemPresaleVault vault;
    address agentWallet = makeAddr("agent");
    address protocolAddr = makeAddr("protocol");

    // 24h default window; MIN is 2h enforced in contract
    uint256 constant DEPOSIT_WINDOW = 24 hours;
    uint256 constant DIEM_TARGET = 100e18;
    uint256 constant EXTENSION_BPS = 1000; // 10%
    uint256 constant TOTAL_SUPPLY = 100_000_000_000e18; // 100B
    uint256 constant EXTENSION_SUPPLY = TOTAL_SUPPLY * EXTENSION_BPS / 10_000; // 10B

    // 1000 VVV → 100 DIEM at mock rate 0.1 DIEM/VVV = exactly diemTarget
    uint256 constant VVV_FOR_MAX = 1000e18;

    function setUp() public virtual {
        diemMock = new MockERC20("DIEM", "DIEM");
        stakingMock = new StakingMock(diemMock);
        vvvMock = new VVVMock();
        stakingMock.setVvv(address(vvvMock));
        agentToken = new MockERC20("AgentToken", "AGT");
        factory = new MockFactory();

        agentToken.mint(address(factory), EXTENSION_SUPPLY);

        vault = new MintDiemPresaleVault(
            address(vvvMock),
            address(stakingMock),
            address(diemMock),
            agentWallet,
            DIEM_TARGET,
            DEPOSIT_WINDOW,
            address(factory),
            protocolAddr,
            0 // protocolFeeBps = 0 for baseline tests
        );
    }

    function _initVault() internal {
        factory.callReceiveTokens(address(vault), address(agentToken), EXTENSION_SUPPLY);
    }

    function _giveVvv(address to, uint256 amount) internal {
        vvvMock.mint(to, amount);
        vm.prank(to);
        vvvMock.approve(address(vault), amount);
    }

    function _giveDiem(address to, uint256 amount) internal {
        diemMock.mint(to, amount);
        vm.prank(to);
        diemMock.approve(address(vault), amount);
    }

    function _deposit(address depositor, uint256 vvvAmount) internal {
        vm.prank(depositor);
        vault.deposit(vvvAmount, 0);
    }

    function _depositDIEM(address depositor, uint256 diemAmount) internal {
        vm.prank(depositor);
        vault.depositDIEM(diemAmount);
    }

    // 0.1 DIEM per VVV at mock rate
    function _diem(uint256 vvv_) internal pure returns (uint256) {
        return vvv_ * 1e17 / 1e18;
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

contract MintDiemPresaleVault_Init is BaseTest {
    function test_notInitializedBeforeReceiveTokens() public view {
        assertEq(vault.token(), address(0));
        assertEq(vault.depositDeadline(), 0);
    }

    function test_receiveTokens_setsState() public {
        _initVault();
        assertEq(vault.token(), address(agentToken));
        assertEq(vault.extensionSupply(), EXTENSION_SUPPLY);
        assertEq(vault.depositDeadline(), block.timestamp + DEPOSIT_WINDOW);
    }

    function test_receiveTokens_vaultHoldsTokens() public {
        _initVault();
        assertEq(agentToken.balanceOf(address(vault)), EXTENSION_SUPPLY);
    }

    function test_cannotReinitialize() public {
        _initVault();
        vm.expectRevert("Already initialized");
        factory.callReceiveTokens(address(vault), address(agentToken), EXTENSION_SUPPLY);
    }

    function test_receiveTokens_revertsIfNotFactory() public {
        ILiquid.DeploymentConfig memory cfg;
        PoolKey memory key;
        agentToken.mint(address(this), EXTENSION_SUPPLY);
        agentToken.approve(address(vault), EXTENSION_SUPPLY);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(MintDiemPresaleVault.NotFactory.selector);
        vault.receiveTokens(cfg, key, address(agentToken), EXTENSION_SUPPLY, 0);
    }

    function test_constructor_revertsWindowTooShort() public {
        vm.expectRevert(MintDiemPresaleVault.InvalidDepositWindow.selector);
        new MintDiemPresaleVault(
            address(vvvMock),
            address(stakingMock),
            address(diemMock),
            agentWallet,
            DIEM_TARGET,
            1 hours, // below 2h minimum
            address(factory),
            protocolAddr,
            0
        );
    }

    function test_constructor_acceptsMinWindow() public {
        MintDiemPresaleVault v = new MintDiemPresaleVault(
            address(vvvMock),
            address(stakingMock),
            address(diemMock),
            agentWallet,
            DIEM_TARGET,
            2 hours, // exactly at minimum
            address(factory),
            protocolAddr,
            0
        );
        assertEq(v.depositWindow(), 2 hours);
    }

    function test_supportsInterface() public view {
        assertTrue(vault.supportsInterface(type(ILiquidExtension).interfaceId));
    }
}

contract MintDiemPresaleVault_VvvDeposit is BaseTest {
    address depositor = makeAddr("depositor");

    function setUp() public override {
        super.setUp();
        _initVault();
    }

    function test_deposit_stakesVvvAndMintsToAgent() public {
        uint256 vvvAmount = 100e18;
        _giveVvv(depositor, vvvAmount);
        _deposit(depositor, vvvAmount);

        assertEq(diemMock.balanceOf(agentWallet), _diem(vvvAmount));
        assertEq(vault.vvvDeposited(depositor), vvvAmount);
        assertEq(vault.diemContributed(depositor), _diem(vvvAmount));
        assertEq(vault.totalVvvDeposited(), vvvAmount);
        assertEq(vault.totalDiemMinted(), _diem(vvvAmount));
    }

    function test_deposit_revertsBeforeInit() public {
        MintDiemPresaleVault uninit = new MintDiemPresaleVault(
            address(vvvMock),
            address(stakingMock),
            address(diemMock),
            agentWallet,
            DIEM_TARGET,
            DEPOSIT_WINDOW,
            address(factory),
            protocolAddr,
            0
        );
        _giveVvv(depositor, 1e18);
        vm.prank(depositor);
        vm.expectRevert(MintDiemPresaleVault.NotInitialized.selector);
        uninit.deposit(1e18, 0);
    }

    function test_deposit_revertsAfterDeadline() public {
        _giveVvv(depositor, 1e18);
        vm.warp(block.timestamp + DEPOSIT_WINDOW + 1);
        vm.prank(depositor);
        vm.expectRevert(MintDiemPresaleVault.DepositWindowClosed.selector);
        vault.deposit(1e18, 0);
    }

    function test_deposit_revertsOnZeroAmount() public {
        vm.prank(depositor);
        vm.expectRevert(MintDiemPresaleVault.ZeroDeposit.selector);
        vault.deposit(0, 0);
    }

    function test_deposit_revertsWhenCapReached() public {
        _giveVvv(depositor, VVV_FOR_MAX);
        _deposit(depositor, VVV_FOR_MAX);

        address latecomer = makeAddr("latecomer");
        _giveVvv(latecomer, 1e18);
        vm.prank(latecomer);
        vm.expectRevert(MintDiemPresaleVault.DiemTargetReached.selector);
        vault.deposit(1e18, 0);
    }

    function test_deposit_revertsWhenWouldExceedCap() public {
        // 900 VVV → 90 DIEM; 10 DIEM remain. 200 VVV → preview 20 DIEM → exceeds cap.
        _giveVvv(depositor, 900e18);
        _deposit(depositor, 900e18);

        address latecomer = makeAddr("latecomer");
        _giveVvv(latecomer, 200e18);
        vm.prank(latecomer);
        vm.expectRevert(MintDiemPresaleVault.WouldExceedCap.selector);
        vault.deposit(200e18, 0);
    }

    function test_multipleDepositors() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _giveVvv(alice, 200e18);
        _giveVvv(bob, 100e18);
        _deposit(alice, 200e18);
        _deposit(bob, 100e18);

        assertEq(vault.totalVvvDeposited(), 300e18);
        assertEq(vault.totalDiemMinted(), _diem(300e18));
        assertEq(diemMock.balanceOf(agentWallet), _diem(300e18));
    }

    function test_remainingCapacity_decreasesOnDeposit() public {
        assertEq(vault.remainingCapacity(), DIEM_TARGET);
        _giveVvv(depositor, 100e18);
        _deposit(depositor, 100e18);
        assertEq(vault.remainingCapacity(), DIEM_TARGET - _diem(100e18));
    }
}

contract MintDiemPresaleVault_DiemDeposit is BaseTest {
    address depositor = makeAddr("depositor");

    function setUp() public override {
        super.setUp();
        _initVault();
    }

    function test_depositDIEM_routesToAgent() public {
        uint256 amount = 10e18;
        _giveDiem(depositor, amount);
        _depositDIEM(depositor, amount);

        assertEq(diemMock.balanceOf(agentWallet), amount);
        assertEq(vault.diemDeposited(depositor), amount);
        assertEq(vault.diemContributed(depositor), amount);
        assertEq(vault.totalDiemMinted(), amount);
    }

    function test_depositDIEM_revertsBeforeInit() public {
        MintDiemPresaleVault uninit = new MintDiemPresaleVault(
            address(vvvMock),
            address(stakingMock),
            address(diemMock),
            agentWallet,
            DIEM_TARGET,
            DEPOSIT_WINDOW,
            address(factory),
            protocolAddr,
            0
        );
        _giveDiem(depositor, 1e18);
        vm.prank(depositor);
        vm.expectRevert(MintDiemPresaleVault.NotInitialized.selector);
        uninit.depositDIEM(1e18);
    }

    function test_depositDIEM_revertsAfterDeadline() public {
        _giveDiem(depositor, 1e18);
        vm.warp(block.timestamp + DEPOSIT_WINDOW + 1);
        vm.prank(depositor);
        vm.expectRevert(MintDiemPresaleVault.DepositWindowClosed.selector);
        vault.depositDIEM(1e18);
    }

    function test_depositDIEM_revertsOnZero() public {
        vm.prank(depositor);
        vm.expectRevert(MintDiemPresaleVault.ZeroDeposit.selector);
        vault.depositDIEM(0);
    }

    function test_depositDIEM_revertsWhenCapReached() public {
        // Fill cap with VVV first
        _giveVvv(depositor, VVV_FOR_MAX);
        _deposit(depositor, VVV_FOR_MAX);

        address latecomer = makeAddr("latecomer");
        _giveDiem(latecomer, 1e18);
        vm.prank(latecomer);
        vm.expectRevert(MintDiemPresaleVault.DiemTargetReached.selector);
        vault.depositDIEM(1e18);
    }

    function test_depositDIEM_revertsWhenWouldExceedCap() public {
        // 90 DIEM used directly; 10 remain; 20 DIEM deposit would exceed cap
        _giveDiem(depositor, 90e18);
        _depositDIEM(depositor, 90e18);

        address latecomer = makeAddr("latecomer");
        _giveDiem(latecomer, 20e18);
        vm.prank(latecomer);
        vm.expectRevert(MintDiemPresaleVault.WouldExceedCap.selector);
        vault.depositDIEM(20e18);
    }

    function test_depositDIEM_countsTowardCap() public {
        _giveDiem(depositor, 50e18);
        _depositDIEM(depositor, 50e18);
        assertEq(vault.remainingCapacity(), 50e18);
    }
}

contract MintDiemPresaleVault_MixedDeposits is BaseTest {
    function setUp() public override {
        super.setUp();
        _initVault();
    }

    function test_mixedDeposits_equalDiemValue_equalShares() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        // Alice deposits 100 VVV → 10 DIEM equivalent
        _giveVvv(alice, 100e18);
        _deposit(alice, 100e18);

        // Bob deposits 10 DIEM directly
        _giveDiem(bob, 10e18);
        _depositDIEM(bob, 10e18);

        // Both contributed 10 DIEM → equal shares
        assertApproxEqRel(vault.getShare(alice), vault.getShare(bob), 0.01e18);
    }

    function test_mixedDeposits_proportionalShares() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        // Alice: 200 VVV → 20 DIEM. Bob: 10 DIEM direct. Total: 30 DIEM.
        _giveVvv(alice, 200e18);
        _deposit(alice, 200e18);
        _giveDiem(bob, 10e18);
        _depositDIEM(bob, 10e18);

        uint256 effective = vault.effectiveAllocation();
        // Alice: 20/30 = 2/3; Bob: 10/30 = 1/3
        assertApproxEqRel(vault.getShare(alice), effective * 2 / 3, 0.01e18);
        assertApproxEqRel(vault.getShare(bob), effective / 3, 0.01e18);
    }

    function test_mixedDeposits_capEnforcedAcrossBothPaths() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        // Alice deposits 50 DIEM directly; 50 remain
        _giveDiem(alice, 50e18);
        _depositDIEM(alice, 50e18);
        assertEq(vault.remainingCapacity(), 50e18);

        // Bob tries 600 VVV → 60 DIEM preview → exceeds remaining 50 DIEM cap
        _giveVvv(bob, 600e18);
        vm.prank(bob);
        vm.expectRevert(MintDiemPresaleVault.WouldExceedCap.selector);
        vault.deposit(600e18, 0);

        // Bob deposits exactly 500 VVV → 50 DIEM → fills cap
        _giveVvv(bob, 500e18);
        _deposit(bob, 500e18);
        assertEq(vault.remainingCapacity(), 0);
    }
}

contract MintDiemPresaleVault_Allocation is BaseTest {
    function setUp() public override {
        super.setUp();
        _initVault();
    }

    function test_fullAllocation_at100Diem_vvv() public {
        address depositor = makeAddr("depositor");
        _giveVvv(depositor, VVV_FOR_MAX);
        _deposit(depositor, VVV_FOR_MAX);
        assertApproxEqRel(vault.effectiveAllocation(), EXTENSION_SUPPLY, 0.01e18);
    }

    function test_fullAllocation_at100Diem_directDiem() public {
        address depositor = makeAddr("depositor");
        _giveDiem(depositor, 100e18);
        _depositDIEM(depositor, 100e18);
        assertEq(vault.effectiveAllocation(), EXTENSION_SUPPLY);
    }

    function test_partialAllocation_at10Percent() public {
        address depositor = makeAddr("depositor");
        _giveVvv(depositor, 100e18); // 100 VVV → 10 DIEM → 10% of target
        _deposit(depositor, 100e18);
        assertApproxEqRel(vault.effectiveAllocation(), EXTENSION_SUPPLY / 10, 0.02e18);
    }

    function test_getShare_singleDepositor() public {
        address depositor = makeAddr("depositor");
        _giveVvv(depositor, 200e18);
        _deposit(depositor, 200e18);
        assertEq(vault.getShare(depositor), vault.effectiveAllocation());
    }

    function test_getShare_twoDepositors_proportional() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _giveVvv(alice, 100e18); // 10 DIEM → 1/3
        _giveVvv(bob, 200e18); // 20 DIEM → 2/3
        _deposit(alice, 100e18);
        _deposit(bob, 200e18);

        uint256 effective = vault.effectiveAllocation();
        assertApproxEqRel(vault.getShare(alice), effective / 3, 0.01e18);
        assertApproxEqRel(vault.getShare(bob), effective * 2 / 3, 0.01e18);
    }

    function test_zeroShare_noDeposit() public {
        assertEq(vault.getShare(makeAddr("nobody")), 0);
    }
}

contract MintDiemPresaleVault_Claim is BaseTest {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();
        _initVault();
        _giveVvv(alice, 100e18);
        _giveVvv(bob, 200e18);
        _deposit(alice, 100e18);
        _deposit(bob, 200e18);
        vm.warp(block.timestamp + DEPOSIT_WINDOW + 1);
    }

    function test_claimTokens_transfersCorrectShare() public {
        uint256 aliceShare = vault.getShare(alice);
        vm.prank(alice);
        vault.claimTokens();
        assertEq(agentToken.balanceOf(alice), aliceShare);
    }

    function test_claimTokens_bothDepositors() public {
        uint256 aliceShare = vault.getShare(alice);
        uint256 bobShare = vault.getShare(bob);
        vm.prank(alice);
        vault.claimTokens();
        vm.prank(bob);
        vault.claimTokens();
        assertEq(agentToken.balanceOf(alice), aliceShare);
        assertEq(agentToken.balanceOf(bob), bobShare);
    }

    function test_claimTokens_revertsIfWindowOpen() public {
        // freshVault uses address(this) as factory so receiveTokens can be called directly
        MintDiemPresaleVault freshVault = new MintDiemPresaleVault(
            address(vvvMock),
            address(stakingMock),
            address(diemMock),
            agentWallet,
            DIEM_TARGET,
            DEPOSIT_WINDOW,
            address(this),
            protocolAddr,
            0
        );
        agentToken.mint(address(this), EXTENSION_SUPPLY);
        agentToken.approve(address(freshVault), EXTENSION_SUPPLY);
        ILiquid.DeploymentConfig memory cfg;
        PoolKey memory key;
        freshVault.receiveTokens(cfg, key, address(agentToken), EXTENSION_SUPPLY, 0);

        vm.expectRevert(MintDiemPresaleVault.DepositWindowOpen.selector);
        freshVault.claimTokens();
    }

    function test_claimTokens_revertsDoubleClaim() public {
        vm.prank(alice);
        vault.claimTokens();
        vm.prank(alice);
        vm.expectRevert(MintDiemPresaleVault.AlreadyClaimed.selector);
        vault.claimTokens();
    }

    function test_claimTokens_revertsNonDepositor() public {
        vm.prank(makeAddr("nobody"));
        vm.expectRevert(MintDiemPresaleVault.NothingToMint.selector);
        vault.claimTokens();
    }

    function test_claimTokens_diemDepositor() public {
        // Set up a separate vault where bob deposits DIEM instead of VVV
        MintDiemPresaleVault freshVault = new MintDiemPresaleVault(
            address(vvvMock),
            address(stakingMock),
            address(diemMock),
            agentWallet,
            DIEM_TARGET,
            DEPOSIT_WINDOW,
            address(this),
            protocolAddr,
            0
        );
        agentToken.mint(address(this), EXTENSION_SUPPLY);
        agentToken.approve(address(freshVault), EXTENSION_SUPPLY);
        ILiquid.DeploymentConfig memory cfg;
        PoolKey memory key;
        freshVault.receiveTokens(cfg, key, address(agentToken), EXTENSION_SUPPLY, 0);

        diemMock.mint(bob, 10e18);
        vm.prank(bob);
        diemMock.approve(address(freshVault), 10e18);
        vm.prank(bob);
        freshVault.depositDIEM(10e18);

        vm.warp(block.timestamp + DEPOSIT_WINDOW + 1);
        vm.prank(bob);
        freshVault.claimTokens();
        // Bob contributed 10 DIEM → 10% of EXTENSION_SUPPLY
        assertApproxEqRel(agentToken.balanceOf(bob), EXTENSION_SUPPLY / 10, 0.02e18);
    }
}

contract MintDiemPresaleVault_Burn is BaseTest {
    function setUp() public override {
        super.setUp();
        _initVault();
    }

    function test_burnUnclaimed_partialPresale() public {
        address depositor = makeAddr("depositor");
        _giveVvv(depositor, 500e18); // 50 DIEM = 50% of target
        _deposit(depositor, 500e18);
        vm.warp(block.timestamp + DEPOSIT_WINDOW + 1);

        uint256 effective = vault.effectiveAllocation();
        uint256 expectedBurn = EXTENSION_SUPPLY - effective;
        vault.burnUnclaimed();
        assertEq(agentToken.balanceOf(address(0xdead)), expectedBurn);
    }

    function test_burnUnclaimed_fullPresale_noBurn() public {
        address depositor = makeAddr("depositor");
        _giveVvv(depositor, VVV_FOR_MAX);
        _deposit(depositor, VVV_FOR_MAX);
        vm.warp(block.timestamp + DEPOSIT_WINDOW + 1);
        vault.burnUnclaimed();
        assertLt(agentToken.balanceOf(address(0xdead)), EXTENSION_SUPPLY / 100);
    }

    function test_burnUnclaimed_idempotent() public {
        vm.warp(block.timestamp + DEPOSIT_WINDOW + 1);
        vault.burnUnclaimed();
        uint256 burned = agentToken.balanceOf(address(0xdead));
        vault.burnUnclaimed();
        assertEq(agentToken.balanceOf(address(0xdead)), burned);
    }

    function test_burnUnclaimed_revertsIfWindowOpen() public {
        vm.expectRevert(MintDiemPresaleVault.DepositWindowOpen.selector);
        vault.burnUnclaimed();
    }
}

contract MintDiemPresaleVault_ProtocolFee is BaseTest {
    MintDiemPresaleVault feeVault;
    uint256 constant FEE_BPS = 200; // 2%

    function setUp() public override {
        super.setUp();
        feeVault = new MintDiemPresaleVault(
            address(vvvMock),
            address(stakingMock),
            address(diemMock),
            agentWallet,
            DIEM_TARGET,
            DEPOSIT_WINDOW,
            address(factory),
            protocolAddr,
            FEE_BPS
        );
        factory.callReceiveTokens(address(feeVault), address(agentToken), EXTENSION_SUPPLY);
    }

    function test_vvvDeposit_splitsFee() public {
        address depositor = makeAddr("depositor");
        uint256 vvvAmount = 100e18;
        vvvMock.mint(depositor, vvvAmount);
        vm.prank(depositor);
        vvvMock.approve(address(feeVault), vvvAmount);
        vm.prank(depositor);
        feeVault.deposit(vvvAmount, 0);

        uint256 diemMinted = _diem(vvvAmount); // 10e18
        uint256 fee = diemMinted * FEE_BPS / 10_000; // 0.2e18
        assertEq(diemMock.balanceOf(protocolAddr), fee);
        assertEq(diemMock.balanceOf(agentWallet), diemMinted - fee);
    }

    function test_diemDeposit_splitsFee() public {
        address depositor = makeAddr("depositor");
        uint256 diemAmount = 10e18;
        diemMock.mint(depositor, diemAmount);
        vm.prank(depositor);
        diemMock.approve(address(feeVault), diemAmount);
        vm.prank(depositor);
        feeVault.depositDIEM(diemAmount);

        uint256 fee = diemAmount * FEE_BPS / 10_000; // 0.2e18
        assertEq(diemMock.balanceOf(protocolAddr), fee);
        assertEq(diemMock.balanceOf(agentWallet), diemAmount - fee);
    }

    function test_totalDiemMinted_isGross() public {
        address depositor = makeAddr("depositor");
        uint256 vvvAmount = 100e18;
        vvvMock.mint(depositor, vvvAmount);
        vm.prank(depositor);
        vvvMock.approve(address(feeVault), vvvAmount);
        vm.prank(depositor);
        feeVault.deposit(vvvAmount, 0);
        // totalDiemMinted tracks gross DIEM (drives allocation formula)
        assertEq(feeVault.totalDiemMinted(), _diem(vvvAmount));
    }
}

contract MintDiemPresaleVault_RateCalc is BaseTest {
    function test_vvvRequired_for100Diem() public pure {
        uint256 rate = 1e17; // 0.1 DIEM per sVVV (mock)
        uint256 diemWant = 100e18;
        uint256 vvvNeeded = diemWant * 1e18 / rate; // 1000 VVV
        assertEq(vvvNeeded, 1000e18);
    }

    function test_allocationFormula_10PercentPresale() public {
        _initVault();
        address depositor = makeAddr("depositor");
        _giveVvv(depositor, 100e18); // 100 VVV → 10 DIEM → 10% of target
        _deposit(depositor, 100e18);

        assertApproxEqRel(vault.effectiveAllocation(), EXTENSION_SUPPLY / 10, 0.02e18);
        assertApproxEqRel(vault.getShare(depositor), EXTENSION_SUPPLY / 10, 0.02e18);
    }

    function test_depositWindow_defaultIs24h() public view {
        assertEq(vault.depositWindow(), 24 hours);
    }

    function test_depositWindow_minimum2h() public view {
        assertEq(vault.MIN_DEPOSIT_WINDOW(), 2 hours);
    }
}
