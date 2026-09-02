// SPDX-License-Identifier: Apache-2.0

/*
 * Copyright 2026, Offchain Labs, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

pragma solidity ^0.8.20;

// forge-lint: disable-start

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Tickets} from "../src/Tickets.sol";

contract TicketsHarness is Tickets {
    constructor(address _token) Tickets(_token) {}

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

    function exposed_storedProceeds() external view returns (uint256) {
        return _storedProceeds;
    }

    function exposed_setTicketsSoldThisRound(uint256 amount) external {
        _ticketsSoldThisRound = uint16(amount);
    }

    function exposed_setCurrentPrice(uint256 price) external {
        _currentPrice = uint72(price);
    }

    function exposed_lazyUpdateRoundState() external {
        _lazyUpdateRoundState();
    }

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
    ERC20Mock token;

    address proxyAdmin = makeAddr("proxyAdmin");
    address defaultAdmin = makeAddr("defaultAdmin");
    address beneficiarySetter = makeAddr("beneficiarySetter");
    address marketParamsSetter = makeAddr("marketParamsSetter");
    address beneficiary = makeAddr("beneficiary");

    uint24 constant ROUND_DURATION = 1 hours;
    uint16 constant TARGET_TICKETS = 100;
    uint16 constant MAX_TICKETS = 200;
    uint64 constant MINIMUM_PRICE = 1 ether;
    uint24 constant PRICE_UPDATE_FRACTION = 50;
    uint8 constant GRANDFATHER_PERIOD_FRACTION = 100;

    uint40 constant FIRST_ROUND_START = 1_700_000_000;

    function setUp() public virtual {
        vm.warp(FIRST_ROUND_START - 1);
        token = new ERC20Mock();
        impl = new TicketsHarness(address(token));
        tickets = TicketsHarness(address(new TransparentUpgradeableProxy(address(impl), proxyAdmin, _initData())));
        vm.warp(FIRST_ROUND_START);
    }

    function _deposit(address user, uint256 amount) internal {
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(tickets), amount);
        tickets.depositToken(amount);
        vm.stopPrank();
    }

    function _initData() internal view returns (bytes memory) {
        return abi.encodeCall(
            Tickets.initialize,
            (Tickets.InitParams({
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
                }))
        );
    }
}
