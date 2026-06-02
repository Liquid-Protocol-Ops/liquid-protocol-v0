// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// DIEM token — Venice AI inference credit token.
// stake(amount)       — stakes from msg.sender into msg.sender's Venice account
// stakeFor(to, amt)   — stakes from msg.sender into `to`'s Venice account
//                       (vault deposits go directly into keeper's Venice budget)
// initiateUnstakeFor  — vault can initiate unstaking of DIEM it staked to keeper
// unstakeFor          — vault completes unstaking from keeper's position
// stakedInfos         — returns (stakedAmount, unstakingAmount, cooldownEnd)
interface IDIEM is IERC20 {
    function stake(uint256 amount) external;
    function stakeFor(address to, uint256 amount) external;
    function initiateUnstake(uint256 amount) external;
    function initiateUnstakeFor(address who, uint256 amount) external;
    function unstake() external;
    function unstakeFor(address who, uint256 amount) external;
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
    // inferenceKeeper: EOA that holds the Venice API key and serves inference.
    // When set, ALL DIEM deposits are staked into the keeper's Venice account via
    // stakeFor(keeper, amount) rather than into the vault's own account.
    // totalAssets() counts BOTH vault's and keeper's sDIEM — they are one pool.
    // The keeper's Venice API key budget = stakedInfos(keeper) = total user deposits.
    address public keeper;
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
    // Counts ALL DIEM controlled by the vault: its own sDIEM + keeper's sDIEM.
    // When inferenceKeeper is set, deposits go to keeper via stakeFor() so the
    // vault's own stakedInfos may be zero — keeper's is the primary bucket.
    // Reading both ensures totalAssets() is always accurate regardless of routing.
    function totalAssets() public view override returns (uint256) {
        IDIEM diem = IDIEM(asset());
        (uint256 vStaked, uint256 vUnstaking,) = diem.stakedInfos(address(this));
        uint256 total = IERC20(asset()).balanceOf(address(this)) + vStaked + vUnstaking;
        if (keeper != address(0)) {
            (uint256 kStaked, uint256 kUnstaking,) = diem.stakedInfos(keeper);
            total += kStaked + kUnstaking;
        }
        return total;
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

        // Stake deposited DIEM into Venice. When keeper is set, stake into the keeper's
        // Venice account so their API key has that DIEM as inference budget.
        // Both routes count in totalAssets(), so wstDIEM rate is unaffected.
        if (keeper != address(0)) {
            IDIEM(asset()).stakeFor(keeper, assets);
        } else {
            IDIEM(asset()).stake(assets);
        }
    }

    // --- Non-dilutive yield credit ---
    // FeeRouter calls this to add protocol fee income to the staked pool,
    // increasing the DIEM redeemable per wstDIEM share over time.
    // Inference revenue credited back to the pool. Routes to keeper when set
    // so yield also grows the keeper's Venice inference budget.
    function creditDIEM(uint256 amount) external {
        if (msg.sender != feeRouter) revert NotFeeRouter();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        if (keeper != address(0)) {
            IDIEM(asset()).stakeFor(keeper, amount);
        } else {
            IDIEM(asset()).stake(amount);
        }
        emit DIEMCredited(amount);
    }

    // --- Unstaking (admin-managed liquidity) ---
    // Primary liquidity path: Curve DIEM/wstDIEM pool or V4 wstDIEM/WETH pool.
    // Direct redemption requires pre-unstaking and a 14-day governance timelock.
    //
    // When keeper is set, DIEM is in stakedInfos[keeper]. The vault uses
    // initiateUnstakeFor/unstakeFor to reclaim it without keeper cooperation.

    function initiateUnstake(uint256 amount) external onlyOwner {
        if (keeper != address(0)) {
            // Vault staked DIEM to keeper via stakeFor — use initiateUnstakeFor to reclaim
            IDIEM(asset()).initiateUnstakeFor(keeper, amount);
        } else {
            IDIEM(asset()).initiateUnstake(amount);
        }
    }

    // Call after DIEM cooldown (24h) to move DIEM to idle balance.
    function completeUnstake() external {
        if (keeper != address(0)) {
            IDIEM(asset()).unstakeFor(keeper, 0); // amount=0 = complete all pending
        } else {
            IDIEM(asset()).unstake();
        }
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

    // --- Venice inference credit management ---

    // Mint DIEM directly to the keeper EOA from the vault's sVVV position.
    // The vault must have sVVV (funded via vault.fundKeeperVVV or direct VVV stake).
    // This does NOT touch user-deposited DIEM — it creates NEW DIEM from the VVV CDP.
    // Keeper then calls DIEM.stake(amount) to get sDIEM = Venice inference credits.
    //
    // Flow:
    //   vault.sVVV → mintDiem(keeperEOA, sVVVAmount, 0) → DIEM at keeperEOA
    //   keeperEOA.DIEM.stake() → keeperEOA.sDIEM → Venice API key inference budget
    //
    // Why vault not keeper: Venice needs EOA signing for API key creation.
    // File Venice feature request for EIP-1271 to make vault the direct Venice account.
    function mintKeeperDiem(address keeperEOA, address vvvStaking, uint256 minDiemOut)
        external
        onlyOwner
    {
        require(keeperEOA != address(0), "zero keeper");
        uint256 sVVVBalance = IERC20(vvvStaking).balanceOf(address(this));
        require(sVVVBalance > 0, "no sVVV - fund vault with VVV first");
        // mintDiem(address to, uint256 sVVVAmount, uint256 minOut)
        // Mints DIEM to keeperEOA backed by vault's sVVV position
        (bool ok,) = vvvStaking.call(
            abi.encodeWithSignature("mintDiem(address,uint256,uint256)", keeperEOA, sVVVBalance, minDiemOut)
        );
        require(ok, "mintDiem failed");
        emit KeeperFunded(keeperEOA, sVVVBalance);
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
