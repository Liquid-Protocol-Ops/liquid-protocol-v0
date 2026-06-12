// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ⚠ SUPERSEDED (2026-06-12, Linear MOG-497): the canonical Venice Agent Launchpad presale
// contract is LiquidPresaleVault (liquid-website repo, contracts/presale/). This contract is
// retained for tests/reference and must not be deployed for new launches.

import {ILiquid} from "../interfaces/ILiquid.sol";
import {ILiquidExtension} from "../interfaces/ILiquidExtension.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title ComputePresaleVault
/// @notice Two-mode presale vault for Venice Agent Launchpad.
///
///   VVV irrevocable mode (lockDuration == 0):
///     Depositors permanently transfer VVV; agent calls finalizeVVV() after the
///     deposit window closes to receive the VVV and stake it for sVVV → Venice key.
///
///   DIEM time-lock mode (lockDuration > 0):
///     Depositors lock DIEM for lockDuration seconds after the deposit window closes.
///     At lock expiry the DIEM is returned in full. Depositors earn a pro-rata share
///     of the token allocation as yield on the opportunity cost of their locked DIEM.
///
///   Both modes: 20% (or configured bps) of token supply distributed pro-rata
///   to depositors via claimTokens().
///
///   Deploy this contract BEFORE the Liquid Protocol token so its address can be
///   included in extensionConfigs. The factory calls receiveTokens() during deployToken(),
///   which opens the deposit window.
contract ComputePresaleVault is ReentrancyGuard, ILiquidExtension {
    using SafeERC20 for IERC20;

    // ── Immutable config ───────────────────────────────────────────────────

    ILiquid public immutable factory;
    IERC20 public immutable depositToken; // VVV (irrevocable) or DIEM (time-lock)
    address public immutable agentWallet; // receives VVV on finalizeVVV()
    uint256 public immutable lockDuration; // 0 = VVV irrevocable; >0 = DIEM lock seconds
    uint256 public immutable depositWindow; // seconds after receiveTokens until deposit window closes

    // ── State (set on receiveTokens) ───────────────────────────────────────

    address public token; // launched token address
    uint256 public totalTokenSupply; // extensionSupply received from factory
    uint256 public depositDeadline; // block.timestamp + depositWindow
    uint256 public lockExpiry; // depositDeadline + lockDuration (DIEM mode only)
    bool public initialized;

    // ── Deposit accounting ────────────────────────────────────────────────

    uint256 public totalDeposited;
    mapping(address => uint256) public deposited;
    mapping(address => bool) public tokensClaimed;
    mapping(address => bool) public depositTokenWithdrawn;

    // ── Errors ────────────────────────────────────────────────────────────

    error Unauthorized();
    error NotInitialized();
    error AlreadyInitialized();
    error DepositWindowClosed();
    error DepositWindowStillOpen();
    error LockNotExpired();
    error AlreadyClaimed();
    error AlreadyWithdrawn();
    error NothingDeposited();
    error NoDepositsInVault();
    error WrongMode();
    error DepositTokenCollision();
    error NothingReceived();

    // ── Events ────────────────────────────────────────────────────────────

    event VaultInitialized(address indexed token, uint256 tokenSupply, uint256 depositDeadline);
    event Deposited(address indexed depositor, uint256 amount, uint256 totalDeposited);
    event TokensClaimed(address indexed depositor, uint256 tokenAmount);
    event DepositTokenWithdrawn(address indexed depositor, uint256 amount);
    event VVVFinalized(address indexed agentWallet, uint256 vvvAmount);

    // ── Modifiers ─────────────────────────────────────────────────────────

    modifier onlyFactory() {
        if (msg.sender != address(factory)) revert Unauthorized();
        _;
    }

    modifier onlyInitialized() {
        if (!initialized) revert NotInitialized();
        _;
    }

    // ── Constructor ───────────────────────────────────────────────────────

    constructor(
        address factory_,
        address depositToken_,
        address agentWallet_,
        uint256 lockDuration_,
        uint256 depositWindow_
    ) {
        factory = ILiquid(factory_);
        depositToken = IERC20(depositToken_);
        agentWallet = agentWallet_;
        lockDuration = lockDuration_;
        depositWindow = depositWindow_;
    }

    // ── ILiquidExtension ──────────────────────────────────────────────────

    /// @notice Called by the Liquid factory during deployToken(). Opens the deposit window.
    function receiveTokens(
        ILiquid.DeploymentConfig calldata,
        PoolKey memory,
        address token_,
        uint256 extensionSupply,
        uint256
    ) external payable nonReentrant onlyFactory {
        if (initialized) revert AlreadyInitialized();
        if (msg.value != 0) revert InvalidMsgValue();
        // The launched token and the deposit token must be distinct: they are tracked by
        // separate accounting systems that both read this contract's balance. Sharing one
        // balance would let finalizeVVV()/withdrawDepositToken() sweep the claim allocation.
        if (token_ == address(depositToken)) revert DepositTokenCollision();

        // Credit the balance actually received rather than the requested amount, so a
        // fee-on-transfer / rebasing launched token cannot leave claims under-collateralized.
        uint256 balanceBefore = IERC20(token_).balanceOf(address(this));
        IERC20(token_).safeTransferFrom(msg.sender, address(this), extensionSupply);
        uint256 received = IERC20(token_).balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert NothingReceived();

        token = token_;
        totalTokenSupply = received;
        depositDeadline = block.timestamp + depositWindow;
        lockExpiry = depositDeadline + lockDuration;
        initialized = true;

        emit VaultInitialized(token_, received, depositDeadline);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ILiquidExtension).interfaceId;
    }

    // ── Deposit ───────────────────────────────────────────────────────────

    /// @notice Deposit depositToken (VVV or DIEM) during the deposit window.
    function deposit(uint256 amount) external nonReentrant onlyInitialized {
        if (block.timestamp >= depositDeadline) revert DepositWindowClosed();

        // Credit the measured balance delta, not the requested amount, so a fee-on-transfer
        // or rebasing depositToken cannot inflate accounting and render withdrawals insolvent.
        uint256 balanceBefore = depositToken.balanceOf(address(this));
        depositToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = depositToken.balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert NothingReceived();

        deposited[msg.sender] += received;
        totalDeposited += received;

        emit Deposited(msg.sender, received, totalDeposited);
    }

    // ── Claim tokens ──────────────────────────────────────────────────────

    /// @notice Claim pro-rata token allocation. Only callable after depositDeadline
    ///         to prevent over-claiming while the window is still open.
    function claimTokens() external nonReentrant onlyInitialized {
        if (block.timestamp < depositDeadline) revert DepositWindowStillOpen();
        if (tokensClaimed[msg.sender]) revert AlreadyClaimed();
        if (deposited[msg.sender] == 0) revert NothingDeposited();
        if (totalDeposited == 0) revert NoDepositsInVault();

        tokensClaimed[msg.sender] = true;

        // Integer division rounds down; dust accumulates in contract over many claimants.
        uint256 tokenAmount = deposited[msg.sender] * totalTokenSupply / totalDeposited;
        IERC20(token).safeTransfer(msg.sender, tokenAmount);

        emit TokensClaimed(msg.sender, tokenAmount);
    }

    // ── DIEM time-lock: withdraw principal ────────────────────────────────

    /// @notice Return locked DIEM after lock expiry. DIEM time-lock mode only.
    function withdrawDepositToken() external nonReentrant onlyInitialized {
        if (lockDuration == 0) revert WrongMode();
        if (block.timestamp < lockExpiry) revert LockNotExpired();
        if (depositTokenWithdrawn[msg.sender]) revert AlreadyWithdrawn();
        if (deposited[msg.sender] == 0) revert NothingDeposited();

        depositTokenWithdrawn[msg.sender] = true;

        depositToken.safeTransfer(msg.sender, deposited[msg.sender]);

        emit DepositTokenWithdrawn(msg.sender, deposited[msg.sender]);
    }

    // ── VVV irrevocable: send all VVV to agent ────────────────────────────

    /// @notice Transfer accumulated VVV to agentWallet. VVV irrevocable mode only.
    ///         Callable by anyone after depositDeadline; safe to call multiple times
    ///         (no-op if balance is already zero).
    function finalizeVVV() external nonReentrant onlyInitialized {
        if (lockDuration != 0) revert WrongMode();
        if (block.timestamp < depositDeadline) revert DepositWindowStillOpen();

        uint256 balance = depositToken.balanceOf(address(this));
        if (balance > 0) {
            depositToken.safeTransfer(agentWallet, balance);
            emit VVVFinalized(agentWallet, balance);
        }
    }

    // ── Views ─────────────────────────────────────────────────────────────

    /// @notice Preview pro-rata token allocation for a depositor.
    function getShare(address who) external view returns (uint256) {
        if (totalDeposited == 0 || deposited[who] == 0) return 0;
        return deposited[who] * totalTokenSupply / totalDeposited;
    }
}
