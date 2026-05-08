// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Tickets} from "../src/Tickets.sol";

contract TicketsHarness is Tickets {
    function exposed_roundStart() external view returns (uint256) {
        return _roundStart;
    }
}

contract TicketsTest is Test {
    TicketsHarness impl;
    TicketsHarness tickets;

    address proxyAdmin = makeAddr("proxyAdmin");
    address defaultAdmin = makeAddr("defaultAdmin");
    address beneficiarySetter = makeAddr("beneficiarySetter");
    address marketParamsSetter = makeAddr("marketParamsSetter");
    address beneficiary = makeAddr("beneficiary");

    uint256 constant ROUND_DURATION = 1 hours;
    uint256 constant TARGET_TICKETS = 100;
    uint256 constant MAX_TICKETS = 200;
    uint256 constant MINIMUM_PRICE = 1 ether;
    uint256 constant PRICE_UPDATE_FRACTION = 50;

    uint256 constant DEPLOY_TIMESTAMP = 1_700_000_000;

    function setUp() public {
        vm.warp(DEPLOY_TIMESTAMP);
        impl = new TicketsHarness();
        tickets = TicketsHarness(
            address(new TransparentUpgradeableProxy(address(impl), proxyAdmin, _initData()))
        );
    }

    function _initData() internal view returns (bytes memory) {
        return abi.encodeCall(
            Tickets.initialize,
            (
                defaultAdmin,
                beneficiarySetter,
                marketParamsSetter,
                beneficiary,
                ROUND_DURATION,
                TARGET_TICKETS,
                MAX_TICKETS,
                MINIMUM_PRICE,
                PRICE_UPDATE_FRACTION
            )
        );
    }

    function test_initialize_setsState() public view {
        assertEq(tickets.beneficiary(), beneficiary);
        assertEq(tickets.roundDuration(), ROUND_DURATION);
        assertEq(tickets.targetTicketsPerRound(), TARGET_TICKETS);
        assertEq(tickets.maxTicketsPerRound(), MAX_TICKETS);
        assertEq(tickets.minimumPrice(), MINIMUM_PRICE);
        assertEq(tickets.priceUpdateFraction(), PRICE_UPDATE_FRACTION);
    }

    function test_initialize_setsRoundStart() public view {
        assertEq(tickets.exposed_roundStart(), DEPLOY_TIMESTAMP);
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
