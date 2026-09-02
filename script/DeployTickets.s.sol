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

import {Script, console} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Tickets} from "../src/Tickets.sol";

/// @notice Deploys Tickets behind a TransparentUpgradeableProxy, configured by env vars.
///         See .env.example. If CREATE2_SALT is unset, contracts are deployed with plain
///         CREATE; if TOKEN is unset, a mintable TestToken is deployed as the token.
contract DeployTickets is Script {
    using SafeCast for uint256;

    function run() external {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        Tickets.InitParams memory p = Tickets.InitParams({
            defaultAdmin: vm.envOr("DEFAULT_ADMIN", deployer),
            beneficiarySetter: vm.envOr("BENEFICIARY_SETTER", deployer),
            marketParamsSetter: vm.envOr("MARKET_PARAMS_SETTER", deployer),
            beneficiary: vm.envOr("BENEFICIARY", deployer),
            roundDuration: vm.envUint("ROUND_DURATION").toUint24(),
            targetTicketsPerRound: vm.envUint("TARGET_TICKETS_PER_ROUND").toUint16(),
            maxTicketsPerRound: vm.envUint("MAX_TICKETS_PER_ROUND").toUint16(),
            minimumPrice: vm.envUint("MINIMUM_PRICE").toUint64(),
            priceUpdateFraction: vm.envUint("PRICE_UPDATE_FRACTION").toUint40(),
            grandfatherPeriodFraction: vm.envUint("GRANDFATHER_PERIOD_FRACTION").toUint8(),
            // initialize requires a future start, so "now" would revert on-chain; give the
            // deploy tx a small window to land
            // forge-lint: disable-next-line(block-timestamp)
            firstRoundStart: vm.envOr("FIRST_ROUND_START", block.timestamp + 1 minutes).toUint40()
        });

        bool useCreate2 = vm.envExists("CREATE2_SALT");
        bytes32 salt = useCreate2 ? vm.envBytes32("CREATE2_SALT") : bytes32(0);

        address token = vm.envOr("TOKEN", address(0));
        if (token == address(0)) {
            token = useCreate2 ? address(new TestToken{salt: salt}(deployer)) : address(new TestToken(deployer));
        }

        Tickets impl = useCreate2 ? new Tickets{salt: salt}(token) : new Tickets(token);

        address proxyAdminOwner = vm.envOr("PROXY_ADMIN_OWNER", deployer);
        bytes memory initData = abi.encodeCall(Tickets.initialize, (p));
        TransparentUpgradeableProxy proxy = useCreate2
            ? new TransparentUpgradeableProxy{salt: salt}(address(impl), proxyAdminOwner, initData)
            : new TransparentUpgradeableProxy(address(impl), proxyAdminOwner, initData);

        vm.stopBroadcast();

        console.log("token:", token);
        console.log("implementation:", address(impl));
        console.log("proxy:", address(proxy));
        console.log("proxyAdmin:", address(uint160(uint256(vm.load(address(proxy), ERC1967Utils.ADMIN_SLOT)))));
        console.log("firstRoundStart:", p.firstRoundStart);
    }
}

contract TestToken is ERC20 {
    address public immutable minter;

    constructor(address _minter) ERC20("TestToken", "TEST") {
        minter = _minter;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "not minter");
        _mint(to, amount);
    }
}
