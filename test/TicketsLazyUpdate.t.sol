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

import {ITickets} from "../src/ITickets.sol";
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

    function test_grandfatherPeriodEnd_atFirstRound() public view {
        uint256 phase = (uint256(ROUND_DURATION) * GRANDFATHER_PERIOD_FRACTION) / 256;
        assertEq(tickets.grandfatherPeriodEnd(), FIRST_ROUND_START + phase);
    }

    function test_grandfatherPeriodEnd_advancesByRoundDuration() public {
        uint256 phase = (uint256(ROUND_DURATION) * GRANDFATHER_PERIOD_FRACTION) / 256;
        vm.warp(FIRST_ROUND_START + 3 * ROUND_DURATION);
        assertEq(tickets.grandfatherPeriodEnd(), FIRST_ROUND_START + 3 * ROUND_DURATION + phase);
        vm.warp(FIRST_ROUND_START + 3 * ROUND_DURATION - 1);
        assertEq(tickets.grandfatherPeriodEnd(), FIRST_ROUND_START + 2 * ROUND_DURATION + phase);
    }

    function test_excessTicketsSold_returnsStoredWhenNoRoundsElapsed() public {
        tickets.exposed_setTicketsSoldThisRound(350);
        assertEq(tickets.excessTicketsSold(), 0);
    }

    function test_excessTicketsSold_appliesFormulaAfterAdvance() public {
        tickets.exposed_setTicketsSoldThisRound(350);
        vm.warp(FIRST_ROUND_START + 1 * ROUND_DURATION);
        assertEq(tickets.excessTicketsSold(), 350 - TARGET_TICKETS);
        vm.warp(FIRST_ROUND_START + 3 * ROUND_DURATION - 1);
        assertEq(tickets.excessTicketsSold(), 350 - 2 * TARGET_TICKETS);
    }

    /// @dev With a queued pricing update, excessTicketsSold() returns the override (not the
    ///      natural-decay value) once a round has elapsed, and the override does not itself
    ///      decay across further inactive rounds. The override is distinct from both
    ///      `_excessTicketsSold` (0) and the natural-decay value (350 - 1 * TARGET_TICKETS = 250).
    function test_excessTicketsSold_returnsOverrideWhenPricingUpdateQueuedAndRoundElapsed() public {
        tickets.exposed_setTicketsSoldThisRound(350);

        uint56 newExcessOverride = 42;
        vm.prank(marketParamsSetter);
        tickets.setPricingParams(MINIMUM_PRICE, PRICE_UPDATE_FRACTION, newExcessOverride);

        // Boundary - 1: still in the first round, override does not apply.
        vm.warp(FIRST_ROUND_START + ROUND_DURATION - 1);
        assertEq(tickets.excessTicketsSold(), 0);

        // Boundary: one round elapsed, override applies in place of the natural-decay value.
        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        assertEq(tickets.excessTicketsSold(), newExcessOverride);

        // Further inactive rounds: override does not itself decay.
        vm.warp(FIRST_ROUND_START + 5 * ROUND_DURATION);
        assertEq(tickets.excessTicketsSold(), newExcessOverride);
    }

    /// @dev Regression: a pricing-params commit resets `excessTicketsSoldOverride` to its
    ///      `type(uint56).max` sentinel (not 0). A later non-pricing admin update flips
    ///      `isAdminUpdateQueued` back on, but `excessTicketsSold()` must still take the
    ///      formula path rather than returning the stale override.
    function test_excessTicketsSold_formulaAfterPricingCommitThenNonPricingQueue() public {
        uint56 firstOverride = 42;
        vm.prank(marketParamsSetter);
        tickets.setPricingParams(MINIMUM_PRICE, PRICE_UPDATE_FRACTION, firstOverride);

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        tickets.exposed_lazyUpdateRoundState();
        assertEq(tickets.exposed_storedExcessTicketsSold(), firstOverride);
        assertEq(tickets.excessTicketsSoldOverride(), type(uint56).max);

        tickets.exposed_setTicketsSoldThisRound(350);
        vm.prank(marketParamsSetter);
        tickets.setRoundDuration(ROUND_DURATION + 1);

        // Boundary - 1: elapsed == 0, view short-circuits to the stored value.
        assertEq(tickets.excessTicketsSold(), firstOverride);

        // Boundary: one round elapsed, view must take the formula path.
        vm.warp(FIRST_ROUND_START + 2 * ROUND_DURATION);
        uint256 expectedExcess = uint256(firstOverride) + 350 - TARGET_TICKETS;
        assertEq(tickets.excessTicketsSold(), expectedExcess);

        // Commit also writes the formula value (not the stale override) to storage.
        tickets.exposed_lazyUpdateRoundState();
        assertEq(tickets.exposed_storedExcessTicketsSold(), expectedExcess);
    }

    function test_lazyUpdateRoundState_writesViewValuesToPrivateState() public {
        tickets.exposed_setTicketsSoldThisRound(350);
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
        uint56 newExcessOverride = 42;
        uint8 newGrandfatherFraction = 200;

        vm.startPrank(marketParamsSetter);
        tickets.setRoundDuration(newDuration);
        tickets.setTargetTicketsPerRound(newTarget);
        tickets.setMaxTicketsPerRound(newMax);
        tickets.setPricingParams(newMinPrice, newFraction, newExcessOverride);
        tickets.setGrandfatherPeriodFraction(newGrandfatherFraction);
        vm.stopPrank();

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        tickets.exposed_lazyUpdateRoundState();

        assertEq(tickets.roundDuration(), newDuration);
        assertEq(tickets.targetTicketsPerRound(), newTarget);
        assertEq(tickets.maxTicketsPerRound(), newMax);
        assertEq(tickets.minimumPrice(), newMinPrice);
        assertEq(tickets.priceUpdateFraction(), newFraction);
        assertEq(tickets.excessTicketsSold(), newExcessOverride);
        assertEq(tickets.grandfatherPeriodFraction(), newGrandfatherFraction);

        assertEq(tickets.nextRoundDuration(), 0);
        assertEq(tickets.nextTargetTicketsPerRound(), 0);
        assertEq(tickets.nextMaxTicketsPerRound(), 0);
        assertEq(tickets.nextMinimumPrice(), 0);
        assertEq(tickets.nextPriceUpdateFraction(), 0);
        assertEq(tickets.excessTicketsSoldOverride(), type(uint56).max);
        assertEq(tickets.nextGrandfatherPeriodFraction(), type(uint8).max);
    }

    function test_views_unchangedByFirstPurchaseWithQueuedAdminSettings() public {
        address buyer = makeAddr("buyer");

        // Buyer needs a round 0 ticket to be grandfathered for round 1's grandfather phase.
        _deposit(buyer, MINIMUM_PRICE);
        vm.prank(buyer);
        tickets.purchaseTickets(0, MINIMUM_PRICE, 1, bytes32(0));

        vm.startPrank(marketParamsSetter);
        tickets.setRoundDuration(2 hours);
        tickets.setTargetTicketsPerRound(150);
        tickets.setMaxTicketsPerRound(300);
        tickets.setPricingParams(2 ether, 75, 0);
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

        _deposit(buyer, priceBefore);
        vm.prank(buyer);
        tickets.purchaseTickets(1, priceBefore, 1, bytes32(0));

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
        tickets.exposed_setTicketsSoldThisRound(350);

        // Queue updates that would change every view if applied: nextRoundDuration would
        // halve elapsed rounds; nextTargetTicketsPerRound would zero out the excess below.
        // setPricingParams intentionally omitted: a queued pricing update diverts
        // excessTicketsSold() to the override, which is covered separately.
        vm.startPrank(marketParamsSetter);
        tickets.setRoundDuration(ROUND_DURATION + 1);
        tickets.setTargetTicketsPerRound(TARGET_TICKETS + 1);
        tickets.setMaxTicketsPerRound(MAX_TICKETS + 1);
        vm.stopPrank();

        // 3 inactive rounds elapse; no mutating call ever flushes the queue.
        vm.warp(FIRST_ROUND_START + 3 * ROUND_DURATION);

        assertEq(tickets.roundsElapsedSinceStored(), 3);
        assertEq(tickets.roundNumber(), 3);
        assertEq(tickets.roundStart(), FIRST_ROUND_START + 3 * ROUND_DURATION);
        assertEq(tickets.excessTicketsSold(), 350 - 3 * TARGET_TICKETS);
    }

    function test_queuedDurationTakesEffectAtLeastOneRoundAfterQueuing() public {
        uint24 newDuration = ROUND_DURATION + 1;

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
        tickets.setPricingParams(newMinPrice, newFraction, 0);

        assertEq(tickets.nextMinimumPrice(), newMinPrice);
        assertEq(tickets.nextPriceUpdateFraction(), newFraction);
        assertEq(tickets.minimumPrice(), MINIMUM_PRICE);
        assertEq(tickets.priceUpdateFraction(), PRICE_UPDATE_FRACTION);

        vm.warp(FIRST_ROUND_START + 2 * ROUND_DURATION);
        assertEq(tickets.roundNumber(), 2);

        assertEq(tickets.minimumPrice(), newMinPrice);
        assertEq(tickets.priceUpdateFraction(), newFraction);
    }

    function test_queuedGrandfatherFractionTakesEffectAtLeastOneRoundAfterQueuing() public {
        uint8 newFraction = GRANDFATHER_PERIOD_FRACTION + 1;

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        assertEq(tickets.roundNumber(), 1);

        vm.prank(marketParamsSetter);
        tickets.setGrandfatherPeriodFraction(newFraction);

        assertEq(tickets.nextGrandfatherPeriodFraction(), newFraction);
        assertEq(tickets.grandfatherPeriodFraction(), GRANDFATHER_PERIOD_FRACTION);

        vm.warp(FIRST_ROUND_START + 2 * ROUND_DURATION);
        assertEq(tickets.roundNumber(), 2);

        assertEq(tickets.grandfatherPeriodFraction(), newFraction);
    }

    /// @dev Boundary: one round has fully elapsed. commitRoundState credits the closing round's
    ///      revenue to `_storedProceeds` and advances stored round number.
    function test_commitRoundState_creditsRevenueAfterRoundEnd() public {
        address buyer = makeAddr("buyer");
        _deposit(buyer, MINIMUM_PRICE);
        vm.prank(buyer);
        tickets.purchaseTickets(0, MINIMUM_PRICE, 1, bytes32(0));

        assertEq(tickets.exposed_storedProceeds(), 0);

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        vm.prank(makeAddr("watcher"));
        tickets.commitRoundState();

        assertEq(tickets.exposed_storedProceeds(), MINIMUM_PRICE);
        assertEq(tickets.exposed_storedRoundNumber(), 1);
    }

    /// @dev Boundary - 1: one second before the round ends. commitRoundState is a no-op.
    function test_commitRoundState_noOpBeforeRoundEnd() public {
        address buyer = makeAddr("buyer");
        _deposit(buyer, MINIMUM_PRICE);
        vm.prank(buyer);
        tickets.purchaseTickets(0, MINIMUM_PRICE, 1, bytes32(0));

        vm.warp(FIRST_ROUND_START + ROUND_DURATION - 1);
        tickets.commitRoundState();

        assertEq(tickets.exposed_storedProceeds(), 0);
        assertEq(tickets.exposed_storedRoundNumber(), 0);
    }
}
