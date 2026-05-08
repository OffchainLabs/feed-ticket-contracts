# Feed Ticket Contracts

These contracts sell "feed tickets." Feed tickets grant holders access to a premium sequencer feed.

The basic mechanism is as follows:
- Each round, up to some number of tickets are sold all with an equal price. Each round is an hour/day/week/etc.
- In the first half of the round, only those who bought tickets in the _previous_ round can purchase tickets.
- In the second half of the round, _anyone_ can purchase a ticket.
- Once the round ends the newly purchased tickets become "active", while tickets from prior rounds become "inactive" (i.e. the sequencer no longer respects the old tickets and starts respecting the new ones)
- Once the round ends, the next one begins immediately with a new price which is set by an EIP-4844 like mechanism. 

# Specification

There are fundamentally two pieces in the onchain system. 

The `Tickets` contract sells and tracks tickets.

The `ApiKeyRegistry` contract maps ticket holder accounts to hashes of API keys.

## `Tickets`

Limit 1 ticket per customer per round.

Admin setters are queued and applied in a future round. Specifically, updates are applied the round after the next round with activity.

We update round information lazily on the first state mutating call during the round. We keep this state private since it can be stale. We expose view functions that will apply appropriate changes to stored round information before returning it. It's possible that there are no mutating calls during a round, so we must be able to apply changes caused by multiple dead rounds in constant time.

`Tickets` has the following public state:
- `beneficiary` - account that receives sale proceeds
- `roundDuration` - the duration of a round
- `nextRoundDuration` - if set, upcoming rounds will use this duration
- `targetTicketsPerRound` - the targeted number of tickets to sell per round
- `nextTargetTicketsPerRound` - if set, upcoming rounds will use it
- `maxTicketsPerRound` - the maximum tickets that can be sold per round
- `nextMaxTicketsPerRound` - if set, upcoming rounds will use it
- `minimumPrice` - the minimum ticket price
- `nextMinimumPrice` - if set, upcoming rounds will use it
- `priceUpdateFraction` - a parameter of the pricing function
- `nextPriceUpdateFraction` - if set, upcoming rounds will use it
- `hasTicket` - maps user => roundnum => bool
- `ticketsSold` - maps roundnum => numtickets

Private state (updated lazily per round):
- `_roundNumber` - the recorded current round number
- `_roundStart` - start timestamp of the recorded current round (inclusive)
    - initialized to `block.timestamp`
- `_excessTicketsSold` - the total "extra" number of tickets that have been sold as of the last stored round relative to the "targeted" number.

In addition to the public state, `Tickets` has the following view functions:
- `roundsElapsedSinceStored()`
    - `return (block.timestamp - _roundStart) / roundDuration`
- `roundNumber()`
    - `return _roundNumber + roundsElapsedSinceStored()`
    - tickets belonging to `roundNumber() - 1` are "active" while tickets belonging to `roundNumber()` are currently being sold
- `roundStart()` - start timestamp of the current round (inclusive)
    - `return _roundStart + roundsElapsedSinceStored() * roundDuration`
- `roundEnd()` - end timestamp of the current round (exclusive)
    - `return _roundStart + (1 + roundsElapsedSinceStored()) * roundDuration`
- `excessTicketsSold()` - the total "extra" number of tickets that have been sold as of the last round relative to the "targeted" number.
    - `if (_roundNumber == roundNumber()) return _excessTicketsSold;`
    - `else return max(0, _excessTicketsSold + ticketsSold[_roundNumber] - roundsElapsedSinceStored() * targetTicketsPerRound)`
    - max(0, ...) underflows in solidity. code's for illustration
- `currentPrice()` - the ticket price for the current round
    - see `fake_exponential` in https://eips.ethereum.org/EIPS/eip-4844
    - `return fake_exponential(minimumPrice, excessTicketsSold(), priceUpdateFraction)`
        - to get an idea of how to set `priceUpdateFraction`, see the "Base fee per blob gas update rule" in EIP-4844

`Tickets` has the following mutative functions:

```solidity
function purchaseTicket(uint256 expectedRound) external payable lazyUpdateRoundState {
    require(expectedRound == _roundNumber, "Round number mismatch");
    require(msg.value == currentPrice(), "Incorrect ticket price");
    require(ticketsSold[_roundNumber] < maxTicketsPerRound, "Max tickets sold for this round");
    require(!hasTicket[msg.sender][_roundNumber], "Cannot buy two tickets in one round");

    uint256 midTime = _roundStart + roundDuration / 2;
    if (block.timestamp < midTime && _roundNumber > 0) {
        require(hasTicket[msg.sender][_roundNumber - 1], "Must have ticket from previous round to purchase in first half of round");
    }

    ticketsSold[_roundNumber]++;
    hasTicket[msg.sender][_roundNumber] = true;

    emit TicketPurchased(...);
}
```

```solidity
function distributeSaleProceeds() external {
    (bool success,) = beneficiary.call{value: address(this).balance}("");
    require(success, "Payment failed");
    emit ProceedsDistributed(...);
}
```

```solidity
// Takes effect immediately
setBeneficiary(address newBeneficiary) external onlyRole(BENEFICIARY_SETTER) lazyUpdateRoundState {
    require(newBeneficiary != address(0), "Zero beneficiary");
    beneficiary = newBeneficiary;
    emit BeneficiarySet(...);
}

// Takes effect next round
setRoundDuration(uint256 newDuration) external onlyRole(MARKET_PARAMS_SETTER) lazyUpdateRoundState {
    require(newDuration != 0, "Zero round duration");
    nextRoundDuration = newDuration;
    emit RoundDurationQueued(...);
}

// Takes effect next round
setMaxTicketsPerRound(uint256 newMax) external onlyRole(MARKET_PARAMS_SETTER) lazyUpdateRoundState {
    require(newMax != 0, "Zero max tickets per round");
    nextMaxTicketsPerRound = newMax;
    emit MaxTicketsPerRoundQueued(...);
}

// Takes effect next round
setTargetTicketsPerRound(uint256 newTarget) external onlyRole(MARKET_PARAMS_SETTER) lazyUpdateRoundState {
    require(newTarget != 0, "Zero target tickets per round");
    nextTargetTicketsPerRound = newTarget;
    emit TargetTicketsPerRoundQueued(...);
}

// Takes effect next round
// Note that updates affecting pricing might make price jump suddenly
setPricingParams(
    uint256 newMinimumPrice,
    uint256 newPriceUpdateFraction
) external onlyRole(MARKET_PARAMS_SETTER) lazyUpdateRoundState {
    require(newMinimumPrice != 0, "Zero minimum price");
    require(newPriceUpdateFraction != 0, "Zero price update fraction");
    nextMinimumPrice = newMinimumPrice;
    nextPriceUpdateFraction = newPriceUpdateFraction;
    emit PricingParamsQueued(...);
}
```

Each mutative function uses the following modifier:
```solidity
modifier lazyUpdateRoundState() {
    if (roundsElapsedSinceStored() > 0) {
        uint256 __roundNumber = roundNumber();
        uint256 __roundStart = roundStart();
        uint256 __excessTicketsSold = excessTicketsSold();
        _roundNumber = __roundNumber;
        _roundStart = __roundStart;
        _excessTicketsSold = __excessTicketsSold;

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

        emit RoundStateUpdated(...);
    }
    _;
}
```

### Admin Roles

`Tickets` has three admin roles:

- `DEFAULT_ADMIN`: Can assign all other roles to accounts
- `BENEFICIARY_SETTER`: Can set the beneficiary account
- `MARKET_PARAMS_SETTER`: Can set parameters of the market (eg minimum price, target ticket count, etc)

## `ApiKeyRegistry`

The `ApiKeyRegistry` simply maps user accounts to hashes of user generated API keys that will be used to authenticate with the sequencer.

```solidity
contract ApiKeyRegistry {
    mapping(address => bytes32) public keyHash;

    event KeyHashUpdated(address indexed user, bytes32 newKeyHash);

    function registerKeyHash(bytes32 newKeyHash) external {
        keyHash[msg.sender] = newKeyHash;
        emit KeyHashUpdated(msg.sender, newKeyHash);
    }

    function getMultipleKeyHashes(address[] calldata accounts) external view returns (bytes32[] memory hashes) {
        hashes = new bytes32[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            hashes[i] = keyHash[accounts[i]];
        }
    }
}
```

# How Buyers Use the System

1. [One time] Generate an API key and record its hash in the `ApiKeyRegistry` using the account that will purchase tickets
1. [Each Round] Purchase tickets through the `Tickets` contract

Buyers can choose to use a smart contract to do both steps to avoid having a pile of money sitting on a hot EOA.

# How the Sequencer Uses the System

The sequencer subscribes to `TicketPurchased` to reconstruct the list of ticket holders for each round in real time.

When a round ends/advances, the sequencer takes the full list of ticket holders for the newly active round and queries the `ApiKeyRegistry` to get key hashes. Any overlap between the previously active ticket holder set and currently active ticket holder set should not have their websocket connections closed. Everyone who was in the previous set and not in the new set has their connection closed. When a new connection comes in, the provided API key is hashed and checked against the list of currently active key hashes.

The sequencer will also have to subscribe to `KeyHashUpdated` events to keep the list of active key hashes up to date. Active ticket holders may rotate keys mid round. If there is an open connection using a key that has just been overwritten in the contract, it should be dropped.

The sequencer cannot allow more than one open connection per ticket holder. If more than one connection is allowed then people will share tickets.

# Secondary Markets

Despite tickets being non-transferrable, a secondary market can still be built. It could look something like a bunch of vault contracts (one per ticket). Users would purchase tickets _through_ the vault contracts, which would then each purchase a ticket. Ownership of these vaults grants owners the ability to interact with the `ApiKeyRegistry` _through_ the vault, and ownership _could_ be transferrable.

# Potential Improvements

## Continuous Pricing Across Param Updates

The price is `currentPrice = fake_exponential(M, E, F) ≈ M · e^(E/F)` where `M = minimumPrice`, `E = excessTicketsSold`, `F = priceUpdateFraction`. As written, changing `nextMinimumPrice` / `nextPriceUpdateFraction` causes the price to jump discontinuously.

To make the price continuous across a pricing-param update, recompute `E` in `lazyUpdateRoundState` (at the moment the new params are applied) so that

```
M' · e^(E'/F') = M · e^(E/F)
```

Solving for `E'`:

```
E' = F' · ln(M/M') + E · F'/F
```

## Configurable Grandfather Phase

The mechanism assumes that in the first half of the round, only previous round ticket holders can purchase new tickets. We may want to make this configurable instead of fixed at half.

## Timelocked Admin

We should consider putting the admin behind a timelock to boost confidence in the market rules not changing unpredictably. I would imagine we want this contract to have a similar setup to the ELA where the DAO controls the proxy and OCL controls a few select levers.

## First round start in the future

Currently, the first round starts immediately when the tickets contract is deployed. We may want to be able to specify a future time
