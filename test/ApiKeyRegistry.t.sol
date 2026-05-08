// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ApiKeyRegistry} from "../src/ApiKeyRegistry.sol";
import {IApiKeyRegistry} from "../src/interfaces/IApiKeyRegistry.sol";

contract ApiKeyRegistryTest is Test {
    ApiKeyRegistry registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    bytes32 constant HASH_A = keccak256("key-a");
    bytes32 constant HASH_B = keccak256("key-b");

    function setUp() public {
        registry = new ApiKeyRegistry();
    }

    function test_getKeyHash_zeroByDefault() public view {
        assertEq(registry.getKeyHash(alice), bytes32(0));
    }

    function test_registerKeyHash_storesHashForCaller() public {
        vm.prank(alice);
        registry.registerKeyHash(HASH_A);
        assertEq(registry.getKeyHash(alice), HASH_A);
        assertEq(registry.getKeyHash(bob), bytes32(0));
    }

    function test_registerKeyHash_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit IApiKeyRegistry.KeyHashUpdated(alice, HASH_A);
        vm.prank(alice);
        registry.registerKeyHash(HASH_A);
    }

    function test_registerKeyHash_overwritesPriorHash() public {
        vm.startPrank(alice);
        registry.registerKeyHash(HASH_A);
        registry.registerKeyHash(HASH_B);
        vm.stopPrank();
        assertEq(registry.getKeyHash(alice), HASH_B);
    }

    function test_registerKeyHash_isPerSender() public {
        vm.prank(alice);
        registry.registerKeyHash(HASH_A);
        vm.prank(bob);
        registry.registerKeyHash(HASH_B);
        assertEq(registry.getKeyHash(alice), HASH_A);
        assertEq(registry.getKeyHash(bob), HASH_B);
    }

    function test_registerKeyHash_zeroIsAllowed() public {
        vm.startPrank(alice);
        registry.registerKeyHash(HASH_A);
        registry.registerKeyHash(bytes32(0));
        vm.stopPrank();
        assertEq(registry.getKeyHash(alice), bytes32(0));
    }

    function test_getMultipleKeyHashes_returnsInOrder() public {
        vm.prank(alice);
        registry.registerKeyHash(HASH_A);
        vm.prank(bob);
        registry.registerKeyHash(HASH_B);

        address[] memory accounts = new address[](3);
        accounts[0] = bob;
        accounts[1] = makeAddr("carol");
        accounts[2] = alice;

        bytes32[] memory hashes = registry.getMultipleKeyHashes(accounts);
        assertEq(hashes.length, 3);
        assertEq(hashes[0], HASH_B);
        assertEq(hashes[1], bytes32(0));
        assertEq(hashes[2], HASH_A);
    }

    function test_getMultipleKeyHashes_emptyArray() public view {
        address[] memory accounts = new address[](0);
        bytes32[] memory hashes = registry.getMultipleKeyHashes(accounts);
        assertEq(hashes.length, 0);
    }
}
