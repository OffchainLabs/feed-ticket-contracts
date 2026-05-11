// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {ITickets} from "./interfaces/ITickets.sol";

contract Tickets is ITickets, AccessControlEnumerableUpgradeable {
    /// @notice Parameters passed to `initialize`. Bundled to avoid stack-too-deep at the call site.
    struct InitParams {
        address defaultAdmin;
        address beneficiarySetter;
        address marketParamsSetter;
        address beneficiary;
        uint24 roundDuration;
        uint16 targetTicketsPerRound;
        uint16 maxTicketsPerRound;
        uint64 minimumPrice;
        uint24 priceUpdateFraction;
        uint8 grandfatherPeriodFraction;
        uint40 firstRoundStart;
    }

    bytes32 public constant BENEFICIARY_SETTER = keccak256("BENEFICIARY_SETTER");
    bytes32 public constant MARKET_PARAMS_SETTER = keccak256("MARKET_PARAMS_SETTER");

    // ----- Begin Slot 0 ----- //

    /// @dev uint24 seconds - up to ~194 days.
    uint24 internal _roundDuration;

    /// @dev uint16 - up to 65,535.
    uint16 internal _maxTicketsPerRound;

    /// @dev uint64 wei - up to ~18.4 ether.
    uint64 internal _minimumPrice;

    /// @dev uint72 - up to ~4700 ether.
    ///      Caching price is cheaper than recomputing via Taylor series on each purchase.
    uint72 internal _currentPrice;

    /// @dev uint32 - at 1-second rounds, supports up to ~136 years.
    uint32 internal _roundNumber;

    /// @dev uint40 seconds - Unix timestamps to year ~36800 (well past the uint32 year-2106 limit).
    uint40 internal _roundStart;

    /// @dev uint8 - length of the grandfather phase as a fraction of 256 of the round.
    ///      e.g. 128 = first half of the round.
    uint8 internal _grandfatherPeriodFraction;

    // ------ End Slot 0 ------ //
    // ----- Begin Slot 1 ----- //

    /// @dev Type matches maxTicketsPerRound.
    uint16 internal _targetTicketsPerRound;

    /// @dev uint24 - up to ~16.7M. Assuming target is 1 and max is 2^16-1, and we want a
    ///      max change rate of 1% per round (lower change needs larger fraction), then
    ///      1.01 = e^(A/B), A = 65534, solve for B -> B = 6.58611*10^6, log2(B) = 23.
    uint24 internal _priceUpdateFraction;

    /// @dev uint48 - Up to 2^16 excess/round (uint16 cap) * 2^32 rounds (uint32 _roundNumber)
    ///      = 2^48 worst-case excess.
    uint48 internal _excessTicketsSold;

    /// @inheritdoc ITickets
    /// @dev Type matches roundDuration.
    uint24 public nextRoundDuration;

    /// @inheritdoc ITickets
    /// @dev Type matches targetTicketsPerRound.
    uint16 public nextTargetTicketsPerRound;

    /// @inheritdoc ITickets
    /// @dev Type matches maxTicketsPerRound.
    uint16 public nextMaxTicketsPerRound;

    /// @inheritdoc ITickets
    /// @dev Type matches minimumPrice.
    uint64 public nextMinimumPrice;

    /// @inheritdoc ITickets
    /// @dev Type matches priceUpdateFraction.
    uint24 public nextPriceUpdateFraction;

    /// @inheritdoc ITickets
    /// @dev Type matches grandfatherPeriodFraction.
    uint8 public nextGrandfatherPeriodFraction;

    // ------ End Slot 1 ------ //

    address public beneficiary;

    /// @inheritdoc ITickets
    mapping(address => uint256) public grandfatheredIntoRound;
    mapping(uint256 => uint256) public ticketsSold;

    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata p) external initializer {
        __AccessControlEnumerable_init();
        _initRoles(p.defaultAdmin, p.beneficiarySetter, p.marketParamsSetter);

        beneficiary = p.beneficiary;
        _roundDuration = p.roundDuration;
        _targetTicketsPerRound = p.targetTicketsPerRound;
        _maxTicketsPerRound = p.maxTicketsPerRound;
        _minimumPrice = p.minimumPrice;
        _priceUpdateFraction = p.priceUpdateFraction;
        _grandfatherPeriodFraction = p.grandfatherPeriodFraction;

        _roundStart = p.firstRoundStart;
        _currentPrice = p.minimumPrice;
    }

    function _initRoles(address defaultAdmin, address beneficiarySetter, address marketParamsSetter) internal {
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(BENEFICIARY_SETTER, beneficiarySetter);
        _grantRole(MARKET_PARAMS_SETTER, marketParamsSetter);
    }

    function purchaseTicket(uint256 expectedRound) external payable {
        _lazyUpdateRoundState();
        require(expectedRound == _roundNumber, "Round number mismatch");
        require(msg.value == _currentPrice, "Incorrect ticket price");
        require(ticketsSold[_roundNumber] < _maxTicketsPerRound, "Max tickets sold for this round");
        require(grandfatheredIntoRound[msg.sender] != _roundNumber + 1, "Cannot buy two tickets in one round");

        // forge-lint: disable-start(block-timestamp)
        if (
            _roundNumber > 0
                && block.timestamp
                    < uint256(_roundStart) + (uint256(_roundDuration) * uint256(_grandfatherPeriodFraction)) / 256
        ) {
            require(
                grandfatheredIntoRound[msg.sender] == _roundNumber,
                "Must have ticket from previous round to purchase during grandfather phase"
            );
        }
        // forge-lint: disable-end(block-timestamp)

        ticketsSold[_roundNumber]++;
        grandfatheredIntoRound[msg.sender] = _roundNumber + 1;

        emit TicketPurchased(msg.sender, _roundNumber, msg.value);
    }

    function distributeSaleProceeds() external {
        uint256 amount = address(this).balance;
        (bool success,) = beneficiary.call{value: amount}("");
        require(success, "Payment failed");
        emit ProceedsDistributed(beneficiary, amount);
    }

    function roundsElapsedSinceStored() public view returns (uint256) {
        // forge-lint: disable-next-line(block-timestamp)
        require(block.timestamp >= _roundStart, "Current time is before first round start");
        return (block.timestamp - _roundStart) / _roundDuration;
    }

    function roundNumber() public view returns (uint256) {
        return _roundNumber + roundsElapsedSinceStored();
    }

    function roundStart() public view returns (uint256) {
        return _roundStart + roundsElapsedSinceStored() * _roundDuration;
    }

    function roundEnd() external view returns (uint256) {
        return roundStart() + roundDuration();
    }

    function grandfatherPeriodEnd() external view returns (uint256) {
        return roundStart() + (roundDuration() * grandfatherPeriodFraction()) / 256;
    }

    function roundDuration() public view returns (uint256) {
        return _applyAdminUpdate(_roundDuration, nextRoundDuration);
    }

    function maxTicketsPerRound() external view returns (uint256) {
        return _applyAdminUpdate(_maxTicketsPerRound, nextMaxTicketsPerRound);
    }

    function minimumPrice() public view returns (uint256) {
        return _applyAdminUpdate(_minimumPrice, nextMinimumPrice);
    }

    function targetTicketsPerRound() external view returns (uint256) {
        return _applyAdminUpdate(_targetTicketsPerRound, nextTargetTicketsPerRound);
    }

    function priceUpdateFraction() public view returns (uint256) {
        return _applyAdminUpdate(_priceUpdateFraction, nextPriceUpdateFraction);
    }

    function grandfatherPeriodFraction() public view returns (uint256) {
        return _applyAdminUpdate(_grandfatherPeriodFraction, nextGrandfatherPeriodFraction);
    }

    function excessTicketsSold() public view returns (uint256) {
        uint256 elapsed = roundsElapsedSinceStored();
        if (elapsed == 0) return _excessTicketsSold;
        uint256 gross = _excessTicketsSold + ticketsSold[_roundNumber];
        uint256 consumed = elapsed * _targetTicketsPerRound;
        return gross > consumed ? gross - consumed : 0;
    }

    function currentPrice() public view returns (uint256) {
        uint256 result = _fakeExponential(minimumPrice(), excessTicketsSold(), priceUpdateFraction());
        // forge-lint: disable-next-line(unsafe-typecast)
        return result > type(uint72).max ? type(uint72).max : uint72(result);
    }

    function setBeneficiary(address newBeneficiary) external onlyRole(BENEFICIARY_SETTER) {
        beneficiary = newBeneficiary;
        emit BeneficiarySet(newBeneficiary);
    }

    function setRoundDuration(uint24 newDuration) external onlyRole(MARKET_PARAMS_SETTER) {
        _lazyUpdateRoundState();
        nextRoundDuration = newDuration;
        emit RoundDurationQueued(newDuration);
    }

    function setMaxTicketsPerRound(uint16 newMax) external onlyRole(MARKET_PARAMS_SETTER) {
        _lazyUpdateRoundState();
        nextMaxTicketsPerRound = newMax;
        emit MaxTicketsPerRoundQueued(newMax);
    }

    function setTargetTicketsPerRound(uint16 newTarget) external onlyRole(MARKET_PARAMS_SETTER) {
        _lazyUpdateRoundState();
        nextTargetTicketsPerRound = newTarget;
        emit TargetTicketsPerRoundQueued(newTarget);
    }

    function setPricingParams(uint64 newMinimumPrice, uint24 newPriceUpdateFraction)
        external
        onlyRole(MARKET_PARAMS_SETTER)
    {
        _lazyUpdateRoundState();
        nextMinimumPrice = newMinimumPrice;
        nextPriceUpdateFraction = newPriceUpdateFraction;
        emit PricingParamsQueued(newMinimumPrice, newPriceUpdateFraction);
    }

    function setGrandfatherPeriodFraction(uint8 newFraction) external onlyRole(MARKET_PARAMS_SETTER) {
        _lazyUpdateRoundState();
        nextGrandfatherPeriodFraction = newFraction;
        emit GrandfatherPeriodFractionQueued(newFraction);
    }

    function _lazyUpdateRoundState() internal {
        if (roundsElapsedSinceStored() > 0) {
            uint32 newRoundNumber = uint32(roundNumber());
            uint40 newRoundStart = uint40(roundStart());
            uint48 newExcessTicketsSold = uint48(excessTicketsSold());
            uint72 newCurrentPrice = uint72(currentPrice());

            _roundNumber = newRoundNumber;
            _roundStart = newRoundStart;
            _excessTicketsSold = newExcessTicketsSold;
            _currentPrice = newCurrentPrice;

            _storeAdminUpdates();

            emit RoundStateUpdated();
        }
    }

    function _storeAdminUpdates() internal {
        if (nextRoundDuration != 0) {
            _roundDuration = nextRoundDuration;
            nextRoundDuration = 0;
        }
        if (nextTargetTicketsPerRound != 0) {
            _targetTicketsPerRound = nextTargetTicketsPerRound;
            nextTargetTicketsPerRound = 0;
        }
        if (nextMaxTicketsPerRound != 0) {
            _maxTicketsPerRound = nextMaxTicketsPerRound;
            nextMaxTicketsPerRound = 0;
        }
        if (nextMinimumPrice != 0) {
            _minimumPrice = nextMinimumPrice;
            nextMinimumPrice = 0;
        }
        if (nextPriceUpdateFraction != 0) {
            _priceUpdateFraction = nextPriceUpdateFraction;
            nextPriceUpdateFraction = 0;
        }
        if (nextGrandfatherPeriodFraction != 0) {
            _grandfatherPeriodFraction = nextGrandfatherPeriodFraction;
            nextGrandfatherPeriodFraction = 0;
        }
    }

    function _applyAdminUpdate(uint256 currValue, uint256 nextValue) internal view returns (uint256) {
        return roundsElapsedSinceStored() > 0 && nextValue != 0 ? nextValue : currValue;
    }

    /// @notice Approximates `factor * e^(numerator / denominator)` via a Taylor series with
    ///         integer arithmetic.
    /// @dev    Reference: EIP-4844 `fake_exponential` - https://eips.ethereum.org/EIPS/eip-4844
    ///         See also go-ethereum's reference implementation:
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
