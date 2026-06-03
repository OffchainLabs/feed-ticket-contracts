import {
  BaseError,
  createPublicClient,
  encodeFunctionData,
  ExecutionRevertedError,
  getContract,
  Hex,
  http,
  parseEventLogs,
} from 'viem';
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
    if (signal?.aborted) {
      log({ event: 'abort', reason: 'signal_aborted' });
      return;
    }

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
    log({
      event: 'handle_grandfather_period',
      roundNumber,
      grandfatherCount,
      grandfatherPeriodEnd,
    });
    const { numTicketsPurchased: numTicketsPurchasedInGrandfatherPhase, transactionSent } =
      await purchaseTicketsWhenGasIsAcceptable(
        config,
        publicClient,
        account,
        Number(grandfatherPeriodEnd) * 1000,
        Number(grandfatherCount),
        roundNumber,
        price,
        nonce,
        chainId,
      );

    // if we bought enough tickets, wait for the next round to start
    if (numTicketsPurchasedInGrandfatherPhase >= config.ticketsPerRound) {
      log({
        event: 'round_filled_during_grandfather',
        roundNumber,
        numTicketsPurchasedInGrandfatherPhase,
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
    log({
      event: 'handle_open_purchase_window',
      roundNumber,
      ticketsToBuy: config.ticketsPerRound - numTicketsPurchasedInGrandfatherPhase,
    });
    await purchaseTicketsWhenGasIsAcceptable(
      config,
      publicClient,
      account,
      Number(roundEnd) * 1000,
      config.ticketsPerRound - numTicketsPurchasedInGrandfatherPhase,
      roundNumber,
      price,
      nonce + (transactionSent ? 1 : 0),
      chainId,
    );

    // wait for next round
    log({
      event: 'wait_next_round',
      roundNumber,
      roundEnd,
    });
    await wait(calculateWaitTime(roundEnd, config.maxScheduleJitterMs, config.roundEndBufferMs));
  }
}

async function purchaseTicketsWhenGasIsAcceptable(
  config: Config,
  publicClient: ReturnType<typeof createPublicClient>,
  account: ReturnType<typeof privateKeyToAccount>,
  deadlineTimestampMs: number,
  ticketsToBuy: number,
  roundNumber: bigint,
  price: bigint,
  nonce: number,
  chainId: number,
) {
  if (ticketsToBuy <= 0) {
    log({
      event: 'no_tickets_to_buy',
      roundNumber,
    });
    return { numTicketsPurchased: 0, transactionSent: false };
  }

  const purchaseArgs = [roundNumber, price, BigInt(ticketsToBuy), config.apiKeyHash] as const;
  const data = encodeFunctionData({
    abi: ticketsAbi,
    functionName: 'purchaseTickets',
    args: purchaseArgs,
  });

  while (true) {
    if (Date.now() >= deadlineTimestampMs) {
      log({ event: 'abort', reason: 'deadline_passed' });
      return { numTicketsPurchased: 0, transactionSent: false };
    }

    let gas: bigint;
    let gasPrice: bigint;
    try {
      [gas, gasPrice] = await Promise.all([
        publicClient.estimateGas({
          account,
          to: config.ticketsAddress,
          data,
          prepare: false,
        }),
        publicClient.getGasPrice(),
      ]);
    } catch (err) {
      // Revert = can't buy this round (sold out / low balance / stale); skip it. Transport errors propagate.
      if (err instanceof BaseError && err.walk((e) => e instanceof ExecutionRevertedError)) {
        log({
          event: 'skip',
          reason: 'revert',
          roundNumber,
          err,
        });
        return { numTicketsPurchased: 0, transactionSent: false };
      }
      throw err;
    }

    // if the resulting fee is within budget, purchase tickets
    if (gas * gasPrice <= config.maxTransactionFee) {
      log({
        event: 'purchase_attempt',
        gas,
        gasPrice,
        maxTransactionFee: config.maxTransactionFee,
      });

      const serializedTransaction = await account.signTransaction({
        type: 'legacy',
        chainId,
        nonce,
        to: config.ticketsAddress,
        data,
        gas,
        gasPrice,
      });

      const hash = await publicClient.sendRawTransaction({
        serializedTransaction,
      });

      log({ event: 'transaction_sent', hash });

      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      const txFee = receipt.gasUsed * receipt.effectiveGasPrice;
      const [purchase] = parseEventLogs({
        abi: ticketsAbi,
        eventName: 'TicketsPurchased',
        logs: receipt.logs,
      });

      if (purchase) {
        const { numTickets, price: ticketPrice } = purchase.args;
        log({
          event: 'purchase_success',
          hash,
          numTickets,
          roundNumber,
          blockNumber: receipt.blockNumber,
          txFee,
        });
        return { transactionSent: true, numTicketsPurchased: Number(numTickets) };
      } else {
        log({
          event: 'purchase_reverted',
          hash,
          roundNumber,
          blockNumber: receipt.blockNumber,
          txFee,
        });
        return { transactionSent: true, numTicketsPurchased: 0 };
      }
    }

    log({
      event: 'wait_gas_fee_above_max',
      gas,
      gasPrice,
      fee: gas * gasPrice,
      maxTransactionFee: config.maxTransactionFee,
    });

    await wait(config.gasPollIntervalMs);
  }
}

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
