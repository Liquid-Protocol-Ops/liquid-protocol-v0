// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract InferenceVault is ERC4626, Ownable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // --- Errors ---
    error NotFeeRouter();
    error WithdrawalNotInitiated();
    error TimelockActive();
    error AlreadyInitiated();

    // --- Constants ---
    uint256 public constant TVL_FEE_THRESHOLD = 5_000_000e18;
    uint256 public constant FEE_LOW_BPS       = 10;
    uint256 public constant FEE_HIGH_BPS      = 50;
    uint256 public constant WITHDRAWAL_DELAY  = 14 days;

    // --- State ---
    address public feeRouter;
    address public treasury;
    bool    public withdrawalsEnabled;
    uint256 public withdrawalEnabledAt;

    constructor(address diem, address _treasury, address initialOwner)
        ERC4626(IERC20(diem))
        ERC20("Wrapped Staked DIEM", "wstDIEM")
        Ownable(initialOwner)
    {
        treasury = _treasury;
    }

    // _decimalsOffset=0: share decimals == asset decimals (18).
    // The virtual +1 in mulDiv denominators already prevents first-depositor inflation.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 0;
    }

    // Expose vault-owned shares for external inspection (VOL tracking).
    // Not subtracted from supply in price formulas: excluding VOL shares AND
    // their backing assets from the rate formula is mathematically equivalent
    // to standard totalAssets/totalSupply, preserving rate invariance.
    function vaultOwnedShares() public view returns (uint256) {
        return balanceOf(address(this));
    }

    // Standard ERC-4626 conversion — totalSupply includes VOL, totalAssets
    // includes VOL-backing assets; they cancel so the external-holder rate is
    // unaffected by vault accumulation of its own shares.
    function _convertToShares(uint256 assets, Math.Rounding rounding)
        internal view override returns (uint256)
    {
        return assets.mulDiv(
            totalSupply() + 10 ** _decimalsOffset(),
            totalAssets() + 1,
            rounding
        );
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding)
        internal view override returns (uint256)
    {
        return shares.mulDiv(
            totalAssets() + 1,
            totalSupply() + 10 ** _decimalsOffset(),
            rounding
        );
    }

    // --- Deposit fee ---
    function currentDepositFeeBps() public view returns (uint256) {
        return totalAssets() < TVL_FEE_THRESHOLD ? FEE_LOW_BPS : FEE_HIGH_BPS;
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        uint256 fee = assets.mulDiv(currentDepositFeeBps(), 10_000, Math.Rounding.Ceil);
        return _convertToShares(assets - fee, Math.Rounding.Floor);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal override
    {
        uint256 feeAssets = assets.mulDiv(currentDepositFeeBps(), 10_000, Math.Rounding.Ceil);
        // Compute fee shares BEFORE transferring assets so totalAssets is the
        // pre-deposit value and the mulDiv ratio is well-defined at genesis.
        uint256 feeShares;
        if (feeAssets > 0 && treasury != address(0)) {
            feeShares = _convertToShares(feeAssets, Math.Rounding.Floor);
        }
        IERC20(asset()).safeTransferFrom(caller, address(this), assets);
        if (feeShares > 0) _mint(treasury, feeShares);
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    // --- Non-dilutive credit ---
    function creditDIEM(uint256 amount) external {
        if (msg.sender != feeRouter) revert NotFeeRouter();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
    }

    // --- Withdrawal gate ---
    function maxWithdraw(address owner) public view override returns (uint256) {
        return withdrawalsEnabled ? super.maxWithdraw(owner) : 0;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return withdrawalsEnabled ? super.maxRedeem(owner) : 0;
    }

    function initiateEnableWithdrawals() external onlyOwner {
        if (withdrawalEnabledAt != 0) revert AlreadyInitiated();
        withdrawalEnabledAt = block.timestamp + WITHDRAWAL_DELAY;
    }

    function enableWithdrawals() external {
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
}
