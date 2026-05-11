// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// forge-lint: disable-start

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Test} from "forge-std/Test.sol";
import {Tickets} from "../src/Tickets.sol";

contract TicketsE2ETest is Test {
    Tickets impl;
    Tickets tickets;

    address proxyAdmin = makeAddr("proxyAdmin");
    address defaultAdmin = makeAddr("defaultAdmin");
    address beneficiarySetter = makeAddr("beneficiarySetter");
    address marketParamsSetter = makeAddr("marketParamsSetter");
    address beneficiary = makeAddr("beneficiary");

    uint32 constant ROUND_DURATION = 1 hours;
    uint16 constant TARGET = 4;
    uint16 constant MAX = 8;
    uint64 constant MIN_PRICE = 1 ether;
    uint24 constant FRACTION = 10;
    uint40 constant FIRST_ROUND_START = 1_700_000_000;

    address[10] buyers;

    function setUp() public {
        vm.warp(FIRST_ROUND_START);
        impl = new Tickets();
        bytes memory initData = abi.encodeCall(
            Tickets.initialize,
            (
                defaultAdmin,
                beneficiarySetter,
                marketParamsSetter,
                beneficiary,
                ROUND_DURATION,
                TARGET,
                MAX,
                MIN_PRICE,
                FRACTION,
                FIRST_ROUND_START
            )
        );
        tickets = Tickets(address(new TransparentUpgradeableProxy(address(impl), proxyAdmin, initData)));
        for (uint256 i = 0; i < buyers.length; i++) {
            buyers[i] = makeAddr(string.concat("buyer", vm.toString(i)));
            vm.deal(buyers[i], 100 ether);
        }
    }

    function _buy(address buyer, uint256 round) internal returns (uint256 price) {
        price = tickets.currentPrice();
        vm.prank(buyer);
        tickets.purchaseTicket{value: price}(round);
    }

    function test_severalRoundsEvolveLogically() public {
        uint256 totalSpent;

        // ===== Round 0 — anyone can buy, no grandfather rule (since _roundNumber == 0) =====
        assertEq(tickets.roundNumber(), 0);
        assertEq(tickets.currentPrice(), MIN_PRICE);
        assertEq(tickets.excessTicketsSold(), 0);

        // Fill round 0 up to one short of the cap. Tested under the cap so the
        // double-buy / wrong-price / wrong-round checks aren't shadowed by the cap check.
        for (uint256 i = 0; i < MAX - 1; i++) {
            totalSpent += _buy(buyers[i], 0);
            assertTrue(tickets.hasTicket(buyers[i], 0));
            assertEq(tickets.ticketsSold(0), i + 1);
            assertEq(tickets.currentPrice(), MIN_PRICE);
        }

        // Cannot buy twice in the same round.
        vm.expectRevert("Cannot buy two tickets in one round");
        vm.prank(buyers[0]);
        tickets.purchaseTicket{value: MIN_PRICE}(0);

        // Wrong price reverts.
        vm.expectRevert("Incorrect ticket price");
        vm.prank(buyers[7]);
        tickets.purchaseTicket{value: MIN_PRICE + 1}(0);

        // Wrong expectedRound reverts.
        vm.expectRevert("Round number mismatch");
        vm.prank(buyers[7]);
        tickets.purchaseTicket{value: MIN_PRICE}(1);

        // Fill the final slot so the round closes at the cap.
        totalSpent += _buy(buyers[MAX - 1], 0);
        assertEq(tickets.ticketsSold(0), MAX);

        // 9th buy hits the cap.
        vm.expectRevert("Max tickets sold for this round");
        vm.prank(buyers[8]);
        tickets.purchaseTicket{value: MIN_PRICE}(0);

        // ===== Round 1 — first half restricts to round-0 holders =====
        vm.warp(FIRST_ROUND_START +ROUND_DURATION);
        assertEq(tickets.roundNumber(), 1);
        // gross = 0 + 8 = 8, consumed = 1*4 = 4 → excess = 4.
        assertEq(tickets.excessTicketsSold(), 4);
        uint256 r1Price = tickets.currentPrice();
        assertGt(r1Price, MIN_PRICE);

        // Boundary: at midTime - 1 the grandfather rule applies; at midTime it does not.
        uint256 r1Mid = FIRST_ROUND_START +ROUND_DURATION + ROUND_DURATION / 2;
        vm.warp(r1Mid - 1);
        // buyers[8] never bought in round 0 → reverts in first half.
        vm.expectRevert("Must have ticket from previous round to purchase in first half of round");
        vm.prank(buyers[8]);
        tickets.purchaseTicket{value: r1Price}(1);
        // A grandfathered buyer succeeds at the same instant.
        totalSpent += _buy(buyers[0], 1);

        vm.warp(r1Mid);
        // Same non-grandfathered buyer now succeeds at the boundary.
        totalSpent += _buy(buyers[8], 1);
        // Two more second-half buys, mixing grandfathered and not.
        totalSpent += _buy(buyers[1], 1);
        totalSpent += _buy(buyers[9], 1);

        assertEq(tickets.ticketsSold(1), 4);
        assertTrue(tickets.hasTicket(buyers[0], 1));
        assertTrue(tickets.hasTicket(buyers[1], 1));
        assertTrue(tickets.hasTicket(buyers[8], 1));
        assertTrue(tickets.hasTicket(buyers[9], 1));

        // ===== Round 2 — round-1 holders are the new grandfathered set =====
        vm.warp(FIRST_ROUND_START +2 * ROUND_DURATION);
        assertEq(tickets.roundNumber(), 2);
        // gross = 4 + 4 = 8, consumed = 1*4 = 4 → excess = 4 (round 1 sold exactly the target).
        assertEq(tickets.excessTicketsSold(), 4);
        // No change in excess → price unchanged from round 1.
        assertEq(tickets.currentPrice(), r1Price);

        // First half: round-1 holders may buy.
        totalSpent += _buy(buyers[0], 2);
        totalSpent += _buy(buyers[8], 2);

        // buyers[2] only ever bought in round 0 → not grandfathered for round 2 → reverts.
        vm.expectRevert("Must have ticket from previous round to purchase in first half of round");
        vm.prank(buyers[2]);
        tickets.purchaseTicket{value: r1Price}(2);

        // Second half: anyone may buy.
        vm.warp(FIRST_ROUND_START +2 * ROUND_DURATION + ROUND_DURATION / 2);
        totalSpent += _buy(buyers[2], 2);
        totalSpent += _buy(buyers[3], 2);
        totalSpent += _buy(buyers[4], 2);

        assertEq(tickets.ticketsSold(2), 5);

        // ===== Round 3 — excess and therefore price grow =====
        vm.warp(FIRST_ROUND_START +3 * ROUND_DURATION);
        assertEq(tickets.roundNumber(), 3);
        // gross = 4 + 5 = 9, consumed = 1*4 = 4 → excess = 5.
        assertEq(tickets.excessTicketsSold(), 5);
        uint256 r3Price = tickets.currentPrice();
        assertGt(r3Price, r1Price);

        // Skip to the second half so we can fill the cap from any buyer.
        vm.warp(FIRST_ROUND_START +3 * ROUND_DURATION + ROUND_DURATION / 2);
        for (uint256 i = 0; i < MAX; i++) {
            totalSpent += _buy(buyers[i], 3);
        }
        assertEq(tickets.ticketsSold(3), MAX);

        // 9th buy hits the cap.
        vm.expectRevert("Max tickets sold for this round");
        vm.prank(buyers[8]);
        tickets.purchaseTicket{value: r3Price}(3);

        // ===== Distribute proceeds =====
        assertEq(address(tickets).balance, totalSpent);
        uint256 beneBefore = beneficiary.balance;
        tickets.distributeSaleProceeds();
        assertEq(address(tickets).balance, 0);
        assertEq(beneficiary.balance - beneBefore, totalSpent);
    }
}
