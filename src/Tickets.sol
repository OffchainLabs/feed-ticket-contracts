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
    uint96 private __gap1; // puts beneficiary in its own slot

    uint32 public roundDuration; // up to ~136 years
    uint16 public maxTicketsPerRound; // up to 65,535
    uint64 public minimumPrice; // up to 18.4 ether

    // assuming target is 1 and max is 2^16-1, and we want a max change rate of 1% per round (lower change needs larger fraction)
    // then 1.01 = e ^ (A/B), A = 65534, solve for B
    // B = 6.58611×10^6
    // log2(B) = 23
    uint24 public priceUpdateFraction;

    uint32 internal _roundNumber; // if each round is 1 second we get up to ~136 years
    uint40 internal _roundStart; // up to year 2106
    uint48 internal _excessTicketsSold; // we have 48 bits left. if we sell 2^16 above target for 2^32 rounds we get 2^48 excess

    uint16 public targetTicketsPerRound;
    uint32 public nextRoundDuration;
    uint16 public nextTargetTicketsPerRound;
    uint16 public nextMaxTicketsPerRound;
    uint64 public nextMinimumPrice;
    uint24 public nextPriceUpdateFraction;

    mapping(address => mapping(uint256 => bool)) public hasTicket;
    mapping(uint256 => uint256) public ticketsSold;


    constructor() {
        _disableInitializers();
    }

    /// @dev Foundry linter suggests moving the logic into an internal function to save code size.
    ///      https://www.getfoundry.sh/forge/linting/unwrapped-modifier-logic#unwrapped-modifier-logic
    modifier lazyUpdateRoundState() {
        _lazyUpdateRoundState();
        _;
    }

    function initialize(
        address defaultAdmin,
        address beneficiarySetter,
        address marketParamsSetter,
        address _beneficiary,
        uint32 _roundDuration,
        uint16 _targetTicketsPerRound,
        uint16 _maxTicketsPerRound,
        uint64 _minimumPrice,
        uint24 _priceUpdateFraction
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

        _roundStart = uint40(block.timestamp);
    }

    function roundsElapsedSinceStored() public view returns (uint256) {
        return (block.timestamp - _roundStart) / roundDuration;
    }

    function roundNumber() public view returns (uint256) {
        return _roundNumber + roundsElapsedSinceStored();
    }

    function roundStart() public view returns (uint256) {
        return _roundStart + roundsElapsedSinceStored() * roundDuration;
    }

    function roundEnd() external view returns (uint256) {
        return _roundStart + (1 + roundsElapsedSinceStored()) * roundDuration;
    }

    function excessTicketsSold() public view returns (uint256) {
        uint256 elapsed = roundsElapsedSinceStored();
        if (elapsed == 0) return _excessTicketsSold;
        uint256 gross = _excessTicketsSold + ticketsSold[_roundNumber];
        uint256 consumed = elapsed * targetTicketsPerRound;
        return gross > consumed ? gross - consumed : 0;
    }

    function currentPrice() public view returns (uint256) {
        return _fakeExponential(
            minimumPrice,
            excessTicketsSold(),
            priceUpdateFraction
        );
    }

    function purchaseTicket(uint256 expectedRound) external payable lazyUpdateRoundState {
        require(expectedRound == _roundNumber, "Round number mismatch");
        require(msg.value == currentPrice(), "Incorrect ticket price");
        require(ticketsSold[_roundNumber] < maxTicketsPerRound, "Max tickets sold for this round");
        require(!hasTicket[msg.sender][_roundNumber], "Cannot buy two tickets in one round");

        if (_roundNumber > 0 && block.timestamp < _roundStart + roundDuration / 2) {
            require(
                hasTicket[msg.sender][_roundNumber - 1],
                "Must have ticket from previous round to purchase in first half of round"
            );
        }

        ticketsSold[_roundNumber]++;
        hasTicket[msg.sender][_roundNumber] = true;

        emit TicketPurchased(msg.sender, _roundNumber, msg.value);
    }

    function distributeSaleProceeds() external {
        uint256 amount = address(this).balance;
        (bool success,) = beneficiary.call{value: amount}("");
        require(success, "Payment failed");
        emit ProceedsDistributed(beneficiary, amount);
    }

    function setBeneficiary(address newBeneficiary) external onlyRole(BENEFICIARY_SETTER) lazyUpdateRoundState {
        require(newBeneficiary != address(0), "Zero beneficiary");
        beneficiary = newBeneficiary;
        emit BeneficiarySet(newBeneficiary);
    }

    function setRoundDuration(uint32 newDuration) external onlyRole(MARKET_PARAMS_SETTER) lazyUpdateRoundState {
        require(newDuration != 0, "Zero round duration");
        nextRoundDuration = newDuration;
        emit RoundDurationQueued(newDuration);
    }

    function setMaxTicketsPerRound(uint16 newMax) external onlyRole(MARKET_PARAMS_SETTER) lazyUpdateRoundState {
        require(newMax != 0, "Zero max tickets per round");
        nextMaxTicketsPerRound = newMax;
        emit MaxTicketsPerRoundQueued(newMax);
    }

    function setTargetTicketsPerRound(uint16 newTarget) external onlyRole(MARKET_PARAMS_SETTER) lazyUpdateRoundState {
        require(newTarget != 0, "Zero target tickets per round");
        nextTargetTicketsPerRound = newTarget;
        emit TargetTicketsPerRoundQueued(newTarget);
    }

    function setPricingParams(uint64 newMinimumPrice, uint24 newPriceUpdateFraction)
        external
        onlyRole(MARKET_PARAMS_SETTER)
        lazyUpdateRoundState
    {
        require(newMinimumPrice != 0, "Zero minimum price");
        require(newPriceUpdateFraction != 0, "Zero price update fraction");
        nextMinimumPrice = newMinimumPrice;
        nextPriceUpdateFraction = newPriceUpdateFraction;
        emit PricingParamsQueued(newMinimumPrice, newPriceUpdateFraction);
    }

    function _lazyUpdateRoundState() internal {
        if (roundsElapsedSinceStored() > 0) {
            uint32 newRoundNumber = uint32(roundNumber());
            uint40 newRoundStart = uint40(roundStart());
            uint48 newExcessTicketsSold = uint48(excessTicketsSold());
            _roundNumber = newRoundNumber;
            _roundStart = newRoundStart;
            _excessTicketsSold = newExcessTicketsSold;

            _applyAdminUpdates();

            emit RoundStateUpdated(newRoundNumber, newRoundStart, newExcessTicketsSold);
        }
    }

    function _applyAdminUpdates() internal {
        if (nextRoundDuration != 0) {
            roundDuration = nextRoundDuration;
            nextRoundDuration = 0;
        }
        if (nextTargetTicketsPerRound != 0) {
            targetTicketsPerRound = nextTargetTicketsPerRound;
            nextTargetTicketsPerRound = 0;
        }
        if (nextMaxTicketsPerRound != 0) {
            maxTicketsPerRound = nextMaxTicketsPerRound;
            nextMaxTicketsPerRound = 0;
        }
        if (nextMinimumPrice != 0) {
            minimumPrice = nextMinimumPrice;
            nextMinimumPrice = 0;
        }
        if (nextPriceUpdateFraction != 0) {
            priceUpdateFraction = nextPriceUpdateFraction;
            nextPriceUpdateFraction = 0;
        }
    }

    /// @notice Approximates `factor * e^(numerator / denominator)` via a Taylor series with
    ///         integer arithmetic.
    /// @dev    Reference: EIP-4844 `fake_exponential` — https://eips.ethereum.org/EIPS/eip-4844
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
