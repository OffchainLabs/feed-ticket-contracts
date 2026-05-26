// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// forge-lint: disable-start

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {BaseTicketsTest} from "./BaseTicketsTest.t.sol";
import {ITickets} from "../src/ITickets.sol";
import {Tickets} from "../src/Tickets.sol";

contract TicketsInitTest is BaseTicketsTest {
    function test_initialize_setsState() public view {
        assertEq(tickets.beneficiary(), beneficiary);
        assertEq(tickets.roundDuration(), ROUND_DURATION);
        assertEq(tickets.targetTicketsPerRound(), TARGET_TICKETS);
        assertEq(tickets.maxTicketsPerRound(), MAX_TICKETS);
        assertEq(tickets.minimumPrice(), MINIMUM_PRICE);
        assertEq(tickets.priceUpdateFraction(), PRICE_UPDATE_FRACTION);
        assertEq(tickets.grandfatherPeriodFraction(), GRANDFATHER_PERIOD_FRACTION);
    }

    function test_initialize_setsRoundStart() public view {
        assertEq(tickets.exposed_storedRoundStart(), FIRST_ROUND_START);
    }

    function test_token_returnsConstructorAddress() public view {
        assertEq(tickets.token(), address(token));
        assertEq(impl.token(), address(token));
    }

    function test_initialize_grantsRoles() public view {
        assertTrue(tickets.hasRole(tickets.DEFAULT_ADMIN_ROLE(), defaultAdmin));
        assertTrue(tickets.hasRole(tickets.BENEFICIARY_SETTER(), beneficiarySetter));
        assertTrue(tickets.hasRole(tickets.MARKET_PARAMS_SETTER(), marketParamsSetter));
    }

    function _params() internal view returns (Tickets.InitParams memory) {
        return Tickets.InitParams({
            defaultAdmin: defaultAdmin,
            beneficiarySetter: beneficiarySetter,
            marketParamsSetter: marketParamsSetter,
            beneficiary: beneficiary,
            roundDuration: ROUND_DURATION,
            targetTicketsPerRound: TARGET_TICKETS,
            maxTicketsPerRound: MAX_TICKETS,
            minimumPrice: MINIMUM_PRICE,
            priceUpdateFraction: PRICE_UPDATE_FRACTION,
            grandfatherPeriodFraction: GRANDFATHER_PERIOD_FRACTION,
            firstRoundStart: FIRST_ROUND_START
        });
    }

    function test_initialize_cannotBeCalledTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        tickets.initialize(_params());
    }

    function test_initialize_disabledOnImplementation() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(_params());
    }

    function test_initialize_revertsWhenFirstRoundStartEqualsNow() public {
        Tickets.InitParams memory p = _params();
        p.firstRoundStart = uint40(block.timestamp);
        vm.expectRevert(ITickets.FirstRoundStartNotInFuture.selector);
        new TransparentUpgradeableProxy(address(impl), proxyAdmin, abi.encodeCall(Tickets.initialize, (p)));
    }

    // KILLS MUTANT #4 in src/Tickets.sol
    function test_initialize_revertsOnZeroRoundDuration() public {
        Tickets.InitParams memory p = _params();
        p.roundDuration = 0;
        vm.expectRevert(ITickets.RoundDurationZero.selector);
        new TransparentUpgradeableProxy(address(impl), proxyAdmin, abi.encodeCall(Tickets.initialize, (p)));
    }

    // KILLS MUTANT #6 in src/Tickets.sol
    function test_initialize_revertsOnZeroTargetTicketsPerRound() public {
        Tickets.InitParams memory p = _params();
        p.targetTicketsPerRound = 0;
        vm.expectRevert(ITickets.TargetTicketsPerRoundZero.selector);
        new TransparentUpgradeableProxy(address(impl), proxyAdmin, abi.encodeCall(Tickets.initialize, (p)));
    }

    // KILLS MUTANT #8 in src/Tickets.sol
    function test_initialize_revertsOnZeroMaxTicketsPerRound() public {
        Tickets.InitParams memory p = _params();
        p.maxTicketsPerRound = 0;
        vm.expectRevert(ITickets.MaxTicketsPerRoundZero.selector);
        new TransparentUpgradeableProxy(address(impl), proxyAdmin, abi.encodeCall(Tickets.initialize, (p)));
    }

    // KILLS MUTANT #10 in src/Tickets.sol
    function test_initialize_revertsOnZeroMinimumPrice() public {
        Tickets.InitParams memory p = _params();
        p.minimumPrice = 0;
        vm.expectRevert(ITickets.MinimumPriceZero.selector);
        new TransparentUpgradeableProxy(address(impl), proxyAdmin, abi.encodeCall(Tickets.initialize, (p)));
    }

    // KILLS MUTANT #12 in src/Tickets.sol
    function test_initialize_revertsOnZeroPriceUpdateFraction() public {
        Tickets.InitParams memory p = _params();
        p.priceUpdateFraction = 0;
        vm.expectRevert(ITickets.PriceUpdateFractionZero.selector);
        new TransparentUpgradeableProxy(address(impl), proxyAdmin, abi.encodeCall(Tickets.initialize, (p)));
    }

    // KILLS MUTANT #14 in src/Tickets.sol
    function test_initialize_revertsOnReservedGrandfatherPeriodFraction() public {
        Tickets.InitParams memory p = _params();
        p.grandfatherPeriodFraction = type(uint8).max;
        vm.expectRevert(ITickets.GrandfatherPeriodFractionReserved.selector);
        new TransparentUpgradeableProxy(address(impl), proxyAdmin, abi.encodeCall(Tickets.initialize, (p)));
    }
}
