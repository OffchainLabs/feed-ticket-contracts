// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IApiKeyRegistry} from "./interfaces/IApiKeyRegistry.sol";

/// @title  API Key Registry
contract ApiKeyRegistry is IApiKeyRegistry {
    /// @inheritdoc IApiKeyRegistry
    mapping(address => bytes32) public getKeyHash;

    /// @inheritdoc IApiKeyRegistry
    function registerKeyHash(bytes32 newKeyHash) external {
        getKeyHash[msg.sender] = newKeyHash;
        emit KeyHashUpdated(msg.sender, newKeyHash);
    }

    /// @inheritdoc IApiKeyRegistry
    function getMultipleKeyHashes(address[] calldata accounts) external view returns (bytes32[] memory hashes) {
        hashes = new bytes32[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            hashes[i] = getKeyHash[accounts[i]];
        }
    }
}
