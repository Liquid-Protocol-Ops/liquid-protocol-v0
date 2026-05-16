// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MintDiemPresaleVault} from "../src/extensions/MintDiemPresaleVault.sol";
import {ILiquid} from "../src/interfaces/ILiquid.sol";
import {ILiquidExtension} from "../src/interfaces/ILiquidExtension.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

// ── Mocks ─────────────────────────────────────────────────────────────────────

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
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
    uint256 constant RATE = 1e17; // mock: 0.1 DIEM per sVVV (1e17 wei DIEM per 1e18 wei sVVV)

    constructor(MockERC20 _diem) { diemMock = _diem; }

    function setVvv(address _vvv) external { vvv = _vvv; }

    function stake(address staker, uint256 amount) external {
        IERC20(vvv).transferFrom(msg.sender, address(this), amount);
        balanceOf[staker] += amount;
    }

    /// @dev Mirrors VVV_STAKING.mintDiem(uint256,uint256): burns sVVV from msg.sender, mints DIEM.
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
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

// ── Base test contract ────────────────────────────────────────────────────────

abstract contract BaseTest is Test {
    StakingMock    stakingMock;
    VVVMock        vvvMock;
    MockERC20      diemMock;
    MockERC20      agentToken;
    MockFactory    factory;

    MintDiemPresaleVault vault;
    address agentWallet  = makeAddr("agent");
    address protocolAddr = makeAddr("protocol");

    uint256 constant DEPOSIT_WINDOW   = 7 days;
    uint256 constant DIEM_TARGET      = 100e18;
    uint256 constant EXTENSION_BPS    = 1000;               // 10%
    uint256 constant TOTAL_SUPPLY     = 100_000_000_000e18; // 100B
    uint256 constant EXTENSION_SUPPLY = TOTAL_SUPPLY * EXTENSION_BPS / 10_000; // 10B

    // 1000 VVV → 100 DIEM at mock rate 0.1 DIEM/VVV = exactly diemTarget
    uint256 constant VVV_FOR_MAX = 1000e18;

    function setUp() public virtual {
        diemMock    = new MockERC20("DIEM", "DIEM");
        stakingMock = new StakingMock(diemMock);
        vvvMock     = new VVVMock();
        stakingMock.setVvv(address(vvvMock));
        agentToken  = new MockERC20("AgentToken", "AGT");
        factory     = new MockFactory();

        agentToken.mint(address(factory), EXTENSION_SUPPLY);

        vault = new MintDiemPresaleVault(
            address(vvvMock),
            address(stakingMock),
            address(diemMock),
            agentWallet,
            DIEM_TARGET,
            DEPOSIT_WINDOW,
            address(factory),   // only factory may call receiveTokens
            protocolAddr,       // autonomopoly fee recipient
            0                   // protocolFeeBps = 0 for baseline tests
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

    function _deposit(address depositor, uint256 vvvAmount) internal {
        vm.prank(depositor);
        vault.deposit(vvvAmount, 0);
    }

    function _diem(uint256 vvv_) internal pure returns (uint256) {
        return vvv_ * 1e17 / 1e18; // 0.1 DIEM per VVV (mock rate)
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

    function test_supportsInterface() public view {
        assertTrue(vault.supportsInterface(type(ILiquidExtension).interfaceId));
    }
}

contract MintDiemPresaleVault_Deposit is BaseTest {
    address depositor = makeAddr("depositor");

    function setUp() public override {
        super.setUp();
        _initVault();
    }

    function test_deposit_stakesVvvAndMintsToAgent() public {
        uint256 vvvAmount = 100e18;
        _giveVvv(depositor, vvvAmount);
        _deposit(depositor, vvvAmount);

        // Agent wallet received DIEM (protocolFeeBps = 0, so full amount)
        assertEq(diemMock.balanceOf(agentWallet), _diem(vvvAmount));
        assertEq(vault.vvvDeposited(depositor), vvvAmount);
        assertEq(vault.totalVvvDeposited(), vvvAmount);
        assertEq(vault.totalDiemMinted(), _diem(vvvAmount));
    }

    function test_deposit_revertsBeforeInit() public {
        MintDiemPresaleVault uninit = new MintDiemPresaleVault(
            address(vvvMock), address(stakingMock), address(diemMock),
            agentWallet, DIEM_TARGET, DEPOSIT_WINDOW,
            address(factory), protocolAddr, 0
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
        address bob   = makeAddr("bob");
        _giveVvv(alice, 200e18);
        _giveVvv(bob,   100e18);
        _deposit(alice, 200e18);
        _deposit(bob,   100e18);

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

contract MintDiemPresaleVault_Allocation is BaseTest {
    function setUp() public override {
        super.setUp();
        _initVault();
    }

    function test_fullAllocation_at100Diem() public {
        address depositor = makeAddr("depositor");
        _giveVvv(depositor, VVV_FOR_MAX);
        _deposit(depositor, VVV_FOR_MAX);

        uint256 effective = vault.effectiveAllocation();
        assertApproxEqRel(effective, EXTENSION_SUPPLY, 0.01e18);
    }

    function test_partialAllocation_at10Percent() public {
        address depositor = makeAddr("depositor");
        uint256 vvvFor10Diem = 100e18; // 100 VVV → 10 DIEM at 0.1 rate
        _giveVvv(depositor, vvvFor10Diem);
        _deposit(depositor, vvvFor10Diem);

        uint256 effective = vault.effectiveAllocation();
        assertApproxEqRel(effective, EXTENSION_SUPPLY / 10, 0.02e18);
    }

    function test_getShare_singleDepositor() public {
        address depositor = makeAddr("depositor");
        _giveVvv(depositor, 200e18);
        _deposit(depositor, 200e18);

        uint256 share     = vault.getShare(depositor);
        uint256 effective = vault.effectiveAllocation();
        assertEq(share, effective);
    }

    function test_getShare_twoDepositors_proportional() public {
        address alice = makeAddr("alice");
        address bob   = makeAddr("bob");
        _giveVvv(alice, 100e18); // 1/3 of total
        _giveVvv(bob,   200e18); // 2/3 of total
        _deposit(alice, 100e18);
        _deposit(bob,   200e18);

        uint256 effective = vault.effectiveAllocation();
        assertApproxEqRel(vault.getShare(alice), effective / 3,     0.01e18);
        assertApproxEqRel(vault.getShare(bob),   effective * 2 / 3, 0.01e18);
    }

    function test_zeroShare_noDeposit() public {
        address nobody = makeAddr("nobody");
        assertEq(vault.getShare(nobody), 0);
    }
}

contract MintDiemPresaleVault_Claim is BaseTest {
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    function setUp() public override {
        super.setUp();
        _initVault();
        _giveVvv(alice, 100e18);
        _giveVvv(bob,   200e18);
        _deposit(alice, 100e18);
        _deposit(bob,   200e18);
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
        uint256 bobShare   = vault.getShare(bob);

        vm.prank(alice); vault.claimTokens();
        vm.prank(bob);   vault.claimTokens();

        assertEq(agentToken.balanceOf(alice), aliceShare);
        assertEq(agentToken.balanceOf(bob),   bobShare);
    }

    function test_claimTokens_revertsIfWindowOpen() public {
        // freshVault uses address(this) as factory so receiveTokens can be called directly
        MintDiemPresaleVault freshVault = new MintDiemPresaleVault(
            address(vvvMock), address(stakingMock), address(diemMock),
            agentWallet, DIEM_TARGET, DEPOSIT_WINDOW,
            address(this),  // factory = test contract
            protocolAddr, 0
        );
        agentToken.mint(address(this), EXTENSION_SUPPLY);
        agentToken.approve(address(freshVault), EXTENSION_SUPPLY);
        ILiquid.DeploymentConfig memory cfg; PoolKey memory key;
        freshVault.receiveTokens(cfg, key, address(agentToken), EXTENSION_SUPPLY, 0);

        vm.expectRevert(MintDiemPresaleVault.DepositWindowOpen.selector);
        freshVault.claimTokens();
    }

    function test_claimTokens_revertsDoubleCllaim() public {
        vm.prank(alice);
        vault.claimTokens();
        vm.prank(alice);
        vm.expectRevert(MintDiemPresaleVault.AlreadyClaimed.selector);
        vault.claimTokens();
    }

    function test_claimTokens_revertsNonDepositor() public {
        address nobody = makeAddr("nobody");
        vm.prank(nobody);
        vm.expectRevert(MintDiemPresaleVault.NothingToMint.selector);
        vault.claimTokens();
    }
}

contract MintDiemPresaleVault_Burn is BaseTest {
    function setUp() public override {
        super.setUp();
        _initVault();
    }

    function test_burnUnclaimed_partialPresale() public {
        address depositor = makeAddr("depositor");
        uint256 vvvFor50 = 500e18; // 500 VVV → 50 DIEM at 0.1 rate
        _giveVvv(depositor, vvvFor50);
        _deposit(depositor, vvvFor50);
        vm.warp(block.timestamp + DEPOSIT_WINDOW + 1);

        uint256 effective    = vault.effectiveAllocation();
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
        vault.burnUnclaimed(); // second call is no-op
        assertEq(agentToken.balanceOf(address(0xdead)), burned);
    }

    function test_burnUnclaimed_revertsIfWindowOpen() public {
        vm.expectRevert(MintDiemPresaleVault.DepositWindowOpen.selector);
        vault.burnUnclaimed();
    }
}

contract MintDiemPresaleVault_RateCalc is BaseTest {
    /// @notice Rate reference test — how much VVV to mint 100 DIEM at 0.1 DIEM/sVVV (mock rate).
    function test_vvvRequired_for100Diem() public pure {
        uint256 rate      = 1e17;    // 0.1 DIEM per sVVV (1:1 VVV:sVVV)
        uint256 diemWant  = 100e18;  // 100 DIEM target
        uint256 vvvNeeded = diemWant * 1e18 / rate; // = 1000 VVV
        assertEq(vvvNeeded, 1000e18);
    }

    /// @notice Verify allocation math: 10 DIEM minted → 10% of extension supply distributable.
    function test_allocationFormula_10PercentPresale() public {
        _initVault();
        address depositor = makeAddr("depositor");
        uint256 vvvFor10  = 100e18; // 100 VVV → 10 DIEM at 0.1 rate
        _giveVvv(depositor, vvvFor10);
        _deposit(depositor, vvvFor10);

        uint256 effective = vault.effectiveAllocation();
        assertApproxEqRel(effective, EXTENSION_SUPPLY / 10, 0.02e18);
        assertApproxEqRel(vault.getShare(depositor), EXTENSION_SUPPLY / 10, 0.02e18);
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
        // factory already holds EXTENSION_SUPPLY from super.setUp()
        factory.callReceiveTokens(address(feeVault), address(agentToken), EXTENSION_SUPPLY);
    }

    function test_protocolFee_splitOnDeposit() public {
        address depositor = makeAddr("depositor");
        uint256 vvvAmount = 100e18;
        vvvMock.mint(depositor, vvvAmount);
        vm.prank(depositor); vvvMock.approve(address(feeVault), vvvAmount);
        vm.prank(depositor); feeVault.deposit(vvvAmount, 0);

        uint256 diemMinted = _diem(vvvAmount);             // 10e18
        uint256 fee        = diemMinted * FEE_BPS / 10_000; // 0.2e18
        uint256 agentAmt   = diemMinted - fee;              // 9.8e18

        assertEq(diemMock.balanceOf(protocolAddr), fee,      "protocol fee");
        assertEq(diemMock.balanceOf(agentWallet),  agentAmt, "agent diem");
    }

    function test_protocolFee_totalDiemMintedIsGross() public {
        address depositor = makeAddr("depositor");
        uint256 vvvAmount = 100e18;
        vvvMock.mint(depositor, vvvAmount);
        vm.prank(depositor); vvvMock.approve(address(feeVault), vvvAmount);
        vm.prank(depositor); feeVault.deposit(vvvAmount, 0);

        // totalDiemMinted tracks gross (pre-fee) — drives allocation formula
        assertEq(feeVault.totalDiemMinted(), _diem(vvvAmount));
    }

}
