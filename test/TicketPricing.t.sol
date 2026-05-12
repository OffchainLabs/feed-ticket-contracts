// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// forge-lint: disable-start

import {BaseTicketsTest} from "./BaseTicketsTest.t.sol";

contract TicketPricingTest is BaseTicketsTest {
    function test_currentPrice_returnsMinimumPriceWithNoExcess() public view {
        assertEq(tickets.currentPrice(), MINIMUM_PRICE);
    }

    function test_currentPrice_matchesFakeExponentialOfPricingState() public {
        tickets.exposed_setTicketsSold(0, 350);
        vm.warp(FIRST_ROUND_START + 2 * ROUND_DURATION);

        uint256 excess = tickets.excessTicketsSold();
        assertEq(tickets.currentPrice(), tickets.exposed_fakeExponential(MINIMUM_PRICE, excess, PRICE_UPDATE_FRACTION));
    }

    /// @dev `purchaseTicket` enforces `msg.value == _currentPrice`, while quoters read
    ///      `currentPrice()`. After a lazy update they must agree, otherwise a buyer who
    ///      quotes off the view and pays that amount will revert.
    function test_currentPrice_equalsStoredAfterLazyUpdate() public {
        tickets.exposed_setTicketsSold(0, 350);
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
        tickets.exposed_setTicketsSold(0, 1200);
        vm.warp(FIRST_ROUND_START + 2 * ROUND_DURATION);

        uint256 raw = tickets.exposed_fakeExponential(MINIMUM_PRICE, tickets.excessTicketsSold(), PRICE_UPDATE_FRACTION);
        assertGt(raw, uint256(type(uint72).max));
        assertEq(tickets.currentPrice(), type(uint72).max);
    }
}
