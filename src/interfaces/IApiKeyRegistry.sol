// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @title  API Key Registry
/// @notice Maps user accounts to hashes of API keys used to authenticate with the sequencer.
interface IApiKeyRegistry {
    /// @notice Emitted when an account's API key hash is set.
    /// @param  user       The account whose key hash was updated.
    /// @param  newKeyHash The new key hash now associated with `user`.
    event KeyHashUpdated(address indexed user, bytes32 newKeyHash);

    /// @notice Register an API key hash.
    /// @param  newKeyHash The hash of the API key to associate with the caller.
    function registerKeyHash(bytes32 newKeyHash) external;

    /// @notice Get the registered API key hash for an account.
    /// @param  account The account to look up.
    /// @return The key hash registered by `account`, or zero if none has been registered.
    function getKeyHash(address account) external view returns (bytes32);

    /// @notice Batch lookup of registered API key hashes.
    /// @param  accounts The accounts to look up.
    /// @return hashes   The key hash for each account in `accounts`, in the same order.
    function getMultipleKeyHashes(address[] calldata accounts) external view returns (bytes32[] memory hashes);
}
