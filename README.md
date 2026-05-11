# Feed Ticket Contracts

These contracts sell "feed tickets." Feed tickets grant holders access to a premium sequencer feed.

The basic mechanism is as follows:
- Each round, up to some number of tickets are sold all with an equal price. Each round is an hour/day/week/etc.
- The start of each round is a "grandfather phase" of admin-configured length, during which only those who bought tickets in the _previous_ round can purchase tickets.
- After the grandfather phase, _anyone_ can purchase a ticket for the rest of the round.
- Once the round ends the newly purchased tickets become "active", while tickets from prior rounds become "inactive" (i.e. the sequencer no longer respects the old tickets and starts respecting the new ones)
- Once the round ends, the next one begins immediately with a new price which is set by an EIP-4844 like mechanism. 

# Actors & Trust Model

- Sequencer
    - The sequencer is trusted to actually serve the priority feed to the correct users
- Market Parameter Setter
    - Can set various market parameters such as max tickets per round, round timing, etc. Changing certain parameters can cause sudden price changes or affect the true value of tickets that have already been purchased.
- Beneficiary
    - The beneficiary is trusted to not sybil the auction. The beneficiary can purchase tickets for free, thereby reducing the real supply and pushing the price up arbitrarily (even to the point of DoS).
- Proxy Admin
    - Can upgrade the `Tickets` contract arbitrarily. Can steal any sale proceeds that haven't yet been flushed to the beneficiary.
- Users
    - Have no special privileges. Are allowed and expected to sybil for multiple tickets.

# Specification

There are fundamentally two pieces in the onchain system. 

The `Tickets` contract sells and tracks tickets.

The `ApiKeyRegistry` contract maps ticket holder accounts to hashes of API keys.

## `Tickets`

Limit 1 ticket per address per round. If users want multiple tickets they must sybil.

We update round information lazily on the first mutative call during the round. We keep this state private since it can be stale. We expose view functions that will apply appropriate changes to stored round information before returning it.

Admin setters queue their new values rather than applying them immediately. Queued values are applied by the round's lazy-update. Concretely, a value queued in round `R` is committed to storage at the start of the first round strictly after `R` that sees a mutative call. Rounds with no mutative calls are skipped. The queued value keeps waiting in `next*` storage until activity resumes.

The view functions for the queued admin params surface the queued value as soon as one round has elapsed (even before a mutative call has committed it to storage). However, if there is no mutative call in the current round, the contract's own arithmetic still uses the previous stored value, so the view's "as-if-rolled-forward" answer can diverge from the value actually in effect until a mutative call reconciles them.

The only mutative calls that _do not_ trigger lazy update are setting the beneficiary and distributing funds. This keeps a fund-rescue path live even if a bug in the lazy update would otherwise cause it to revert.

`Tickets` has the following public state:
- `beneficiary` - account that receives sale proceeds
- `nextRoundDuration` - if set, upcoming rounds will use this duration
- `nextTargetTicketsPerRound` - if set, upcoming rounds will use it
- `nextMaxTicketsPerRound` - if set, upcoming rounds will use it
- `nextMinimumPrice` - if set, upcoming rounds will use it
- `nextPriceUpdateFraction` - if set, upcoming rounds will use it
- `nextGrandfatherPeriodFraction` - if set, upcoming rounds will use it
- `grandfatheredIntoRound` - maps user => the round into which they are grandfathered (i.e. the round in which they may purchase during the grandfather phase). Concretely, after a user purchases a ticket in round `R`, this is set to `R + 1`. Returns 0 if the user has never purchased; the +1 encoding lets us distinguish "never bought" from "bought in round 0".
- `ticketsSold` - maps roundnum => numtickets

Private state (committed lazily on the first mutative call in a new round):
- `_roundNumber` - the recorded current round number
- `_roundStart` - start timestamp of the recorded current round (inclusive)
- `_excessTicketsSold` - the total "extra" number of tickets that have been sold as of the last stored round relative to the "targeted" number
- `_currentPrice` - the cached price for the recorded current round (avoids recomputing the Taylor series on each purchase)
- `_roundDuration` - the stored round duration; replaced by `nextRoundDuration` when the queued update is committed
- `_targetTicketsPerRound` - the stored target; replaced by `nextTargetTicketsPerRound` when committed
- `_maxTicketsPerRound` - the stored cap; replaced by `nextMaxTicketsPerRound` when committed
- `_minimumPrice` - the stored minimum price; replaced by `nextMinimumPrice` when committed
- `_priceUpdateFraction` - the stored pricing fraction; replaced by `nextPriceUpdateFraction` when committed
- `_grandfatherPeriodFraction` - the stored grandfather phase length, as a numerator over 256 of the round duration (e.g. `128` = half-round). Replaced by `nextGrandfatherPeriodFraction` when committed

In addition to the public state, `Tickets` has the following view functions:
- `roundDuration()` - the duration of a round
    - `return roundsElapsedSinceStored() > 0 && nextRoundDuration != 0 ? nextRoundDuration : _roundDuration`
- `targetTicketsPerRound()` - the targeted number of tickets to sell per round
    - same queued-update shape as `roundDuration()`
- `maxTicketsPerRound()` - the maximum tickets that can be sold per round
    - same queued-update shape as `roundDuration()`
- `minimumPrice()` - the minimum ticket price
    - same queued-update shape as `roundDuration()`
- `priceUpdateFraction()` - a parameter of the pricing function
    - same queued-update shape as `roundDuration()`
- `grandfatherPeriodFraction()` - length of the grandfather phase as a numerator over 256 of the round
    - same queued-update shape as `roundDuration()`
- `roundsElapsedSinceStored()`
    - reverts if `block.timestamp < _roundStart` (i.e. the first round has not yet started)
    - `return (block.timestamp - _roundStart) / _roundDuration`
    - uses the stored `_roundDuration`, not the queued-update-aware view, so rounds keep ticking on the previously stored cadence until a mutative call commits a queued duration
- `roundNumber()`
    - `return _roundNumber + roundsElapsedSinceStored()`
    - tickets belonging to `roundNumber() - 1` are "active" while tickets belonging to `roundNumber()` are currently being sold
- `roundStart()` - start timestamp of the current round (inclusive)
    - `return _roundStart + roundsElapsedSinceStored() * _roundDuration`
- `roundEnd()` - end timestamp of the current round (exclusive)
    - `return roundStart() + roundDuration()`
- `grandfatherPeriodEnd()` - end timestamp of the current round's grandfather phase (exclusive). Before this time, only previous-round ticket holders may purchase.
    - `return roundStart() + (roundDuration() * grandfatherPeriodFraction()) / 256`
- `excessTicketsSold()` - the total "extra" number of tickets that have been sold as of the last round relative to the "targeted" number.
    - `if (_roundNumber == roundNumber()) return _excessTicketsSold;`
    - `else return max(0, _excessTicketsSold + ticketsSold[_roundNumber] - roundsElapsedSinceStored() * _targetTicketsPerRound)`
    - max(0, ...) underflows in solidity. code's for illustration
- `currentPrice()` - the ticket price (in wei) for the current round
    - see `fake_exponential` in https://eips.ethereum.org/EIPS/eip-4844
    - `return min(fake_exponential(minimumPrice(), excessTicketsSold(), priceUpdateFraction()), type(uint72).max)`
        - the price is stored as `uint72` and clamped at `type(uint72).max` (~4722 ether). If the formula would exceed that cap, tickets are sold at the cap rather than at the higher formula price.
        - to get an idea of how to set `priceUpdateFraction`, see the "Base fee per blob gas update rule" in EIP-4844

`Tickets` has the following mutative functions:

```solidity
function purchaseTicket(uint256 expectedRound) external payable {
    _lazyUpdateRoundState();
    require(expectedRound == _roundNumber, "Round number mismatch");
    require(msg.value == _currentPrice, "Incorrect ticket price");
    require(ticketsSold[_roundNumber] < _maxTicketsPerRound, "Max tickets sold for this round");
    require(grandfatheredIntoRound[msg.sender] != _roundNumber + 1, "Cannot buy two tickets in one round");

    if (_roundNumber > 0 && block.timestamp < _roundStart + (_roundDuration * _grandfatherPeriodFraction) / 256) {
        require(grandfatheredIntoRound[msg.sender] == _roundNumber, "Must have ticket from previous round to purchase during grandfather phase");
    }

    ticketsSold[_roundNumber]++;
    grandfatheredIntoRound[msg.sender] = _roundNumber + 1;

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
setBeneficiary(address newBeneficiary) external onlyRole(BENEFICIARY_SETTER) {
    beneficiary = newBeneficiary;
    emit BeneficiarySet(...);
}

// Queued; committed by the first mutative call in a later round
setRoundDuration(uint24 newDuration) external onlyRole(MARKET_PARAMS_SETTER) {
    _lazyUpdateRoundState();
    nextRoundDuration = newDuration;
    emit RoundDurationQueued(...);
}

// Queued; committed by the first mutative call in a later round
setMaxTicketsPerRound(uint16 newMax) external onlyRole(MARKET_PARAMS_SETTER) {...}

// Queued; committed by the first mutative call in a later round
setTargetTicketsPerRound(uint16 newTarget) external onlyRole(MARKET_PARAMS_SETTER) {...}

// Queued; committed by the first mutative call in a later round
// Note that updates affecting pricing might make price jump suddenly
setPricingParams(
    uint64 newMinimumPrice,
    uint24 newPriceUpdateFraction
) external onlyRole(MARKET_PARAMS_SETTER) {...}

// Queued; committed by the first mutative call in a later round
// `newFraction` is a numerator over 256 of the round duration. Note that 0 is treated
// as "no update queued" by the lazy-update machinery, so once the grandfather phase
// is set to a nonzero value it cannot be returned to zero via the setter; use a small
// nonzero value (e.g. 1) to make the phase effectively negligible.
setGrandfatherPeriodFraction(uint8 newFraction) external onlyRole(MARKET_PARAMS_SETTER) {...}
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
    mapping(address => bytes32) public getKeyHash;

    event KeyHashUpdated(address indexed user, bytes32 newKeyHash);

    function registerKeyHash(bytes32 newKeyHash) external {
        getKeyHash[msg.sender] = newKeyHash;
        emit KeyHashUpdated(msg.sender, newKeyHash);
    }

    function getMultipleKeyHashes(address[] calldata accounts) external view returns (bytes32[] memory hashes) {
        hashes = new bytes32[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            hashes[i] = getKeyHash[accounts[i]];
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

To make the price continuous across a pricing-param update, recompute `E` during lazy update (at the moment the new params are applied) so that

```
M' · e^(E'/F') = M · e^(E/F)
```

Solving for `E'`:

```
E' = F' · ln(M/M') + E · F'/F
```

At the moment, we've deemed discontinuous jumps acceptable.

## ERC-20 as Currency

Currently we use ETH, we might want to use ERC-20.
