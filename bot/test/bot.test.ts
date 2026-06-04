import { spawn, type ChildProcess } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { after, afterEach, before, test } from 'node:test';
import assert from 'node:assert/strict';
import {
  createPublicClient,
  createTestClient,
  createWalletClient,
  encodeFunctionData,
  getAddress,
  http,
  parseEther,
  toHex,
  type Abi,
  type Address,
  type Hex,
} from 'viem';
import { mnemonicToAccount, privateKeyToAccount } from 'viem/accounts';
import { foundry } from 'viem/chains';
import { run } from '../src/bot.js';
import type { Config } from '../src/config.js';

const ANVIL_PORT = 8545;
const ANVIL_BLOCK_TIME = '0.25';
const RPC_URL = `http://127.0.0.1:${ANVIL_PORT}`;

// anvil dev accounts
const DEPLOYER_KEY = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';
const BENEFICIARY_KEY = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d';

// parameters for the test deployment
const ROUND_DURATION_SECONDS = 4;
const TARGET_TICKETS_PER_ROUND = 100;
const MAX_TICKETS_PER_ROUND = 200;
const MINIMUM_PRICE = parseEther('1');
const PRICE_UPDATE_FRACTION = 50;
// 0 = no grandfather phase, so a fresh buyer (the bot) can purchase from the round start; the
// bot acts at the round boundary, which would otherwise fall inside the grandfather phase.
const GRANDFATHER_PERIOD_FRACTION = 0;
const FIRST_ROUND_LEAD_SECONDS = 2n;

function loadArtifact(path: string): { abi: Abi; bytecode: Hex } {
  const artifact = JSON.parse(readFileSync(`${fileURLToPath(new URL('../../out', import.meta.url))}/${path}`, 'utf8'));
  return { abi: artifact.abi, bytecode: artifact.bytecode.object as Hex };
}

const erc20Mock = loadArtifact('ERC20Mock.sol/ERC20Mock.json');
const ticketsArtifact = loadArtifact('Tickets.sol/Tickets.json');
const proxyArtifact = loadArtifact('TransparentUpgradeableProxy.sol/TransparentUpgradeableProxy.json');

const deployer = privateKeyToAccount(DEPLOYER_KEY);
const beneficiary = privateKeyToAccount(BENEFICIARY_KEY);

const publicClient = createPublicClient({
  chain: foundry,
  transport: http(RPC_URL),
  pollingInterval: 200,
  cacheTime: 0,
});
const walletClient = createWalletClient({
  account: deployer,
  chain: foundry,
  transport: http(RPC_URL),
});
const testClient = createTestClient({
  chain: foundry,
  mode: 'anvil',
  transport: http(RPC_URL),
});

let anvil: ChildProcess;
let tokenAddress: Address;
let ticketsAddress: Address;
let firstRoundStart: bigint;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForAnvil(): Promise<void> {
  for (let i = 0; i < 100; i++) {
    try {
      await publicClient.getChainId();
      return;
    } catch {
      await sleep(100);
    }
  }
  throw new Error('anvil did not become ready');
}

async function waitForTimestamp(target: bigint): Promise<void> {
  for (let i = 0; i < 200; i++) {
    const { timestamp } = await publicClient.getBlock({ blockTag: 'latest' });
    if (timestamp >= target) return;
    await sleep(100);
  }
  throw new Error('chain did not reach target timestamp');
}

async function deploy(artifact: { abi: Abi; bytecode: Hex }, args: unknown[]): Promise<Address> {
  const hash = await walletClient.deployContract({
    abi: artifact.abi,
    bytecode: artifact.bytecode,
    args,
    account: deployer,
    chain: foundry,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (!receipt.contractAddress) throw new Error('deployment produced no contract address');
  return getAddress(receipt.contractAddress);
}

async function deployTickets(
  roundDuration = ROUND_DURATION_SECONDS,
  grandfatherPeriodFraction = GRANDFATHER_PERIOD_FRACTION,
): Promise<{
  address: Address;
  firstRoundStart: bigint;
  roundDuration: number;
  grandfatherPeriodFraction: number;
}> {
  const impl = await deploy(ticketsArtifact, [tokenAddress]);
  const { timestamp } = await publicClient.getBlock({ blockTag: 'latest' });
  const start = timestamp + FIRST_ROUND_LEAD_SECONDS;
  const initData = encodeFunctionData({
    abi: ticketsArtifact.abi,
    functionName: 'initialize',
    args: [
      {
        defaultAdmin: deployer.address,
        beneficiarySetter: deployer.address,
        marketParamsSetter: deployer.address,
        beneficiary: beneficiary.address,
        roundDuration,
        targetTicketsPerRound: TARGET_TICKETS_PER_ROUND,
        maxTicketsPerRound: MAX_TICKETS_PER_ROUND,
        minimumPrice: MINIMUM_PRICE,
        priceUpdateFraction: PRICE_UPDATE_FRACTION,
        grandfatherPeriodFraction,
        firstRoundStart: start,
      },
    ],
  });
  const address = await deploy(proxyArtifact, [impl, deployer.address, initData]);
  return { address, firstRoundStart: start, roundDuration, grandfatherPeriodFraction };
}

before(
  async () => {
    anvil = spawn('anvil', ['--port', String(ANVIL_PORT), '--block-time', ANVIL_BLOCK_TIME], {
      stdio: 'ignore',
    });
    await waitForAnvil();

    tokenAddress = await deploy(erc20Mock, []);
    ({ address: ticketsAddress, firstRoundStart } = await deployTickets());

    await waitForTimestamp(firstRoundStart);
  },
  { timeout: 30_000 },
);

after(() => {
  anvil?.kill('SIGKILL');
});

// The bot emits one JSON line per event via console.log. Capture them so tests can assert on the
// bot's own view of what happened, while still printing them so they show in the test output.
type BotLog = { timestamp: number; event: string; [key: string]: unknown };
const botLogs: BotLog[] = [];
const realConsoleLog = console.log;

before(() => {
  console.log = (...args: unknown[]) => {
    realConsoleLog(...args);
    const line = args[0];
    if (typeof line !== 'string') return;
    try {
      const parsed = JSON.parse(line) as BotLog;
      if (parsed?.event) botLogs.push(parsed);
    } catch {}
  };
});

after(() => {
  console.log = realConsoleLog;
});

async function waitForLog(
  fromIndex: number,
  predicate: (l: BotLog) => boolean,
  timeoutMs: number,
): Promise<BotLog | undefined> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const hit = botLogs.slice(fromIndex).find(predicate);
    if (hit) return hit;
    await sleep(150);
  }
  return undefined;
}

// Stop the bot under test after each case and wait for it to confirm it stopped, so its logs don't
// bleed into the next test.
let botAbort: AbortController | undefined;
afterEach(async () => {
  if (!botAbort) return;
  const from = botLogs.length;
  botAbort.abort();
  botAbort = undefined;
  await waitForLog(from, (l) => l.event === 'abort', 15_000);
});

function read(functionName: string) {
  return publicClient.readContract({
    address: ticketsAddress,
    abi: ticketsArtifact.abi,
    functionName,
  });
}

test('deploys the tickets contract', async () => {
  const code = await publicClient.getCode({ address: ticketsAddress });
  assert.notEqual(code, undefined);
  assert.notEqual(code, '0x');

  assert.equal(await read('token'), tokenAddress);
  assert.equal(await read('beneficiary'), beneficiary.address);
  assert.equal(await read('isAdminUpdateQueued'), false);
});

test('exposes live first-round state', async () => {
  assert.equal(await read('roundNumber'), 0n);
  assert.equal(await read('roundEnd'), firstRoundStart + BigInt(ROUND_DURATION_SECONDS));
  assert.equal(await read('currentPrice'), MINIMUM_PRICE);
});

// ===== Bot behavioral tests =====
// These drive the real bot via run() against a fresh deployment each, with its own anvil
// account. afterEach aborts the bot's signal so it stops between cases.

const ANVIL_MNEMONIC = 'test test test test test test test test test test test junk';
const GWEI = 10n ** 9n;
const API_KEY_HASH = ('0x' + 'ab'.repeat(32)) as Hex;
const BOT_TICKETS_PER_ROUND = 3;
const BOT_DEPOSIT = parseEther('100');
const BOT_MAX_PRICE = parseEther('0.5'); // between the dropped price (0.1e18) and the round-0 price (1e18)
const DROPPED_PRICE = parseEther('0.1'); // queued minimum price that round-0's price drops to
const HIGH_BASE_FEE = 5_000n * GWEI; // prices the bot's fee above its budget
const LOW_BASE_FEE = 1n * GWEI;

type PurchaseArgs = {
  buyer: Address;
  round: bigint;
  apiKeyHash: Hex;
  price: bigint;
  numTickets: bigint;
  numTicketsDesired: bigint;
};

function anvilKey(index: number): Hex {
  return toHex(mnemonicToAccount(ANVIL_MNEMONIC, { addressIndex: index }).getHdKey().privateKey!);
}

// Indices 0/1 are the deployer/beneficiary; the bot gets its own account.
const botKey = anvilKey(2);

async function sendTx(hashPromise: Promise<Hex>): Promise<void> {
  await publicClient.waitForTransactionReceipt({ hash: await hashPromise });
}

async function fundDeposit(
  account: ReturnType<typeof privateKeyToAccount>,
  ticketsAddr: Address,
  amount: bigint,
): Promise<void> {
  const wallet = createWalletClient({
    account,
    chain: foundry,
    transport: http(RPC_URL),
  });
  await sendTx(
    wallet.writeContract({
      address: tokenAddress,
      abi: erc20Mock.abi,
      functionName: 'mint',
      args: [account.address, amount],
    }),
  );
  await sendTx(
    wallet.writeContract({
      address: tokenAddress,
      abi: erc20Mock.abi,
      functionName: 'approve',
      args: [ticketsAddr, amount],
    }),
  );
  await sendTx(
    wallet.writeContract({
      address: ticketsAddr,
      abi: ticketsArtifact.abi,
      functionName: 'depositToken',
      args: [amount],
    }),
  );
}

function makeBotConfig(privateKey: Hex, ticketsAddr: Address, overrides: Partial<Config> = {}): Config {
  return {
    rpcUrl: RPC_URL,
    ticketsPerRound: BOT_TICKETS_PER_ROUND,
    maxPricePerTicket: parseEther('10'),
    maxTransactionFee: parseEther('1'),
    privateKey,
    ticketsAddress: ticketsAddr,
    apiKeyHash: API_KEY_HASH,
    maxScheduleJitterMs: 0,
    gasPollIntervalMs: 250,
    boundaryBufferMs: 1000,
    ...overrides,
  };
}

function getPurchases(ticketsAddr: Address, buyer: Address, fromBlock: bigint) {
  return publicClient.getContractEvents({
    address: ticketsAddr,
    abi: ticketsArtifact.abi,
    eventName: 'TicketsPurchased',
    args: { buyer },
    fromBlock,
  });
}

async function waitForPurchase(ticketsAddr: Address, buyer: Address, fromBlock: bigint, timeoutMs: number) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const logs = await getPurchases(ticketsAddr, buyer, fromBlock);
    if (logs.length > 0) return logs;
    await sleep(150);
  }
  return [];
}

function setBaseFee(wei: bigint): Promise<void> {
  return testClient.setNextBlockBaseFeePerGas({ baseFeePerGas: wei });
}

// One bot run, driven through its whole lifecycle in sequence: it waits out a round priced above
// its max, skips an unfunded round on the resulting revert, waits for gas to come down, and finally
// purchases -- proving the loop recovers from both a price cap and a revert without dying.
test(
  'bot lifecycle: waits out the price cap, skips a revert, waits for gas, then purchases',
  async () => {
    const { address, firstRoundStart: start } = await deployTickets(5);
    const account = privateKeyToAccount(botKey);
    await waitForTimestamp(start);

    // Round 0 sits at MINIMUM_PRICE, above the bot's max. Queue a drop below the bot's max so that
    // from round 1 the bot clears the price check and proceeds to purchasing. The bot buys far below
    // target, so excessTicketsSold stays 0 and currentPrice tracks minimumPrice exactly.
    await sendTx(
      walletClient.writeContract({
        address,
        abi: ticketsArtifact.abi,
        functionName: 'setPricingParams',
        args: [DROPPED_PRICE, BigInt(PRICE_UPDATE_FRACTION), 0n],
        account: deployer,
        chain: foundry,
      }),
    );

    const fromBlock = await publicClient.getBlockNumber();
    const logStart = botLogs.length;
    botAbort = new AbortController();
    run(
      makeBotConfig(botKey, address, { maxPricePerTicket: BOT_MAX_PRICE, maxTransactionFee: 10n ** 16n }),
      botAbort.signal,
    );

    // Phase 1 -- price cap: round 0's price is above the bot's max, so it waits without buying.
    const priceWait = await waitForLog(logStart, (l) => l.event === 'price_above_max', 8_000);
    assert.ok(priceWait, 'bot did not log price_above_max in round 0');
    assert.equal(priceWait.roundNumber, '0');
    assert.equal(priceWait.price, MINIMUM_PRICE.toString());
    assert.equal(BigInt(priceWait.price as string) > BigInt(priceWait.maxPricePerTicket as string), true);

    // Phase 2 -- revert skip: the price has dropped so the bot now tries to buy, but it is unfunded,
    // so estimateGas reverts (InsufficientTokenBalance) and the bot skips the round without crashing.
    const revertSkip = await waitForLog(logStart, (l) => l.event === 'skip_due_to_revert', 12_000);
    assert.ok(revertSkip, 'bot did not log skip_due_to_revert after the price dropped');
    assert.equal((await getPurchases(address, account.address, fromBlock)).length, 0);

    // Phase 3 -- gas wait: fund the bot, then price gas out of its fee budget. estimateGas now
    // succeeds, but the fee exceeds the budget, so the bot polls instead of buying. Re-apply the high
    // base fee until we observe the wait, since anvil decays the base fee each block.
    await fundDeposit(account, address, BOT_DEPOSIT);
    const gasMarker = botLogs.length;
    const gasDeadline = Date.now() + 15_000;
    let gasWait: BotLog | undefined;
    while (Date.now() < gasDeadline && !gasWait) {
      await setBaseFee(HIGH_BASE_FEE);
      gasWait = botLogs.slice(gasMarker).find((l) => l.event === 'wait_gas_fee_above_max');
      await sleep(150);
    }
    assert.ok(gasWait, 'bot did not log wait_gas_fee_above_max while gas was high');
    assert.equal(BigInt(gasWait.fee as string) > BigInt(gasWait.maxTransactionFee as string), true);
    // It must not have attempted a purchase while the fee was above budget.
    assert.equal(botLogs.slice(gasMarker).filter((l) => l.event === 'purchase_attempt').length, 0);

    // Phase 4 -- purchase: drop the gas price; the bot's next poll fits the budget and it buys.
    await setBaseFee(LOW_BASE_FEE);
    const success = await waitForLog(gasMarker, (l) => l.event === 'purchase_success', 15_000);
    assert.ok(success, 'bot did not purchase after gas dropped');
    assert.equal(success.numTickets, String(BOT_TICKETS_PER_ROUND));

    // The purchase landed on-chain with the expected terms, at the dropped price.
    const logs = await waitForPurchase(address, account.address, fromBlock, 5_000);
    assert.equal(logs.length > 0, true);
    const purchase = logs[0]!.args as PurchaseArgs;
    assert.equal(purchase.buyer, account.address);
    assert.equal(purchase.numTickets, BigInt(BOT_TICKETS_PER_ROUND));
    assert.equal(purchase.numTicketsDesired, BigInt(BOT_TICKETS_PER_ROUND));
    assert.equal(purchase.price, DROPPED_PRICE);
    assert.equal(purchase.apiKeyHash, API_KEY_HASH);

    // The purchase debited the bot's deposited balance...
    const balance = await publicClient.readContract({
      address,
      abi: ticketsArtifact.abi,
      functionName: 'tokenBalance',
      args: [account.address],
    });
    assert.equal((balance as bigint) < BOT_DEPOSIT, true);

    // ...and it came after the earlier revert, proving the loop recovered rather than died.
    const events = botLogs.slice(logStart);
    const skipIdx = events.findIndex((l) => l.event === 'skip_due_to_revert');
    const successIdx = events.findIndex((l) => l.event === 'purchase_success');
    assert.ok(skipIdx >= 0 && successIdx > skipIdx, 'purchase_success did not follow the revert skip');
  },
  { timeout: 60_000 },
);

// Round 0 has no previous round, so grandfatherCount is 0 and the bot buys in the open phase.
// In round 1 the bot's prior-round purchases entitle it to a full grandfather allotment, so it
// fills the entire round during the grandfather phase and never enters the open window.
test(
  'bot grandfather flow: round 0 sees no grandfather, round 1 fills during grandfather phase',
  async () => {
    // Long rounds + a long grandfather phase keep the bot's round-1 work comfortably inside the
    // grandfather window even with viem's 4s default receipt polling.
    const roundDuration = 10;
    const grandfatherFraction = 192; // 3/4 of the round
    const { address, firstRoundStart: start } = await deployTickets(roundDuration, grandfatherFraction);
    const account = privateKeyToAccount(botKey);

    await fundDeposit(account, address, BOT_DEPOSIT);
    await waitForTimestamp(start);

    const fromBlock = await publicClient.getBlockNumber();
    const logStart = botLogs.length;
    botAbort = new AbortController();
    run(makeBotConfig(botKey, address), botAbort.signal);

    // Round 0: no previous round, so grandfatherCount is 0.
    const r0Grandfather = await waitForLog(
      logStart,
      (l) => l.event === 'handle_grandfather_period' && l.roundNumber === '0',
      8_000,
    );
    assert.ok(r0Grandfather, 'bot did not log handle_grandfather_period in round 0');
    assert.equal(r0Grandfather.grandfatherCount, '0');

    // Round 0 purchase lands in the open phase since the bot has no grandfather count to fill.
    const r0Success = await waitForLog(
      logStart,
      (l) => l.event === 'purchase_success' && l.roundNumber === '0',
      (roundDuration + 5) * 1000,
    );
    assert.ok(r0Success, 'bot did not purchase in round 0');
    assert.equal(r0Success.numTickets, String(BOT_TICKETS_PER_ROUND));

    // Round 1: the prior-round purchase entitles the bot to BOT_TICKETS_PER_ROUND grandfather
    // tickets, which equals its desired count, so the round fills entirely in the grandfather phase.
    const r1Grandfather = await waitForLog(
      logStart,
      (l) => l.event === 'handle_grandfather_period' && l.roundNumber === '1',
      (roundDuration + 5) * 1000,
    );
    assert.ok(r1Grandfather, 'bot did not log handle_grandfather_period in round 1');
    assert.equal(r1Grandfather.grandfatherCount, String(BOT_TICKETS_PER_ROUND));

    const r1Fill = await waitForLog(
      logStart,
      (l) => l.event === 'round_filled_during_grandfather' && l.roundNumber === '1',
      (roundDuration + 5) * 1000,
    );
    assert.ok(r1Fill, 'bot did not log round_filled_during_grandfather in round 1');
    assert.equal(r1Fill.numTicketsPurchasedInGrandfatherPhase, BOT_TICKETS_PER_ROUND);

    const r1Success = await waitForLog(
      logStart,
      (l) => l.event === 'purchase_success' && l.roundNumber === '1',
      5_000,
    );
    assert.ok(r1Success, 'bot did not purchase in round 1');
    assert.equal(r1Success.numTickets, String(BOT_TICKETS_PER_ROUND));

    // Bot must not have entered the open phase in round 1 (it filled in the grandfather phase).
    const r1OpenWindow = botLogs
      .slice(logStart)
      .find((l) => l.event === 'handle_open_purchase_window' && l.roundNumber === '1');
    assert.equal(r1OpenWindow, undefined, 'bot entered the open window in round 1 despite filling');

    // On-chain confirmation: two purchases (round 0 + round 1), each at BOT_TICKETS_PER_ROUND.
    const purchases = await getPurchases(address, account.address, fromBlock);
    assert.equal(purchases.length, 2);
    const rounds = purchases.map((p) => (p.args as PurchaseArgs).round).sort((a, b) => Number(a - b));
    assert.deepEqual(rounds, [0n, 1n]);
    for (const purchase of purchases) {
      assert.equal((purchase.args as PurchaseArgs).numTickets, BigInt(BOT_TICKETS_PER_ROUND));
    }
  },
  { timeout: 60_000 },
);

// Partial grandfather fill: manually buy fewer tickets than the bot's per-round target in round 0
// from the bot's own account, then start the bot only after round 1 begins. The bot fills its
// partial grandfather allotment in the grandfather phase and tops up the remainder in the open
// phase.
test(
  'bot grandfather flow: partial grandfather fill tops up in the open phase',
  async () => {
    const roundDuration = 15;
    const grandfatherFraction = 128; // half the round
    const { address, firstRoundStart: start } = await deployTickets(roundDuration, grandfatherFraction);
    const account = privateKeyToAccount(botKey);
    const partialCount = 2;
    assert.ok(partialCount < BOT_TICKETS_PER_ROUND, 'partialCount must leave room for an open-phase top-up');

    await fundDeposit(account, address, BOT_DEPOSIT);
    await waitForTimestamp(start);

    // Manually buy `partialCount` tickets from the bot's account in round 0. This gives the bot a
    // grandfather allotment of `partialCount` in round 1, which is smaller than its per-round target.
    const wallet = createWalletClient({ account, chain: foundry, transport: http(RPC_URL) });
    await sendTx(
      wallet.writeContract({
        address,
        abi: ticketsArtifact.abi,
        functionName: 'purchaseTickets',
        args: [0n, MINIMUM_PRICE, BigInt(partialCount), API_KEY_HASH],
      }),
    );

    // Wait until round 1 starts so the bot's first iteration is round 1.
    const round1Start = start + BigInt(roundDuration);
    await waitForTimestamp(round1Start);

    const fromBlock = await publicClient.getBlockNumber();
    const logStart = botLogs.length;
    botAbort = new AbortController();
    run(makeBotConfig(botKey, address), botAbort.signal);

    // Bot reads grandfatherCount = partialCount in round 1.
    const r1Grandfather = await waitForLog(
      logStart,
      (l) => l.event === 'handle_grandfather_period' && l.roundNumber === '1',
      8_000,
    );
    assert.ok(r1Grandfather, 'bot did not log handle_grandfather_period in round 1');
    assert.equal(r1Grandfather.grandfatherCount, String(partialCount));

    // Bot does not fully fill in the grandfather phase (partialCount < ticketsPerRound), so it
    // proceeds to the open window for the remainder.
    const r1OpenWindow = await waitForLog(
      logStart,
      (l) => l.event === 'handle_open_purchase_window' && l.roundNumber === '1',
      (roundDuration + 5) * 1000,
    );
    assert.ok(r1OpenWindow, 'bot did not enter open purchase window in round 1');
    assert.equal(r1OpenWindow.ticketsToBuy, BOT_TICKETS_PER_ROUND - partialCount);

    // Bot must not have logged round_filled_during_grandfather in round 1.
    const filled = botLogs
      .slice(logStart)
      .find((l) => l.event === 'round_filled_during_grandfather' && l.roundNumber === '1');
    assert.equal(filled, undefined, 'bot logged round_filled_during_grandfather despite partial fill');

    // Wait for the open-phase purchase to land and the round to wrap up.
    const r1Done = await waitForLog(
      logStart,
      (l) => l.event === 'wait_next_round' && l.roundNumber === '1',
      (roundDuration + 5) * 1000,
    );
    assert.ok(r1Done, 'bot did not finish round 1');

    // On-chain: two round-1 purchases summing to ticketsPerRound, sized partialCount + the rest.
    const r1Purchases = (await getPurchases(address, account.address, fromBlock)).filter(
      (p) => (p.args as PurchaseArgs).round === 1n,
    );
    assert.equal(r1Purchases.length, 2);
    const sizes = r1Purchases.map((p) => (p.args as PurchaseArgs).numTickets).sort((a, b) => Number(a - b));
    assert.deepEqual(sizes, [BigInt(BOT_TICKETS_PER_ROUND - partialCount), BigInt(partialCount)]);
  },
  { timeout: 90_000 },
);
