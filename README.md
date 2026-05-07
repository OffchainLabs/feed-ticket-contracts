# Feed Ticket Contracts

These contracts sell "feed tickets." Feed tickets grant holders access to a premium sequencer feed.

The basic mechanism is as follows:
- Each round, up to some number of tickets are sold all with an equal price. Each round is an hour/day/week/etc.
- In the first half of the round, only those who bought tickets in the _previous_ round can purchase tickets.
- In the second half of the round, _anyone_ can purchase a ticket.
- Once the round ends the newly purchased become "active", while tickets from prior rounds become "inactive" (i.e. the sequencer no longer respects the old tickets and starts respecting the new ones)
- Once the round ends, the next one begins immediately with a new price which is set by an EIP-4844 like mechanism. 

# Specification

There are fundamentally three pieces in the onchain system. 

The `TicketWindow` contract sells ticket tokens.

The `Ticket` contract is an ERC-721 representing the tickets themselves.

The `ApiKeyRegistry` contract maps ticket holder accounts to hashes of API keys.

## `TicketWindow`

We update round information lazily on the first state mutating call during the round. We keep this state private since it can be stale. We expose view functions that will apply appropriate changes to stored round information before returning it. It's possible that there are no mutating calls during a round, so we must be able to apply changes caused by multiple dead rounds in constant time.

There's obviously room for optimizations but they're out of scope of the spec.

The `TicketWindow` has the following public state:
- `beneficiary` - account that receives sale proceeds
- `roundDuration` - the duration of a round
- `targetTicketsPerRound` - the targeted number of tickets to sell per round
- `maxTicketsPerRound` - the maximum tickets that can be sold per round
- `minimumPrice` - the minimum ticket price
- `priceUpdateFraction` - a parameter of the pricing function

Private state (updated lazily per round):
- `_roundNumber` - the recorded current round number
- `_roundStart` - start timestamp of the recorded current round (inclusive)
- `_roundEnd` - end timestamp of the recorded current round (exclusive)
- `_excessTicketsSold` - the total "extra" number of tickets that have been sold as of the last stored round relative to the "targeted" number.

In addition to the public state, the `TicketWindow` has the following view functions:
- `roundsMissed()`
    - `return block.timestamp < _roundEnd ? 0 : (block.timestamp - _roundEnd) / roundDuration + 1`
- `roundNumber()`
    - `return _roundNumber + roundsMissed()`
    - tickets belonging to `roundNumber() - 1` are "active" while tickets belonging to `roundNumber()` are currently being sold
- `roundStart()`
    - `return _roundStart + roundsMissed() * roundDuration`
- `roundEnd()`
    - `return _roundEnd + roundsMissed() * roundDuration`
- `excessTicketsSold()` - the total "extra" number of tickets that have been sold as of the last round relative to the "targeted" number.
    - `if (_roundNumber == roundNumber()) return _excessTicketsSold;`
    - `else return max(0, _excessTicketsSold + ticket.totalSupplyInRound(_roundNumber) - roundsMissed() * targetTicketsPerRound)`
- `currentPrice()` - the ticket price for the current round
    - see `fake_exponential` in https://eips.ethereum.org/EIPS/eip-4844
    - `return fake_exponential(minimumPrice, excessTicketsSold(), priceUpdateFraction)`
        - to get an idea of how to set `priceUpdateFraction`, see the "Base fee per blob gas update rule" in EIP-4844

`TicketWindow` has the following mutative functions:

```solidity
function purchaseTicket(uint256 expectedRound) external payable {
    _lazyUpdateRoundState();

    require(expectedRound == _roundNumber, "Round number mismatch");
    require(msg.value == currentPrice(), "Incorrect ticket price");
    require(ticket.totalSupplyForRound(_roundNumber) < maxTicketsPerRound, "Max tickets sold for this round");

    ticket.mintForRound(msg.sender, _roundNumber);
    beneficiary.call{value: msg.value}("");

    emit TicketPurchased(...);
}
```

```solidity
setBeneficiary(...) external onlyOwner lazyUpdateRoundState {...}
setRoundDuration(...) external onlyOwner lazyUpdateRoundState {...}
setTargetTicketsPerRound(...) external onlyOwner lazyUpdateRoundState {...}
setMaxTicketsPerRound(...) external onlyOwner lazyUpdateRoundState {...}
setMinimumPrice(...) external onlyOwner lazyUpdateRoundState {...}
setPriceUpdateFraction(...) external onlyOwner lazyUpdateRoundState {...}
```

Each mutative function uses the following modifier:
```solidity
modifier lazyUpdateRoundState() {
    if (roundsMissed() > 0) {
        uint256 __roundNumber = roundNumber();
        uint256 __roundStart = roundStart();
        uint256 __roundEnd = roundEnd();
        uint256 __excessTicketsSold = excessTicketsSold();
        _roundNumber = __roundNumber;
        _roundStart = __roundStart;
        _roundEnd = __roundEnd;
        _excessTicketsSold = __excessTicketsSold;

        emit RoundStateUpdated(...);
    }
    _;
}
```

## `Ticket`

Note that for simplicity, we could also track _non transferrable_ ticket ownership in the `TicketWindow` contract itself. If we decide to do that then we don't need a separate `Ticket` contract.

We can also merge the `TicketWindow` and `Ticket` contracts so the sale contract is also the ERC-721 contract. This would save a little bit of gas.

## `ApiKeyRegistry`

# How Buyers Use the System

# How the Sequencer Uses the System
