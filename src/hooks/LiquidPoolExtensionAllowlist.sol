// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILiquidPoolExtensionAllowlist} from "./interfaces/ILiquidPoolExtensionAllowlist.sol";

import {OwnerAdmins} from "../utils/OwnerAdmins.sol";

contract LiquidPoolExtensionAllowlist is ILiquidPoolExtensionAllowlist, OwnerAdmins {
    string public constant PROTOCOL = "Liquid Protocol";
    mapping(address extension => bool enabled) public enabledExtensions;

    constructor(address owner_) OwnerAdmins(owner_) {}

    function setPoolExtension(address extension, bool enabled) external onlyOwnerOrAdmin {
        enabledExtensions[extension] = enabled;
        emit SetPoolExtension(extension, enabled);
    }
}
