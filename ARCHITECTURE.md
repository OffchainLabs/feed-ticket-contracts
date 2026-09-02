# Architecture

This doc complements README.md. README covers what the contract does; this covers how it's structured and what you have to keep in mind when changing it.

## Lazy round state

Storage variables (`_roundNumber`, `_roundStart`, `_currentPrice`, `_excessTicketsSold`, `_ticketsSoldThisRound`, and the pricing/market params) reflect **the last round in which a mutative call ran**, not necessarily the current wall-clock round. View functions roll state forward on the fly using `roundsElapsedSinceStored()`; the first mutative call of a new round commits the roll-forward to storage via `_lazyUpdateRoundState`.

Each mutative entry point either calls `_lazyUpdateRoundState` first or deliberately skips it:

**`purchaseTickets`** calls lazy update because every check it performs is round-relative: `expectedRound` matches against `_roundNumber`, `expectedPrice` matches against `_currentPrice`, and the max-tickets check uses `_ticketsSoldThisRound`. All of those need to reflect the current wall-clock round before the comparison runs.

**`commitRoundState`** is the lazy update — its only job is to expose the roll-forward as a permissionless entry point so anyone can force it without also doing a mutating action.

**`MARKET_PARAMS_SETTER` setters** (`setRoundDuration`, `setMaxTicketsPerRound`, `setTargetTicketsPerRound`, `setPricingParams`, `setGrandfatherPeriodFraction`) call lazy update first so the queued value takes effect at the *next* round boundary, not the current one.

**`setBeneficiary`** skips lazy update because it touches no round-dependent state, and we want beneficiary rotation to remain available even if lazy update is bricked.

**`depositToken` / `withdrawToken`** skip lazy update because their semantics (moving payment tokens between the caller and the internal balance) are round-independent. Skipping also means users can always recover their deposits even if lazy update is bricked.

**`distributeSaleProceeds`** skips lazy update so the fund-flush path stays live even if lazy update is bricked. The trade-off is that the in-flight round's revenue isn't included in the flush; an operator who wants to include it should call `commitRoundState` first.

## Queued admin updates

`MARKET_PARAMS_SETTER` setters write a `next*` slot and set `isAdminUpdateQueued = true`; `_lazyUpdateRoundState` commits the queued values and clears the queue on the next round boundary.

View functions surface the queued value as soon as one round has elapsed since the stored round. Internal arithmetic still uses the stored value until the lazy update lands. This means a queued admin update followed by one or more inactive rounds can cause inconsistency/inaccuracy in some view functions.

`excessTicketsSoldOverride` is special: `_lazyUpdateRoundState` does not assign it to `_excessTicketsSold` explicitly. Instead, the lazy update calls `excessTicketsSold()`, which returns the override if one is queued; that return value is then written to `_excessTicketsSold`. The override slot is reset to the sentinel as a separate step. Any future override mechanism needs to preserve this view-driven application.

## Round skip on duration reduction

Reducing `roundDuration` can cause the lazy update to commit a round to storage that is immediately behind the value reported by `roundNumber()`. A purchase call binds to the round it commits to storage, which may already be over on the wall clock.

With `T` = call timestamp, `S` = stored `_roundStart`, `D_old` = stored `_roundDuration` (the value being replaced), and `D_new` = queued duration, the call binds to

```
R_committed = _roundNumber + floor((T - S) / D_old)
```

but leaves the contract reporting

```
R_committed + floor(((T - S) mod D_old) / D_new)
```

A user whose purchase commits round R but rolls the contract forward to round R+2 will have purchased a ticket that immediately becomes invalid to the sequencer.

Since this requires purchase inactivity and is avoidable by manually triggering a lazy update, this is left alone as a known issue.

## Grandfathered holders excluded after max ticket update

If `maxTicketsPerRound` is reduced below the number of tickets sold in the previous round, then the slowest of those holders will lose their right to purchase in the current round.  

## Pricing

`currentPrice() = min(fake_exponential(minimumPrice(), excessTicketsSold(), priceUpdateFraction()), type(uint72).max)`

- `_currentPrice` is cached so purchases don't recompute the Taylor series every call.
- `excessTicketsSold` accumulates across rounds: each round adds `_ticketsSoldThisRound`, then subtracts `_targetTicketsPerRound * elapsed`, floored at zero.

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

## Per-user state (parity-keyed)

```
struct UserData {
    uint16 evenTicketsHeld;
    uint16 oddTicketsHeld;
    uint40 lastEvenRoundPurchased;
    uint40 lastOddRoundPurchased;
    uint144 tokenBalance;
}
```

During round R the contract reads the user's prior-round count from the **opposite-parity** slot (which still holds round R-1's value) while writing round R's purchases to the **same-parity** slot. "Did this user buy in round X" is encoded as `lastXRoundPurchased == X`; the helper `_ticketCount(user, X)` returns the slot value only if that equality holds, otherwise 0.

Writing round R overwrites the value from round R-2 in the same-parity slot. That's fine: by round R, round R-2's tickets are inactive and have no further use.

## Type widths and casting

Storage vars are packed into tight widths. Math runs in `uint256`; results are cast back.

## Storage layout

Two packed slots, sized tightly:

- **Slot 0** (hot, read every purchase): `_roundDuration`, `_maxTicketsPerRound`, `_currentPrice`, `_roundNumber`, `_roundStart`, `_grandfatherPeriodFraction`, `_ticketsSoldThisRound`, `_priceUpdateFraction`.
- **Slot 1** (warm, read on round change): `_minimumPrice`, `_targetTicketsPerRound`, `_excessTicketsSold`, `isAdminUpdateQueued`, `_storedProceeds`.

## Proceeds accounting

`_storedProceeds` accumulates revenue from rounds **before** the last lazy update. The in-flight round's revenue is implicit in `_ticketsSoldThisRound * _currentPrice` until `_lazyUpdateRoundState` runs and rolls it into `_storedProceeds`. Because `distributeSaleProceeds` bypasses lazy update, it only forwards what's already been rolled in; call `commitRoundState` first to flush the current round.
