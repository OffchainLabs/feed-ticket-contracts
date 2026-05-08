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
        vm.warp(DEPLOY_TIMESTAMP + 5 * ROUND_DURATION);
        assertEq(tickets.roundsElapsedSinceStored(), 5);
        vm.warp(DEPLOY_TIMESTAMP + 5 * ROUND_DURATION - 1);
        assertEq(tickets.roundsElapsedSinceStored(), 4);
    }

    function test_roundNumber_zeroAtDeploy() public view {
        assertEq(tickets.roundNumber(), 0);
    }

    function test_roundNumber_addsElapsedRoundsToStored() public {
        vm.warp(DEPLOY_TIMESTAMP + 3 * ROUND_DURATION);
        assertEq(tickets.roundNumber(), 3);
        vm.warp(DEPLOY_TIMESTAMP + 3 * ROUND_DURATION - 1);
        assertEq(tickets.roundNumber(), 2);
    }

    function test_roundStart_isDeployTimestampAtDeploy() public view {
        assertEq(tickets.roundStart(), DEPLOY_TIMESTAMP);
    }

    function test_roundStart_advancesByRoundDuration() public {
        vm.warp(DEPLOY_TIMESTAMP + 3 * ROUND_DURATION);
        assertEq(tickets.roundStart(), DEPLOY_TIMESTAMP + 3 * ROUND_DURATION);
        vm.warp(DEPLOY_TIMESTAMP + 3 * ROUND_DURATION - 1);
        assertEq(tickets.roundStart(), DEPLOY_TIMESTAMP + 2 * ROUND_DURATION);
    }

    function test_roundEnd_oneRoundAfterStartAtDeploy() public view {
        assertEq(tickets.roundEnd(), DEPLOY_TIMESTAMP + ROUND_DURATION);
    }

    function test_roundEnd_advancesByRoundDuration() public {
        vm.warp(DEPLOY_TIMESTAMP + 3 * ROUND_DURATION);
        assertEq(tickets.roundEnd(), DEPLOY_TIMESTAMP + 4 * ROUND_DURATION);
        vm.warp(DEPLOY_TIMESTAMP + 3 * ROUND_DURATION - 1);
        assertEq(tickets.roundEnd(), DEPLOY_TIMESTAMP + 3 * ROUND_DURATION);
    }

    function test_excessTicketsSold_returnsStoredWhenNoRoundsElapsed() public {
        tickets.exposed_setTicketsSold(0, 350);
        assertEq(tickets.excessTicketsSold(), 0);
    }

    function test_excessTicketsSold_appliesFormulaAfterAdvance() public {
        tickets.exposed_setTicketsSold(0, 350);
        vm.warp(DEPLOY_TIMESTAMP + 1 * ROUND_DURATION);
        assertEq(tickets.excessTicketsSold(), 350 - TARGET_TICKETS);
        vm.warp(DEPLOY_TIMESTAMP + 3 * ROUND_DURATION - 1);
        assertEq(tickets.excessTicketsSold(), 350 - 2 * TARGET_TICKETS);
    }

    function test_lazyUpdateRoundState_writesViewValuesToPrivateState() public {
        tickets.exposed_setTicketsSold(0, 350);
        vm.warp(DEPLOY_TIMESTAMP + 3 * ROUND_DURATION + 17);

        uint256 expectedRound = tickets.roundNumber();
        uint256 expectedStart = tickets.roundStart();
        uint256 expectedExcess = tickets.excessTicketsSold();

        tickets.exposed_lazyUpdateRoundState();

        assertEq(tickets.exposed_storedRoundNumber(), expectedRound);
        assertEq(tickets.exposed_storedRoundStart(), expectedStart);
        assertEq(tickets.exposed_storedExcessTicketsSold(), expectedExcess);
    }

    // TODO: test lazy update modifier sets admin config
}
