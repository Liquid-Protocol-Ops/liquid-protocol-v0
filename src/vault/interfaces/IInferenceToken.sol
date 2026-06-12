// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title  IInferenceToken
/// @notice Standard interface for any tokenized inference capacity source that
///         plugs into the wstDIEM meta-wrapper ecosystem.
///
/// An InferenceToken represents a staked position in some AI inference provider
/// (Venice DIEM, VVV compute, GPU tokens, etc.) that generates USDC revenue
/// from inference sales.  The adapter contract implements this interface and is
/// registered in InferenceVault via addInferenceToken().
///
/// Revenue routing — adapters call back into the vault:
///
///   vault.creditDIEM(holderShare)
///       → stakes DIEM, raises wstDIEM rate for ALL holders
///
///   vault.creditWstDIEM(sourceShare, sourceAddress)
///       → stakes DIEM and mints wstDIEM to the inference source as their cut,
///         allowing each source to accumulate a growing position in the vault
///         proportional to the inference capacity they contribute over time
///
/// The split between holderShare and sourceShare is set per-adapter off-chain;
/// the vault enforces neither a floor nor a ceiling on the ratio.
interface IInferenceToken {
    // ─── Identity ────────────────────────────────────────────────────────────

    /// @notice Human-readable name of this inference source (e.g. "Venice DIEM").
    function inferenceName() external view returns (string memory);

    /// @notice The native token staked to generate inference capacity.
    ///         For Venice DIEM this is the DIEM token address.
    function inferenceAsset() external view returns (address);

    // ─── Position ────────────────────────────────────────────────────────────

    /// @notice Total amount of inferenceAsset() currently staked by this source.
    ///         Does not include pending unstake amounts.
    function inferenceStaked() external view returns (uint256);

    /// @notice Estimate of pending DIEM yield not yet routed to the vault.
    ///         Off-chain informational only — may be 0 if the adapter tracks
    ///         revenue externally.
    function pendingYieldInDIEM() external view returns (uint256);

    // ─── Yield routing ───────────────────────────────────────────────────────

    /// @notice Route accumulated inference yield to the vault.
    ///         Implementations should:
    ///           1. Convert native revenue (USDC, etc.) → DIEM, requiring the swap to
    ///              deliver at least minDiemOut (reverts otherwise, so a sandwiched or
    ///              under-delivering swap fails — MOG-541).
    ///           2. Call vault.creditDIEM(holderDiem) for the holders' share.
    ///           3. Call vault.creditWstDIEM(sourceDiem, address(this)) for the
    ///              source's cut so the source accrues a wstDIEM position.
    ///         Restricted to the adapter operator (owner/keeper), who computes
    ///         minDiemOut off-chain from a fresh quote net of acceptable slippage.
    /// @param  minDiemOut Minimum DIEM the conversion swap must deliver.
    function routeYield(uint256 minDiemOut) external;
}
