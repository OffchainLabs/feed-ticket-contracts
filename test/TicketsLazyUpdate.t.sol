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
        uint32 newDuration = 2 hours;
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

    function test_views_unchangedByFirstPurchaseWithQueuedAdminSettings() public {
        address buyer = makeAddr("buyer");

        // Buyer needs a round 0 ticket to be grandfathered for round 1's first half.
        vm.deal(buyer, MINIMUM_PRICE);
        vm.prank(buyer);
        tickets.purchaseTicket{value: MINIMUM_PRICE}(0);

        vm.startPrank(marketParamsSetter);
        tickets.setRoundDuration(2 hours);
        tickets.setTargetTicketsPerRound(150);
        tickets.setMaxTicketsPerRound(300);
        tickets.setPricingParams(2 ether, 75);
        vm.stopPrank();

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);

        uint256 roundDurBefore = tickets.roundDuration();
        uint256 targetBefore = tickets.targetTicketsPerRound();
        uint256 maxBefore = tickets.maxTicketsPerRound();
        uint256 minPriceBefore = tickets.minimumPrice();
        uint256 fractionBefore = tickets.priceUpdateFraction();
        uint256 roundNumBefore = tickets.roundNumber();
        uint256 roundStartBefore = tickets.roundStart();
        uint256 roundEndBefore = tickets.roundEnd();
        uint256 excessBefore = tickets.excessTicketsSold();
        uint256 priceBefore = tickets.currentPrice();

        vm.deal(buyer, priceBefore);
        vm.prank(buyer);
        tickets.purchaseTicket{value: priceBefore}(1);

        assertEq(tickets.roundDuration(), roundDurBefore);
        assertEq(tickets.targetTicketsPerRound(), targetBefore);
        assertEq(tickets.maxTicketsPerRound(), maxBefore);
        assertEq(tickets.minimumPrice(), minPriceBefore);
        assertEq(tickets.priceUpdateFraction(), fractionBefore);
        assertEq(tickets.roundNumber(), roundNumBefore);
        assertEq(tickets.roundStart(), roundStartBefore);
        assertEq(tickets.roundEnd(), roundEndBefore);
        assertEq(tickets.excessTicketsSold(), excessBefore);
        assertEq(tickets.currentPrice(), priceBefore);
    }

    function test_excessAndTiming_unaffectedByQueuedAdminAcrossInactiveRounds() public {
        tickets.exposed_setTicketsSold(0, 350);

        // Queue updates that would change every view if applied: nextRoundDuration would
        // halve elapsed rounds; nextTargetTicketsPerRound would zero out the excess below.
        vm.startPrank(marketParamsSetter);
        tickets.setRoundDuration(ROUND_DURATION + 1);
        tickets.setTargetTicketsPerRound(TARGET_TICKETS + 1);
        tickets.setMaxTicketsPerRound(MAX_TICKETS + 1);
        tickets.setPricingParams(MINIMUM_PRICE + 1, PRICE_UPDATE_FRACTION + 1);
        vm.stopPrank();

        // 3 inactive rounds elapse; no mutating call ever flushes the queue.
        vm.warp(FIRST_ROUND_START + 3 * ROUND_DURATION);

        assertEq(tickets.roundsElapsedSinceStored(), 3);
        assertEq(tickets.roundNumber(), 3);
        assertEq(tickets.roundStart(), FIRST_ROUND_START + 3 * ROUND_DURATION);
        assertEq(tickets.excessTicketsSold(), 350 - 3 * TARGET_TICKETS);
    }

    function test_queuedDurationTakesEffectAtLeastOneRoundAfterQueuing() public {
        uint32 newDuration = ROUND_DURATION + 1;

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        assertEq(tickets.roundNumber(), 1);

        vm.prank(marketParamsSetter);
        tickets.setRoundDuration(newDuration);

        assertEq(tickets.nextRoundDuration(), newDuration);
        assertEq(tickets.roundDuration(), ROUND_DURATION);
        assertEq(tickets.roundEnd(), FIRST_ROUND_START + 2 * ROUND_DURATION);

        vm.warp(FIRST_ROUND_START + 2 * ROUND_DURATION);
        assertEq(tickets.roundNumber(), 2);

        assertEq(tickets.roundDuration(), newDuration);
        assertEq(tickets.roundStart(), FIRST_ROUND_START + 2 * ROUND_DURATION);
        assertEq(tickets.roundEnd(), FIRST_ROUND_START + 2 * ROUND_DURATION + newDuration);
    }

    function test_queuedTargetTakesEffectAtLeastOneRoundAfterQueuing() public {
        uint16 newTarget = TARGET_TICKETS + 1;

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        assertEq(tickets.roundNumber(), 1);

        vm.prank(marketParamsSetter);
        tickets.setTargetTicketsPerRound(newTarget);

        assertEq(tickets.nextTargetTicketsPerRound(), newTarget);
        assertEq(tickets.targetTicketsPerRound(), TARGET_TICKETS);

        vm.warp(FIRST_ROUND_START + 2 * ROUND_DURATION);
        assertEq(tickets.roundNumber(), 2);

        assertEq(tickets.targetTicketsPerRound(), newTarget);
    }

    function test_queuedMaxTakesEffectAtLeastOneRoundAfterQueuing() public {
        uint16 newMax = MAX_TICKETS + 1;

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        assertEq(tickets.roundNumber(), 1);

        vm.prank(marketParamsSetter);
        tickets.setMaxTicketsPerRound(newMax);

        assertEq(tickets.nextMaxTicketsPerRound(), newMax);
        assertEq(tickets.maxTicketsPerRound(), MAX_TICKETS);

        vm.warp(FIRST_ROUND_START + 2 * ROUND_DURATION);
        assertEq(tickets.roundNumber(), 2);

        assertEq(tickets.maxTicketsPerRound(), newMax);
    }

    function test_queuedPricingParamsTakeEffectAtLeastOneRoundAfterQueuing() public {
        uint64 newMinPrice = MINIMUM_PRICE + 1;
        uint24 newFraction = PRICE_UPDATE_FRACTION + 1;

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        assertEq(tickets.roundNumber(), 1);

        vm.prank(marketParamsSetter);
        tickets.setPricingParams(newMinPrice, newFraction);

        assertEq(tickets.nextMinimumPrice(), newMinPrice);
        assertEq(tickets.nextPriceUpdateFraction(), newFraction);
        assertEq(tickets.minimumPrice(), MINIMUM_PRICE);
        assertEq(tickets.priceUpdateFraction(), PRICE_UPDATE_FRACTION);

        vm.warp(FIRST_ROUND_START + 2 * ROUND_DURATION);
        assertEq(tickets.roundNumber(), 2);

        assertEq(tickets.minimumPrice(), newMinPrice);
        assertEq(tickets.priceUpdateFraction(), newFraction);
    }
}
