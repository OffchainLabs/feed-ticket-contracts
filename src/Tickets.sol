// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {ITickets} from "./interfaces/ITickets.sol";

contract Tickets is ITickets, AccessControlEnumerableUpgradeable {
    bytes32 public constant BENEFICIARY_SETTER = keccak256("BENEFICIARY_SETTER");
    bytes32 public constant MARKET_PARAMS_SETTER = keccak256("MARKET_PARAMS_SETTER");

    address public beneficiary;
    uint256 public roundDuration;
    uint256 public targetTicketsPerRound;
    uint256 public maxTicketsPerRound;
    uint256 public minimumPrice;
    uint256 public priceUpdateFraction;
    uint256 public nextRoundDuration;
    uint256 public nextTargetTicketsPerRound;
    uint256 public nextMaxTicketsPerRound;
    uint256 public nextMinimumPrice;
    uint256 public nextPriceUpdateFraction;
    mapping(address => mapping(uint256 => bool)) public hasTicket;
    mapping(uint256 => uint256) public ticketsSold;

    uint256 internal _roundNumber;
    uint256 internal _roundStart;
    uint256 internal _excessTicketsSold;

    constructor() {
        _disableInitializers();
    }

    modifier lazyUpdateRoundState() {
        _;
    }

    function initialize(
        address defaultAdmin,
        address beneficiarySetter,
        address marketParamsSetter,
        address _beneficiary,
        uint256 _roundDuration,
        uint256 _targetTicketsPerRound,
        uint256 _maxTicketsPerRound,
        uint256 _minimumPrice,
        uint256 _priceUpdateFraction
    ) external initializer {
        __AccessControlEnumerable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(BENEFICIARY_SETTER, beneficiarySetter);
        _grantRole(MARKET_PARAMS_SETTER, marketParamsSetter);

        beneficiary = _beneficiary;
        roundDuration = _roundDuration;
        targetTicketsPerRound = _targetTicketsPerRound;
        maxTicketsPerRound = _maxTicketsPerRound;
        minimumPrice = _minimumPrice;
        priceUpdateFraction = _priceUpdateFraction;

        _roundStart = block.timestamp;
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

    /// @notice Approximates `factor * e^(numerator / denominator)` via a Taylor series with
    ///         integer arithmetic.
    /// @dev    Reference: EIP-4844 `fake_exponential` — https://eips.ethereum.org/EIPS/eip-4844
    ///         Mirrors go-ethereum `fakeExponential`:
    ///         https://github.com/ethereum/go-ethereum/blob/16a6531ac204c110ea4b51c7905b3f71595b8f0c/consensus/misc/eip4844/eip4844.go#L217
    function _fakeExponential(uint256 factor, uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        uint256 i = 1;
        uint256 output = 0;
        uint256 accum = factor * denominator;
        while (accum > 0) {
            output += accum;
            accum = accum * numerator;
            accum = accum / denominator;
            accum = accum / i;
            i++;
        }
        return output / denominator;
    }
}
