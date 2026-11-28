// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Subset of the live wstDIEM InferenceVault (Base, 0xe49FA849cB37b0e7A42B2335e333fb99474167ba)
///         used by jitDIEM. Signatures taken from the verified source.
///         Instant `redeem`/`withdraw` are disabled on the live vault (maxRedeem/maxWithdraw are pure);
///         exits go through the batched requestRedeem -> claimRedeem queue.
interface IInferenceVaultQueue {
    // ERC-20 / ERC-4626 surface
    function asset() external view returns (address);
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
    function decimals() external view returns (uint8);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewMint(uint256 shares) external view returns (uint256);
    function maxDeposit(address) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);

    // Batched redemption queue
    function requestRedeem(uint256 shares, address receiver) external returns (uint256 requestId);
    function claimRedeem(uint256 requestId) external;
    function requestStatus(uint256 requestId)
        external
        view
        returns (
            address receiver,
            uint256 diem,
            uint32 batchId,
            uint64 unlockAt,
            bool settled,
            bool claimed
        );
    function minRedeemShares() external view returns (uint256);
    function paused() external view returns (bool);
}
