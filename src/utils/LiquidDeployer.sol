// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LiquidToken} from "../LiquidToken.sol";
import {ILiquid} from "../interfaces/ILiquid.sol";

/// @notice Liquid Token Launcher
library LiquidDeployer {
    function deployToken(ILiquid.TokenConfig memory tokenConfig, uint256 supply)
        external
        returns (address tokenAddress)
    {
        LiquidToken token = new LiquidToken{
            salt: keccak256(abi.encode(tokenConfig.tokenAdmin, tokenConfig.salt))
        }(
            tokenConfig.name,
            tokenConfig.symbol,
            supply,
            tokenConfig.tokenAdmin,
            tokenConfig.image,
            tokenConfig.metadata,
            tokenConfig.context,
            tokenConfig.originatingChainId
        );
        tokenAddress = address(token);
    }
}
