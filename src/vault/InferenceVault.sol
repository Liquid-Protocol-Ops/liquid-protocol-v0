// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// DIEM token has staking built in. stake() moves DIEM from the liquid balanceOf
// into a staked position tracked by stakedInfos (sDIEM). Unstaking requires
// initiateUnstake() then unstake() after a cooldown period (currently 24h on mainnet).
interface IDIEM is IERC20 {
    function stake(uint256 amount) external;
    function initiateUnstake(uint256 amount) external;
    function unstake() external;
    // Returns (stakedAmount, unstakingAmount, cooldownEnd)
    function stakedInfos(address account)
        external
        view
        returns (uint256 stakedAmount, uint256 unstakingAmount, uint256 cooldownEnd);
    function cooldownDuration() external view returns (uint256);
}

contract InferenceVault is ERC4626, Ownable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // --- Errors ---
    error NotFeeRouter();
    error WithdrawalNotInitiated();
    error TimelockActive();
    error AlreadyInitiated();
    error NothingToCancel();

    event DIEMCredited(uint256 amount);
    event KeeperUpdated(address indexed keeper);
    event KeeperFunded(address indexed keeperEOA, uint256 vvvAmount);

    // --- Constants ---
    uint256 public constant TVL_FEE_THRESHOLD = 5_000_000e18;
    uint256 public constant FEE_LOW_BPS = 10;
    uint256 public constant FEE_HIGH_BPS = 50;
    uint256 public constant WITHDRAWAL_DELAY = 14 days;

    // --- State ---
    address public feeRouter;
    address public treasury;
    address public keeper;       // trusted EOA for inference operations (harvest, API key funding)
    bool public withdrawalsEnabled;
    uint256 public withdrawalEnabledAt;

    constructor(address diem, address _treasury, address initialOwner)
        ERC4626(IERC20(diem))
        ERC20("Wrapped Staked DIEM", "wstDIEM")
        Ownable(initialOwner)
    {
        treasury = _treasury;
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 0;
    }

    // --- Asset accounting ---
    // stake() moves DIEM out of liquid balanceOf into stakedInfos — sum all buckets.
    function totalAssets() public view override returns (uint256) {
        (uint256 staked, uint256 unstaking,) = IDIEM(asset()).stakedInfos(address(this));
        return IERC20(asset()).balanceOf(address(this)) + staked + unstaking;
    }

    function vaultOwnedShares() public view returns (uint256) {
        return balanceOf(address(this));
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding)
        internal
        view
        override
        returns (uint256)
    {
        return assets.mulDiv(totalSupply() + 10 ** _decimalsOffset(), totalAssets() + 1, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding)
        internal
        view
        override
        returns (uint256)
    {
        return shares.mulDiv(totalAssets() + 1, totalSupply() + 10 ** _decimalsOffset(), rounding);
    }

    // --- Deposit fee ---
    function currentDepositFeeBps() public view returns (uint256) {
        return totalAssets() < TVL_FEE_THRESHOLD ? FEE_LOW_BPS : FEE_HIGH_BPS;
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        uint256 fee = assets.mulDiv(currentDepositFeeBps(), 10_000, Math.Rounding.Ceil);
        return _convertToShares(assets - fee, Math.Rounding.Floor);
    }

    // mint() must pull more DIEM than shares imply to cover the deposit fee.
    // Without this override, mint() bypasses the fee and issues unbacked treasury shares.
    function previewMint(uint256 shares) public view override returns (uint256) {
        uint256 netAssets = _convertToAssets(shares, Math.Rounding.Ceil);
        uint256 feeBps = currentDepositFeeBps();
        // grossAssets * (1 - feeBps/10000) = netAssets  →  grossAssets = netAssets * 10000 / (10000 - feeBps)
        return netAssets.mulDiv(10_000, 10_000 - feeBps, Math.Rounding.Ceil);
    }

    // Pull DIEM, mint shares, then stake ALL deposited DIEM in Venice.
    // Treasury's fee shares give it a proportional claim on the staked pool —
    // no separate fee transfer needed.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
    {
        uint256 feeAssets = assets.mulDiv(currentDepositFeeBps(), 10_000, Math.Rounding.Ceil);
        uint256 feeShares;
        if (feeAssets > 0 && treasury != address(0)) {
            feeShares = _convertToShares(feeAssets, Math.Rounding.Floor);
        }
        IERC20(asset()).safeTransferFrom(caller, address(this), assets);
        if (feeShares > 0) _mint(treasury, feeShares);
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);

        // Stake all deposited DIEM in Venice — wstDIEM is a liquid wrapper for sDIEM.
        IDIEM(asset()).stake(assets);
    }

    // --- Non-dilutive yield credit ---
    // FeeRouter calls this to add protocol fee income to the staked pool,
    // increasing the DIEM redeemable per wstDIEM share over time.
    function creditDIEM(uint256 amount) external {
        if (msg.sender != feeRouter) revert NotFeeRouter();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        IDIEM(asset()).stake(amount);
        emit DIEMCredited(amount);
    }

    // --- Unstaking (admin-managed liquidity) ---
    // Primary liquidity path for users is the Curve DIEM/wstDIEM pool.
    // Direct vault withdrawals require the admin to pre-unstake and then
    // enable withdrawals after the 14-day governance timelock.

    function initiateUnstake(uint256 amount) external onlyOwner {
        IDIEM(asset()).initiateUnstake(amount);
    }

    // Call after DIEM cooldown (24h) to move unstaking DIEM back to idle balance.
    function completeUnstake() external {
        IDIEM(asset()).unstake();
    }

    // --- Withdrawal gate ---
    // Cap against idle DIEM balance — only liquid (unstaked) DIEM can be withdrawn.
    // Prevents maxWithdraw() from overstating withdrawable assets when most DIEM is staked,
    // which would cause _withdraw's safeTransfer to revert for compliant EIP-4626 callers.
    function maxWithdraw(address owner) public view override returns (uint256) {
        if (!withdrawalsEnabled) return 0;
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        return Math.min(super.maxWithdraw(owner), idle);
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        if (!withdrawalsEnabled) return 0;
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 idleShares = _convertToShares(idle, Math.Rounding.Floor);
        return Math.min(super.maxRedeem(owner), idleShares);
    }

    function initiateEnableWithdrawals() external onlyOwner {
        if (withdrawalEnabledAt != 0) revert AlreadyInitiated();
        withdrawalEnabledAt = block.timestamp + WITHDRAWAL_DELAY;
    }

    // Cancel a pending withdrawal initiation before the timelock expires.
    // Once withdrawalsEnabled = true this has no effect (withdrawals stay open).
    function cancelEnableWithdrawals() external onlyOwner {
        if (withdrawalEnabledAt == 0) revert NothingToCancel();
        withdrawalEnabledAt = 0;
    }

    function enableWithdrawals() external onlyOwner {
        if (withdrawalEnabledAt == 0) revert WithdrawalNotInitiated();
        if (block.timestamp < withdrawalEnabledAt) revert TimelockActive();
        withdrawalsEnabled = true;
    }

    // --- Admin ---
    function setFeeRouter(address _feeRouter) external onlyOwner {
        feeRouter = _feeRouter;
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    // Set the keeper EOA — the off-chain operator that serves inference and settles revenue.
    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
        emit KeeperUpdated(_keeper);
    }

    // Fund the keeper EOA with a VVV stake so it can self-mint a Venice API key.
    // The keeper EOA receives sVVV; it then calls Venice's generate_web3_key endpoint,
    // signs the challenge token with its private key, and receives a Bearer API key.
    // Requires Safe to send VVV to this call; keeper needs only 1 VVV to mint a key.
    function fundKeeperVVV(address keeperEOA, address vvv, address vvvStaking, uint256 amount)
        external
        onlyOwner
    {
        require(keeperEOA != address(0), "zero address");
        IERC20(vvv).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(vvv).approve(vvvStaking, amount);
        // stake(address to, uint256) mints sVVV directly to keeperEOA — no transferFrom needed
        (bool ok,) = vvvStaking.call(
            abi.encodeWithSignature("stake(address,uint256)", keeperEOA, amount)
        );
        require(ok, "VVV stake failed");
        emit KeeperFunded(keeperEOA, amount);
    }
}
