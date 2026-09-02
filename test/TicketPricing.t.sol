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
}
