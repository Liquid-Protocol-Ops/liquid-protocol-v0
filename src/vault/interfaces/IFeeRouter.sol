// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IFeeRouter {
    function receiveWETH(uint256 amount) external;
    function receiveUSDC(uint256 amount) external;
    function receivewstDIEM(uint256 amount) external;
    function receiveVVV(uint256 amount) external;
    function harvest() external;
    function harvestVVV() external;
    function setVVVBatchThreshold(uint256 amount) external;
    function pendingVVV() external view returns (uint256);
    function pendingWETH() external view returns (uint256);
    function pendingUSDC() external view returns (uint256);
}
