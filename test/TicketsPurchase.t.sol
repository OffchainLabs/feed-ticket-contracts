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
        tickets.purchaseTicket(0, MINIMUM_PRICE, bytes32(0));

        _deposit(otherBuyer, MINIMUM_PRICE);
        vm.prank(otherBuyer);
        tickets.purchaseTicket(0, MINIMUM_PRICE, bytes32(0));

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
        tickets.purchaseTicket(1, price1, bytes32(0));

        _deposit(otherBuyer, price1);
        vm.prank(otherBuyer);
        tickets.purchaseTicket(1, price1, bytes32(0));

        // Inflate the round-1 count so excess stays nonzero after the next lazy update.
        tickets.exposed_setTicketsSoldThisRound(50);

        vm.warp(FIRST_ROUND_START + 2 * ROUND_DURATION);
    }

    function test_purchaseTicket_revertsOnExpectedRoundMismatch() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ITickets.RoundNumberMismatch.selector, 1, 0));
        tickets.purchaseTicket(1, MINIMUM_PRICE, bytes32(0));
    }

    function test_purchaseTicket_revertsOnIncorrectPrice() public {
        vm.startPrank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(ITickets.IncorrectTicketPrice.selector, MINIMUM_PRICE - 1, MINIMUM_PRICE)
        );
        tickets.purchaseTicket(0, MINIMUM_PRICE - 1, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(ITickets.IncorrectTicketPrice.selector, MINIMUM_PRICE + 1, MINIMUM_PRICE)
        );
        tickets.purchaseTicket(0, MINIMUM_PRICE + 1, bytes32(0));
        vm.stopPrank();
    }

    function test_purchaseTicket_revertsWhenMaxTicketsSold() public {
        tickets.exposed_setTicketsSoldThisRound(MAX_TICKETS);

        vm.prank(buyer);
        vm.expectRevert(ITickets.MaxTicketsSold.selector);
        tickets.purchaseTicket(0, MINIMUM_PRICE, bytes32(0));
    }

    function test_purchaseTicket_revertsOnDoublePurchaseInSameRound() public {
        _deposit(buyer, 2 * MINIMUM_PRICE);
        vm.startPrank(buyer);
        tickets.purchaseTicket(0, MINIMUM_PRICE, bytes32(0));
        vm.expectRevert(ITickets.AlreadyPurchasedInRound.selector);
        tickets.purchaseTicket(0, MINIMUM_PRICE, bytes32(0));
        vm.stopPrank();
    }

    function test_purchaseTicket_revertsOnInsufficientTokenBalance() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ITickets.InsufficientTokenBalance.selector, 0, MINIMUM_PRICE));
        tickets.purchaseTicket(0, MINIMUM_PRICE, bytes32(0));
    }

    /// @dev Boundary - 1: balance one wei short of `expectedPrice` reverts with the buyer's
    ///      current balance as the first error arg.
    function test_purchaseTicket_revertsAtBalanceOneBelowPrice() public {
        _deposit(buyer, MINIMUM_PRICE - 1);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(ITickets.InsufficientTokenBalance.selector, MINIMUM_PRICE - 1, MINIMUM_PRICE)
        );
        tickets.purchaseTicket(0, MINIMUM_PRICE, bytes32(0));
    }

    /// @dev Boundary: balance exactly equal to `expectedPrice` succeeds and is debited to zero.
    function test_purchaseTicket_succeedsAtBalanceEqualPriceAndDebitsToZero() public {
        _deposit(buyer, MINIMUM_PRICE);
        vm.prank(buyer);
        tickets.purchaseTicket(0, MINIMUM_PRICE, bytes32(0));

        assertEq(tickets.tokenBalance(buyer), 0);
    }

    function test_purchaseTicket_revertsForNonGrandfatheredInRoundOneGrandfatherPhase() public {
        vm.warp(FIRST_ROUND_START + ROUND_DURATION);

        _deposit(buyer, MINIMUM_PRICE);
        vm.prank(buyer);
        vm.expectRevert(ITickets.NotGrandfathered.selector);
        tickets.purchaseTicket(1, MINIMUM_PRICE, bytes32(0));
    }

    function test_purchaseTicket_firstBuyerInRoundZero() public {
        _deposit(buyer, MINIMUM_PRICE);

        vm.expectEmit(true, true, false, true, address(tickets));
        emit ITickets.TicketPurchased(buyer, 0, bytes32(0), MINIMUM_PRICE);

        vm.prank(buyer);
        tickets.purchaseTicket(0, MINIMUM_PRICE, bytes32(0));

        assertEq(tickets.grandfatheredIntoRound(buyer), 1);
        assertEq(tickets.ticketsSoldThisRound(), 1);
        assertEq(tickets.tokenBalance(buyer), 0);
        assertEq(token.balanceOf(address(tickets)), MINIMUM_PRICE);
    }

    function test_purchaseTicket_grandfatheredBuyerInRoundOne() public {
        _deposit(buyer, MINIMUM_PRICE);
        vm.prank(buyer);
        tickets.purchaseTicket(0, MINIMUM_PRICE, bytes32(0));

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);

        uint256 price = tickets.currentPrice();
        _deposit(buyer, price);
        vm.prank(buyer);
        tickets.purchaseTicket(1, price, bytes32(0));

        assertEq(tickets.grandfatheredIntoRound(buyer), 2);
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
        tickets.purchaseTicket(2, price, bytes32(0));
        vm.snapshotGasLastCall("first-purchase");
        _logAccesses("first-purchase");

        assertEq(tickets.exposed_storedRoundNumber(), 2);
        assertEq(tickets.exposed_storedRoundStart(), FIRST_ROUND_START + 2 * ROUND_DURATION);
        assertEq(tickets.exposed_storedExcessTicketsSold(), 200);
        assertEq(tickets.grandfatheredIntoRound(buyer), 3);
        assertEq(tickets.ticketsSoldThisRound(), 1);
    }

    function test_purchaseTicket_secondPurchaseInRealisticRound() public {
        _setupRealisticRound();

        uint256 price = tickets.currentPrice();

        _deposit(buyer, price);
        vm.prank(buyer);
        tickets.purchaseTicket(2, price, bytes32(0));

        _deposit(otherBuyer, price);
        vm.prank(otherBuyer);
        vm.cool(address(tickets));
        vm.cool(address(impl));
        vm.record();
        tickets.purchaseTicket(2, price, bytes32(0));
        vm.snapshotGasLastCall("second-purchase");
        _logAccesses("second-purchase");

        assertEq(tickets.grandfatheredIntoRound(buyer), 3);
        assertEq(tickets.grandfatheredIntoRound(otherBuyer), 3);
        assertEq(tickets.ticketsSoldThisRound(), 2);
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
