// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// forge-lint: disable-start

import {ITickets} from "../src/ITickets.sol";
import {BaseTicketsTest} from "./BaseTicketsTest.t.sol";

contract TicketsPurchaseTest is BaseTicketsTest {
    address buyer = makeAddr("buyer");
    address otherBuyer = makeAddr("otherBuyer");

    /// @dev Leaves the contract in a state where:
    ///      - stored `_roundNumber`, `_roundStart`, `_excessTicketsSold` are all nonzero
    ///      - `block.timestamp` sits on the next round boundary, so the next mutating call
    ///        triggers the lazy update
    ///      - `buyer` and `otherBuyer` are grandfathered for the upcoming round
    function _setupRealisticRound() internal {
        _deposit(buyer, MINIMUM_PRICE);
        vm.prank(buyer);
        tickets.purchaseTickets(0, MINIMUM_PRICE, 1, bytes32(0));

        _deposit(otherBuyer, MINIMUM_PRICE);
        vm.prank(otherBuyer);
        tickets.purchaseTickets(0, MINIMUM_PRICE, 1, bytes32(0));

        // Inflate the round-0 count so excess after round 0 is nonzero.
        tickets.exposed_setTicketsSoldThisRound(350);

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        tickets.exposed_lazyUpdateRoundState();
        // _roundNumber=1, _roundStart=DEPLOY+RD, _excess=250

        // Round 1 grandfather phase: both buyers (grandfathered via round 0 tickets) purchase to
        // register grandfathering for round 2.
        uint256 price1 = tickets.currentPrice();
        _deposit(buyer, price1);
        vm.prank(buyer);
        tickets.purchaseTickets(1, price1, 1, bytes32(0));

        _deposit(otherBuyer, price1);
        vm.prank(otherBuyer);
        tickets.purchaseTickets(1, price1, 1, bytes32(0));

        // Inflate the round-1 count so excess stays nonzero after the next lazy update.
        tickets.exposed_setTicketsSoldThisRound(50);

        vm.warp(FIRST_ROUND_START + 2 * ROUND_DURATION);
    }

    function test_purchaseTicket_revertsOnExpectedRoundMismatch() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ITickets.RoundNumberMismatch.selector, 1, 0));
        tickets.purchaseTickets(1, MINIMUM_PRICE, 1, bytes32(0));
    }

    function test_purchaseTicket_revertsOnIncorrectPrice() public {
        vm.startPrank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(ITickets.IncorrectTicketPrice.selector, MINIMUM_PRICE - 1, MINIMUM_PRICE)
        );
        tickets.purchaseTickets(0, MINIMUM_PRICE - 1, 1, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(ITickets.IncorrectTicketPrice.selector, MINIMUM_PRICE + 1, MINIMUM_PRICE)
        );
        tickets.purchaseTickets(0, MINIMUM_PRICE + 1, 1, bytes32(0));
        vm.stopPrank();
    }

    function test_purchaseTicket_revertsWhenMaxTicketsSold() public {
        tickets.exposed_setTicketsSoldThisRound(MAX_TICKETS);

        vm.prank(buyer);
        vm.expectRevert(ITickets.MaxTicketsSold.selector);
        tickets.purchaseTickets(0, MINIMUM_PRICE, 1, bytes32(0));
    }

    function test_purchaseTicket_revertsOnInsufficientTokenBalance() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ITickets.InsufficientTokenBalance.selector, 0, MINIMUM_PRICE));
        tickets.purchaseTickets(0, MINIMUM_PRICE, 1, bytes32(0));
    }

    /// @dev Boundary - 1: balance one wei short of `expectedPrice` reverts with the buyer's
    ///      current balance as the first error arg.
    function test_purchaseTicket_revertsAtBalanceOneBelowPrice() public {
        _deposit(buyer, MINIMUM_PRICE - 1);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(ITickets.InsufficientTokenBalance.selector, MINIMUM_PRICE - 1, MINIMUM_PRICE)
        );
        tickets.purchaseTickets(0, MINIMUM_PRICE, 1, bytes32(0));
    }

    /// @dev Boundary: balance exactly equal to `expectedPrice` succeeds and is debited to zero.
    function test_purchaseTicket_succeedsAtBalanceEqualPriceAndDebitsToZero() public {
        _deposit(buyer, MINIMUM_PRICE);
        vm.prank(buyer);
        tickets.purchaseTickets(0, MINIMUM_PRICE, 1, bytes32(0));

        assertEq(tickets.tokenBalance(buyer), 0);
    }

    function test_purchaseTicket_firstBuyerInRoundZero() public {
        _deposit(buyer, MINIMUM_PRICE);

        vm.expectEmit(true, true, false, true, address(tickets));
        emit ITickets.TicketPurchased(buyer, 0, bytes32(0), MINIMUM_PRICE, 1);

        vm.prank(buyer);
        tickets.purchaseTickets(0, MINIMUM_PRICE, 1, bytes32(0));

        assertEq(tickets.ticketsSoldThisRound(), 1);
        assertEq(tickets.tokenBalance(buyer), 0);
        assertEq(token.balanceOf(address(tickets)), MINIMUM_PRICE);
    }

    function test_purchaseTicket_grandfatheredBuyerInRoundOne() public {
        _deposit(buyer, MINIMUM_PRICE);
        vm.prank(buyer);
        tickets.purchaseTickets(0, MINIMUM_PRICE, 1, bytes32(0));

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);

        uint256 price = tickets.currentPrice();
        _deposit(buyer, price);
        vm.prank(buyer);
        tickets.purchaseTickets(1, price, 1, bytes32(0));

        assertEq(tickets.grandfatherCount(buyer), 0);
        assertEq(tickets.ticketsSoldThisRound(), 1);
    }

    function test_purchaseTicket_firstPurchaseInRealisticRound() public {
        _setupRealisticRound();

        assertEq(tickets.exposed_storedRoundNumber(), 1);
        assertEq(tickets.exposed_storedRoundStart(), FIRST_ROUND_START + ROUND_DURATION);
        assertEq(tickets.exposed_storedExcessTicketsSold(), 250);

        uint256 price = tickets.currentPrice();
        _deposit(buyer, price);
        vm.prank(buyer);
        vm.cool(address(tickets));
        vm.cool(address(impl));
        vm.record();
        tickets.purchaseTickets(2, price, 1, bytes32(0));
        vm.snapshotGasLastCall("first-purchase");
        _logAccesses("first-purchase");

        assertEq(tickets.exposed_storedRoundNumber(), 2);
        assertEq(tickets.exposed_storedRoundStart(), FIRST_ROUND_START + 2 * ROUND_DURATION);
        assertEq(tickets.exposed_storedExcessTicketsSold(), 200);
        assertEq(tickets.grandfatherCount(buyer), 0);
        assertEq(tickets.ticketsSoldThisRound(), 1);
    }

    function test_purchaseTicket_secondPurchaseInRealisticRound() public {
        _setupRealisticRound();

        uint256 price = tickets.currentPrice();

        _deposit(buyer, price);
        vm.prank(buyer);
        tickets.purchaseTickets(2, price, 1, bytes32(0));

        _deposit(otherBuyer, price);
        vm.prank(otherBuyer);
        vm.cool(address(tickets));
        vm.cool(address(impl));
        vm.record();
        tickets.purchaseTickets(2, price, 1, bytes32(0));
        vm.snapshotGasLastCall("second-purchase");
        _logAccesses("second-purchase");

        assertEq(tickets.grandfatherCount(buyer), 0);
        assertEq(tickets.grandfatherCount(otherBuyer), 0);
        assertEq(tickets.ticketsSoldThisRound(), 2);
    }

    function test_purchaseTickets_revertsOnZeroTicketsRequested() public {
        vm.prank(buyer);
        vm.expectRevert(ITickets.ZeroTicketsRequested.selector);
        tickets.purchaseTickets(0, MINIMUM_PRICE, 0, bytes32(0));
    }

    function test_purchaseTickets_multiTicketSingleCall() public {
        uint256 n = 5;
        _deposit(buyer, n * MINIMUM_PRICE);

        vm.expectEmit(true, true, true, true, address(tickets));
        emit ITickets.TicketPurchased(buyer, 0, bytes32(0), MINIMUM_PRICE, n);

        vm.prank(buyer);
        tickets.purchaseTickets(0, MINIMUM_PRICE, n, bytes32(0));

        assertEq(tickets.tokenBalance(buyer), 0);
        assertEq(tickets.ticketsSoldThisRound(), n);
    }

    function test_purchaseTickets_repeatInSameRoundAccumulates() public {
        uint256 n1 = 2;
        uint256 n2 = 3;
        _deposit(buyer, (n1 + n2) * MINIMUM_PRICE);

        vm.startPrank(buyer);
        tickets.purchaseTickets(0, MINIMUM_PRICE, n1, bytes32(0));
        tickets.purchaseTickets(0, MINIMUM_PRICE, n2, bytes32(0));
        vm.stopPrank();

        assertEq(tickets.ticketsSoldThisRound(), n1 + n2);
        assertEq(tickets.tokenBalance(buyer), 0);
    }

    /// @dev Boundary: `_ticketsSoldThisRound + numTickets == maxTicketsPerRound` succeeds.
    function test_purchaseTickets_succeedsAtCapBoundary() public {
        tickets.exposed_setTicketsSoldThisRound(MAX_TICKETS - 5);
        _deposit(buyer, 5 * MINIMUM_PRICE);

        vm.prank(buyer);
        tickets.purchaseTickets(0, MINIMUM_PRICE, 5, bytes32(0));

        assertEq(tickets.ticketsSoldThisRound(), MAX_TICKETS);
    }

    /// @dev Boundary + 1: `_ticketsSoldThisRound + numTickets == maxTicketsPerRound + 1` reverts.
    function test_purchaseTickets_revertsAtCapBoundaryPlusOne() public {
        tickets.exposed_setTicketsSoldThisRound(MAX_TICKETS - 5);
        _deposit(buyer, 6 * MINIMUM_PRICE);

        vm.prank(buyer);
        vm.expectRevert(ITickets.MaxTicketsSold.selector);
        tickets.purchaseTickets(0, MINIMUM_PRICE, 6, bytes32(0));
    }

    /// @dev Boundary: in round 1's grandfather phase a buyer with K tickets in round 0 may
    ///      consume exactly K. The prior-round parity slot drops to 0 and the current-round
    ///      parity slot becomes K.
    function test_purchaseTickets_grandfatherPartialConsumption_succeedsAtK() public {
        uint16 k = 3;
        _deposit(buyer, k * MINIMUM_PRICE);
        vm.prank(buyer);
        tickets.purchaseTickets(0, MINIMUM_PRICE, k, bytes32(0));

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);

        uint256 price = tickets.currentPrice();
        _deposit(buyer, k * price);
        vm.prank(buyer);
        tickets.purchaseTickets(1, price, k, bytes32(0));

        assertEq(tickets.grandfatherCount(buyer), 0);
    }

    /// @dev Boundary + 1: in round 1's grandfather phase a buyer with K tickets in round 0
    ///      cannot consume K+1. Revert pins the grandfathered count as the first arg and the
    ///      requested count as the second.
    function test_purchaseTickets_grandfatherPartialConsumption_revertsAtKPlusOne() public {
        uint16 k = 3;
        _deposit(buyer, k * MINIMUM_PRICE);
        vm.prank(buyer);
        tickets.purchaseTickets(0, MINIMUM_PRICE, k, bytes32(0));

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);

        uint256 price = tickets.currentPrice();
        _deposit(buyer, (uint256(k) + 1) * price);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ITickets.NotEnoughGrandfatheredTickets.selector, k, k + 1));
        tickets.purchaseTickets(1, price, k + 1, bytes32(0));
    }

    /// @dev Pins that during the grandfather phase, the parity-aware decrement is read from the
    ///      pre-call userDataMem and is not perturbed by the subsequent same-parity write within
    ///      the same call - and that repeat purchases in the same round still accumulate.
    function test_purchaseTickets_grandfatherWithSameRoundAccumulation() public {
        uint16 k = 5;
        _deposit(buyer, k * MINIMUM_PRICE);
        vm.prank(buyer);
        tickets.purchaseTickets(0, MINIMUM_PRICE, k, bytes32(0));

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);

        uint256 price = tickets.currentPrice();
        _deposit(buyer, 4 * price);

        vm.startPrank(buyer);
        tickets.purchaseTickets(1, price, 2, bytes32(0));
        tickets.purchaseTickets(1, price, 2, bytes32(0));
        vm.stopPrank();

        assertEq(tickets.grandfatherCount(buyer), k - 4);
        assertEq(tickets.ticketsSoldThisRound(), 4);
    }

    /// @dev Boundary: round 0 is the short-circuit return - even an account that just purchased in
    ///      round 0 has no grandfathered tickets yet.
    function test_grandfatherCount_returnsZeroInRoundZeroAfterPurchase() public {
        _deposit(buyer, MINIMUM_PRICE);
        vm.prank(buyer);
        tickets.purchaseTickets(0, MINIMUM_PRICE, 1, bytes32(0));

        assertEq(tickets.grandfatherCount(buyer), 0);
    }

    /// @dev Boundary partner: in round 0 a never-purchased account also returns 0.
    function test_grandfatherCount_returnsZeroInRoundZeroForNeverPurchased() public view {
        assertEq(tickets.grandfatherCount(buyer), 0);
    }

    /// @dev Boundary + 1 (round-wise): one round after a round-0 purchase, the view returns K
    ///      before any round-1 purchase consumes the grandfather allowance.
    function test_grandfatherCount_returnsKInRoundOneBeforeConsumption() public {
        uint16 k = 5;
        _deposit(buyer, k * MINIMUM_PRICE);
        vm.prank(buyer);
        tickets.purchaseTickets(0, MINIMUM_PRICE, k, bytes32(0));

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);

        assertEq(tickets.grandfatherCount(buyer), k);
    }

    /// @dev Boundary partner: in round 1 a never-purchased account still returns 0.
    function test_grandfatherCount_returnsZeroInRoundOneForNeverPurchased() public {
        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        assertEq(tickets.grandfatherCount(buyer), 0);
    }

    /// @dev Stale parity: a round-0 purchase does not grandfather into round 2. In round 2 the
    ///      function reads `lastOddRoundPurchased` (= 0) and compares against `roundNumber() - 1`
    ///      (= 1), so it returns 0.
    function test_grandfatherCount_returnsZeroInRoundTwoWhenOnlyPurchasedInRoundZero() public {
        _deposit(buyer, MINIMUM_PRICE);
        vm.prank(buyer);
        tickets.purchaseTickets(0, MINIMUM_PRICE, 1, bytes32(0));

        vm.warp(FIRST_ROUND_START + 2 * ROUND_DURATION);

        assertEq(tickets.grandfatherCount(buyer), 0);
    }

    /// @dev Parity toggling: a round-0 purchase grandfathers into round 1 (opposite parity), is
    ///      stale by round 2, and remains 0 in round 3.
    function test_grandfatherCount_parityTogglesAcrossRounds() public {
        uint16 k = 3;
        _deposit(buyer, k * MINIMUM_PRICE);
        vm.prank(buyer);
        tickets.purchaseTickets(0, MINIMUM_PRICE, k, bytes32(0));

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        assertEq(tickets.grandfatherCount(buyer), k);

        vm.warp(FIRST_ROUND_START + 2 * ROUND_DURATION);
        assertEq(tickets.grandfatherCount(buyer), 0);

        vm.warp(FIRST_ROUND_START + 3 * ROUND_DURATION);
        assertEq(tickets.grandfatherCount(buyer), 0);
    }

    /// @dev Window-agnostic: the view does not gate on whether the grandfather phase is still open.
    ///      After warping past `grandfatherPeriodEnd()` in round 1, the count is still K.
    function test_grandfatherCount_returnsKAfterGrandfatherPhaseEnds() public {
        uint16 k = 4;
        _deposit(buyer, k * MINIMUM_PRICE);
        vm.prank(buyer);
        tickets.purchaseTickets(0, MINIMUM_PRICE, k, bytes32(0));

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        uint256 phaseEnd = tickets.grandfatherPeriodEnd();
        vm.warp(phaseEnd + 1);

        assertEq(tickets.roundNumber(), 1);
        assertEq(tickets.grandfatherCount(buyer), k);
    }

    function _logAccesses(string memory label) internal {
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(tickets));
        uint256[] memory readSlots;
        uint256[] memory writeSlots;
        assembly {
            readSlots := reads
            writeSlots := writes
        }
        vm.serializeUint(label, "reads", readSlots);
        string memory json = vm.serializeUint(label, "writes", writeSlots);
        vm.writeJson(json, string.concat("snapshots/TicketsPurchaseTest.accesses.", label, ".json"));
    }
}
