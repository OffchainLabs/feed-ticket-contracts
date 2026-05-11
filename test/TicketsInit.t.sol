// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// forge-lint: disable-start

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {BaseTicketsTest} from "./BaseTicketsTest.t.sol";

contract TicketsInitTest is BaseTicketsTest {
    function test_initialize_setsState() public view {
        assertEq(tickets.beneficiary(), beneficiary);
        assertEq(tickets.roundDuration(), ROUND_DURATION);
        assertEq(tickets.targetTicketsPerRound(), TARGET_TICKETS);
        assertEq(tickets.maxTicketsPerRound(), MAX_TICKETS);
        assertEq(tickets.minimumPrice(), MINIMUM_PRICE);
        assertEq(tickets.priceUpdateFraction(), PRICE_UPDATE_FRACTION);
    }

    function test_initialize_setsRoundStart() public view {
        assertEq(tickets.exposed_storedRoundStart(), DEPLOY_TIMESTAMP);
    }

    function test_initialize_grantsRoles() public view {
        assertTrue(tickets.hasRole(tickets.DEFAULT_ADMIN_ROLE(), defaultAdmin));
        assertTrue(tickets.hasRole(tickets.BENEFICIARY_SETTER(), beneficiarySetter));
        assertTrue(tickets.hasRole(tickets.MARKET_PARAMS_SETTER(), marketParamsSetter));
    }

    function test_initialize_cannotBeCalledTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        tickets.initialize(
            defaultAdmin,
            beneficiarySetter,
            marketParamsSetter,
            beneficiary,
            ROUND_DURATION,
            TARGET_TICKETS,
            MAX_TICKETS,
            MINIMUM_PRICE,
            PRICE_UPDATE_FRACTION
        );
    }

    function test_initialize_disabledOnImplementation() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(
            defaultAdmin,
            beneficiarySetter,
            marketParamsSetter,
            beneficiary,
            ROUND_DURATION,
            TARGET_TICKETS,
            MAX_TICKETS,
            MINIMUM_PRICE,
            PRICE_UPDATE_FRACTION
        );
    }
}
