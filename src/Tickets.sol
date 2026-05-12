// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {ITickets} from "./ITickets.sol";

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
        uint40 priceUpdateFraction;
        uint8 grandfatherPeriodFraction;
        uint40 firstRoundStart;
    }

    /// @notice Role that can set the beneficiary account.
    bytes32 public constant BENEFICIARY_SETTER = keccak256("BENEFICIARY_SETTER");
    /// @notice Role that can queue updates to market parameters.
    bytes32 public constant MARKET_PARAMS_SETTER = keccak256("MARKET_PARAMS_SETTER");

    /// @dev Sentinel for "no grandfather fraction queued". Inverted from the other queued params
    ///      (which use 0) because 0 is a valid grandfather fraction (no grandfather phase).
    uint8 constant GRANDFATHER_PERIOD_SENTINEL = type(uint8).max;

    // ----- Begin Slot 0 ----- //

    // -- Begin Hot Path Storage (Accessed Every Purchase) -- //

    /// @dev uint24 seconds - up to ~194 days.
    uint24 internal _roundDuration;

    /// @dev uint16 - up to 65,535.
    uint16 internal _maxTicketsPerRound;

    /// @dev uint72 - up to ~4700 ether.
    ///      Caching price is cheaper than recomputing via Taylor series on each purchase.
    uint72 internal _currentPrice;

    /// @dev uint40 - at 1-second rounds, supports up to ~34,865 years
    uint40 internal _roundNumber;

    /// @dev uint40 seconds - Unix timestamps to year ~36800.
    uint40 internal _roundStart;

    /// @dev uint8 - length of the grandfather phase as a fraction of 256 of the round.
    ///      e.g. 128 = first half of the round.
    uint8 internal _grandfatherPeriodFraction;

    // -- End Hot Path Storage -- //

    /// @dev uint40 - at target of 1, max of 2^16, the lowest max change we can support is
    ///      e^((2^16 - 2) / (2^40 - 1)) = 1.00000006
    uint40 internal _priceUpdateFraction;

    /// @dev Type matches maxTicketsPerRound.
    uint16 internal _targetTicketsPerRound;

    // ------ End Slot 0 ------ //
    // ----- Begin Slot 1 ----- //

    /// @dev uint64 wei - up to ~18.4 ether.
    uint64 internal _minimumPrice;

    /// @dev uint56 - Up to 2^16 excess/round (uint16 cap) * 2^40 rounds (uint40 _roundNumber)
    ///      = 2^56 worst-case excess.
    uint56 internal _excessTicketsSold;

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
    /// @dev Type matches priceUpdateFraction.
    uint40 public nextPriceUpdateFraction;

    /// @inheritdoc ITickets
    /// @dev Type matches grandfatherPeriodFraction.
    uint8 public nextGrandfatherPeriodFraction;

    // ------ End Slot 1 ------ //

    /// @inheritdoc ITickets
    /// @dev Type matches minimumPrice.
    uint64 public nextMinimumPrice;

    /// @inheritdoc ITickets
    /// @dev Type matches excessTicketsSold.
    uint56 public excessTicketsSoldOverride;

    /// @inheritdoc ITickets
    address public beneficiary;

    /// @inheritdoc ITickets
    mapping(address => uint256) public grandfatheredIntoRound;

    /// @inheritdoc ITickets
    mapping(uint256 => uint256) public ticketsSold;

    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata p) external initializer {
        require(p.roundDuration > 0, "Round duration must be greater than zero");
        require(p.targetTicketsPerRound > 0, "Target tickets per round must be greater than zero");
        require(p.maxTicketsPerRound > 0, "Max tickets per round must be greater than zero");
        require(p.minimumPrice > 0, "Minimum price must be greater than zero");
        require(p.priceUpdateFraction > 0, "Price update fraction must be greater than zero");
        require(
            p.grandfatherPeriodFraction != GRANDFATHER_PERIOD_SENTINEL,
            "Grandfather period fraction cannot be type(uint8).max"
        );
        // forge-lint: disable-next-line(block-timestamp)
        require(p.firstRoundStart > block.timestamp, "First round start must be in the future");

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

        nextGrandfatherPeriodFraction = GRANDFATHER_PERIOD_SENTINEL;
    }

    /// @dev Grants the three admin roles. Called once from `initialize`.
    function _initRoles(address defaultAdmin, address beneficiarySetter, address marketParamsSetter) internal {
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(BENEFICIARY_SETTER, beneficiarySetter);
        _grantRole(MARKET_PARAMS_SETTER, marketParamsSetter);
    }

    /// @inheritdoc ITickets
    function purchaseTicket(uint256 expectedRound) external payable {
        _lazyUpdateRoundState();
        require(expectedRound == _roundNumber, "Round number mismatch");
        require(msg.value == _currentPrice, "Incorrect ticket price");
        require(ticketsSold[_roundNumber] < _maxTicketsPerRound, "Max tickets sold for this round");
        require(grandfatheredIntoRound[msg.sender] != uint256(_roundNumber) + 1, "Cannot buy two tickets in one round");

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
        grandfatheredIntoRound[msg.sender] = uint256(_roundNumber) + 1;

        emit TicketPurchased(msg.sender, _roundNumber, msg.value);
    }

    /// @inheritdoc ITickets
    function distributeSaleProceeds() external {
        uint256 amount = address(this).balance;
        (bool success,) = beneficiary.call{value: amount}("");
        require(success, "Payment failed");
        emit ProceedsDistributed(beneficiary, amount);
    }

    /// @inheritdoc ITickets
    function roundsElapsedSinceStored() public view returns (uint256) {
        // forge-lint: disable-next-line(block-timestamp)
        require(block.timestamp >= _roundStart, "Current time is before first round start");
        return (block.timestamp - uint256(_roundStart)) / uint256(_roundDuration);
    }

    /// @inheritdoc ITickets
    function roundNumber() public view returns (uint256) {
        return uint256(_roundNumber) + roundsElapsedSinceStored();
    }

    /// @inheritdoc ITickets
    function roundStart() public view returns (uint256) {
        return uint256(_roundStart) + roundsElapsedSinceStored() * uint256(_roundDuration);
    }

    /// @inheritdoc ITickets
    function roundEnd() external view returns (uint256) {
        return roundStart() + roundDuration();
    }

    /// @inheritdoc ITickets
    function grandfatherPeriodEnd() external view returns (uint256) {
        return roundStart() + (roundDuration() * grandfatherPeriodFraction()) / 256;
    }

    /// @inheritdoc ITickets
    function roundDuration() public view returns (uint256) {
        return _applyAdminUpdate(_roundDuration, nextRoundDuration, 0);
    }

    /// @inheritdoc ITickets
    function maxTicketsPerRound() external view returns (uint256) {
        return _applyAdminUpdate(_maxTicketsPerRound, nextMaxTicketsPerRound, 0);
    }

    /// @inheritdoc ITickets
    function minimumPrice() public view returns (uint256) {
        // since nextPriceUpdateFraction and nextMinimumPrice are set together,
        // we only check the sentinel for nextPriceUpdateFraction to save gas.
        return _applyAdminUpdate(_minimumPrice, nextPriceUpdateFraction != 0 ? nextMinimumPrice : 0, 0);
    }

    /// @inheritdoc ITickets
    function targetTicketsPerRound() external view returns (uint256) {
        return _applyAdminUpdate(_targetTicketsPerRound, nextTargetTicketsPerRound, 0);
    }

    /// @inheritdoc ITickets
    function priceUpdateFraction() public view returns (uint256) {
        return _applyAdminUpdate(_priceUpdateFraction, nextPriceUpdateFraction, 0);
    }

    /// @inheritdoc ITickets
    function grandfatherPeriodFraction() public view returns (uint256) {
        return _applyAdminUpdate(_grandfatherPeriodFraction, nextGrandfatherPeriodFraction, GRANDFATHER_PERIOD_SENTINEL);
    }

    /// @inheritdoc ITickets
    function excessTicketsSold() public view returns (uint256) {
        uint256 elapsed = roundsElapsedSinceStored();
        if (elapsed == 0) return _excessTicketsSold;

        // since nextPriceUpdateFraction and excessTicketsSoldOverride are set together, we only check the sentinel
        // for nextPriceUpdateFraction to save gas. If nextPriceUpdateFraction != 0, an admin has queued a pricing update
        if (nextPriceUpdateFraction != 0) return excessTicketsSoldOverride;

        uint256 gross = uint256(_excessTicketsSold) + ticketsSold[_roundNumber];
        uint256 consumed = elapsed * uint256(_targetTicketsPerRound);
        return gross > consumed ? gross - consumed : 0;
    }

    /// @inheritdoc ITickets
    function currentPrice() public view returns (uint256) {
        uint256 result = _fakeExponential(minimumPrice(), excessTicketsSold(), priceUpdateFraction());
        // forge-lint: disable-next-line(unsafe-typecast)
        return result > type(uint72).max ? type(uint72).max : uint72(result);
    }

    /// @inheritdoc ITickets
    function setBeneficiary(address newBeneficiary) external onlyRole(BENEFICIARY_SETTER) {
        beneficiary = newBeneficiary;
        emit BeneficiarySet(newBeneficiary);
    }

    /// @inheritdoc ITickets
    function setRoundDuration(uint24 newDuration) external onlyRole(MARKET_PARAMS_SETTER) {
        require(newDuration > 0, "Round duration must be greater than zero");
        _lazyUpdateRoundState();
        nextRoundDuration = newDuration;
        emit RoundDurationQueued(newDuration);
    }

    /// @inheritdoc ITickets
    function setMaxTicketsPerRound(uint16 newMax) external onlyRole(MARKET_PARAMS_SETTER) {
        require(newMax > 0, "Max tickets per round must be greater than zero");
        _lazyUpdateRoundState();
        nextMaxTicketsPerRound = newMax;
        emit MaxTicketsPerRoundQueued(newMax);
    }

    /// @inheritdoc ITickets
    function setTargetTicketsPerRound(uint16 newTarget) external onlyRole(MARKET_PARAMS_SETTER) {
        require(newTarget > 0, "Target tickets per round must be greater than zero");
        _lazyUpdateRoundState();
        nextTargetTicketsPerRound = newTarget;
        emit TargetTicketsPerRoundQueued(newTarget);
    }

    /// @inheritdoc ITickets
    /// @dev The three parameters MUST be queued and committed as a coupled triple:
    ///      `nextMinimumPrice`, `nextPriceUpdateFraction`, and `excessTicketsSoldOverride`
    ///      are always set together here and reset together on commit. The `minimumPrice()`
    ///      view, the `excessTicketsSold()` view, and the storage-commit path all treat
    ///      `nextPriceUpdateFraction != 0` as the single "pricing update queued" sentinel
    ///      (saving slot reads of `nextMinimumPrice` and `excessTicketsSoldOverride`).
    function setPricingParams(
        uint64 newMinimumPrice,
        uint40 newPriceUpdateFraction,
        uint56 newExcessTicketsSoldOverride
    ) external onlyRole(MARKET_PARAMS_SETTER) {
        require(newMinimumPrice > 0, "Minimum price must be greater than zero");
        require(newPriceUpdateFraction > 0, "Price update fraction must be greater than zero");
        _lazyUpdateRoundState();
        nextMinimumPrice = newMinimumPrice;
        nextPriceUpdateFraction = newPriceUpdateFraction;
        excessTicketsSoldOverride = newExcessTicketsSoldOverride;
        emit PricingParamsQueued(newMinimumPrice, newPriceUpdateFraction, newExcessTicketsSoldOverride);
    }

    /// @inheritdoc ITickets
    function setGrandfatherPeriodFraction(uint8 newFraction) external onlyRole(MARKET_PARAMS_SETTER) {
        require(newFraction != GRANDFATHER_PERIOD_SENTINEL, "Grandfather period fraction cannot be type(uint8).max");
        _lazyUpdateRoundState();
        nextGrandfatherPeriodFraction = newFraction;
        emit GrandfatherPeriodFractionQueued(newFraction);
    }

    /// @dev On the first mutative call of a new round, rolls stored round state forward and
    ///      commits any queued admin updates. No-op within the same round.
    function _lazyUpdateRoundState() internal {
        if (roundsElapsedSinceStored() > 0) {
            uint40 newRoundNumber = uint40(roundNumber());
            uint40 newRoundStart = uint40(roundStart());
            uint56 newExcessTicketsSold = uint56(excessTicketsSold());
            uint72 newCurrentPrice = uint72(currentPrice());

            _roundNumber = newRoundNumber;
            _roundStart = newRoundStart;
            _excessTicketsSold = newExcessTicketsSold;
            _currentPrice = newCurrentPrice;

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
            if (nextGrandfatherPeriodFraction != GRANDFATHER_PERIOD_SENTINEL) {
                _grandfatherPeriodFraction = nextGrandfatherPeriodFraction;
                nextGrandfatherPeriodFraction = GRANDFATHER_PERIOD_SENTINEL;
            }
            // nextPriceUpdateFraction and nextMinimumPrice are set together,
            // so we only check sentinel for nextPriceUpdateFraction to save gas.
            if (nextPriceUpdateFraction != 0) {
                _priceUpdateFraction = nextPriceUpdateFraction;
                _minimumPrice = nextMinimumPrice;
                nextPriceUpdateFraction = 0;
                nextMinimumPrice = 0;

                // excessTicketsSoldOverride is applied in excessTicketsSold(), which has already been called
                excessTicketsSoldOverride = 0;
            }

            emit RoundStateUpdated();
        }
    }

    /// @dev View-side queued-update helper
    function _applyAdminUpdate(uint256 currValue, uint256 nextValue, uint256 sentinelValue)
        internal
        view
        returns (uint256)
    {
        return roundsElapsedSinceStored() > 0 && nextValue != sentinelValue ? nextValue : currValue;
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
