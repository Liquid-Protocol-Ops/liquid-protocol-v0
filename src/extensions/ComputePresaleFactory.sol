// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ⚠ SUPERSEDED (2026-06-12, Linear MOG-497): the canonical Venice Agent Launchpad presale
// contract is LiquidPresaleVault (liquid-website repo, contracts/presale/). This contract is
// retained for tests/reference and must not be deployed for new launches.

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
 * Salt discipline (enforced on-chain): the effective CREATE2 salt and the registry
 * key are both derived as keccak256(abi.encode(msg.sender, salt)). The caller-supplied
 * `salt` is only ever a namespace *within* the caller's own address space, so a
 * different EOA can never deploy to — or burn the registry slot of — another deployer's
 * vault address. Use computeAddress(deployer, salt, ...) (or effectiveSalt(deployer, salt))
 * to predict the address / registry key for a given deployer.
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

    mapping(bytes32 => address) public vaultAt; // effectiveSalt(deployer, salt) → deployed vault

    // ── Core: deploy ──────────────────────────────────────────────────────────

    /**
     * Deploy a ComputePresaleVault at a deterministic CREATE2 address.
     *
     * The effective CREATE2 salt and registry key are derived from msg.sender, so the
     * supplied `salt` only namespaces deployments within the caller's own address space.
     * This makes front-running impossible: another EOA passing the same `salt` resolves
     * to a different effective salt, a different address, and a different registry slot.
     *
     * @param salt          Caller-chosen namespace value (need not be secret).
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
        if (liquidFactory == address(0) || depositToken == address(0)) {
            revert ZeroAddress();
        }

        bytes32 namespacedSalt = effectiveSalt(msg.sender, salt);
        if (vaultAt[namespacedSalt] != address(0)) revert SaltAlreadyUsed();

        bytes memory initCode =
            _initCode(liquidFactory, depositToken, agentWallet, lockDuration, depositWindow);

        assembly {
            vault := create2(0, add(initCode, 0x20), mload(initCode), namespacedSalt)
        }
        if (vault == address(0)) revert DeployFailed();

        vaultAt[namespacedSalt] = vault;

        emit VaultDeployed(
            namespacedSalt, vault, depositToken, agentWallet, lockDuration, depositWindow
        );
    }

    // ── Core: predict ─────────────────────────────────────────────────────────

    /**
     * Compute the vault address for the given parameters without deploying.
     * Use this to pre-compute the vault address for extensionConfigs.
     *
     * @param deployer      The address that will call deployVault() (the namespace owner).
     * @param salt          The same salt that will be passed to deployVault().
     * @param liquidFactory Liquid Protocol factory address.
     * @param depositToken  VVV or DIEM token address.
     * @param agentWallet   Agent wallet address.
     * @param lockDuration  Lock duration in seconds (0 = VVV mode).
     * @param depositWindow Deposit window in seconds.
     * @return predicted    Deterministic vault address.
     */
    function computeAddress(
        address deployer,
        bytes32 salt,
        address liquidFactory,
        address depositToken,
        address agentWallet,
        uint256 lockDuration,
        uint256 depositWindow
    ) external view returns (address predicted) {
        bytes32 ns = effectiveSalt(deployer, salt);
        bytes32 initCodeHash = keccak256(
            _initCode(liquidFactory, depositToken, agentWallet, lockDuration, depositWindow)
        );
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), ns, initCodeHash));
        predicted = address(uint160(uint256(hash)));
    }

    // ── Convenience: salt derivation ──────────────────────────────────────────

    /**
     * Derive the effective CREATE2 salt / registry key for a (deployer, salt) pair.
     * Mirrors the internal derivation used by deployVault(), so off-chain callers can
     * look up vaultAt(...) or reproduce the deployment address for a given deployer.
     *
     * @param deployer  The address that calls (or will call) deployVault().
     * @param salt      The caller-supplied salt namespace value.
     * @return          keccak256(abi.encode(deployer, salt)).
     */
    function effectiveSalt(address deployer, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(deployer, salt));
    }

    /**
     * Optional helper to derive a bytes32 salt from a uint256 nonce.
     * Front-running protection no longer depends on this — deployVault() namespaces by
     * msg.sender unconditionally — but it remains a convenient way to pick a unique salt.
     *
     * @param deployer  Address to namespace the nonce under.
     * @param nonce     Any unique uint256 (e.g., block.number, counter).
     * @return          Bytes32 salt suitable for deployVault().
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
