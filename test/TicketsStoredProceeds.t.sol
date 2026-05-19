// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// forge-lint: disable-start

import {ITickets} from "../src/ITickets.sol";
import {BaseTicketsTest} from "./BaseTicketsTest.t.sol";

contract TicketsStoredProceedsTest is BaseTicketsTest {
    address buyer = makeAddr("buyer");

    function _buyInRoundZero() internal {
        _deposit(buyer, MINIMUM_PRICE);
        vm.prank(buyer);
        tickets.purchaseTicket(0, MINIMUM_PRICE, bytes32(0));
    }

    /// @dev The accumulator must use the price of the round being closed, not the new round's
    ///      price. Inflate `_ticketsSoldThisRound` past target so the post-update excess pushes
    ///      `_currentPrice` strictly higher; the credit should still use the old MINIMUM_PRICE.
    function test_storedProceeds_creditsUseStoredPriceNotNewPrice() public {
        _buyInRoundZero();
        tickets.exposed_setTicketsSoldThisRound(MAX_TICKETS);

        uint256 oldPrice = tickets.exposed_storedCurrentPrice();
        assertEq(oldPrice, MINIMUM_PRICE);

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        tickets.exposed_lazyUpdateRoundState();

        // sanity: new price moved strictly above the old price
        assertGt(tickets.exposed_storedCurrentPrice(), oldPrice);

        // credit used the OLD price, not the new one
        assertEq(tickets.exposed_storedProceeds(), uint256(MAX_TICKETS) * oldPrice);
    }

    function test_storedProceeds_accumulatesAcrossRounds() public {
        // Round 0: one purchase at MINIMUM_PRICE.
        _buyInRoundZero();

        // Close round 0: credits 1 * MINIMUM_PRICE.
        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        tickets.exposed_lazyUpdateRoundState();
        assertEq(tickets.exposed_storedProceeds(), MINIMUM_PRICE);

        // buyer was grandfathered by round 0; reuse for round 1.
        uint256 r1Price = tickets.currentPrice();
        _deposit(buyer, r1Price);
        vm.prank(buyer);
        tickets.purchaseTicket(1, r1Price, bytes32(0));

        // Close round 1: credits another 1 * r1Price on top of the running total.
        vm.warp(FIRST_ROUND_START + 2 * ROUND_DURATION);
        tickets.exposed_lazyUpdateRoundState();
        assertEq(tickets.exposed_storedProceeds(), MINIMUM_PRICE + r1Price);
    }

    function test_storedProceeds_doubleLazyUpdate_creditsOnce() public {
        _buyInRoundZero();

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        tickets.exposed_lazyUpdateRoundState();
        uint256 afterFirst = tickets.exposed_storedProceeds();
        assertEq(afterFirst, MINIMUM_PRICE);

        // Second call in the same round is a no-op: roundsElapsedSinceStored() is now 0.
        tickets.exposed_lazyUpdateRoundState();
        assertEq(tickets.exposed_storedProceeds(), afterFirst);
    }

    function test_storedProceeds_emptyRoundCreditsZero() public {
        assertEq(tickets.ticketsSoldThisRound(), 0);

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        tickets.exposed_lazyUpdateRoundState();

        assertEq(tickets.exposed_storedProceeds(), 0);
    }

    /// @dev `_storedProceeds += uint112(_ticketsSoldThisRound) * _currentPrice` must not overflow
    ///      at the per-round cap (uint16 max tickets * uint72 max price ~ 2**88 < uint112 ~ 2**112).
    ///      Pins the at-cap value so a future width tightening of `_storedProceeds` is caught.
    ///
    ///      The 656-round warp makes `elapsed * target = 65600 > 65535 = gross`, so the post-update
    ///      excess saturates to 0 and the subsequent `currentPrice()` call doesn't blow up the
    ///      Taylor series. That's only a setup convenience — the property under test is the credit
    ///      multiplication, not the price computation.
    function test_storedProceeds_singleRoundCapDoesNotOverflowUint112() public {
        tickets.exposed_setTicketsSoldThisRound(type(uint16).max);
        tickets.exposed_setCurrentPrice(type(uint72).max);

        vm.warp(FIRST_ROUND_START + 656 * ROUND_DURATION);
        tickets.exposed_lazyUpdateRoundState();

        uint256 expected = uint256(type(uint16).max) * uint256(type(uint72).max);
        assertEq(tickets.exposed_storedProceeds(), expected);
    }
}
