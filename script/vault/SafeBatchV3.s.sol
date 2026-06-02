// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Script, console} from "forge-std/Script.sol";

interface ISafe {
    function getTransactionHash(address to, uint256 value, bytes calldata data, uint8 operation,
        uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address gasToken,
        address refundReceiver, uint256 nonce) external view returns (bytes32);
    function execTransaction(address to, uint256 value, bytes calldata data, uint8 operation,
        uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address gasToken,
        address payable refundReceiver, bytes memory signatures) external payable returns (bool);
    function nonce() external view returns (uint256);
}

contract SafeBatchV3 is Script {
    address constant SAFE         = 0x872c561f699B42977c093F0eD8b4C9a431280c6c;
    address constant VAULT        = 0x3394898b648385FAd4FE847c52B5E4CCe0D63662;
    address constant FEEROUTER    = 0x33B218bd86046AAd25c209B1d7Adb7e8A6648387;
    address constant ROUTER       = 0xA92EF6a90058f52556e74504324D28D7EC8d49a2;
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    bytes32 constant POOL_ID      = 0x834007392f8ff5f0f2d5c5465009df1b319ec1f8ac77386f179450f2abb65045;
    address constant ZERO         = address(0);

    uint256 sk1; uint256 sk2;

    function setUp() public {
        sk1 = uint256(vm.envBytes32("SAFE_SK1"));
        sk2 = uint256(vm.envBytes32("SAFE_SK2"));
    }

    function run() external {
        vm.startBroadcast(vm.envUint("EXECUTOR_PK"));

        // Approve FeeRouter as a venue adapter on vault
        _execSafe(VAULT, abi.encodeWithSignature("setVenueAdapter(address,bool)", FEEROUTER, true));
        console.log("vault.setVenueAdapter(feeRouter, true) done");

        // Wire router → v4Pool
        _execSafe(ROUTER, abi.encodeWithSignature("setV4Pool(address)", POOL_MANAGER));
        console.log("router.setV4Pool done");

        // Create Morpho market (38.5% LLTV) for new vault address
        // Market params: loanToken=DIEM, collateral=new wstDIEM, oracle, IRM, LLTV
        _execSafe(
            0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb,
            abi.encodeWithSignature(
                "createMarket((address,address,address,address,uint256))",
                0xF4d97F2da56e8c3098f3a8D538DB630A2606a024,  // DIEM
                VAULT,                                          // new wstDIEM
                0xE762e8011D453853638D1978398df8b1D383A2D9,  // oracle (reuse)
                0x46415998764C29aB2a25CbeA6254146D50D22687,  // IRM
                uint256(385000000000000000)                     // 38.5% LLTV
            )
        );
        console.log("Morpho 38.5% market created for new vault");

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
