// SPDX-License-Identifier: Apache-2.0

/*
 * Copyright 2026, Offchain Labs, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

pragma solidity ^0.8.20;

// forge-lint: disable-start

import {Test} from "forge-std/Test.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Tickets} from "../src/Tickets.sol";

/// @notice Upgrades a proxy running the 1.0.1 build. Run via test/upgrade/test-upgrade.bash, which
///         sets TICKETS_V1_0_1_BYTECODE; skipped otherwise.
contract TicketsUpgradeTest is Test {
    /// @dev 0.1%. Rescaling floors priceUpdateFraction (to over 1e5 here) and excess, shifting the
    ///      exponent by under max(1, exponent) / 1e5. Below the uint72 cap the exponent is under 36,
    ///      and 1.0.1's fake exponential truncates by under 1e-4.
    uint256 constant PRICE_TOLERANCE = 1e15;

    bytes v1Bytecode;
    Tickets tickets;

    function setUp() public {
        v1Bytecode = vm.envOr("TICKETS_V1_0_1_BYTECODE", bytes(""));
        vm.skip(v1Bytecode.length == 0);
        assertNotEq(keccak256(v1Bytecode), keccak256(type(Tickets).creationCode));
    }

    /// @dev `history` is tickets bought per round before the upgrade round. `sold` is bought in the
    ///      upgrade round after the upgrade, and must not move the next round's price.
    function testFuzz_upgradeFromV1_0_1(
        uint16 target,
        uint16 max,
        uint64 minimumPrice,
        uint40 priceUpdateFraction,
        uint16[6] memory history,
        uint16 sold
    ) public {
        target = uint16(bound(target, 1, type(uint16).max - 1));
        max = uint16(bound(max, target + 1, type(uint16).max));
        minimumPrice = uint64(bound(minimumPrice, 1e6, type(uint64).max));
        // rescaled to priceUpdateFraction * 1e6 / target, which must be over 1e5 and fit a uint40
        priceUpdateFraction =
            uint40(bound(priceUpdateFraction, target / 10 + 1, uint256(type(uint40).max) * target / 1e6));
        _deployV1(target, max, minimumPrice, priceUpdateFraction);

        for (uint256 i; i < history.length; i++) {
            _buy(history[i]);
            vm.warp(tickets.roundEnd());
        }
        tickets.commitRoundState();

        uint256 price = tickets.currentPrice();
        ProxyAdmin proxyAdmin =
            ProxyAdmin(address(uint160(uint256(vm.load(address(tickets), ERC1967Utils.ADMIN_SLOT)))));
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(tickets)),
            address(new Tickets(tickets.token())),
            abi.encodeCall(Tickets.postUpgradeInit_v1_1_0, ())
        );
        assertEq(tickets.currentPrice(), price, "upgrade round price");

        _buy(sold);
        vm.warp(tickets.roundEnd());
        assertApproxEqRel(tickets.currentPrice(), price, PRICE_TOLERANCE, "next round price");
    }

    /// @dev Deploys 1.0.1 behind a proxy owned by this contract, which is also a funded buyer.
    function _deployV1(uint16 target, uint16 max, uint64 minimumPrice, uint40 priceUpdateFraction) internal {
        ERC20Mock token = new ERC20Mock();
        bytes memory code = bytes.concat(v1Bytecode, abi.encode(address(token)));
        address v1Impl;
        assembly {
            v1Impl := create(0, add(code, 0x20), mload(code))
        }
        assertNotEq(v1Impl, address(0));

        Tickets.InitParams memory p = Tickets.InitParams({
            defaultAdmin: address(this),
            beneficiarySetter: address(this),
            marketParamsSetter: address(this),
            beneficiary: address(this),
            roundDuration: 1 hours,
            targetTicketsPerRound: target,
            maxTicketsPerRound: max,
            minimumPrice: minimumPrice,
            priceUpdateFraction: priceUpdateFraction,
            grandfatherPeriodFraction: 0,
            firstRoundStart: uint40(block.timestamp + 1)
        });
        tickets = Tickets(
            address(new TransparentUpgradeableProxy(v1Impl, address(this), abi.encodeCall(Tickets.initialize, (p))))
        );
        vm.warp(block.timestamp + 1);

        token.mint(address(this), type(uint128).max);
        token.approve(address(tickets), type(uint128).max);
        tickets.depositToken(type(uint128).max);
    }

    /// @dev Buys `n` tickets, which purchaseTickets clamps to the room left in the round.
    function _buy(uint256 n) internal {
        if (n > 0) tickets.purchaseTickets(tickets.roundNumber(), tickets.currentPrice(), n, bytes32(0));
    }
}
