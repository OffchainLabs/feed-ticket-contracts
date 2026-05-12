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
        vm.deal(buyer, MINIMUM_PRICE);
        vm.prank(buyer);
        tickets.purchaseTicket{value: MINIMUM_PRICE}(0, bytes32(0));

        vm.deal(otherBuyer, MINIMUM_PRICE);
        vm.prank(otherBuyer);
        tickets.purchaseTicket{value: MINIMUM_PRICE}(0, bytes32(0));

        // Inflate ticketsSold[0] so excess after round 0 is nonzero.
        tickets.exposed_setTicketsSold(0, 350);

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        tickets.exposed_lazyUpdateRoundState();
        // _roundNumber=1, _roundStart=DEPLOY+RD, _excess=250

        // Round 1 grandfather phase: both buyers (grandfathered via round 0 tickets) purchase to
        // register grandfathering for round 2.
        uint256 price1 = tickets.currentPrice();
        vm.deal(buyer, price1);
        vm.prank(buyer);
        tickets.purchaseTicket{value: price1}(1, bytes32(0));

        vm.deal(otherBuyer, price1);
        vm.prank(otherBuyer);
        tickets.purchaseTicket{value: price1}(1, bytes32(0));

        // Inflate ticketsSold[1] so excess stays nonzero after the next lazy update.
        tickets.exposed_setTicketsSold(1, 50);

        vm.warp(FIRST_ROUND_START + 2 * ROUND_DURATION);
    }

    function test_purchaseTicket_revertsOnExpectedRoundMismatch() public {
        vm.deal(buyer, MINIMUM_PRICE);
        vm.prank(buyer);
        vm.expectRevert("Round number mismatch");
        tickets.purchaseTicket{value: MINIMUM_PRICE}(1, bytes32(0));
    }

    function test_purchaseTicket_revertsOnIncorrectPrice() public {
        vm.deal(buyer, MINIMUM_PRICE);
        vm.prank(buyer);
        vm.expectRevert("Incorrect ticket price");
        tickets.purchaseTicket{value: MINIMUM_PRICE - 1}(0, bytes32(0));
        vm.expectRevert("Incorrect ticket price");
        tickets.purchaseTicket{value: MINIMUM_PRICE + 1}(0, bytes32(0));
    }

    function test_purchaseTicket_revertsWhenMaxTicketsSold() public {
        tickets.exposed_setTicketsSold(0, MAX_TICKETS);

        vm.deal(buyer, MINIMUM_PRICE);
        vm.prank(buyer);
        vm.expectRevert("Max tickets sold for this round");
        tickets.purchaseTicket{value: MINIMUM_PRICE}(0, bytes32(0));
    }

    function test_purchaseTicket_revertsOnDoublePurchaseInSameRound() public {
        vm.deal(buyer, 2 * MINIMUM_PRICE);
        vm.startPrank(buyer);
        tickets.purchaseTicket{value: MINIMUM_PRICE}(0, bytes32(0));
        vm.expectRevert("Cannot buy two tickets in one round");
        tickets.purchaseTicket{value: MINIMUM_PRICE}(0, bytes32(0));
        vm.stopPrank();
    }

    function test_purchaseTicket_revertsForNonGrandfatheredInRoundOneGrandfatherPhase() public {
        vm.warp(FIRST_ROUND_START + ROUND_DURATION);

        vm.deal(buyer, MINIMUM_PRICE);
        vm.prank(buyer);
        vm.expectRevert("Must have ticket from previous round to purchase during grandfather phase");
        tickets.purchaseTicket{value: MINIMUM_PRICE}(1, bytes32(0));
    }

    function test_purchaseTicket_firstBuyerInRoundZero() public {
        vm.deal(buyer, MINIMUM_PRICE);

        vm.expectEmit(true, true, false, true, address(tickets));
        emit ITickets.TicketPurchased(buyer, 0, MINIMUM_PRICE, bytes32(0));

        vm.prank(buyer);
        tickets.purchaseTicket{value: MINIMUM_PRICE}(0, bytes32(0));

        assertEq(tickets.grandfatheredIntoRound(buyer), 1);
        assertEq(tickets.ticketsSold(0), 1);
        assertEq(address(tickets).balance, MINIMUM_PRICE);
    }

    function test_purchaseTicket_grandfatheredBuyerInRoundOne() public {
        vm.deal(buyer, MINIMUM_PRICE);
        vm.prank(buyer);
        tickets.purchaseTicket{value: MINIMUM_PRICE}(0, bytes32(0));

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);

        uint256 price = tickets.currentPrice();
        vm.deal(buyer, price);
        vm.prank(buyer);
        tickets.purchaseTicket{value: price}(1, bytes32(0));

        assertEq(tickets.grandfatheredIntoRound(buyer), 2);
        assertEq(tickets.ticketsSold(1), 1);
    }

    function test_purchaseTicket_firstPurchaseInRealisticRound() public {
        _setupRealisticRound();

        assertEq(tickets.exposed_storedRoundNumber(), 1);
        assertEq(tickets.exposed_storedRoundStart(), FIRST_ROUND_START + ROUND_DURATION);
        assertEq(tickets.exposed_storedExcessTicketsSold(), 250);

        uint256 price = tickets.currentPrice();
        vm.deal(buyer, price);
        vm.prank(buyer);
        vm.cool(address(tickets));
        vm.cool(address(impl));
        vm.record();
        tickets.purchaseTicket{value: price}(2, bytes32(0));
        vm.snapshotGasLastCall("first-purchase");
        _logAccesses("first-purchase");

        assertEq(tickets.exposed_storedRoundNumber(), 2);
        assertEq(tickets.exposed_storedRoundStart(), FIRST_ROUND_START + 2 * ROUND_DURATION);
        assertEq(tickets.exposed_storedExcessTicketsSold(), 200);
        assertEq(tickets.grandfatheredIntoRound(buyer), 3);
        assertEq(tickets.ticketsSold(2), 1);
    }

    function test_purchaseTicket_secondPurchaseInRealisticRound() public {
        _setupRealisticRound();

        uint256 price = tickets.currentPrice();

        vm.deal(buyer, price);
        vm.prank(buyer);
        tickets.purchaseTicket{value: price}(2, bytes32(0));

        vm.deal(otherBuyer, price);
        vm.prank(otherBuyer);
        vm.cool(address(tickets));
        vm.cool(address(impl));
        vm.record();
        tickets.purchaseTicket{value: price}(2, bytes32(0));
        vm.snapshotGasLastCall("second-purchase");
        _logAccesses("second-purchase");

        assertEq(tickets.grandfatheredIntoRound(buyer), 3);
        assertEq(tickets.grandfatheredIntoRound(otherBuyer), 3);
        assertEq(tickets.ticketsSold(2), 2);
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
