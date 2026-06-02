// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IInferenceVault is IERC4626 {
    // ── Yield credit ─────────────────────────────────────────────────────────

    /// @notice Credit inference revenue as staked DIEM, raising the wstDIEM rate
    ///         for all holders. Callable only by registered venue adapters.
    function creditDIEM(uint256 amount) external;

    /// @notice Credit an inference source with wstDIEM proportional to their
    ///         contributed DIEM. Pulls DIEM from msg.sender, stakes it, and mints
    ///         wstDIEM to recipient at the current rate with no entry fee.
    ///         Used by inference sources to reinvest their cut of revenue.
    ///         Callable only by registered venue adapters / inference tokens.
    function creditWstDIEM(uint256 amount, address recipient) external;

    // ── Withdrawal queue ─────────────────────────────────────────────────────

    function requestRedeem(uint256 shares, address receiver) external returns (uint256 requestId);
    function flush() external;
    function settle() external;
    function claimRedeem(uint256 requestId) external;

    // ── Views ────────────────────────────────────────────────────────────────

    function pendingWithdrawalDiem() external view returns (uint256);
    function currentDepositFeeBps() external view returns (uint256);
    function vaultOwnedShares() external view returns (uint256);
    function inferenceTokenList() external view returns (address[] memory);

    // ── State ────────────────────────────────────────────────────────────────

    function treasury() external view returns (address);
    function veniceSigner() external view returns (address);
    function isVenueAdapter(address) external view returns (bool);
    function isInferenceToken(address) external view returns (bool);
}
