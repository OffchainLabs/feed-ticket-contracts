// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Tickets} from "../src/Tickets.sol";

/// @notice Deploys Tickets behind a TransparentUpgradeableProxy, configured by env vars.
///         See .env.example. If CREATE2_SALT is unset, contracts are deployed with plain
///         CREATE; if TOKEN is unset, a test ERC20PresetMinter is deployed as the token.
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
            token = useCreate2
                ? address(new ERC20PresetMinter{salt: salt}("TestToken", "TEST", deployer))
                : address(new ERC20PresetMinter("TestToken", "TEST", deployer));
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

contract ERC20PresetMinter is ERC20 {
    address public immutable minter;

    constructor(string memory name, string memory symbol, address _minter) ERC20(name, symbol) {
        minter = _minter;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "not minter");
        _mint(to, amount);
    }
}
