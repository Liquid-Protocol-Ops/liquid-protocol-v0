// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILiquid} from "../../interfaces/ILiquid.sol";
import {ILiquidExtension} from "../../interfaces/ILiquidExtension.sol";

interface ILiquidPresaleEthToCreator is ILiquidExtension {
    event PresaleStarted(
        uint256 presaleId,
        address allowlist,
        ILiquid.DeploymentConfig deploymentConfig,
        uint256 minEthGoal,
        uint256 maxEthGoal,
        uint256 presaleDuration,
        address presaleOwner,
        uint256 lockupDuration,
        uint256 vestingDuration,
        uint256 liquidFeeBps
    );

    event PresaleDeployed(uint256 indexed presaleId, address token);
    event PresaleFailed(uint256 indexed presaleId);
    event PresaleBuy(uint256 indexed presaleId, address buyer, uint256 ethToUse, uint256 ethRaised);
    event WithdrawFromPresale(
        uint256 indexed presaleId, address withdrawer, uint256 amount, uint256 ethRaised
    );
    event ClaimTokens(uint256 indexed presaleId, address claimer, uint256 tokenAmount);
    event ClaimEth(uint256 indexed presaleId, address recipient, uint256 ethAmount, uint256 fee);
    event WithdrawWithdrawFee(address recipient, uint256 amount);
    event LiquidFeeRecipientUpdated(address oldRecipient, address recipient);
    event MinLockupDurationUpdated(uint256 oldMinLockupDuration, uint256 minLockupDuration);
    event LiquidDefaultFeeUpdated(uint256 oldLiquidDefaultFee, uint256 liquidDefaultFee);
    event LiquidFeeUpdatedForPresale(uint256 presaleId, uint256 oldLiquidFee, uint256 liquidFee);
    event SetAllowlist(address allowlist, bool enabled);

    struct Presale {
        PresaleStatus status; // current status of the presale
        ILiquid.DeploymentConfig deploymentConfig; // token to be deployed upon successful presale
        address allowlist; // address of the allowlist for the presale
        // presale success configuration fields
        address presaleOwner; // address to claim raised eth on successful presale
        uint256 minEthGoal; // minimum eth goal for successful presale, presale will fail if this goal is not met and the time limit is reached
        uint256 maxEthGoal; // maximum eth goal for successful presale, presale will end early if this goal is reached
        uint256 endTime; // timestamp when presale expires
        // presale fields
        address deployedToken; // address of the token that was deployed
        uint256 ethRaised; // total eth raised during presale
        uint256 tokenSupply; // supply of the token that was deployed to distribute to presale buyers
        // toggle flags
        bool deploymentExpected; // bool to flag to us that we are expecting a token deployment from the factory
        bool ethClaimed; // bool to flag to us that the tokens have been claimed
        // lockup and vesting fields
        uint256 lockupDuration; // duration of the lockup period
        uint256 vestingDuration; // duration of the vesting period
        uint256 lockupEndTime; // timestamp to mark when the lockup period ends
        uint256 vestingEndTime; // timestamp to mark when the vesting period ends
        uint256 liquidFee; // liquid's fee to take in weth on successful presale
    }

    enum PresaleStatus {
        NotCreated,
        Active,
        SuccessfulMinimumHit,
        SuccessfulMaximumHit,
        Failed,
        Claimable
    }

    error PresaleNotLastExtension();
    error InvalidPresaleSupply();
    error InvalidPresaleDuration();
    error InvalidEthGoal();
    error InvalidPresaleOwner();
    error InvalidTimeLimit();
    error InvalidLiquidFee();
    error RecipientMustBePresaleOwner();
    error AllowlistNotEnabled();
    error PresaleNotActive();
    error PresaleSuccessful();
    error InsufficientBalance();
    error InvalidPresale();
    error PresaleNotReadyForDeployment();
    error PresaleAlreadyClaimed();
    error PresaleSaltBufferNotExpired();
    error NoTokensToClaim();
    error NotExpectingTokenDeployment();
    error PresaleNotClaimable();
    error PresaleLockupNotPassed();
    error EthTransferFailed();
    error NoWithdrawFeeAccumulated();
    error LockupDurationTooShort();
    error AllowlistAmountExceeded(uint256 allowedAmount);

    function getPresale(uint256 _presaleId) external view returns (Presale memory);
}
