// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

interface ISafe {
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 nonce
    ) external view returns (bytes32);
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool);
    function nonce() external view returns (uint256);
}

// Registers Surplus Intelligence as FeeRouter channel 1.
// The keeper EOA (0x32fD...) is the payoutWallet - Surplus settles x402 USDC
// directly to it, and the Railway settle loop routes it to the vault.
// platformFeeBps=0: Surplus deducts their cut before paying the keeper,
// so the amount received is already net.
contract SafeAddSurplusChannel is Script {
    address constant SAFE = 0x872c561f699B42977c093F0eD8b4C9a431280c6c;
    address constant FEEROUTER = 0x21fe048B10dC9bED2Ee0Ae76724C627CA7F35F61;
    address constant KEEPER = 0x32fDdfB0eeC6c638d5C8b7cabF3bE9065478e90E;
    address constant ZERO = address(0);

    address constant SK2_ADDR = 0x6FDDe67e9c545AcdcE17944bf8f9988E1f88aa9E;
    address constant SK1_ADDR = 0x8f60eB404a5CA868f37bc798ec4c54FA0dcCFC9F;

    uint256 sk1;
    uint256 sk2;

    function setUp() public {
        sk1 = uint256(vm.envBytes32("SAFE_SK1"));
        sk2 = uint256(vm.envBytes32("SAFE_SK2"));
        require(vm.addr(sk1) == SK1_ADDR, "SAFE_SK1 mismatch");
        require(vm.addr(sk2) == SK2_ADDR, "SAFE_SK2 mismatch");
    }

    function run() external {
        vm.startBroadcast(vm.envUint("EXECUTOR_PK"));

        _execSafe(
            FEEROUTER,
            abi.encodeWithSignature(
                "addChannel(string,address,uint256)", "SurplusIntelligence", KEEPER, uint256(0)
            )
        );
        console.log("FeeRouter.addChannel('SurplusIntelligence', keeper, 0) done");
        console.log("Channel 1 registered - Surplus Intelligence x402 USDC -> keeper -> vault");

        vm.stopBroadcast();
    }

    function _execSafe(address to, bytes memory data) internal {
        uint256 nonce = ISafe(SAFE).nonce();
        bytes32 txHash = ISafe(SAFE).getTransactionHash(to, 0, data, 0, 0, 0, 0, ZERO, ZERO, nonce);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(sk2, txHash);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(sk1, txHash);
        bytes memory sigs = abi.encodePacked(r2, s2, v2, r1, s1, v1);
        bool ok = ISafe(SAFE).execTransaction(to, 0, data, 0, 0, 0, 0, ZERO, payable(ZERO), sigs);
        require(ok, "SafeTx failed");
    }
}
