# Feed Ticket Contracts

These contracts sell "feed tickets." Feed tickets grant holders access to a premium sequencer feed.

The basic mechanism is as follows:
- Each round, up to some number of tickets are sold all with an equal price. Each round is an hour/day/week/etc.
- The start of each round is a "grandfather phase" of admin-configured length, during which only those who bought tickets in the _previous_ round can purchase tickets.
- After the grandfather phase, _anyone_ can purchase a ticket for the rest of the round.
- Once the round ends the newly purchased tickets become "active", while tickets from prior rounds become "inactive" (i.e. the sequencer no longer respects the old tickets and starts respecting the new ones)
- Once the round ends, the next one begins immediately with a new price which is set by an EIP-4844 like mechanism. 

Tickets are paid for in a specific ERC-20 token, chosen at deployment time and immutable thereafter. Users first deposit tokens to fund an internal balance held by the contract; each ticket purchase debits the caller's internal balance.

# Actors & Trust Model

- Sequencer
    - The sequencer is trusted to actually serve the priority feed to the correct users
- Market Parameter Setter
    - Can set various market parameters such as max tickets per round, round timing, etc. Changing certain parameters can cause sudden price changes or affect the true value of tickets that have already been purchased.
- Beneficiary
    - The beneficiary is trusted to not sybil the auction. The beneficiary can purchase tickets for free, thereby reducing the real supply and pushing the price up arbitrarily (even to the point of DoS).
- Proxy Admin
    - Can upgrade the `Tickets` contract arbitrarily. Can steal any sale proceeds that haven't yet been flushed to the beneficiary, as well as any user-deposited token balances that have not yet been spent on a ticket or withdrawn.
- Users
    - Have no special privileges. Are allowed and expected to sybil for multiple tickets.

# Specification

1 ticket per address per round. 1 connection per ticket. 1 API key per ticket. Multiple tickets may have the same API key.

We update round information lazily on the first mutative call during the round. We keep this state private since it can be stale. We expose view functions that will apply appropriate changes to stored round information before returning it.

Admin setters queue their new values rather than applying them immediately. Queued values are applied by the round's lazy-update. Concretely, a value queued in round `R` is committed to storage at the start of the first round strictly after `R` that sees a mutative call. Rounds with no mutative calls are skipped. The queued value keeps waiting in `next*` storage until activity resumes.

The view functions for the queued admin params surface the queued value as soon as one round has elapsed (even before a mutative call has committed it to storage). However, if there is no mutative call in the current round, the contract's own arithmetic still uses the previous stored value, so the view's "as-if-rolled-forward" answer can diverge from the value actually in effect until a mutative call reconciles them.

The mutative calls that _do not_ trigger lazy update are setting the beneficiary, distributing funds, and depositing/withdrawing payment tokens. For beneficiary/distribute this keeps a fund-rescue path live even if a bug in the lazy update would otherwise cause it to revert; for deposit/withdraw the round state is irrelevant to the operation, so we skip the work.

`Tickets` has the following public state:
- `beneficiary` - account that receives sale proceeds
- `token` - the ERC-20 used as payment. Immutable, set at construction.
- `isAdminUpdateQueued` - true if any of the `next*` fields (or `excessTicketsSoldOverride`) below holds a queued update that has not yet been committed by lazy update.
- `nextRoundDuration` - if set, upcoming rounds will use this duration
- `nextTargetTicketsPerRound` - if set, upcoming rounds will use it
- `nextMaxTicketsPerRound` - if set, upcoming rounds will use it
- `nextMinimumPrice` - if set, upcoming rounds will use it
- `nextPriceUpdateFraction` - if set, upcoming rounds will use it
- `nextGrandfatherPeriodFraction` - if set, upcoming rounds will use it
- `excessTicketsSoldOverride` - queued override for `excessTicketsSold()`
- `grandfatheredIntoRound(user)` - the round into which `user` is grandfathered (i.e. the round in which they may purchase during the grandfather phase). Concretely, after a user purchases a ticket in round `R`, this is set to `R + 1`. Returns 0 if the user has never purchased; the +1 encoding lets us distinguish "never bought" from "bought in round 0".
- `tokenBalance(account)` - `account`'s internal payment-token balance, available to be spent on ticket purchases or returned via `withdrawToken`. Credited by `depositToken`, debited by `purchaseTicket`/`withdrawToken`. Packed alongside `grandfatheredIntoRound` in a per-account `UserData` struct.

Private state (committed lazily on the first mutative call in a new round):
- `_roundNumber` - the recorded current round number
- `_roundStart` - start timestamp of the recorded current round (inclusive)
- `_excessTicketsSold` - the total "extra" number of tickets that have been sold as of the last stored round relative to the "targeted" number
- `_currentPrice` - the cached price for the recorded current round (avoids recomputing the Taylor series on each purchase)
- `_ticketsSoldThisRound` - the number of tickets sold in the recorded current round. Incremented on each purchase and reset to 0 by lazy update at the start of a new round
- `_roundDuration` - the stored round duration; replaced by `nextRoundDuration` when the queued update is committed
- `_targetTicketsPerRound` - the stored target; replaced by `nextTargetTicketsPerRound` when committed
- `_maxTicketsPerRound` - the stored cap; replaced by `nextMaxTicketsPerRound` when committed
- `_minimumPrice` - the stored minimum price; replaced by `nextMinimumPrice` when committed
- `_priceUpdateFraction` - the stored pricing fraction; replaced by `nextPriceUpdateFraction` when committed
- `_grandfatherPeriodFraction` - the stored grandfather phase length, as a numerator over 256 of the round duration (e.g. `128` = half-round). Replaced by `nextGrandfatherPeriodFraction` when committed
- `_storedProceeds` - accumulated payment-token proceeds from rounds prior to the last lazy update, minus distributions already made. Incremented by `_ticketsSoldThisRound * _currentPrice` during lazy update at round rollover, drained to zero by `distributeSaleProceeds`

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
- `ticketsSoldThisRound()` - the number of tickets sold in the current round.
    - `return roundsElapsedSinceStored() == 0 ? _ticketsSoldThisRound : 0`
    - returns 0 once the round has advanced beyond the stored round, since the next mutative call will reset the counter to 0 before recording any new purchase
- `excessTicketsSold()` - the total "extra" number of tickets that have been sold as of the last round relative to the "targeted" number.
    - `if (_roundNumber == roundNumber()) return _excessTicketsSold;`
    - `else if (isAdminUpdateQueued && excessTicketsSoldOverride != type(uint56).max) return excessTicketsSoldOverride;`
    - `else return max(0, _excessTicketsSold + _ticketsSoldThisRound - roundsElapsedSinceStored() * _targetTicketsPerRound)`
    - max(0, ...) underflows in solidity. code's for illustration
- `currentPrice()` - the ticket price (in base units of the payment token) for the current round
    - see `fake_exponential` in https://eips.ethereum.org/EIPS/eip-4844
    - `return min(fake_exponential(minimumPrice(), excessTicketsSold(), priceUpdateFraction()), type(uint72).max)`
        - the price is stored as `uint72` and clamped at `type(uint72).max` (~4.72e21 base units). If the formula would exceed that cap, tickets are sold at the cap rather than at the higher formula price.
        - to get an idea of how to set `priceUpdateFraction`, see the "Base fee per blob gas update rule" in EIP-4844

`Tickets` has the following mutative functions:

```solidity
function purchaseTicket(uint256 expectedRound, uint256 expectedPrice, bytes32 apiKeyHash) external {
    _lazyUpdateRoundState();
    if (expectedRound != _roundNumber) revert RoundNumberMismatch(expectedRound, _roundNumber);
    if (expectedPrice != _currentPrice) revert IncorrectTicketPrice(expectedPrice, _currentPrice);
    if (_ticketsSoldThisRound >= _maxTicketsPerRound) revert MaxTicketsSold();
    if (_userData[msg.sender].grandfatheredRound == _roundNumber + 1) revert AlreadyPurchasedInRound();
    if (_userData[msg.sender].tokenBalance < expectedPrice) revert InsufficientTokenBalance(...);

    if (_roundNumber > 0 && block.timestamp < _roundStart + (_roundDuration * _grandfatherPeriodFraction) / 256) {
        if (_userData[msg.sender].grandfatheredRound != _roundNumber) revert NotGrandfathered();
    }

    _ticketsSoldThisRound++;
    _userData[msg.sender].grandfatheredRound = _roundNumber + 1;
    _userData[msg.sender].tokenBalance -= uint216(expectedPrice);

    emit TicketPurchased(msg.sender, _roundNumber, apiKeyHash, expectedPrice);
}
```

The caller declares the price they expect via `expectedPrice`; the contract verifies it equals `currentPrice()` and debits that amount from the caller's deposited token balance.

```solidity
function depositToken(uint256 amount) external {
    _userData[msg.sender].tokenBalance += uint216(amount);
    IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    emit TokensDeposited(msg.sender, amount);
}

function withdrawToken(uint256 amount) external {
    if (_userData[msg.sender].tokenBalance < amount) revert InsufficientTokenBalance(...);
    _userData[msg.sender].tokenBalance -= uint216(amount);
    IERC20(token).safeTransfer(msg.sender, amount);
    emit TokensWithdrawn(msg.sender, amount);
}
```

```solidity
function distributeSaleProceeds() external {
    uint256 amount = _storedProceeds;
    _storedProceeds = 0;
    IERC20(token).safeTransfer(beneficiary, amount);
    emit ProceedsDistributed(beneficiary, amount);
}
```

`distributeSaleProceeds` only forwards proceeds that lazy update has already credited to `_storedProceeds`. Revenue from the current round is included once the round ends and the next lazy update commits it.

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
// Updates affecting pricing make the price jump suddenly. newExcessTicketsSoldOverride is provided to minimize jumps
setPricingParams(
    uint64 newMinimumPrice,
    uint40 newPriceUpdateFraction,
    uint56 newExcessTicketsSoldOverride
) external onlyRole(MARKET_PARAMS_SETTER) {...}

// Queued; committed by the first mutative call in a later round
// `newFraction` is a numerator over 256 of the round duration. Unlike the other queued
// params, the "no update queued" sentinel is `type(uint8).max` (255) rather than 0, so
// 0 is a valid value (disables the grandfather phase entirely). Passing 255 reverts.
setGrandfatherPeriodFraction(uint8 newFraction) external onlyRole(MARKET_PARAMS_SETTER) {...}
```

### Admin Roles

`Tickets` has three admin roles:

- `DEFAULT_ADMIN`: Can assign all other roles to accounts
- `BENEFICIARY_SETTER`: Can set the beneficiary account
- `MARKET_PARAMS_SETTER`: Can set parameters of the market (eg minimum price, target ticket count, etc)

### Optimized Data Sizes

Hot path state lives in slot 0 and a common-case purchase only loads that slot. Slot 1 holds colder state read during round rollover. Slots 2 and above hold other information that is only occasionally accessed during round rollover due to an admin configuration change.

Slot 0:
- `_roundDuration` (uint24 seconds): up to ~194 days per round
- `_maxTicketsPerRound` (uint16): up to 65,535 tickets per round
- `_currentPrice` (uint72): cached so we don't recompute the Taylor series on each purchase; capped at ~4.72e21 base units of the payment token
- `_roundNumber` (uint40): at 1-second rounds, well past uint32's ~136-year limit
- `_roundStart` (uint40 seconds): Unix timestamps past year 36800
- `_grandfatherPeriodFraction` (uint8): numerator over 256 of the round duration
- `_ticketsSoldThisRound` (uint16): matches `_maxTicketsPerRound`'s range
- `_priceUpdateFraction` (uint40): 23 bits cover a 1% max change at target=1, max=65535; widened to uint40 to fill slot 0

Slot 1:
- `_minimumPrice` (uint64): up to ~1.84e19 base units of the payment token
- `_targetTicketsPerRound` (uint16): matches `_maxTicketsPerRound`'s range
- `_excessTicketsSold` (uint56): worst case is uint16 cap per round * uint40 rounds = 2^56
- `isAdminUpdateQueued` (bool)
- `_storedProceeds` (uint112): accumulated proceeds awaiting distribution; sized to fill the remainder of slot 1

Slots 2+:
- `nextRoundDuration` (uint24), `nextTargetTicketsPerRound` (uint16), `nextMaxTicketsPerRound` (uint16), `nextPriceUpdateFraction` (uint40), `nextGrandfatherPeriodFraction` (uint8)
- `nextMinimumPrice` (uint64), `excessTicketsSoldOverride` (uint56)
- `beneficiary` (address): account that receives sale proceeds
- `_userData` mapping of `address => UserData`, where `UserData` packs `grandfatheredRound` (uint40) and `tokenBalance` (uint216) into a single 32-byte slot per account.

# How Buyers Use the System

Before a purchase, the buyer ERC-20-approves the `Tickets` contract for the desired amount of the payment token and calls `depositToken(amount)` to move those tokens into an internal balance held by the contract.

Each round, buyers then call `purchaseTicket(expectedRound, expectedPrice, apiKeyHash)`. The contract verifies `expectedRound` and `expectedPrice` against current state (so a buyer never accidentally pays a new round's higher price) and debits `expectedPrice` from the caller's deposited balance. Any unused balance can be returned to the caller at any time via `withdrawToken`.

Users can use the same API key for multiple purchases. Using the same key to purchase two tickets in the same round is permitted.

# How the Sequencer Uses the System

The sequencer subscribes to `TicketPurchased` to reconstruct the list of ticket holders and their key hashes for each round in real time.

When a round ends/advances, the sequencer compares the new list of api keys to the old list of api keys. Any overlap between the previously active keys and currently active keys should not have their websocket connections closed. Keys that were included in the previous set and not in the new set have their connection closed. When a new connection comes in, the provided API key is hashed and checked against the list of currently active key hashes.

The sequencer cannot allow more open connections per key than the number of active tickets bound to that key. If more connections are allowed, then people will share keys.

# Potential Improvements

## Continuous Pricing Across Param Updates

The price is `currentPrice = fake_exponential(M, E, F) ~= M * e^(E/F)` where `M = minimumPrice`, `E = excessTicketsSold`, `F = priceUpdateFraction`. By default, changing `nextMinimumPrice` / `nextPriceUpdateFraction` causes the price to jump discontinuously.

To make the price continuous across a pricing-param update, recompute `E` during lazy update (at the moment the new params are applied) so that

```
M' * e^(E'/F') = M * e^(E/F)
```

Solving for `E'`:

```
E' = F' * ln(M/M') + E * F'/F
```

At the moment, we've deemed discontinuous jumps acceptable.

## Multiple tickets per address
