import { BaseError, createPublicClient, encodeFunctionData, ExecutionRevertedError, getContract, http, parseEventLogs } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { Config } from './config.js';
import { ticketsAbi } from './ticketsAbi.js';

export async function run(config: Config, signal?: AbortSignal): Promise<void> {
  const account = privateKeyToAccount(config.privateKey);
  const transport = http(config.rpcUrl, { batch: true });
  const publicClient = createPublicClient({ transport });

  const tickets = getContract({
    address: config.ticketsAddress,
    abi: ticketsAbi,
    client: publicClient,
  });

  const chainId = await publicClient.getChainId();

  // outer loop processes rounds sequentially, inner loop polls for price and round end, purchasing when conditions are met
  while (true) {
    const [price, roundEnd, roundNumber, nonce] = await Promise.all([
      publicClient.readContract({ address: tickets.address, abi: ticketsAbi, functionName: 'currentPrice' }),
      publicClient.readContract({ address: tickets.address, abi: ticketsAbi, functionName: 'roundEnd' }),
      publicClient.readContract({ address: tickets.address, abi: ticketsAbi, functionName: 'roundNumber' }),
      publicClient.getTransactionCount({ address: account.address, blockTag: 'pending' }),
    ]);

    log({ event: 'round_start', roundNumber: roundNumber.toString(), roundEnd: roundEnd.toString(), price: price.toString() });

    while (true) {
      if (signal?.aborted) {
        log({ event: 'bot_stopped', reason: 'signal_aborted' });
        return;
      }

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

      let gas: bigint;
      let gasPrice: bigint;
      try {
        [gas, gasPrice] = await Promise.all([
          publicClient.estimateGas({ account, to: config.ticketsAddress, data, prepare: false }),
          publicClient.getGasPrice(),
        ]);
      } catch (err) {
        // Revert = can't buy this round (sold out / low balance / stale); skip it. Transport errors propagate.
        if (err instanceof BaseError && err.walk((e) => e instanceof ExecutionRevertedError)) {
          log({ event: 'skip', reason: 'revert', roundNumber: roundNumber.toString(), err });
          break;
        }
        throw err;
      }

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

      await wait(config.gasPollIntervalMs);
    }

    await wait(calculateWaitTime(roundEnd, config.maxScheduleJitterMs, config.roundEndBufferMs));
  }
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
  console.log(JSON.stringify({timestamp: Date.now(), ...obj}));
}
