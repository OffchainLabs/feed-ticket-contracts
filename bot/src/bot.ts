import { createPublicClient, encodeFunctionData, getContract, http, parseEventLogs } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { Config } from './config.js';
import { ticketsAbi } from './ticketsAbi.js';

// todo: add env overrides for these parameters

// Used to add some random delay to the bot's actions, to avoid all bots acting at the same time
const RANDOM_DELAY_MAX = 30_000; // 30 seconds

// Inner loop interval when trying to purchase tickets for a round
// Used to wait for gas prices to drop
const LOOP_INTERVAL = 10_000; // 10 seconds

export async function run(config: Config): Promise<void> {
  const account = privateKeyToAccount(config.privateKey);
  const transport = http(config.rpcUrl, { batch: true });
  const publicClient = createPublicClient({ transport });

  const tickets = getContract({
    address: config.ticketsAddress,
    abi: ticketsAbi,
    client: publicClient,
  });

  const chainId = await publicClient.getChainId();

  const processRound = async () => {
    const [price, roundEnd, roundNumber, nonce] = await Promise.all([
      publicClient.readContract({ address: tickets.address, abi: ticketsAbi, functionName: 'currentPrice' }),
      publicClient.readContract({ address: tickets.address, abi: ticketsAbi, functionName: 'roundEnd' }),
      publicClient.readContract({ address: tickets.address, abi: ticketsAbi, functionName: 'roundNumber' }),
      publicClient.getTransactionCount({ address: account.address, blockTag: 'pending' }),
    ]);

    log({ event: 'round_start', roundNumber: roundNumber.toString(), roundEnd: roundEnd.toString(), price: price.toString() });

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

      const purchaseArgs = [roundNumber, price, BigInt(config.ticketsPerRound), config.apiKeyHash] as const;
      const data = encodeFunctionData({ abi: ticketsAbi, functionName: 'purchaseTickets', args: purchaseArgs });

      const [gas, gasPrice] = await Promise.all([
        publicClient.estimateGas({ account, to: config.ticketsAddress, data, prepare: false }),
        publicClient.getGasPrice(),
        tickets.simulate.purchaseTickets(purchaseArgs, { account }),
      ]);

      // if the resulting fee is within budget, purchase tickets and break
      if (gas * gasPrice <= config.maxTransactionFee) {
        log({ event: 'purchase_attempt', gas: gas.toString(), gasPrice: gasPrice.toString(), maxTransactionFee: config.maxTransactionFee.toString() });

        const serializedTransaction = await account.signTransaction({
          type: 'legacy',
          chainId,
          nonce,
          to: config.ticketsAddress,
          data,
          gas,
          gasPrice,
        });
        const hash = await publicClient.sendRawTransaction({ serializedTransaction });
        log({ event: 'transaction_sent', hash });

        // don't block the loop waiting for the transaction receipt
        publicClient.waitForTransactionReceipt({ hash }).then((receipt) => {
          const txFee = receipt.gasUsed * receipt.effectiveGasPrice;
          const [purchase] = parseEventLogs({ abi: ticketsAbi, eventName: 'TicketsPurchased', logs: receipt.logs });
          if (purchase) {
            const { numTickets, price: ticketPrice } = purchase.args;
            log({ event: 'purchase_success', hash, numTickets: numTickets.toString(), ticketPrice: ticketPrice.toString(), roundNumber: roundNumber.toString(), blockNumber: receipt.blockNumber.toString(), txFee: txFee.toString() });
          } else {
            log({ event: 'purchase_reverted', hash, roundNumber: roundNumber.toString(), blockNumber: receipt.blockNumber.toString(), txFee: txFee.toString() });
          }
        });

        break;
      }

      await wait(LOOP_INTERVAL);
    }

    setTimeout(processRound, timeout(roundEnd));
  }

  setTimeout(processRound, timeout(await tickets.read.roundEnd()));
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
