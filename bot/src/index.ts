import { createPublicClient, createWalletClient, getContract, http, type Address, type PublicClient } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { Config, loadConfig } from './config.js';
import { ticketsAbi } from './ticketsAbi.js';

// todo: add env overrides for these parameters

// Used to add some random delay to the bot's actions, to avoid all bots acting at the same time
const RANDOM_DELAY_MAX = 30_000; // 30 seconds

// Inner loop interval when trying to purchase tickets for a round
// Used to wait for gas prices to drop
const LOOP_INTERVAL = 10_000; // 10 seconds

async function main(): Promise<void> {
  run(loadConfig());
}

export async function run(config: Config): Promise<void> {
  const account = privateKeyToAccount(config.privateKey);
  const transport = http(config.rpcUrl);
  const publicClient = createPublicClient({ transport });
  const walletClient = createWalletClient({ account, transport });

  const tickets = getContract({
    address: config.ticketsAddress,
    abi: ticketsAbi,
    client: { public: publicClient, wallet: walletClient },
  });
  
  const processRound = async () => {
    const { price, maxTickets, roundEnd, roundNumber } =
      await fetchRoundState(publicClient, config.ticketsAddress);

    console.log(`Processing round ${roundNumber} ending at ${new Date(Number(roundEnd) * 1000).toISOString()}`);
    
    while (true) {
      // check price, if it's above maxPricePerTicket, break
      if (price > config.maxPricePerTicket) {
        console.log(`Price ${price} is above maxPricePerTicket ${config.maxPricePerTicket}, skipping round`);
        break;
      }

      // if round is over, break
      if (Date.now() >= Number(roundEnd) * 1000) {
        console.log('Round ended without purchasing tickets, skipping round');
        break;
      }

      // if max tickets have been purchased, break
      if (await tickets.read.ticketsSoldThisRound() >= maxTickets) {
        console.log(`Max tickets purchased, skipping round`);
        break;
      }

      // estimate transaction fee, if it's below maxTransactionFee, purchase tickets and break
      // TODO

      await wait(LOOP_INTERVAL);
    }

    
    setTimeout(processRound, timeout(roundEnd));
  }

  setTimeout(processRound, timeout(await tickets.read.roundEnd()));
}

async function fetchRoundState(client: PublicClient, address: Address) {
  const [price, maxTickets, roundEnd, roundNumber] = await client.multicall({
    contracts: [
      { address, abi: ticketsAbi, functionName: 'currentPrice' },
      { address, abi: ticketsAbi, functionName: 'maxTicketsPerRound' },
      { address, abi: ticketsAbi, functionName: 'roundEnd' },
      { address, abi: ticketsAbi, functionName: 'roundNumber' },
    ],
    allowFailure: false,
  });
  return { price, maxTickets, roundEnd, roundNumber };
}

function randomDelay(): number {
  return Math.floor(Math.random() * RANDOM_DELAY_MAX);
}

function wait(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function timeout(roundEndSeconds: bigint): number {
  return Math.max(0, Number(roundEndSeconds) * 1000 - Date.now() + randomDelay());
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
