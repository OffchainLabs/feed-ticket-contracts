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

import {BaseTicketsTest} from "./BaseTicketsTest.t.sol";
import {ITickets} from "../src/ITickets.sol";

contract TicketPricingTest is BaseTicketsTest {
    function test_currentPrice_returnsMinimumPriceWithNoExcess() public view {
        assertEq(tickets.currentPrice(), MINIMUM_PRICE);
    }

    function test_currentPrice_matchesFakeExponentialOfPricingState() public {
        tickets.exposed_setTicketsSoldThisRound(350);
        vm.warp(FIRST_ROUND_START + 2 * ROUND_DURATION);

        uint256 excess = tickets.excessTicketsSold();
        assertEq(tickets.currentPrice(), tickets.exposed_fakeExponential(MINIMUM_PRICE, excess, PRICE_UPDATE_FRACTION));
    }

    /// @dev `purchaseTickets` enforces `expectedPrice == _currentPrice`, while quoters read
    ///      `currentPrice()`. After a lazy update they must agree, otherwise a buyer who
    ///      quotes off the view and passes that value as `expectedPrice` will revert.
    function test_currentPrice_equalsStoredAfterLazyUpdate() public {
        tickets.exposed_setTicketsSoldThisRound(350);
        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        tickets.exposed_lazyUpdateRoundState();

        assertEq(tickets.currentPrice(), tickets.exposed_storedCurrentPrice());
    }

    /// @dev Same invariant, but exercises the path where a queued pricing-param update
    ///      gets applied during the lazy update. Catches the case where the cache is
    ///      written before `_applyAdminUpdates`, leaving `_currentPrice` on old params
    ///      while `currentPrice()` recomputes with new ones.
    function test_currentPrice_equalsStoredAfterPricingParamUpdateApplies() public {
        vm.prank(marketParamsSetter);
        tickets.setPricingParams(2 ether, 100, 0);

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        tickets.exposed_lazyUpdateRoundState();

        assertEq(tickets.currentPrice(), tickets.exposed_storedCurrentPrice());
    }

    /// @dev `currentPrice` returns uint72, while `_fakeExponential` produces a uint256
    ///      that can far exceed uint72.max. The view must saturate instead of reverting
    ///      on the narrowing cast.
    function test_currentPrice_saturatesAtUint72Max() public {
        // E/F = 1000/50 = 20 -> e^20 ~= 4.85e8 -> raw ~= 4.85e26 wei, well past uint72.max (~4.72e21).
        tickets.exposed_setTicketsSoldThisRound(1200);
        vm.warp(FIRST_ROUND_START + 2 * ROUND_DURATION);

        uint256 raw = tickets.exposed_fakeExponential(MINIMUM_PRICE, tickets.excessTicketsSold(), PRICE_UPDATE_FRACTION);
        assertGt(raw, uint256(type(uint72).max));
        assertEq(tickets.currentPrice(), type(uint72).max);
    }

    /// @dev Raises max to 500 (target 100) and commits it, leaving the contract at round 1.
    function _setMax500() internal {
        vm.prank(marketParamsSetter);
        tickets.setMaxTicketsPerRound(500);
        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        tickets.commitRoundState();
    }

    function test_excessTicketsSold_scalesSalesAboveTarget() public {
        _setMax500();
        tickets.exposed_setTicketsSoldThisRound(300);
        vm.warp(FIRST_ROUND_START + 2 * ROUND_DURATION);

        // EXCESS_SCALE * (1 + (300 - 100) / (500 - 100) - 1)
        assertEq(tickets.excessTicketsSold(), EXCESS_SCALE / 2);
    }

    function test_excessTicketsSold_countsSingleTicketAboveTarget() public {
        _setMax500();
        tickets.exposed_setTicketsSoldThisRound(TARGET_TICKETS + 1);
        vm.warp(FIRST_ROUND_START + 2 * ROUND_DURATION);

        assertEq(tickets.excessTicketsSold(), EXCESS_SCALE / (500 - TARGET_TICKETS));
    }

    function test_excessTicketsSold_saturatesBelowSentinel() public {
        vm.prank(marketParamsSetter);
        tickets.setPricingParams(MINIMUM_PRICE, PRICE_UPDATE_FRACTION, type(uint56).max - 1);
        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        tickets.commitRoundState();

        tickets.exposed_setTicketsSoldThisRound(MAX_TICKETS);
        vm.warp(FIRST_ROUND_START + 2 * ROUND_DURATION);
        tickets.commitRoundState();

        assertEq(tickets.excessTicketsSold(), type(uint56).max - 1);
        assertEq(tickets.currentPrice(), type(uint72).max);
    }

    function test_currentPrice_fullRoundThenEmptyRoundRestoresMinimum() public {
        _setMax500();
        tickets.exposed_setTicketsSoldThisRound(500);
        vm.warp(FIRST_ROUND_START + 2 * ROUND_DURATION);
        tickets.commitRoundState();

        assertEq(
            tickets.currentPrice(), tickets.exposed_fakeExponential(MINIMUM_PRICE, EXCESS_SCALE, PRICE_UPDATE_FRACTION)
        );

        vm.warp(FIRST_ROUND_START + 3 * ROUND_DURATION);
        assertEq(tickets.currentPrice(), MINIMUM_PRICE);
    }

    function test_setTargetTicketsPerRound_revertsAtOrAboveMax() public {
        vm.startPrank(marketParamsSetter);
        vm.expectRevert(abi.encodeWithSelector(ITickets.TargetTicketsNotBelowMax.selector, MAX_TICKETS, MAX_TICKETS));
        tickets.setTargetTicketsPerRound(MAX_TICKETS);
        tickets.setTargetTicketsPerRound(MAX_TICKETS - 1);
        assertEq(tickets.nextTargetTicketsPerRound(), MAX_TICKETS - 1);
    }

    function test_setMaxTicketsPerRound_revertsAtOrBelowTarget() public {
        vm.startPrank(marketParamsSetter);
        vm.expectRevert(
            abi.encodeWithSelector(ITickets.TargetTicketsNotBelowMax.selector, TARGET_TICKETS, TARGET_TICKETS)
        );
        tickets.setMaxTicketsPerRound(TARGET_TICKETS);
        tickets.setMaxTicketsPerRound(TARGET_TICKETS + 1);
        assertEq(tickets.nextMaxTicketsPerRound(), TARGET_TICKETS + 1);
    }

    function test_setTargetTicketsPerRound_checksQueuedMax() public {
        vm.startPrank(marketParamsSetter);
        tickets.setMaxTicketsPerRound(TARGET_TICKETS + 10);
        vm.expectRevert(
            abi.encodeWithSelector(ITickets.TargetTicketsNotBelowMax.selector, TARGET_TICKETS + 10, TARGET_TICKETS + 10)
        );
        tickets.setTargetTicketsPerRound(TARGET_TICKETS + 10);

        tickets.setMaxTicketsPerRound(MAX_TICKETS + 100);
        tickets.setTargetTicketsPerRound(MAX_TICKETS + 50);
        assertEq(tickets.nextTargetTicketsPerRound(), MAX_TICKETS + 50);
    }

    function test_setMaxTicketsPerRound_checksQueuedTarget() public {
        vm.startPrank(marketParamsSetter);
        tickets.setTargetTicketsPerRound(TARGET_TICKETS + 50);
        vm.expectRevert(
            abi.encodeWithSelector(ITickets.TargetTicketsNotBelowMax.selector, TARGET_TICKETS + 50, TARGET_TICKETS + 50)
        );
        tickets.setMaxTicketsPerRound(TARGET_TICKETS + 50);

        tickets.setTargetTicketsPerRound(TARGET_TICKETS / 2);
        tickets.setMaxTicketsPerRound(TARGET_TICKETS);
        assertEq(tickets.nextMaxTicketsPerRound(), TARGET_TICKETS);
    }
}
