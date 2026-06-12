// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILiquidExtension} from "../../src/interfaces/ILiquidExtension.sol";
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
    ) external payable returns (bool success);

    function nonce() external view returns (uint256);
}

interface ILiquidFactoryOwner {
    function owner() external view returns (address);
}

interface IPresaleVault {
    function factory() external view returns (address);
    function initialized() external view returns (bool);
}

/// @notice Enables (or disables) a per-launch presale vault as a Liquid factory
///         extension via the owner Safe, so the creator's subsequent deployToken()
///         call passes the enabledExtensions check instead of reverting
///         ExtensionNotEnabled.
///
///         Used for curated Venice Agent Launchpad presale launches (MOG-497):
///         the website's /launch/confirm flow deploys the vault (tx 1) and calls
///         deployToken (tx 2); this script must run between the two, or the vault
///         address can be pre-computed (CREATE2) and enabled before tx 1.
///
/// Usage:
///   PRESALE_VAULT=0x... \
///   SAFE_SK1=0x... SAFE_SK2=0x... EXECUTOR_PK=0x... \
///   forge script script/vault/SafeEnablePresaleVault.s.sol \
///     --rpc-url $BASE_RPC_URL            # simulate first
///     --broadcast                        # then execute
///
/// Optional:
///   ENABLED=false        disable instead of enable
///   ALLOW_INITIALIZED=1  skip the not-yet-initialized guard (e.g. re-enable)
contract SafeEnablePresaleVault is Script {
    address constant SAFE = 0x872c561f699B42977c093F0eD8b4C9a431280c6c;
    address constant FACTORY = 0x04F1a284168743759BE6554f607a10CEBdB77760;
    address constant ZERO = address(0);

    // Safe requires signatures sorted by signer address ascending.
    // Signer 2 (0x6FDD) < Signer 1 (0x8f60), so SIG2 first.
    uint256 sk1;
    uint256 sk2;

    function setUp() public {
        sk1 = uint256(vm.envBytes32("SAFE_SK1"));
        sk2 = uint256(vm.envBytes32("SAFE_SK2"));
    }

    function run() external {
        address vault = vm.envAddress("PRESALE_VAULT");
        bool enabled = vm.envOr("ENABLED", true);

        // ── Sanity guards (all free reads; fail before any signature) ────────
        require(vault.code.length > 0, "PRESALE_VAULT has no code");
        require(
            ILiquidExtension(vault).supportsInterface(type(ILiquidExtension).interfaceId),
            "vault does not support ILiquidExtension (setExtension would revert)"
        );
        require(IPresaleVault(vault).factory() == FACTORY, "vault.factory() != Liquid factory");
        require(ILiquidFactoryOwner(FACTORY).owner() == SAFE, "factory owner is not the Safe");
        if (enabled && !vm.envOr("ALLOW_INITIALIZED", false)) {
            // A vault that already ran receiveTokens() belongs to a past launch;
            // enabling it again is almost certainly the wrong address.
            require(
                !IPresaleVault(vault).initialized(),
                "vault already initialized (set ALLOW_INITIALIZED=1 to override)"
            );
        }

        bytes memory data = abi.encodeWithSignature("setExtension(address,bool)", vault, enabled);

        vm.startBroadcast(vm.envUint("EXECUTOR_PK"));
        _execSafe(FACTORY, data);
        vm.stopBroadcast();

        console.log("setExtension executed: vault=%s enabled=%s", vault, enabled);
    }

    function _execSafe(address to, bytes memory data) internal {
        uint256 nonce = ISafe(SAFE).nonce();
        bytes32 txHash = ISafe(SAFE).getTransactionHash(to, 0, data, 0, 0, 0, 0, ZERO, ZERO, nonce);

        // Sign with both keys (signer 2 first — lower address)
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(sk2, txHash);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(sk1, txHash);

        bytes memory sigs = abi.encodePacked(r2, s2, v2, r1, s1, v1);

        bool success =
            ISafe(SAFE).execTransaction(to, 0, data, 0, 0, 0, 0, ZERO, payable(ZERO), sigs);
        require(success, "SafeTx failed");
    }
}
