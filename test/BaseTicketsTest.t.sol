// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// forge-lint: disable-start

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Tickets} from "../src/Tickets.sol";

contract TicketsHarness is Tickets {
    function exposed_storedRoundNumber() external view returns (uint256) {
        return _roundNumber;
    }

    function exposed_storedRoundStart() external view returns (uint256) {
        return _roundStart;
    }

    function exposed_storedExcessTicketsSold() external view returns (uint256) {
        return _excessTicketsSold;
    }

    function exposed_storedCurrentPrice() external view returns (uint256) {
        return _currentPrice;
    }

    function exposed_setTicketsSold(uint256 round, uint256 amount) external {
        ticketsSold[round] = amount;
    }

    function exposed_lazyUpdateRoundState() external lazyUpdateRoundState {}

    function exposed_fakeExponential(uint256 factor, uint256 numerator, uint256 denominator)
        external
        pure
        returns (uint256)
    {
        return _fakeExponential(factor, numerator, denominator);
    }
}

abstract contract BaseTicketsTest is Test {
    TicketsHarness impl;
    TicketsHarness tickets;

    address proxyAdmin = makeAddr("proxyAdmin");
    address defaultAdmin = makeAddr("defaultAdmin");
    address beneficiarySetter = makeAddr("beneficiarySetter");
    address marketParamsSetter = makeAddr("marketParamsSetter");
    address beneficiary = makeAddr("beneficiary");

    uint32 constant ROUND_DURATION = 1 hours;
    uint16 constant TARGET_TICKETS = 100;
    uint16 constant MAX_TICKETS = 200;
    uint64 constant MINIMUM_PRICE = 1 ether;
    uint24 constant PRICE_UPDATE_FRACTION = 50;

    uint40 constant FIRST_ROUND_START = 1_700_000_000;

    function setUp() public virtual {
        vm.warp(FIRST_ROUND_START);
        impl = new TicketsHarness();
        tickets = TicketsHarness(address(new TransparentUpgradeableProxy(address(impl), proxyAdmin, _initData())));
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
                PRICE_UPDATE_FRACTION,
                FIRST_ROUND_START
            )
        );
    }
}
