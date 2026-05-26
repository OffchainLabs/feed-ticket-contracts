// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// forge-lint: disable-start

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ITickets} from "../src/ITickets.sol";
import {Tickets} from "../src/Tickets.sol";
import {BaseTicketsTest, TicketsHarness} from "./BaseTicketsTest.t.sol";

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

    // KILLS MUTANT #195 in src/Tickets.sol
    /// @dev With the default config `firstRoundStart` (~1.7e9) far exceeds `roundDuration` (3600s),
    ///      `block.timestamp % _roundStart` happens to equal `block.timestamp - _roundStart` whenever
    ///      `block.timestamp < 2 * _roundStart`. Deploy a fresh proxy with a small `firstRoundStart`
    ///      so the modulo and subtraction give visibly different elapsed counts.
    function test_roundsElapsedSinceStored_subtractsRoundStartNotModulo() public {
        vm.warp(1);
        TicketsHarness freshImpl = new TicketsHarness(address(token));
        Tickets.InitParams memory p = Tickets.InitParams({
            defaultAdmin: defaultAdmin,
            beneficiarySetter: beneficiarySetter,
            marketParamsSetter: marketParamsSetter,
            beneficiary: beneficiary,
            roundDuration: 10,
            targetTicketsPerRound: TARGET_TICKETS,
            maxTicketsPerRound: MAX_TICKETS,
            minimumPrice: MINIMUM_PRICE,
            priceUpdateFraction: PRICE_UPDATE_FRACTION,
            grandfatherPeriodFraction: GRANDFATHER_PERIOD_FRACTION,
            firstRoundStart: 5
        });
        TicketsHarness fresh = TicketsHarness(
            address(new TransparentUpgradeableProxy(address(freshImpl), proxyAdmin, abi.encodeCall(Tickets.initialize, (p))))
        );

        // t = 35: original is (35 - 5) / 10 = 3; modulo mutant is (35 % 5) / 10 = 0.
        vm.warp(35);
        assertEq(fresh.roundsElapsedSinceStored(), 3);
    }

    // KILLS MUTANT #258 in src/Tickets.sol
    function test_setRoundDuration_revertsOnZero() public {
        vm.prank(marketParamsSetter);
        vm.expectRevert(ITickets.RoundDurationZero.selector);
        tickets.setRoundDuration(0);
    }

    // KILLS MUTANTS #260, #261 in src/Tickets.sol
    function test_setRoundDuration_setsAdminUpdateQueuedFlag() public {
        assertFalse(tickets.isAdminUpdateQueued());
        vm.prank(marketParamsSetter);
        tickets.setRoundDuration(ROUND_DURATION + 1);
        assertTrue(tickets.isAdminUpdateQueued());
    }

    // KILLS MUTANT #266 in src/Tickets.sol
    function test_setMaxTicketsPerRound_revertsOnZero() public {
        vm.prank(marketParamsSetter);
        vm.expectRevert(ITickets.MaxTicketsPerRoundZero.selector);
        tickets.setMaxTicketsPerRound(0);
    }

    // KILLS MUTANTS #268, #269 in src/Tickets.sol
    function test_setMaxTicketsPerRound_setsAdminUpdateQueuedFlag() public {
        assertFalse(tickets.isAdminUpdateQueued());
        vm.prank(marketParamsSetter);
        tickets.setMaxTicketsPerRound(MAX_TICKETS + 1);
        assertTrue(tickets.isAdminUpdateQueued());
    }

    // KILLS MUTANT #274 in src/Tickets.sol
    function test_setTargetTicketsPerRound_revertsOnZero() public {
        vm.prank(marketParamsSetter);
        vm.expectRevert(ITickets.TargetTicketsPerRoundZero.selector);
        tickets.setTargetTicketsPerRound(0);
    }

    // KILLS MUTANTS #276, #277 in src/Tickets.sol
    function test_setTargetTicketsPerRound_setsAdminUpdateQueuedFlag() public {
        assertFalse(tickets.isAdminUpdateQueued());
        vm.prank(marketParamsSetter);
        tickets.setTargetTicketsPerRound(TARGET_TICKETS + 1);
        assertTrue(tickets.isAdminUpdateQueued());
    }

    // KILLS MUTANT #282 in src/Tickets.sol
    function test_setPricingParams_revertsOnZeroMinimumPrice() public {
        vm.prank(marketParamsSetter);
        vm.expectRevert(ITickets.MinimumPriceZero.selector);
        tickets.setPricingParams(0, PRICE_UPDATE_FRACTION, 0);
    }

    // KILLS MUTANT #284 in src/Tickets.sol
    function test_setPricingParams_revertsOnZeroPriceUpdateFraction() public {
        vm.prank(marketParamsSetter);
        vm.expectRevert(ITickets.PriceUpdateFractionZero.selector);
        tickets.setPricingParams(MINIMUM_PRICE, 0, 0);
    }

    // KILLS MUTANT #286 in src/Tickets.sol
    function test_setPricingParams_revertsOnSentinelExcessOverride() public {
        vm.prank(marketParamsSetter);
        vm.expectRevert(ITickets.ExcessTicketsSoldOverrideReserved.selector);
        tickets.setPricingParams(MINIMUM_PRICE, PRICE_UPDATE_FRACTION, type(uint56).max);
    }

    // KILLS MUTANT #301 in src/Tickets.sol
    function test_setGrandfatherPeriodFraction_revertsOnSentinel() public {
        vm.prank(marketParamsSetter);
        vm.expectRevert(ITickets.GrandfatherPeriodFractionReserved.selector);
        tickets.setGrandfatherPeriodFraction(type(uint8).max);
    }

    // KILLS MUTANT #303 in src/Tickets.sol
    function test_setGrandfatherPeriodFraction_setsAdminUpdateQueuedFlag() public {
        assertFalse(tickets.isAdminUpdateQueued());
        vm.prank(marketParamsSetter);
        tickets.setGrandfatherPeriodFraction(GRANDFATHER_PERIOD_FRACTION + 1);
        assertTrue(tickets.isAdminUpdateQueued());
    }

    // KILLS MUTANTS #391, #392 in src/Tickets.sol
    /// @dev After a queued admin update is committed by lazy update, isAdminUpdateQueued must be
    ///      cleared. Distinguishes the original `= false` from both `assert(true)` (leaves it true)
    ///      and `= true` (explicitly sets it true).
    function test_lazyUpdateRoundState_clearsAdminUpdateQueuedFlag() public {
        vm.prank(marketParamsSetter);
        tickets.setRoundDuration(ROUND_DURATION + 1);
        assertTrue(tickets.isAdminUpdateQueued());

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        tickets.exposed_lazyUpdateRoundState();

        assertFalse(tickets.isAdminUpdateQueued());
    }

    // KILLS MUTANT #341 in src/Tickets.sol
    /// @dev `if (isAdminUpdateQueued)` gates the inner per-field commits. Forge a state where the
    ///      flag is false but a queued field is non-default - this combination is impossible via the
    ///      public surface, so we install it directly via the harness. With the gate intact the
    ///      stored roundDuration is unchanged; mutated to `if (true)` it gets clobbered with the
    ///      injected next value.
    function test_lazyUpdateRoundState_skipsInnerBlockWhenFlagFalse() public {
        uint24 injected = ROUND_DURATION + 7;
        tickets.exposed_setNextRoundDuration(injected);
        assertFalse(tickets.isAdminUpdateQueued());

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        tickets.exposed_lazyUpdateRoundState();

        assertEq(tickets.roundDuration(), ROUND_DURATION);
    }

    // KILLS MUTANT #357 in src/Tickets.sol
    /// @dev Queue a non-max admin update (so `isAdminUpdateQueued` is true) but leave
    ///      `nextMaxTicketsPerRound` at its zero sentinel. The mutation `if (true)` would assign
    ///      the sentinel to `_maxTicketsPerRound`, breaking subsequent purchases.
    function test_lazyUpdateRoundState_doesNotApplyMaxWhenSentinel() public {
        vm.prank(marketParamsSetter);
        tickets.setRoundDuration(ROUND_DURATION + 1);

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        tickets.exposed_lazyUpdateRoundState();

        assertEq(tickets.maxTicketsPerRound(), MAX_TICKETS);
    }

    // KILLS MUTANT #364 in src/Tickets.sol
    /// @dev Queue a non-grandfather admin update so the gate is reached with
    ///      `nextGrandfatherPeriodFraction == GRANDFATHER_PERIOD_SENTINEL`. The mutation would
    ///      clobber `_grandfatherPeriodFraction` with the sentinel.
    function test_lazyUpdateRoundState_doesNotApplyGrandfatherWhenSentinel() public {
        vm.prank(marketParamsSetter);
        tickets.setRoundDuration(ROUND_DURATION + 1);

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        tickets.exposed_lazyUpdateRoundState();

        assertEq(tickets.grandfatherPeriodFraction(), GRANDFATHER_PERIOD_FRACTION);
    }

    // KILLS MUTANT #372 in src/Tickets.sol
    function test_lazyUpdateRoundState_doesNotApplyPriceUpdateFractionWhenSentinel() public {
        vm.prank(marketParamsSetter);
        tickets.setRoundDuration(ROUND_DURATION + 1);

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        tickets.exposed_lazyUpdateRoundState();

        assertEq(tickets.priceUpdateFraction(), PRICE_UPDATE_FRACTION);
    }

    // KILLS MUTANT #379 in src/Tickets.sol
    function test_lazyUpdateRoundState_doesNotApplyMinimumPriceWhenSentinel() public {
        vm.prank(marketParamsSetter);
        tickets.setRoundDuration(ROUND_DURATION + 1);

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        tickets.exposed_lazyUpdateRoundState();

        assertEq(tickets.minimumPrice(), MINIMUM_PRICE);
    }
}
