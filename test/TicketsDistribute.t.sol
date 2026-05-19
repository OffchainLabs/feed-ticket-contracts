// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// forge-lint: disable-start

import {ITickets} from "../src/ITickets.sol";
import {BaseTicketsTest} from "./BaseTicketsTest.t.sol";

contract TicketsDistributeTest is BaseTicketsTest {
    address buyer = makeAddr("buyer");
    address depositor = makeAddr("depositor");

    /// @dev Buy one ticket in round 0 at MINIMUM_PRICE. Leaves `_storedProceeds` at 0 because the
    ///      lazy update only credits proceeds at round rollover.
    function _buyInRoundZero() internal {
        _deposit(buyer, MINIMUM_PRICE);
        vm.prank(buyer);
        tickets.purchaseTicket(0, MINIMUM_PRICE, bytes32(0));
    }

    function test_distribute_zeroProceeds_transfersZero() public {
        vm.expectEmit(true, false, false, true, address(tickets));
        emit ITickets.ProceedsDistributed(beneficiary, 0);
        tickets.distributeSaleProceeds();

        assertEq(token.balanceOf(beneficiary), 0);
        assertEq(token.balanceOf(address(tickets)), 0);
    }

    function test_distribute_excludesCurrentRoundRevenue() public {
        _buyInRoundZero();

        // No round has elapsed since the purchase; current-round revenue must not be distributed.
        tickets.distributeSaleProceeds();

        assertEq(token.balanceOf(beneficiary), 0);
        assertEq(token.balanceOf(address(tickets)), MINIMUM_PRICE);
    }

    function test_distribute_excludesProceedsAfterRoundEndButBeforeLazyUpdate() public {
        _buyInRoundZero();

        // Round 0 has ended but no mutative call has triggered lazy update, so _storedProceeds
        // is still 0. distribute must not sweep the contract's raw token balance.
        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        tickets.distributeSaleProceeds();

        assertEq(token.balanceOf(beneficiary), 0);
        assertEq(token.balanceOf(address(tickets)), MINIMUM_PRICE);
    }

    function test_distribute_includesProceedsAfterLazyUpdate() public {
        _buyInRoundZero();

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        tickets.exposed_lazyUpdateRoundState();

        vm.expectEmit(true, false, false, true, address(tickets));
        emit ITickets.ProceedsDistributed(beneficiary, MINIMUM_PRICE);
        tickets.distributeSaleProceeds();

        assertEq(token.balanceOf(beneficiary), MINIMUM_PRICE);
        assertEq(token.balanceOf(address(tickets)), 0);
    }

    function test_distribute_doubleCall_secondTransfersZero() public {
        _buyInRoundZero();
        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        tickets.exposed_lazyUpdateRoundState();

        tickets.distributeSaleProceeds();
        assertEq(token.balanceOf(beneficiary), MINIMUM_PRICE);

        // _storedProceeds was zeroed on the first call; second call distributes nothing.
        tickets.distributeSaleProceeds();
        assertEq(token.balanceOf(beneficiary), MINIMUM_PRICE);
    }

    function test_distribute_multiRoundSkip_creditsOnlyStoredRound() public {
        _buyInRoundZero();

        // Skip 5 rounds with no purchases in between. Only round 0 contributes; the empty
        // intermediate rounds have `_ticketsSoldThisRound == 0`.
        vm.warp(FIRST_ROUND_START + 5 * ROUND_DURATION);
        tickets.exposed_lazyUpdateRoundState();

        tickets.distributeSaleProceeds();
        assertEq(token.balanceOf(beneficiary), MINIMUM_PRICE);
    }

    function test_distribute_doesNotTriggerLazyUpdate() public {
        _buyInRoundZero();

        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        // sanity: rounds have elapsed in the view but the stored value is still 0
        assertEq(tickets.roundNumber(), 1);
        assertEq(tickets.exposed_storedRoundNumber(), 0);

        tickets.distributeSaleProceeds();

        // distribute must not roll the stored round forward — keeps a fund-rescue path live even
        // if a bug in lazy update would otherwise cause it to revert.
        assertEq(tickets.exposed_storedRoundNumber(), 0);
        // _storedProceeds was 0 at distribute time, so the buyer's payment is still parked in the
        // contract waiting for a later lazy update + distribute to forward it.
        assertEq(token.balanceOf(address(tickets)), MINIMUM_PRICE);
        assertEq(token.balanceOf(beneficiary), 0);
    }

    function test_distribute_doesNotSweepUserDeposits() public {
        // depositor parks tokens without ever purchasing; their balance must not be sweepable.
        _deposit(depositor, 5 ether);

        // Also seed real proceeds so we can assert beneficiary gets exactly those, not deposits.
        _buyInRoundZero();
        vm.warp(FIRST_ROUND_START + ROUND_DURATION);
        tickets.exposed_lazyUpdateRoundState();

        tickets.distributeSaleProceeds();

        // Beneficiary received only the purchase proceeds, not depositor's parked balance.
        assertEq(token.balanceOf(beneficiary), MINIMUM_PRICE);

        // depositor's internal balance is intact and fully withdrawable.
        assertEq(tickets.tokenBalance(depositor), 5 ether);
        vm.prank(depositor);
        tickets.withdrawToken(5 ether);
        assertEq(token.balanceOf(depositor), 5 ether);
        assertEq(token.balanceOf(address(tickets)), 0);
    }
}
