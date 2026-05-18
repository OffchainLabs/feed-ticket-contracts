// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// forge-lint: disable-start

import {ITickets} from "../src/ITickets.sol";
import {BaseTicketsTest} from "./BaseTicketsTest.t.sol";

contract TicketsDepositWithdrawTest is BaseTicketsTest {
    address user = makeAddr("user");

    /* ====================== depositToken ====================== */

    function test_depositToken_creditsBalanceAndPullsExactly() public {
        uint256 amount = 5 ether;
        token.mint(user, amount);

        vm.startPrank(user);
        token.approve(address(tickets), amount);
        tickets.depositToken(amount);
        vm.stopPrank();

        assertEq(tickets.tokenBalance(user), amount);
        assertEq(token.balanceOf(user), 0);
        assertEq(token.balanceOf(address(tickets)), amount);
    }

    function test_depositToken_emitsEvent() public {
        uint256 amount = 5 ether;
        token.mint(user, amount);

        vm.startPrank(user);
        token.approve(address(tickets), amount);
        vm.expectEmit(true, false, false, true, address(tickets));
        emit ITickets.TokensDeposited(user, amount);
        tickets.depositToken(amount);
        vm.stopPrank();
    }

    function test_depositToken_accumulatesAcrossCalls() public {
        token.mint(user, 10 ether);

        vm.startPrank(user);
        token.approve(address(tickets), 10 ether);
        tickets.depositToken(3 ether);
        tickets.depositToken(7 ether);
        vm.stopPrank();

        assertEq(tickets.tokenBalance(user), 10 ether);
    }

    function test_depositToken_zeroAmountIsNoOp() public {
        token.mint(user, 5 ether);

        vm.startPrank(user);
        token.approve(address(tickets), 5 ether);

        vm.expectEmit(true, false, false, true, address(tickets));
        emit ITickets.TokensDeposited(user, 0);
        tickets.depositToken(0);
        vm.stopPrank();

        assertEq(tickets.tokenBalance(user), 0);
        assertEq(token.balanceOf(user), 5 ether);
        assertEq(token.balanceOf(address(tickets)), 0);
    }

    function test_depositToken_doesNotTriggerLazyUpdate() public {
        vm.warp(FIRST_ROUND_START + 5 * ROUND_DURATION);

        // sanity: rounds have elapsed in the view but the stored value is still 0
        assertEq(tickets.roundNumber(), 5);
        assertEq(tickets.exposed_storedRoundNumber(), 0);

        token.mint(user, 1 ether);
        vm.startPrank(user);
        token.approve(address(tickets), 1 ether);
        tickets.depositToken(1 ether);
        vm.stopPrank();

        // depositToken did not roll the stored round forward
        assertEq(tickets.exposed_storedRoundNumber(), 0);
    }

    /// @dev Pins the additive-overflow revert path: each deposit fits in uint216 on its own,
    ///      but the running sum overflows the field.
    function test_depositToken_revertsOnAdditiveOverflowAboveUint216Max() public {
        uint256 nearMax = uint256(type(uint216).max) - 5;
        token.mint(user, nearMax);
        vm.startPrank(user);
        token.approve(address(tickets), nearMax);
        tickets.depositToken(nearMax);
        vm.stopPrank();

        token.mint(user, 10);
        vm.startPrank(user);
        token.approve(address(tickets), 10);
        vm.expectRevert();
        tickets.depositToken(10);
        vm.stopPrank();
    }

    /* ====================== withdrawToken ====================== */

    function test_withdrawToken_debitsBalanceAndTransfers() public {
        _deposit(user, 5 ether);

        vm.prank(user);
        tickets.withdrawToken(2 ether);

        assertEq(tickets.tokenBalance(user), 3 ether);
        assertEq(token.balanceOf(user), 2 ether);
        assertEq(token.balanceOf(address(tickets)), 3 ether);
    }

    function test_withdrawToken_emitsEvent() public {
        _deposit(user, 5 ether);

        vm.expectEmit(true, false, false, true, address(tickets));
        emit ITickets.TokensWithdrawn(user, 2 ether);
        vm.prank(user);
        tickets.withdrawToken(2 ether);
    }

    function test_withdrawToken_fullBalance() public {
        _deposit(user, 5 ether);

        vm.prank(user);
        tickets.withdrawToken(5 ether);

        assertEq(tickets.tokenBalance(user), 0);
        assertEq(token.balanceOf(user), 5 ether);
        assertEq(token.balanceOf(address(tickets)), 0);
    }

    function test_withdrawToken_partialThenFull() public {
        _deposit(user, 10 ether);

        vm.startPrank(user);
        tickets.withdrawToken(3 ether);
        assertEq(tickets.tokenBalance(user), 7 ether);
        tickets.withdrawToken(7 ether);
        vm.stopPrank();

        assertEq(tickets.tokenBalance(user), 0);
        assertEq(token.balanceOf(user), 10 ether);
        assertEq(token.balanceOf(address(tickets)), 0);
    }

    function test_withdrawToken_zeroAmountIsNoOp() public {
        _deposit(user, 5 ether);

        vm.expectEmit(true, false, false, true, address(tickets));
        emit ITickets.TokensWithdrawn(user, 0);
        vm.prank(user);
        tickets.withdrawToken(0);

        assertEq(tickets.tokenBalance(user), 5 ether);
        assertEq(token.balanceOf(user), 0);
        assertEq(token.balanceOf(address(tickets)), 5 ether);
    }

    function test_withdrawToken_revertsOnInsufficientBalance_withCorrectArgs() public {
        _deposit(user, 5 ether);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(ITickets.InsufficientTokenBalance.selector, 5 ether, 5 ether + 1)
        );
        tickets.withdrawToken(5 ether + 1);
    }

    function test_withdrawToken_revertsOnNeverDeposited() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ITickets.InsufficientTokenBalance.selector, 0, 1));
        tickets.withdrawToken(1);
    }

    function test_withdrawToken_doesNotTriggerLazyUpdate() public {
        _deposit(user, 5 ether);

        vm.warp(FIRST_ROUND_START + 5 * ROUND_DURATION);

        // sanity: rounds have elapsed in the view but the stored value is still 0
        assertEq(tickets.roundNumber(), 5);
        assertEq(tickets.exposed_storedRoundNumber(), 0);

        vm.prank(user);
        tickets.withdrawToken(1 ether);

        assertEq(tickets.exposed_storedRoundNumber(), 0);
    }
}
