# Purchase Bot

TypeScript bot for purchasing feed tickets from the `Tickets` contract. Implements a "buy N tickets up to some max price every round" strategy.

## Configuration

| Env var                  | Description                                                                                                                         |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| `RPC_URL`                | JSON-RPC endpoint.                                                                                                                  |
| `PRIVATE_KEY`            | 0x-prefixed 32-byte hex private key.                                                                                                |
| `TICKETS_ADDRESS`        | Deployed `Tickets` contract address.                                                                                                |
| `TICKETS_PER_ROUND`      | Number of tickets to buy per round.                                                                                                 |
| `MAX_PRICE_PER_TICKET`   | Maximum price per ticket the bot will pay, in wei of the payment token.                                                             |
| `MAX_TRANSACTION_FEE`    | Maximum total transaction fee (gas) the bot will pay per purchase, in wei.                                                          |
| `API_KEY_HASH`           | 0x-prefixed 32-byte hex hash of the API key to bind purchased tickets to.                                                           |
| `MAX_SCHEDULE_JITTER_MS` | Optional. Max scheduling jitter in ms, so bots don't all act at once. Default `30000`.                                              |
| `GAS_POLL_INTERVAL_MS`   | Optional. Poll interval in ms while waiting for gas to drop within a round. Default `10000`.                                        |
| `ROUND_END_BUFFER_MS`    | Optional. Delay in ms past round end before processing the next round, so the chain has advanced past the boundary. Default `2000`. |

The bot does not manage its own deposit balance; fund the signer's internal balance out of band via `depositToken` before purchases will succeed.

## Error handling

The bot does not catch transient RPC/network errors: any such failure crashes the whole process, and restarts are expected to be handled at a higher level (e.g. Docker `--restart`, Kubernetes, systemd). A contract revert on a purchase attempt is not an error -- the bot skips that round and continues. It also stops cleanly on SIGINT/SIGTERM.

## Local dev

```
npm install
RPC_URL=... PRIVATE_KEY=0x... TICKETS_ADDRESS=0x... TICKETS_PER_ROUND=... MAX_PRICE_PER_TICKET=... MAX_TRANSACTION_FEE=... API_KEY_HASH=0x... npm run dev
```

## Docker

The image build runs `tsc` only; it does not regenerate the ABI (no Foundry in the image). Generate it on the host first:

```
npm run abigen
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
