// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ITickets} from "./interfaces/ITickets.sol";

contract Tickets is ITickets, AccessControlUpgradeable {
    bytes32 public constant BENEFICIARY_SETTER = keccak256("BENEFICIARY_SETTER");
    bytes32 public constant MARKET_PARAMS_SETTER = keccak256("MARKET_PARAMS_SETTER");

    address public beneficiary;
    uint256 public roundDuration;
    uint256 public nextRoundDuration;
    uint256 public targetTicketsPerRound;
    uint256 public nextTargetTicketsPerRound;
    uint256 public maxTicketsPerRound;
    uint256 public nextMaxTicketsPerRound;
    uint256 public minimumPrice;
    uint256 public nextMinimumPrice;
    uint256 public priceUpdateFraction;
    uint256 public nextPriceUpdateFraction;
    mapping(address => mapping(uint256 => bool)) public hasTicket;
    mapping(uint256 => uint256) public ticketsSold;

    uint256 private _roundNumber;
    uint256 private _roundStart;
    uint256 private _excessTicketsSold;

    constructor() {
        _disableInitializers();
    }

    modifier lazyUpdateRoundState() {
        _;
    }

    function initialize(address initialAdmin) external initializer {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
    }

    function roundsElapsedSinceStored() external view returns (uint256) {}

    function roundNumber() external view returns (uint256) {}

    function roundStart() external view returns (uint256) {}

    function roundEnd() external view returns (uint256) {}

    function excessTicketsSold() external view returns (uint256) {}

    function currentPrice() external view returns (uint256) {}

    function purchaseTicket(uint256 expectedRound) external payable lazyUpdateRoundState {}

    function distributeSaleProceeds() external {}

    function setBeneficiary(address newBeneficiary) external onlyRole(BENEFICIARY_SETTER) lazyUpdateRoundState {}

    function setRoundDuration(uint256 newDuration) external onlyRole(MARKET_PARAMS_SETTER) lazyUpdateRoundState {}

    function setMaxTicketsPerRound(uint256 newMax) external onlyRole(MARKET_PARAMS_SETTER) lazyUpdateRoundState {}

    function setTargetTicketsPerRound(uint256 newTarget) external onlyRole(MARKET_PARAMS_SETTER) lazyUpdateRoundState {}

    function setPricingParams(uint256 newMinimumPrice, uint256 newPriceUpdateFraction)
        external
        onlyRole(MARKET_PARAMS_SETTER)
        lazyUpdateRoundState
    {}

    function _fakeExponential(uint256 factor, uint256 numerator, uint256 denominator) internal pure returns (uint256) {}
}
