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
        vm.warp(DEPLOY_TIMESTAMP + 2 * ROUND_DURATION);

        uint256 excess = tickets.excessTicketsSold();
        assertEq(
            tickets.currentPrice(),
            tickets.exposed_fakeExponential(MINIMUM_PRICE, excess, PRICE_UPDATE_FRACTION)
        );
    }

    /// @dev `purchaseTicket` enforces `msg.value == _currentPrice`, while quoters read
    ///      `currentPrice()`. After a lazy update they must agree, otherwise a buyer who
    ///      quotes off the view and pays that amount will revert.
    function test_currentPrice_equalsStoredAfterLazyUpdate() public {
        tickets.exposed_setTicketsSold(0, 350);
        vm.warp(DEPLOY_TIMESTAMP + ROUND_DURATION);
        tickets.exposed_lazyUpdateRoundState();

        assertEq(tickets.currentPrice(), tickets.exposed_storedCurrentPrice());
    }

    /// @dev Same invariant, but exercises the path where a queued pricing-param update
    ///      gets applied during the lazy update. Catches the case where the cache is
    ///      written before `_applyAdminUpdates`, leaving `_currentPrice` on old params
    ///      while `currentPrice()` recomputes with new ones.
    function test_currentPrice_equalsStoredAfterPricingParamUpdateApplies() public {
        vm.prank(marketParamsSetter);
        tickets.setPricingParams(2 ether, 100);

        vm.warp(DEPLOY_TIMESTAMP + ROUND_DURATION);
        tickets.exposed_lazyUpdateRoundState();

        assertEq(tickets.currentPrice(), tickets.exposed_storedCurrentPrice());
    }
}
