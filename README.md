# Feed Ticket Contracts

_This repository is offered under the Apache 2.0 license. See [LICENSE](./LICENSE) for details._

These contracts sell "feed tickets." Feed tickets grant holders access to a premium sequencer feed.

The basic mechanism is as follows:
- Each round, up to some number of tickets are sold all with an equal price. Each round is an hour/day/week/etc.
- The start of each round is a "grandfather phase" of admin-configured length, during which a previous-round ticket holder may purchase up to the number of tickets they held in the previous round; no one else may purchase.
- After the grandfather phase, _anyone_ can purchase a ticket for the rest of the round.
- Once the round ends the newly purchased tickets become "active", while tickets from prior rounds become "inactive" (i.e. the sequencer no longer respects the old tickets and starts respecting the new ones)
- Once the round ends, the next one begins immediately with a new price which is set by an EIP-4844 like mechanism.

Tickets are paid for in a specific ERC-20 token, chosen at deployment time and immutable thereafter. Users first deposit tokens to fund an internal balance held by the contract; each ticket purchase debits the caller's internal balance.

See [ARCHITECTURE.md](./ARCHITECTURE.md) for an overview of the contract's internal structure and the invariants future changes need to respect.

# Actors & Trust Model

- Sequencer
    - The sequencer is trusted to actually serve the priority feed to the correct users
- Market Parameter Setter
    - Can set various market parameters such as max tickets per round, round timing, etc. Changing certain parameters can cause sudden price changes or affect the true value of tickets that have already been purchased.
- Beneficiary
    - The beneficiary is trusted to not sybil the auction. The beneficiary can essentially purchase tickets for free, thereby reducing the real supply and pushing the price up arbitrarily. Funds used to buy tickets can only be reclaimed by the beneficiary after the round ends, so atomically recycling the same money to buy tickets is not possible.
- Proxy Admin
    - Can upgrade the `Tickets` contract arbitrarily. Can steal any sale proceeds that haven't yet been flushed to the beneficiary, as well as any user-deposited token balances that have not yet been spent on a ticket or withdrawn.
- Users
    - Have no special privileges.

# Specification

A single address may buy multiple tickets per round. 1 connection per ticket. 1 API key per ticket. Multiple tickets may have the same API key.

Round state (round number, price, tickets sold, market parameters) is updated lazily on the first mutative call that lands in a new round. View functions roll the stored state forward on the fly so external callers always see the live values. `commitRoundState` is a permissionless entry point that runs the lazy update directly.

Admin setters queue their new values rather than applying them immediately. A value queued in round `R` is committed to storage at the start of the first round strictly after `R` that sees a mutative call. Rounds with no mutative calls are skipped. View functions surface the queued value as soon as one round has elapsed, even before a mutative call commits it; if there is no mutative call in the current round, the contract's own arithmetic still uses the previous stored value, so the view's "as-if-rolled-forward" answer can diverge from the value actually in effect until a mutative call reconciles them.

The mutative calls that _do not_ trigger lazy update are setting the beneficiary, distributing funds, and depositing/withdrawing payment tokens. For beneficiary/distribute this keeps a fund-rescue path live even if a bug in the lazy update would otherwise cause it to revert; for deposit/withdraw the round state is irrelevant to the operation, so we skip the work.

Pricing follows EIP-4844's `fake_exponential`: `currentPrice = min(fake_exponential(minimumPrice, excessTicketsSold, priceUpdateFraction), type(uint72).max)`. `excessTicketsSold` is the running total of tickets sold above `targetTicketsPerRound` across all rounds, floored at zero. The cap (~4722e18) prevents the cached price from overflowing its slot; if the formula would exceed it, tickets are sold at the cap. See the "Base fee per blob gas update rule" in EIP-4844 for guidance on setting `priceUpdateFraction`.

### Admin Roles

`Tickets` has three admin roles:

- `DEFAULT_ADMIN`: Can assign all other roles to accounts
- `BENEFICIARY_SETTER`: Can set the beneficiary account
- `MARKET_PARAMS_SETTER`: Can set parameters of the market (eg minimum price, target ticket count, etc)

`setBeneficiary` takes effect immediately. All `MARKET_PARAMS_SETTER` setters queue their values for the next round as described above.

# How Buyers Use the System

Before a purchase, the buyer ERC-20-approves the `Tickets` contract for the desired amount of the payment token and calls `depositToken(amount)` to move those tokens into an internal balance held by the contract.

Each round, buyers then call `purchaseTickets(expectedRound, expectedPrice, numTicketsDesired, apiKeyHash)`. The contract verifies `expectedRound` and `expectedPrice` against current state (so a buyer never accidentally pays a new round's higher price), fills up to `numTicketsDesired` clamped to the room left in the round, and debits `expectedPrice * (filled count)` from the caller's deposited balance. A buyer near the cap may receive (and pay for) fewer tickets than requested; the call only reverts if the round is already sold out. Any unused balance can be returned to the caller at any time via `withdrawToken`.

The `apiKeyHash` argument is the Keccak-256 hash of the buyer's API key.

Users can use the same API key for multiple purchases. Using the same key for multiple tickets in the same round is permitted.

A reference TypeScript bot lives in [`bot/`](./bot/README.md).

# How the Sequencer Uses the System

The sequencer subscribes to `TicketsPurchased` to reconstruct the list of ticket holders and their key hashes for each round in real time. The event carries both the filled count and the desired count.

When a round ends/advances, the sequencer compares the new list of api keys to the old list of api keys. Any overlap between the previously active keys and currently active keys should not have their websocket connections closed. Keys that were included in the previous set and not in the new set have their connection closed. When a new connection comes in, the provided API key is hashed and checked against the list of currently active key hashes.

The sequencer cannot allow more open connections per key than the number of active tickets bound to that key. If more connections are allowed, then people will share keys.

# Deployment

`script/DeployTickets.s.sol` deploys the `Tickets` contract, configured by environment variables. See [`.env.example`](./.env.example) for the full list and defaults.

```bash
cp .env.example .env  # edit as needed
forge script script/DeployTickets.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
```

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
