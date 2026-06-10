# Purchase Bot

TypeScript bot for purchasing feed tickets from the `Tickets` contract. Implements a "buy N tickets up to some max price every round" strategy.

## Algorithm

```
loop forever:
    read price, roundEnd, roundNumber, grandfatherCount, grandfatherPeriodEnd

    if price > MAX_PRICE_PER_TICKET:
        sleep_past(roundEnd)
        continue

    boughtInGrandfather = purchaseWithinGasBudget(
        deadline = grandfatherPeriodEnd,
        toBuy    = min(grandfatherCount, TICKETS_PER_ROUND),
    )

    if boughtInGrandfather >= TICKETS_PER_ROUND:
        sleep_past(roundEnd)
        continue

    sleep_past(grandfatherPeriodEnd)

    purchaseWithinGasBudget(
        deadline = roundEnd,
        toBuy    = TICKETS_PER_ROUND - boughtInGrandfather,
    )

    sleep_past(roundEnd)


function purchaseWithinGasBudget(deadline, toBuy):
    if toBuy <= 0: return 0
    loop:
        if now >= deadline: return 0
        try:
            gas     = estimateGas()
            baseFee = latestBlock.baseFeePerGas
        except revert: # transport errors propagate and crash the process; contract reverts are caught
            return 0   # skip the purchase
        maxFeePerGas = baseFee * (100 + BASE_FEE_BOOST_PERCENT) / 100 + PRIORITY_FEE_PER_GAS
        if gas * maxFeePerGas <= MAX_TRANSACTION_FEE:
            send tx and wait for receipt
            return TicketsPurchased.numTickets from receipt (0 if no event)
        sleep(GAS_POLL_INTERVAL_MS)


function sleep_past(boundarySeconds):
    target = boundarySeconds*1000 + BOUNDARY_BUFFER_MS + random(0, MAX_SCHEDULE_JITTER_MS)
    sleep(max(0, target - now))
```

## Configuration

| Env var                  | Description                                                                                                                        |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| `RPC_URL`                | JSON-RPC endpoint.                                                                                                                 |
| `PRIVATE_KEY`            | 0x-prefixed 32-byte hex private key.                                                                                               |
| `TICKETS_ADDRESS`        | Deployed `Tickets` contract address.                                                                                               |
| `TICKETS_PER_ROUND`      | Number of tickets to buy per round.                                                                                                |
| `MAX_PRICE_PER_TICKET`   | Maximum price per ticket the bot will pay, in wei of the payment token.                                                            |
| `MAX_TRANSACTION_FEE`    | Maximum total transaction fee (gas) the bot will pay per purchase, in wei.                                                         |
| `API_KEY_HASH`           | 0x-prefixed 32-byte hex hash of the API key to bind purchased tickets to.                                                          |
| `MAX_SCHEDULE_JITTER_MS` | Optional. Max scheduling jitter in ms, so bots don't all act at once. Default `30000`.                                             |
| `GAS_POLL_INTERVAL_MS`   | Optional. Poll interval in ms while waiting for gas to drop within a round. Default `10000`.                                       |
| `BOUNDARY_BUFFER_MS`     | Optional. Delay in ms past a round or grandfather-phase boundary before acting, so the chain has advanced past it. Default `2000`. |
| `PRIORITY_FEE_PER_GAS`   | Optional. EIP-1559 priority fee per gas, in wei. Default `0`.                                                                      |
| `BASE_FEE_BOOST_PERCENT` | Optional. Percentage boost applied to the latest block's base fee when computing `maxFeePerGas`. Default `20`.                     |

The bot does not manage its own deposit balance; fund the signer's internal balance out of band via `depositToken` before purchases will succeed.

## Error handling

The bot does not catch transient RPC/network errors: any such failure crashes the whole process, and restarts are expected to be handled at a higher level (e.g. Docker `--restart`, Kubernetes, systemd). A contract revert on a purchase attempt is not an error -- the bot skips that round and continues. It also stops cleanly on SIGINT/SIGTERM.

## Local dev

```
npm install
cp .env.example .env  # then fill it in
npm run dev
```

## Docker

```
docker build -t purchase-bot .
docker run --rm \
  -e RPC_URL=... \
  -e PRIVATE_KEY=0x... \
  -e TICKETS_ADDRESS=0x... \
  -e TICKETS_PER_ROUND=... \
  -e MAX_PRICE_PER_TICKET=... \
  -e MAX_TRANSACTION_FEE=... \
  -e API_KEY_HASH=0x... \
  purchase-bot
```
