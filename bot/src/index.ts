import { createPublicClient, createWalletClient, getContract, http, parseEventLogs, type Address, type PublicClient } from 'viem';
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
    const { price, roundEnd, roundNumber } =
      await fetchRoundState(publicClient, config.ticketsAddress);

    log({ event: 'round_start', roundNumber, roundEnd: roundEnd.toString(), price: price.toString() });
    
    while (true) {
      // check price, if it's above maxPricePerTicket, break
      if (price > config.maxPricePerTicket) {
        log({ event: 'skip', reason: 'price_above_max', price: price.toString(), maxPricePerTicket: config.maxPricePerTicket.toString() });
        break;
      }

      // if round is over, break
      if (Date.now() >= Number(roundEnd) * 1000) {
        log({ event: 'skip', reason: 'round_ended', roundEnd: roundEnd.toString() });
        break;
      }

      // estimate transaction fee, if it's below maxTransactionFee, purchase tickets and break (even if we revert we break)
      const { request } = await tickets.simulate.purchaseTickets([roundNumber, price, BigInt(config.ticketsPerRound), config.apiKeyHash]);
      if (!request.gas || !request.maxFeePerGas) {
        log({ event: 'skip', reason: 'gas_estimation_failed' });
        break;
      }
      if (request.gas * request.maxFeePerGas <= config.maxTransactionFee) {
        log({ event: 'purchase_attempt', gas: request.gas.toString(), maxFeePerGas: request.maxFeePerGas.toString(), maxTransactionFee: config.maxTransactionFee.toString() });
        const hash = await walletClient.writeContract(request);
        log({ event: 'transaction_sent', hash });
        const receipt = await publicClient.waitForTransactionReceipt({ hash });

        const txFee = receipt.gasUsed * receipt.effectiveGasPrice;
        const [purchase] = parseEventLogs({ abi: ticketsAbi, eventName: 'TicketsPurchased', logs: receipt.logs });
        if (purchase) {
          const { numTickets, price: ticketPrice } = purchase.args;
          log({ event: 'purchase_success', hash, numTickets: numTickets.toString(), ticketPrice: ticketPrice.toString(), roundNumber: roundNumber.toString(), blockNumber: receipt.blockNumber, txFee: txFee.toString() });
        } else {
          log({ event: 'purchase_reverted', hash, roundNumber: roundNumber.toString(), blockNumber: receipt.blockNumber, txFee: txFee.toString() });
        }

        break;
      }

      await wait(LOOP_INTERVAL);
    }

    
    setTimeout(processRound, timeout(roundEnd));
  }

  setTimeout(processRound, timeout(await tickets.read.roundEnd()));
}

async function fetchRoundState(client: PublicClient, address: Address) {
  const [price, roundEnd, roundNumber] = await client.multicall({
    contracts: [
      { address, abi: ticketsAbi, functionName: 'currentPrice' },
      { address, abi: ticketsAbi, functionName: 'roundEnd' },
      { address, abi: ticketsAbi, functionName: 'roundNumber' },
    ],
    allowFailure: false,
  });
  return { price, roundEnd, roundNumber };
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

function log(obj: Record<string, unknown>): void {
  console.log(JSON.stringify({timestamp: Date.now(), obj}));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
