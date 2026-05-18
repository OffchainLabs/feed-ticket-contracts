// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// forge-lint: disable-start

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Test} from "forge-std/Test.sol";
import {ITickets} from "../src/ITickets.sol";
import {Tickets} from "../src/Tickets.sol";

contract TicketsE2ETest is Test {
    Tickets impl;
    Tickets tickets;
    ERC20Mock token;

    address proxyAdmin = makeAddr("proxyAdmin");
    address defaultAdmin = makeAddr("defaultAdmin");
    address beneficiarySetter = makeAddr("beneficiarySetter");
    address marketParamsSetter = makeAddr("marketParamsSetter");
    address beneficiary = makeAddr("beneficiary");

    uint24 constant ROUND_DURATION = 1 hours;
    uint16 constant TARGET = 4;
    uint16 constant MAX = 8;
    uint64 constant MIN_PRICE = 1 ether;
    uint24 constant FRACTION = 10;
    uint8 constant GRANDFATHER_PERIOD_FRACTION = 100;
    uint40 constant FIRST_ROUND_START = 1_700_000_000;

    address[10] buyers;

    function setUp() public {
        vm.warp(FIRST_ROUND_START - 1);
        token = new ERC20Mock();
        impl = new Tickets(address(token));
        bytes memory initData = abi.encodeCall(
            Tickets.initialize,
            (Tickets.InitParams({
                    defaultAdmin: defaultAdmin,
                    beneficiarySetter: beneficiarySetter,
                    marketParamsSetter: marketParamsSetter,
                    beneficiary: beneficiary,
                    roundDuration: ROUND_DURATION,
                    targetTicketsPerRound: TARGET,
                    maxTicketsPerRound: MAX,
                    minimumPrice: MIN_PRICE,
                    priceUpdateFraction: FRACTION,
                    grandfatherPeriodFraction: GRANDFATHER_PERIOD_FRACTION,
                    firstRoundStart: FIRST_ROUND_START
                }))
        );
        tickets = Tickets(address(new TransparentUpgradeableProxy(address(impl), proxyAdmin, initData)));
        vm.warp(FIRST_ROUND_START);
        for (uint256 i = 0; i < buyers.length; i++) {
            buyers[i] = makeAddr(string.concat("buyer", vm.toString(i)));
        }
    }

    function _buy(address buyer, uint256 round) internal returns (uint256 price) {
        price = tickets.currentPrice();
        token.mint(buyer, price);
        vm.startPrank(buyer);
        token.approve(address(tickets), price);
        tickets.depositToken(price);
        tickets.purchaseTicket(round, price, bytes32(0));
        vm.stopPrank();
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
            assertEq(tickets.grandfatheredIntoRound(buyers[i]), 1);
            assertEq(tickets.ticketsSoldThisRound(), i + 1);
            assertEq(tickets.currentPrice(), MIN_PRICE);
        }

        // Cannot buy twice in the same round.
        vm.expectRevert(ITickets.AlreadyPurchasedInRound.selector);
        vm.prank(buyers[0]);
        tickets.purchaseTicket(0, MIN_PRICE, bytes32(0));

        // Wrong price reverts.
        vm.expectRevert(abi.encodeWithSelector(ITickets.IncorrectTicketPrice.selector, MIN_PRICE + 1, MIN_PRICE));
        vm.prank(buyers[7]);
        tickets.purchaseTicket(0, MIN_PRICE + 1, bytes32(0));

        // Wrong expectedRound reverts.
        vm.expectRevert(abi.encodeWithSelector(ITickets.RoundNumberMismatch.selector, 1, 0));
        vm.prank(buyers[7]);
        tickets.purchaseTicket(1, MIN_PRICE, bytes32(0));

        // Fill the final slot so the round closes at the cap.
        totalSpent += _buy(buyers[MAX - 1], 0);
        assertEq(tickets.ticketsSoldThisRound(), MAX);

        // 9th buy hits the cap.
        vm.expectRevert(ITickets.MaxTicketsSold.selector);
        vm.prank(buyers[8]);
        tickets.purchaseTicket(0, MIN_PRICE, bytes32(0));

        // ===== Round 1 — grandfather phase restricts to round-0 holders =====
        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        assertEq(tickets.roundNumber(), 1);
        // gross = 0 + 8 = 8, consumed = 1*4 = 4 → excess = 4.
        assertEq(tickets.excessTicketsSold(), 4);
        uint256 r1Price = tickets.currentPrice();
        assertGt(r1Price, MIN_PRICE);

        // Boundary: just before grandfatherPeriodEnd the rule applies; at the boundary it does not.
        uint256 r1GrandfatherEnd = tickets.grandfatherPeriodEnd();
        vm.warp(r1GrandfatherEnd - 1);
        // buyers[8] never bought in round 0 → reverts during grandfather phase.
        // Pre-deposit so the InsufficientTokenBalance check passes and the grandfather check fires.
        // buyers[8] will reuse this deposit when they succeed at the boundary below.
        token.mint(buyers[8], r1Price);
        vm.startPrank(buyers[8]);
        token.approve(address(tickets), r1Price);
        tickets.depositToken(r1Price);
        vm.expectRevert(ITickets.NotGrandfathered.selector);
        tickets.purchaseTicket(1, r1Price, bytes32(0));
        vm.stopPrank();
        // A grandfathered buyer succeeds at the same instant.
        totalSpent += _buy(buyers[0], 1);

        vm.warp(r1GrandfatherEnd);
        // Same non-grandfathered buyer now succeeds at the boundary, spending the prior deposit.
        vm.prank(buyers[8]);
        tickets.purchaseTicket(1, r1Price, bytes32(0));
        totalSpent += r1Price;
        // Two more post-grandfather buys, mixing grandfathered and not.
        totalSpent += _buy(buyers[1], 1);
        totalSpent += _buy(buyers[9], 1);

        assertEq(tickets.ticketsSoldThisRound(), 4);
        assertEq(tickets.grandfatheredIntoRound(buyers[0]), 2);
        assertEq(tickets.grandfatheredIntoRound(buyers[1]), 2);
        assertEq(tickets.grandfatheredIntoRound(buyers[8]), 2);
        assertEq(tickets.grandfatheredIntoRound(buyers[9]), 2);

        // ===== Round 2 — round-1 holders are the new grandfathered set =====
        vm.warp(FIRST_ROUND_START + 2 * ROUND_DURATION);
        assertEq(tickets.roundNumber(), 2);
        // gross = 4 + 4 = 8, consumed = 1*4 = 4 → excess = 4 (round 1 sold exactly the target).
        assertEq(tickets.excessTicketsSold(), 4);
        // No change in excess → price unchanged from round 1.
        assertEq(tickets.currentPrice(), r1Price);

        // Grandfather phase: round-1 holders may buy.
        totalSpent += _buy(buyers[0], 2);
        totalSpent += _buy(buyers[8], 2);

        // buyers[2] only ever bought in round 0 → not grandfathered for round 2 → reverts.
        // Pre-deposit so the balance check passes and the grandfather check fires.
        // buyers[2] will reuse this deposit when they succeed post-grandfather below.
        token.mint(buyers[2], r1Price);
        vm.startPrank(buyers[2]);
        token.approve(address(tickets), r1Price);
        tickets.depositToken(r1Price);
        vm.expectRevert(ITickets.NotGrandfathered.selector);
        tickets.purchaseTicket(2, r1Price, bytes32(0));
        vm.stopPrank();

        // After grandfather phase: anyone may buy.
        vm.warp(tickets.grandfatherPeriodEnd());
        // buyers[2] spends the deposit made before the NotGrandfathered revert above. Price is
        // still r1Price (excess unchanged from round 1), so the pre-deposit suffices.
        vm.prank(buyers[2]);
        tickets.purchaseTicket(2, r1Price, bytes32(0));
        totalSpent += r1Price;
        totalSpent += _buy(buyers[3], 2);
        totalSpent += _buy(buyers[4], 2);

        assertEq(tickets.ticketsSoldThisRound(), 5);

        // ===== Round 3 — excess and therefore price grow =====
        vm.warp(FIRST_ROUND_START + 3 * ROUND_DURATION);
        assertEq(tickets.roundNumber(), 3);
        // gross = 4 + 5 = 9, consumed = 1*4 = 4 → excess = 5.
        assertEq(tickets.excessTicketsSold(), 5);
        uint256 r3Price = tickets.currentPrice();
        assertGt(r3Price, r1Price);

        // Skip past the grandfather phase so we can fill the cap from any buyer.
        vm.warp(tickets.grandfatherPeriodEnd());
        for (uint256 i = 0; i < MAX; i++) {
            totalSpent += _buy(buyers[i], 3);
        }
        assertEq(tickets.ticketsSoldThisRound(), MAX);

        // 9th buy hits the cap.
        vm.expectRevert(ITickets.MaxTicketsSold.selector);
        vm.prank(buyers[8]);
        tickets.purchaseTicket(3, r3Price, bytes32(0));

        // ===== Distribute proceeds =====
        // Contract balance equals total deposited, which equals total spent (every _buy deposits
        // exactly the price). Round 3's proceeds have not yet been flushed into `_storedProceeds`
        // because no mutative call has run since the round 3 buys; trigger one via the admin so
        // distributeSaleProceeds sweeps the entire balance.
        assertEq(token.balanceOf(address(tickets)), totalSpent);
        vm.warp(FIRST_ROUND_START + 4 * ROUND_DURATION);
        vm.prank(marketParamsSetter);
        tickets.setRoundDuration(ROUND_DURATION + 1);

        uint256 beneBefore = token.balanceOf(beneficiary);
        tickets.distributeSaleProceeds();
        assertEq(token.balanceOf(address(tickets)), 0);
        assertEq(token.balanceOf(beneficiary) - beneBefore, totalSpent);
    }
}
