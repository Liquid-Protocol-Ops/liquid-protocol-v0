// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IInferenceVault} from "./interfaces/IInferenceVault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ICurvePool {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
}

contract SurplusStakingWrapper is Ownable {
    using SafeERC20 for IERC20;

    IInferenceVault public immutable vault;
    address public curvePool;

    event Staked(address indexed user, uint256 diemIn, uint256 wstDIEMOut, bytes32 ref);
    event Unstaked(address indexed user, uint256 wstDIEMIn, uint256 diemOut);

    error CurvePoolNotSet();

    constructor(address _vault, address _curvePool, address initialOwner) Ownable(initialOwner) {
        vault = IInferenceVault(_vault);
        curvePool = _curvePool;
    }

    function stakeForUser(address user, uint256 diemAmount) external returns (uint256 shares) {
        address diem = vault.asset();
        IERC20(diem).safeTransferFrom(msg.sender, address(this), diemAmount);
        IERC20(diem).approve(address(vault), diemAmount);
        shares = vault.deposit(diemAmount, user);
        emit Staked(user, diemAmount, shares, bytes32(0));
    }

    function referralDeposit(address user, uint256 diemAmount, bytes32 ref)
        external
        returns (uint256 shares)
    {
        address diem = vault.asset();
        IERC20(diem).safeTransferFrom(msg.sender, address(this), diemAmount);
        IERC20(diem).approve(address(vault), diemAmount);
        shares = vault.deposit(diemAmount, user);
        emit Staked(user, diemAmount, shares, ref);
    }

    function unstakeForUser(address user, uint256 wstDIEMAmount, uint256 minDiemOut) external {
        if (curvePool == address(0)) revert CurvePoolNotSet();
        IERC20(address(vault)).safeTransferFrom(msg.sender, address(this), wstDIEMAmount);
        IERC20(address(vault)).approve(curvePool, wstDIEMAmount);
        // Curve: index 1 = wstDIEM, index 0 = DIEM
        uint256 diemOut = ICurvePool(curvePool).exchange(1, 0, wstDIEMAmount, minDiemOut);
        IERC20(vault.asset()).safeTransfer(user, diemOut);
        emit Unstaked(user, wstDIEMAmount, diemOut);
    }

    function getBalance(address user) external view returns (uint256) {
        return vault.balanceOf(user);
    }

    function getYield(address user) external view returns (uint256 accruedDIEM) {
        uint256 shares = vault.balanceOf(user);
        return vault.convertToAssets(shares);
    }

    function setCurvePool(address pool) external onlyOwner {
        curvePool = pool;
    }
}
