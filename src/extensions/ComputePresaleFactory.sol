// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * ComputePresaleFactory — CREATE2 factory for ComputePresaleVault.
 *
 * Problem: Liquid Protocol's deployToken() call takes extensionConfigs, which
 * includes the vault address. The vault must be deployed before the token, so
 * its address is known. Without CREATE2, the workflow is:
 *   1. Deploy vault → get address
 *   2. Deploy token with that address in extensionConfigs
 *
 * With CREATE2, the address is deterministic from the salt alone:
 *   1. Call computeAddress(salt, params) — no deploy needed
 *   2. Include computed address in extensionConfigs
 *   3. Deploy vault at computed address via deployVault(salt, params)
 *   4. Deploy token — factory calls vault.receiveTokens()
 *
 * Steps 3 and 4 can be batched in a single transaction via a multicall contract
 * or sequenced script, since the address is already known.
 *
 * Salt discipline: salt encodes the deployer address in the upper 20 bytes to
 * prevent front-running (another EOA cannot deploy to the same address with the
 * same salt because the salt would differ).
 *   salt = keccak256(abi.encode(msg.sender, userNonce))
 */

import {ComputePresaleVault} from "./ComputePresaleVault.sol";

contract ComputePresaleFactory {
    // ── Errors ────────────────────────────────────────────────────────────────

    error SaltAlreadyUsed();
    error DeployFailed();
    error ZeroAddress();

    // ── Events ────────────────────────────────────────────────────────────────

    event VaultDeployed(
        bytes32 indexed salt,
        address indexed vault,
        address indexed depositToken,
        address agentWallet,
        uint256 lockDuration,
        uint256 depositWindow
    );

    // ── State ─────────────────────────────────────────────────────────────────

    mapping(bytes32 => address) public vaultAt; // salt → deployed vault

    // ── Core: deploy ──────────────────────────────────────────────────────────

    /**
     * Deploy a ComputePresaleVault at a deterministic CREATE2 address.
     *
     * @param salt          Unique bytes32; include msg.sender to prevent front-running.
     * @param liquidFactory Liquid Protocol factory that will call receiveTokens().
     * @param depositToken  VVV (lockDuration=0) or DIEM (lockDuration>0).
     * @param agentWallet   Receives VVV on finalizeVVV() (VVV mode only).
     * @param lockDuration  0 = VVV irrevocable; >0 = DIEM time-lock seconds.
     * @param depositWindow Seconds from receiveTokens() until deposit window closes.
     * @return vault        Address of deployed vault.
     */
    function deployVault(
        bytes32 salt,
        address liquidFactory,
        address depositToken,
        address agentWallet,
        uint256 lockDuration,
        uint256 depositWindow
    ) external returns (address vault) {
        if (vaultAt[salt] != address(0)) revert SaltAlreadyUsed();
        if (liquidFactory == address(0) || depositToken == address(0)) revert ZeroAddress();

        bytes memory initCode =
            _initCode(liquidFactory, depositToken, agentWallet, lockDuration, depositWindow);

        assembly {
            vault := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        if (vault == address(0)) revert DeployFailed();

        vaultAt[salt] = vault;

        emit VaultDeployed(salt, vault, depositToken, agentWallet, lockDuration, depositWindow);
    }

    // ── Core: predict ─────────────────────────────────────────────────────────

    /**
     * Compute the vault address for the given parameters without deploying.
     * Use this to pre-compute the vault address for extensionConfigs.
     *
     * @param salt          The same salt that will be passed to deployVault().
     * @param liquidFactory Liquid Protocol factory address.
     * @param depositToken  VVV or DIEM token address.
     * @param agentWallet   Agent wallet address.
     * @param lockDuration  Lock duration in seconds (0 = VVV mode).
     * @param depositWindow Deposit window in seconds.
     * @return predicted    Deterministic vault address.
     */
    function computeAddress(
        bytes32 salt,
        address liquidFactory,
        address depositToken,
        address agentWallet,
        uint256 lockDuration,
        uint256 depositWindow
    ) external view returns (address predicted) {
        bytes32 initCodeHash = keccak256(
            _initCode(liquidFactory, depositToken, agentWallet, lockDuration, depositWindow)
        );
        predicted = address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash))
                )
            )
        );
    }

    // ── Convenience: build salt ───────────────────────────────────────────────

    /**
     * Build a deployer-namespaced salt from a user-supplied nonce.
     * Using the deployer address in the salt prevents front-running:
     * the same nonce from a different EOA produces a different salt.
     *
     * @param deployer  msg.sender of the deployVault call.
     * @param nonce     Any unique uint256 (e.g., block.number, counter).
     * @return salt     Bytes32 salt safe to pass to deployVault().
     */
    function buildSalt(address deployer, uint256 nonce) external pure returns (bytes32) {
        return keccak256(abi.encode(deployer, nonce));
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    function _initCode(
        address liquidFactory,
        address depositToken,
        address agentWallet,
        uint256 lockDuration,
        uint256 depositWindow
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(ComputePresaleVault).creationCode,
            abi.encode(liquidFactory, depositToken, agentWallet, lockDuration, depositWindow)
        );
    }
}
