import { createPublicClient, getContract, Hex, http } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { Config } from './config.js';
import { ticketsAbi } from './ticketsAbi.js';

export async function run(config: Config, signal?: AbortSignal): Promise<void> {
  const account = privateKeyToAccount(config.privateKey);
  const transport = http(config.rpcUrl, { batch: true });
  const publicClient = createPublicClient({ transport });

  const tickets = getTicketsContract(config.ticketsAddress, publicClient);

  const chainId = await publicClient.getChainId();

  // outer loop processes rounds sequentially, inner loop polls for price and round end, purchasing when conditions are met
  while (true) {
    const [price, roundEnd, roundNumber, grandfatherCount, grandfatherPeriodEnd, nonce] = await Promise.all([
      tickets.read.currentPrice(),
      tickets.read.roundEnd(),
      tickets.read.roundNumber(),
      tickets.read.grandfatherCount([account.address]),
      tickets.read.grandfatherPeriodEnd(),
      publicClient.getTransactionCount({
        address: account.address,
        blockTag: 'pending',
      }),
    ]);

    log({
      event: 'round_start',
      roundNumber,
      roundEnd,
      price,
    });

    // if the price is too high, wait for the next round to start
    if (price > config.maxPricePerTicket) {
      log({
        event: 'price_above_max',
        roundNumber,
        price,
        maxPricePerTicket: config.maxPricePerTicket,
      });
      await wait(calculateWaitTime(roundEnd, config.maxScheduleJitterMs, config.roundEndBufferMs));
      continue;
    }

    // if we are in grandfather period, buy as many tickets as we can up to the grandfather limit
    const { ticketsPurchased } = await handleGrandfatherPeriod();

    // if we bought enough tickets, wait for the next round to start
    if (ticketsPurchased >= config.ticketsPerRound) {
      log({
        event: 'round_filled_during_grandfather',
        roundNumber,
        ticketsPurchased,
      });
      await wait(calculateWaitTime(roundEnd, config.maxScheduleJitterMs, config.roundEndBufferMs));
      continue;
    }

    // if we need to buy more tickets, wait until the grandfather period ends
    log({
      event: 'wait_grandfather_period_end',
      roundNumber,
      grandfatherPeriodEnd,
    });
    await wait(calculateWaitTime(grandfatherPeriodEnd, config.maxScheduleJitterMs, config.roundEndBufferMs));

    // attempt to buy remaining tickets
    await handleOpenPurchaseWindow(config.ticketsPerRound - ticketsPurchased);

    // wait for next round
    log({
      event: 'wait_next_round',
      roundNumber,
      roundEnd,
    });
    await wait(calculateWaitTime(roundEnd, config.maxScheduleJitterMs, config.roundEndBufferMs));
  }
}

async function handleGrandfatherPeriod() {
  return {
    ticketsPurchased: 0,
  };
}

async function handleOpenPurchaseWindow(numTicketsDesired: number) {}

function getTicketsContract(address: Hex, client: ReturnType<typeof createPublicClient>) {
  return getContract({
    address,
    abi: ticketsAbi,
    client,
  });
}

function randomDelay(max: number): number {
  return Math.floor(Math.random() * max);
}

function wait(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function calculateWaitTime(roundEndSeconds: bigint, maxScheduleJitterMs: number, roundEndBufferMs: number): number {
  return roundEndBufferMs + Math.max(0, Number(roundEndSeconds) * 1000 - Date.now() + randomDelay(maxScheduleJitterMs));
}

function log(obj: Record<string, unknown>): void {
  console.log(JSON.stringify({ timestamp: Date.now(), ...obj }, (_, v) => (typeof v === 'bigint' ? v.toString() : v)));
}
