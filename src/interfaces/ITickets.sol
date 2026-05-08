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

    /// @notice Account that receives ticket sale proceeds.
    function beneficiary() external view returns (address);

    /// @notice Duration of a round, in seconds.
    function roundDuration() external view returns (uint256);

    /// @notice Queued round duration. Takes effect next active round; zero if none queued.
    function nextRoundDuration() external view returns (uint256);

    /// @notice Targeted number of tickets to sell per round. Drives the pricing function.
    function targetTicketsPerRound() external view returns (uint256);

    /// @notice Queued target tickets per round. Takes effect next active round; zero if none queued.
    function nextTargetTicketsPerRound() external view returns (uint256);

    /// @notice Hard cap on tickets sold per round.
    function maxTicketsPerRound() external view returns (uint256);

    /// @notice Queued max tickets per round. Takes effect next active round; zero if none queued.
    function nextMaxTicketsPerRound() external view returns (uint256);

    /// @notice Minimum ticket price. Floor of the pricing function.
    function minimumPrice() external view returns (uint256);

    /// @notice Queued minimum price. Takes effect next active round; zero if none queued.
    function nextMinimumPrice() external view returns (uint256);

    /// @notice Parameter controlling how quickly price moves per excess ticket sold.
    function priceUpdateFraction() external view returns (uint256);

    /// @notice Queued price update fraction. Takes effect next active round; zero if none queued.
    function nextPriceUpdateFraction() external view returns (uint256);

    /// @notice Whether `user` purchased a ticket in `round`.
    /// @param  user  The account to check.
    /// @param  round The round to check.
    function hasTicket(address user, uint256 round) external view returns (bool);

    /// @notice Number of tickets sold in `round`.
    /// @param  round The round to query.
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
