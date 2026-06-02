// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Mock DIEM that implements the Venice staking interface used by InferenceVault.
/// stake() moves tokens from liquid balanceOf into the stakedInfos mapping,
/// replicating the real DIEM contract's behaviour on Base mainnet.
contract MockDIEM is ERC20 {
    struct StakedInfo {
        uint256 stakedAmount;
        uint256 unstakingAmount;
        uint256 cooldownEnd;
    }

    mapping(address => StakedInfo) private _infos;
    uint256 private constant COOLDOWN = 86_400; // 24 h

    constructor() ERC20("Mock DIEM", "DIEM") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    // Moves tokens from liquid balance into staked bucket.
    function stake(uint256 amount) external {
        _burn(msg.sender, amount);
        _infos[msg.sender].stakedAmount += amount;
    }

    function initiateUnstake(uint256 amount) external {
        StakedInfo storage info = _infos[msg.sender];
        require(info.stakedAmount >= amount, "insufficient staked");
        info.stakedAmount -= amount;
        info.unstakingAmount += amount;
        info.cooldownEnd = block.timestamp + COOLDOWN;
    }

    function unstake() external {
        StakedInfo storage info = _infos[msg.sender];
        require(block.timestamp >= info.cooldownEnd, "cooldown active");
        uint256 amount = info.unstakingAmount;
        info.unstakingAmount = 0;
        info.cooldownEnd = 0;
        _mint(msg.sender, amount);
    }

    // Return order matches verified Diem.sol on Base:
    //   slot 0: amountStaked  (active stake)
    //   slot 1: coolDownEnd   (timestamp — NOT an amount)
    //   slot 2: coolDownAmount (DIEM queued for withdrawal)
    function stakedInfos(address account)
        external
        view
        returns (uint256 amountStaked, uint256 coolDownEnd, uint256 coolDownAmount)
    {
        StakedInfo storage info = _infos[account];
        return (info.stakedAmount, info.cooldownEnd, info.unstakingAmount);
    }

    function cooldownDuration() external pure returns (uint256) {
        return COOLDOWN;
    }
}
