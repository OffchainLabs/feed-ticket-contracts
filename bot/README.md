# Purchase Bot

TypeScript bot for purchasing feed tickets from the `Tickets` contract.

## Configuration

| Env var | Description |
|---|---|
| `RPC_URL` | JSON-RPC endpoint. |
| `PRIVATE_KEY` | 0x-prefixed 32-byte hex private key. |
| `TICKETS_ADDRESS` | Deployed `Tickets` contract address. |

The bot does not manage its own deposit balance; fund the signer's internal balance out of band via `depositToken` before purchases will succeed.

## Local dev

```
npm install
RPC_URL=... PRIVATE_KEY=0x... TICKETS_ADDRESS=0x... npm run dev
```

## Docker

```
docker build -t purchase-bot .
docker run --rm \
  -e RPC_URL=... \
  -e PRIVATE_KEY=0x... \
  -e TICKETS_ADDRESS=0x... \
  purchase-bot
```
