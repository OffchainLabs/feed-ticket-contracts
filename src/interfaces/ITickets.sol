// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

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

    /// @notice Emitted when accumulated sale proceeds are forwarded to the beneficiary.
    /// @param  beneficiary The account that received the proceeds.
    /// @param  amount      The amount forwarded.
    event ProceedsDistributed(address indexed beneficiary, uint256 amount);

    /// @notice Emitted when the beneficiary is updated. Takes effect immediately.
    /// @param  newBeneficiary The new account that will receive sale proceeds.
    event BeneficiarySet(address indexed newBeneficiary);

    /// @notice Emitted when a new round duration is queued. Takes effect next active round.
    /// @param  newDuration The duration of each round.
    event RoundDurationQueued(uint256 newDuration);

    /// @notice Emitted when a new max tickets per round is queued. Takes effect next active round.
    /// @param  newMax The maximum tickets that can be sold per round.
    event MaxTicketsPerRoundQueued(uint256 newMax);

    /// @notice Emitted when a new target tickets per round is queued. Takes effect next active round.
    /// @param  newTarget The targeted number of tickets to sell per round.
    event TargetTicketsPerRoundQueued(uint256 newTarget);

    /// @notice Emitted when new pricing parameters are queued. Takes effect next active round.
    /// @param  newMinimumPrice The minimum ticket price.
    /// @param  newPriceUpdateFraction The price update fraction.
    event PricingParamsQueued(uint256 newMinimumPrice, uint256 newPriceUpdateFraction);

    /// @notice Emitted when stored round state is rolled forward by the lazy update modifier.
    event RoundStateUpdated();

    /// @notice Account that receives ticket sale proceeds.
    function beneficiary() external view returns (address);

    /// @notice Duration of a round, in seconds.
    /// @dev    Assumes at least one ticket will be sold in the current round to apply any queued update.
    ///         If not, the actual value in effect this round remains the previous setting.
    function roundDuration() external view returns (uint256);

    /// @notice Targeted number of tickets to sell per round. Drives the pricing function.
    /// @dev    Assumes at least one ticket will be sold in the current round to apply any queued update.
    ///         If not, the actual value in effect this round remains the previous setting.
    function targetTicketsPerRound() external view returns (uint256);

    /// @notice Hard cap on tickets sold per round.
    /// @dev    Assumes at least one ticket will be sold in the current round to apply any queued update.
    ///         If not, the actual value in effect this round remains the previous setting.
    function maxTicketsPerRound() external view returns (uint256);

    /// @notice Minimum ticket price. Floor of the pricing function.
    /// @dev    Assumes at least one ticket will be sold in the current round to apply any queued update.
    ///         If not, the actual value in effect this round remains the previous setting.
    function minimumPrice() external view returns (uint256);

    /// @notice Parameter controlling how quickly price moves per excess ticket sold.
    /// @dev    Assumes at least one ticket will be sold in the current round to apply any queued update.
    ///         If not, the actual value in effect this round remains the previous setting.
    function priceUpdateFraction() external view returns (uint256);

    /// @notice Queued round duration. Takes effect next active round; zero if none queued.
    function nextRoundDuration() external view returns (uint32);

    /// @notice Queued target tickets per round. Takes effect next active round; zero if none queued.
    function nextTargetTicketsPerRound() external view returns (uint16);

    /// @notice Queued max tickets per round. Takes effect next active round; zero if none queued.
    function nextMaxTicketsPerRound() external view returns (uint16);

    /// @notice Queued minimum price. Takes effect next active round; zero if none queued.
    function nextMinimumPrice() external view returns (uint64);

    /// @notice Queued price update fraction. Takes effect next active round; zero if none queued.
    function nextPriceUpdateFraction() external view returns (uint24);

    /// @notice Whether `user` purchased a ticket in `round`.
    /// @param  user  The account to check.
    /// @param  round The round to check.
    function hasTicket(address user, uint256 round) external view returns (bool);

    /// @notice Number of tickets sold in `round`.
    /// @param  round The round to query.
    function ticketsSold(uint256 round) external view returns (uint256);

    /// @notice Number of full rounds that have elapsed since the stored round start.
    function roundsElapsedSinceStored() external view returns (uint256);

    /// @notice Current round number. Tickets bought in `roundNumber() - 1` are active;
    ///         tickets bought in `roundNumber()` are still being sold.
    function roundNumber() external view returns (uint256);

    /// @notice Start timestamp of the current round (inclusive).
    function roundStart() external view returns (uint256);

    /// @notice End timestamp of the current round (exclusive).
    /// @dev    Assumes at least one ticket will be sold in the current round to apply any queued update.
    ///         If not, the actual value in effect this round remains based on previous settings.
    function roundEnd() external view returns (uint256);

    /// @notice Total tickets sold in excess of the cumulative target as of the end of last round.
    function excessTicketsSold() external view returns (uint256);

    /// @notice Ticket price for the current round, in wei.
    /// @dev    The price is `fake_exponential(minimumPrice, excessTicketsSold(), priceUpdateFraction)`
    ///         (EIP-4844 style), clamped at `type(uint72).max` (~4722 ether). If the formula would
    ///         exceed that cap, this returns `type(uint72).max` and tickets are sold at the cap
    ///         rather than at the higher formula price.
    ///
    ///         Assumes at least one ticket will be sold in the current round to apply any queued update.
    ///         If not, the actual value in effect this round remains based on previous settings.
    function currentPrice() external view returns (uint256);

    /// @notice Purchase one ticket for the current round. Caller must send exactly `currentPrice()` value.
    ///         In the first half of a round, only holders of a ticket from the previous round may purchase.
    /// @param  expectedRound Round the caller expects to be current. Reverts if it does not match.
    function purchaseTicket(uint256 expectedRound) external payable;

    /// @notice Forward all accumulated sale proceeds to the current beneficiary. Permissionless.
    function distributeSaleProceeds() external;

    /// @notice Set the account that receives sale proceeds. Takes effect immediately.
    /// @param  newBeneficiary The new beneficiary.
    function setBeneficiary(address newBeneficiary) external;

    /// @notice Queue a new round duration. Takes effect next active round.
    /// @param  newDuration The new duration of each round.
    function setRoundDuration(uint32 newDuration) external;

    /// @notice Queue a new hard cap on tickets sold per round. Takes effect next active round.
    /// @param  newMax The new max tickets per round.
    function setMaxTicketsPerRound(uint16 newMax) external;

    /// @notice Queue a new target tickets per round. Takes effect next active round.
    /// @param  newTarget The new target tickets per round.
    function setTargetTicketsPerRound(uint16 newTarget) external;

    /// @notice Queue new pricing parameters. Takes effect next active round.
    ///         May cause a discontinuous jump in the current price.
    /// @param  newMinimumPrice        The new minimum ticket price.
    /// @param  newPriceUpdateFraction The new price update fraction.
    function setPricingParams(uint64 newMinimumPrice, uint24 newPriceUpdateFraction) external;
}
