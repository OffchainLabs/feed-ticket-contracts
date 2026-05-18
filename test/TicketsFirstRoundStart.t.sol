// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// forge-lint: disable-start

import {BaseTicketsTest} from "./BaseTicketsTest.t.sol";
import {ITickets} from "../src/ITickets.sol";

/// @dev Exercises the pre-start window where `block.timestamp < firstRoundStart`. Every view
///      that derives state from elapsed time, plus `purchaseTickets`, must revert. At exactly
///      `firstRoundStart` the same calls must succeed.
contract TicketsFirstRoundStartTest is BaseTicketsTest {
    address buyer = makeAddr("buyer");

    bytes4 constant PRE_START_REVERT = ITickets.BeforeFirstRoundStart.selector;

    function setUp() public override {
        super.setUp();
        // BaseTicketsTest.setUp warps to FIRST_ROUND_START. Rewind into the pre-start window.
        vm.warp(FIRST_ROUND_START - 1 hours);
    }

    function test_roundsElapsedSinceStored_revertsJustBeforeStart() public {
        vm.warp(FIRST_ROUND_START - 1);
        vm.expectRevert(PRE_START_REVERT);
        tickets.roundsElapsedSinceStored();
    }

    function test_roundsElapsedSinceStored_succeedsAtStart() public {
        vm.warp(FIRST_ROUND_START);
        assertEq(tickets.roundsElapsedSinceStored(), 0);
    }

    function test_roundNumber_revertsJustBeforeStart() public {
        vm.warp(FIRST_ROUND_START - 1);
        vm.expectRevert(PRE_START_REVERT);
        tickets.roundNumber();
    }

    function test_roundNumber_succeedsAtStart() public {
        vm.warp(FIRST_ROUND_START);
        assertEq(tickets.roundNumber(), 0);
    }

    function test_roundStart_revertsJustBeforeStart() public {
        vm.warp(FIRST_ROUND_START - 1);
        vm.expectRevert(PRE_START_REVERT);
        tickets.roundStart();
    }

    function test_roundStart_succeedsAtStart() public {
        vm.warp(FIRST_ROUND_START);
        assertEq(tickets.roundStart(), FIRST_ROUND_START);
    }

    function test_roundEnd_revertsJustBeforeStart() public {
        vm.warp(FIRST_ROUND_START - 1);
        vm.expectRevert(PRE_START_REVERT);
        tickets.roundEnd();
    }

    function test_roundEnd_succeedsAtStart() public {
        vm.warp(FIRST_ROUND_START);
        assertEq(tickets.roundEnd(), uint256(FIRST_ROUND_START) + ROUND_DURATION);
    }

    function test_grandfatherPeriodEnd_revertsJustBeforeStart() public {
        vm.warp(FIRST_ROUND_START - 1);
        vm.expectRevert(PRE_START_REVERT);
        tickets.grandfatherPeriodEnd();
    }

    function test_grandfatherPeriodEnd_succeedsAtStart() public {
        vm.warp(FIRST_ROUND_START);
        uint256 phase = (uint256(ROUND_DURATION) * GRANDFATHER_PERIOD_FRACTION) / 256;
        assertEq(tickets.grandfatherPeriodEnd(), uint256(FIRST_ROUND_START) + phase);
    }

    function test_excessTicketsSold_revertsJustBeforeStart() public {
        vm.warp(FIRST_ROUND_START - 1);
        vm.expectRevert(PRE_START_REVERT);
        tickets.excessTicketsSold();
    }

    function test_excessTicketsSold_succeedsAtStart() public {
        vm.warp(FIRST_ROUND_START);
        assertEq(tickets.excessTicketsSold(), 0);
    }

    function test_currentPrice_revertsJustBeforeStart() public {
        vm.warp(FIRST_ROUND_START - 1);
        vm.expectRevert(PRE_START_REVERT);
        tickets.currentPrice();
    }

    function test_currentPrice_succeedsAtStart() public {
        vm.warp(FIRST_ROUND_START);
        assertEq(tickets.currentPrice(), MINIMUM_PRICE);
    }

    function test_purchaseTicket_revertsJustBeforeStart() public {
        vm.warp(FIRST_ROUND_START - 1);
        vm.prank(buyer);
        vm.expectRevert(PRE_START_REVERT);
        tickets.purchaseTickets(0, MINIMUM_PRICE, 1, bytes32(0));
    }

    function test_purchaseTicket_succeedsAtStart() public {
        vm.warp(FIRST_ROUND_START);
        _deposit(buyer, MINIMUM_PRICE);
        vm.prank(buyer);
        tickets.purchaseTickets(0, MINIMUM_PRICE, 1, bytes32(0));
        assertEq(tickets.evenTicketsHeld(buyer), 1);
        assertEq(tickets.lastEvenRoundPurchased(buyer), 0);
    }
}
