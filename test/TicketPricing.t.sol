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
}
