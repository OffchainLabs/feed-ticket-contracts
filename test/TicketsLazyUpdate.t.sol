// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// forge-lint: disable-start

import {ITickets} from "../src/interfaces/ITickets.sol";
import {BaseTicketsTest} from "./BaseTicketsTest.t.sol";

contract TicketsLazyUpdateTest is BaseTicketsTest {
    function test_roundsElapsedSinceStored_zeroWithinFirstRound() public view {
        assertEq(tickets.roundsElapsedSinceStored(), 0);
    }

    function test_roundsElapsedSinceStored_countsElapsedRounds() public {
        vm.warp(FIRST_ROUND_START + 5 * ROUND_DURATION);
        assertEq(tickets.roundsElapsedSinceStored(), 5);
        vm.warp(FIRST_ROUND_START + 5 * ROUND_DURATION - 1);
        assertEq(tickets.roundsElapsedSinceStored(), 4);
    }

    function test_roundNumber_zeroAtFirstRoundStart() public view {
        assertEq(tickets.roundNumber(), 0);
    }

    function test_roundNumber_addsElapsedRoundsToStored() public {
        vm.warp(FIRST_ROUND_START + 3 * ROUND_DURATION);
        assertEq(tickets.roundNumber(), 3);
        vm.warp(FIRST_ROUND_START + 3 * ROUND_DURATION - 1);
        assertEq(tickets.roundNumber(), 2);
    }

    function test_roundStart_isFirstRoundStartAtFirstRound() public view {
        assertEq(tickets.roundStart(), FIRST_ROUND_START);
    }

    function test_roundStart_advancesByRoundDuration() public {
        vm.warp(FIRST_ROUND_START + 3 * ROUND_DURATION);
        assertEq(tickets.roundStart(), FIRST_ROUND_START + 3 * ROUND_DURATION);
        vm.warp(FIRST_ROUND_START + 3 * ROUND_DURATION - 1);
        assertEq(tickets.roundStart(), FIRST_ROUND_START + 2 * ROUND_DURATION);
    }

    function test_roundEnd_oneRoundAfterStartAtFirstRound() public view {
        assertEq(tickets.roundEnd(), FIRST_ROUND_START + ROUND_DURATION);
    }

    function test_roundEnd_advancesByRoundDuration() public {
        vm.warp(FIRST_ROUND_START + 3 * ROUND_DURATION);
        assertEq(tickets.roundEnd(), FIRST_ROUND_START + 4 * ROUND_DURATION);
        vm.warp(FIRST_ROUND_START + 3 * ROUND_DURATION - 1);
        assertEq(tickets.roundEnd(), FIRST_ROUND_START + 3 * ROUND_DURATION);
    }

    function test_excessTicketsSold_returnsStoredWhenNoRoundsElapsed() public {
        tickets.exposed_setTicketsSold(0, 350);
        assertEq(tickets.excessTicketsSold(), 0);
    }

    function test_excessTicketsSold_appliesFormulaAfterAdvance() public {
        tickets.exposed_setTicketsSold(0, 350);
        vm.warp(FIRST_ROUND_START + 1 * ROUND_DURATION);
        assertEq(tickets.excessTicketsSold(), 350 - TARGET_TICKETS);
        vm.warp(FIRST_ROUND_START + 3 * ROUND_DURATION - 1);
        assertEq(tickets.excessTicketsSold(), 350 - 2 * TARGET_TICKETS);
    }

    function test_lazyUpdateRoundState_writesViewValuesToPrivateState() public {
        tickets.exposed_setTicketsSold(0, 350);
        vm.warp(FIRST_ROUND_START + 3 * ROUND_DURATION + 17);

        uint256 expectedRound = tickets.roundNumber();
        uint256 expectedStart = tickets.roundStart();
        uint256 expectedExcess = tickets.excessTicketsSold();

        tickets.exposed_lazyUpdateRoundState();

        assertEq(tickets.exposed_storedRoundNumber(), expectedRound);
        assertEq(tickets.exposed_storedRoundStart(), expectedStart);
        assertEq(tickets.exposed_storedExcessTicketsSold(), expectedExcess);
    }

    function test_lazyUpdateRoundState_appliesQueuedAdminConfig() public {
        uint24 newDuration = 2 hours;
        uint16 newTarget = 150;
        uint16 newMax = 300;
        uint64 newMinPrice = 2 ether;
        uint24 newFraction = 75;

        vm.startPrank(marketParamsSetter);
        tickets.setRoundDuration(newDuration);
        tickets.setTargetTicketsPerRound(newTarget);
        tickets.setMaxTicketsPerRound(newMax);
        tickets.setPricingParams(newMinPrice, newFraction);
        vm.stopPrank();

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        tickets.exposed_lazyUpdateRoundState();

        assertEq(tickets.roundDuration(), newDuration);
        assertEq(tickets.targetTicketsPerRound(), newTarget);
        assertEq(tickets.maxTicketsPerRound(), newMax);
        assertEq(tickets.minimumPrice(), newMinPrice);
        assertEq(tickets.priceUpdateFraction(), newFraction);

        assertEq(tickets.nextRoundDuration(), 0);
        assertEq(tickets.nextTargetTicketsPerRound(), 0);
        assertEq(tickets.nextMaxTicketsPerRound(), 0);
        assertEq(tickets.nextMinimumPrice(), 0);
        assertEq(tickets.nextPriceUpdateFraction(), 0);
    }
}
