// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IInferenceVault} from "./interfaces/IInferenceVault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IVVVStaking {
    function lock(uint256 amount) external returns (uint256 diemMinted);
    function burn(uint256 diemAmount) external;
}

interface ICurvePool {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
}

contract Router is Ownable {
    using SafeERC20 for IERC20;

    IInferenceVault public immutable vault;
    address public immutable weth;
    address public immutable vvvStaking;

    address public curvePool; // set after Phase B deploy
    address public v4Pool; // set after Phase B deploy

    error PoolNotSet();
    error SlippageExceeded();

    constructor(address _vault, address _weth, address _vvvStaking) Ownable(msg.sender) {
        vault = IInferenceVault(_vault);
        weth = _weth;
        vvvStaking = _vvvStaking;
    }

    // WETH → wstDIEM via V4 pool
    function depositWETH(uint256 wethAmount, uint256 minWstDIEM, address receiver)
        external
        returns (uint256 shares)
    {
        if (v4Pool == address(0)) revert PoolNotSet();
        IERC20(weth).safeTransferFrom(msg.sender, address(this), wethAmount);
        // V4 swap: WETH → DIEM (via hook pool) then deposit into vault
        // Full V4 swap implementation wired in Task B3 after v4Pool is set
        revert("V4 pool not wired"); // placeholder until v4Pool integration
    }

    // wstDIEM → WETH via V4 pool
    function exitToWETH(uint256 wstDIEMAmount, uint256 minWETH, address receiver)
        external
        returns (uint256 wethOut)
    {
        if (v4Pool == address(0)) revert PoolNotSet();
        IERC20(address(vault)).safeTransferFrom(msg.sender, address(this), wstDIEMAmount);
        revert("V4 pool not wired");
    }

    // sVVV → DIEM (via Venice lock) → wstDIEM
    function depositSVVV(uint256 sVVVAmount, uint256 minWstDIEM, address receiver)
        external
        returns (uint256 shares)
    {
        // sVVV held by msg.sender; lock it → DIEM minted to this contract
        IERC20(vvvStaking).safeTransferFrom(msg.sender, address(this), sVVVAmount);
        uint256 diemMinted = IVVVStaking(vvvStaking).lock(sVVVAmount);
        address diem = vault.asset();
        IERC20(diem).approve(address(vault), diemMinted);
        shares = vault.deposit(diemMinted, receiver);
        if (shares < minWstDIEM) revert SlippageExceeded();
    }

    // VVV → sVVV (stake first) → lock → DIEM → wstDIEM
    function depositVVV(uint256 vvvAmount, uint256 minWstDIEM, address receiver)
        external
        returns (uint256 shares)
    {
        // Caller must have VVV approved to this contract
        // Stake VVV → sVVV (via VVV staking contract) then call depositSVVV logic
        // VVV staking ABI: stake(uint256) returns sVVV amount
        revert("Implement after confirming VVV stake ABI");
    }

    // Admin
    function setCurvePool(address _pool) external onlyOwner {
        curvePool = _pool;
    }

    function setV4Pool(address _pool) external onlyOwner {
        v4Pool = _pool;
    }
}
