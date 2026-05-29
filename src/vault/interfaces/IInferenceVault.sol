// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IInferenceVault is IERC4626 {
    function creditDIEM(uint256 amount) external;
    function initiateEnableWithdrawals() external;
    function enableWithdrawals() external;
    function setFeeRouter(address _feeRouter) external;
    function setTreasury(address _treasury) external;
    function withdrawalsEnabled() external view returns (bool);
    function currentDepositFeeBps() external view returns (uint256);
    function vaultOwnedShares() external view returns (uint256);
    function feeRouter() external view returns (address);
    function treasury() external view returns (address);
}
