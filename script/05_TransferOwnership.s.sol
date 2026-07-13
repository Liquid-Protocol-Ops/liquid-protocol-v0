// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Phase 5: Transfer ownership of all ownable contracts from deployer to the Safe.
///         Run AFTER Phase 4 (ConfigureAllowlists) is complete.
contract TransferOwnership is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address newOwner = vm.envAddress("OWNER_ADDRESS");

        // All ownable contracts
        address liquidFactory = vm.envAddress("LIQUID_FACTORY");
        address feeLocker = vm.envAddress("LIQUID_FEE_LOCKER");
        address poolExtAllowlist = vm.envAddress("POOL_EXTENSION_ALLOWLIST");
        address lpLocker = vm.envAddress("LIQUID_LP_LOCKER_FEE_CONVERSION");
        address sniperAuction = vm.envAddress("LIQUID_SNIPER_AUCTION_V2");
        address presale = vm.envAddress("LIQUID_PRESALE_ETH_TO_CREATOR");

        vm.startBroadcast(deployerKey);

        Ownable(liquidFactory).transferOwnership(newOwner);
        console.log("Transferred Liquid factory to:", newOwner);

        Ownable(feeLocker).transferOwnership(newOwner);
        console.log("Transferred LiquidFeeLocker to:", newOwner);

        Ownable(poolExtAllowlist).transferOwnership(newOwner);
        console.log("Transferred PoolExtensionAllowlist to:", newOwner);

        Ownable(lpLocker).transferOwnership(newOwner);
        console.log("Transferred LpLockerFeeConversion to:", newOwner);

        Ownable(sniperAuction).transferOwnership(newOwner);
        console.log("Transferred SniperAuctionV2 to:", newOwner);

        Ownable(presale).transferOwnership(newOwner);
        console.log("Transferred PresaleEthToCreator to:", newOwner);

        vm.stopBroadcast();

        console.log("All ownership transferred to Safe:", newOwner);
    }
}
