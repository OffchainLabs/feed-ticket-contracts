// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// @title  Tickets
/// @notice Sells and tracks feed tickets that grant holders access to a premium sequencer feed.
///         Up to a configurable cap of tickets are sold each round at a single price set by an
///         EIP-4844 style update rule. In the first half of a round only previous round ticket
///         holders may purchase; in the second half anyone may purchase. Tickets become active
///         once the round in which they were purchased ends.
interface ITickets {
    /// @notice Emitted when a ticket is purchased.
    /// @param  buyer The account that purchased the ticket.
    /// @param  round The round the ticket was purchased in.
    /// @param  price The price paid for the ticket.
    event TicketPurchased(address indexed buyer, uint256 indexed round, uint256 price);

    /// @notice Emitted when the beneficiary is updated. Takes effect immediately.
    /// @param  newBeneficiary The new account that will receive sale proceeds.
    event BeneficiarySet(address indexed newBeneficiary);

    /// @notice Emitted when a new round duration is queued. Takes effect next active round.
    /// @param  newDuration The duration of each round.
    event RoundDurationSet(uint256 newDuration);

    /// @notice Emitted when a new max tickets per round is queued. Takes effect next active round.
    /// @param  newMax The maximum tickets that can be sold per round.
    event MaxTicketsPerRoundSet(uint256 newMax);

    /// @notice Emitted when a new target tickets per round is queued. Takes effect next active round.
    /// @param  newTarget The targeted number of tickets to sell per round.
    event TargetTicketsPerRoundSet(uint256 newTarget);

    /// @notice Emitted when new pricing parameters are queued. Takes effect next active round.
    /// @param  newMinimumPrice The minimum ticket price.
    /// @param  newPriceUpdateFraction The price update fraction.
    event PricingParamsSet(uint256 newMinimumPrice, uint256 newPriceUpdateFraction);

    /// @notice Emitted when stored round state is rolled forward by the lazy update modifier.
    /// @param  roundNumber The newly stored current round number.
    /// @param  roundStart The start timestamp of the newly stored current round (inclusive).
    /// @param  excessTicketsSold The total tickets sold in excess of the target as of the new round.
    event RoundStateUpdated(uint256 indexed roundNumber, uint256 roundStart, uint256 excessTicketsSold);

    function beneficiary() external view returns (address);
    function roundDuration() external view returns (uint256);
    function nextRoundDuration() external view returns (uint256);
    function targetTicketsPerRound() external view returns (uint256);
    function nextTargetTicketsPerRound() external view returns (uint256);
    function maxTicketsPerRound() external view returns (uint256);
    function nextMaxTicketsPerRound() external view returns (uint256);
    function minimumPrice() external view returns (uint256);
    function nextMinimumPrice() external view returns (uint256);
    function priceUpdateFraction() external view returns (uint256);
    function nextPriceUpdateFraction() external view returns (uint256);
    function hasTicket(address user, uint256 round) external view returns (bool);
    function ticketsSold(uint256 round) external view returns (uint256);

    function roundsElapsedSinceStored() external view returns (uint256);
    function roundNumber() external view returns (uint256);
    function roundStart() external view returns (uint256);
    function roundEnd() external view returns (uint256);
    function excessTicketsSold() external view returns (uint256);
    function currentPrice() external view returns (uint256);

    function purchaseTicket(uint256 expectedRound) external payable;
    function setBeneficiary(address newBeneficiary) external;
    function setRoundDuration(uint256 newDuration) external;
    function setMaxTicketsPerRound(uint256 newMax) external;
    function setTargetTicketsPerRound(uint256 newTarget) external;
    function setPricingParams(uint256 newMinimumPrice, uint256 newPriceUpdateFraction) external;
}
