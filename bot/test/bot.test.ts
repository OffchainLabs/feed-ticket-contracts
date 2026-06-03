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
const DEPLOYER_KEY =
  '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';
const BENEFICIARY_KEY =
  '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d';

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
  const artifact = JSON.parse(
    readFileSync(
      `${fileURLToPath(new URL('../../out', import.meta.url))}/${path}`,
      'utf8',
    ),
  );
  return { abi: artifact.abi, bytecode: artifact.bytecode.object as Hex };
}

const erc20Mock = loadArtifact('ERC20Mock.sol/ERC20Mock.json');
const ticketsArtifact = loadArtifact('Tickets.sol/Tickets.json');
const proxyArtifact = loadArtifact(
  'TransparentUpgradeableProxy.sol/TransparentUpgradeableProxy.json',
);

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

async function deploy(
  artifact: { abi: Abi; bytecode: Hex },
  args: unknown[],
): Promise<Address> {
  const hash = await walletClient.deployContract({
    abi: artifact.abi,
    bytecode: artifact.bytecode,
    args,
    account: deployer,
    chain: foundry,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (!receipt.contractAddress)
    throw new Error('deployment produced no contract address');
  return getAddress(receipt.contractAddress);
}

async function deployTickets(roundDuration = ROUND_DURATION_SECONDS): Promise<{
  address: Address;
  firstRoundStart: bigint;
  roundDuration: number;
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
        grandfatherPeriodFraction: GRANDFATHER_PERIOD_FRACTION,
        firstRoundStart: start,
      },
    ],
  });
  const address = await deploy(proxyArtifact, [
    impl,
    deployer.address,
    initData,
  ]);
  return { address, firstRoundStart: start, roundDuration };
}

before(
  async () => {
    anvil = spawn(
      'anvil',
      ['--port', String(ANVIL_PORT), '--block-time', ANVIL_BLOCK_TIME],
      { stdio: 'ignore' },
    );
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
  await waitForLog(from, (l) => l.event === 'bot_stopped', 15_000);
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
  assert.equal(
    await read('roundEnd'),
    firstRoundStart + BigInt(ROUND_DURATION_SECONDS),
  );
  assert.equal(await read('currentPrice'), MINIMUM_PRICE);
});

// ===== Bot behavioral tests =====
// These drive the real bot via run() against a fresh deployment each, with its own anvil
// account. afterEach aborts the bot's signal so it stops between cases.

const ANVIL_MNEMONIC =
  'test test test test test test test test test test test junk';
const GWEI = 10n ** 9n;
const API_KEY_HASH = ('0x' + 'ab'.repeat(32)) as Hex;
const BOT_TICKETS_PER_ROUND = 3;
const BOT_DEPOSIT = parseEther('100');

type PurchaseArgs = {
  buyer: Address;
  round: bigint;
  apiKeyHash: Hex;
  price: bigint;
  numTickets: bigint;
  numTicketsDesired: bigint;
};

function anvilKey(index: number): Hex {
  return toHex(
    mnemonicToAccount(ANVIL_MNEMONIC, { addressIndex: index }).getHdKey()
      .privateKey!,
  );
}

// Indices 0/1 are the deployer/beneficiary; give each bot test its own account.
const botKeys = [anvilKey(2), anvilKey(3), anvilKey(4)];

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

function makeBotConfig(
  privateKey: Hex,
  ticketsAddr: Address,
  overrides: Partial<Config> = {},
): Config {
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
    roundEndBufferMs: 1000,
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

async function waitForPurchase(
  ticketsAddr: Address,
  buyer: Address,
  fromBlock: bigint,
  timeoutMs: number,
) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const logs = await getPurchases(ticketsAddr, buyer, fromBlock);
    if (logs.length > 0) return logs;
    await sleep(150);
  }
  return [];
}

test('bot purchases tickets (happy path)', async () => {
  const { address, firstRoundStart: start } = await deployTickets();
  const account = privateKeyToAccount(botKeys[0]);
  await waitForTimestamp(start);
  await fundDeposit(account, address, BOT_DEPOSIT);

  const fromBlock = await publicClient.getBlockNumber();
  const logStart = botLogs.length;
  botAbort = new AbortController();
  run(makeBotConfig(botKeys[0], address), botAbort.signal);

  const logs = await waitForPurchase(
    address,
    account.address,
    fromBlock,
    20_000,
  );
  assert.equal(logs.length > 0, true);

  const purchase = logs[0]!.args as PurchaseArgs;
  assert.equal(purchase.buyer, account.address);
  assert.equal(purchase.numTickets, BigInt(BOT_TICKETS_PER_ROUND));
  assert.equal(purchase.numTicketsDesired, BigInt(BOT_TICKETS_PER_ROUND));
  assert.equal(purchase.price, MINIMUM_PRICE);
  assert.equal(purchase.apiKeyHash, API_KEY_HASH);

  const balance = await publicClient.readContract({
    address,
    abi: ticketsArtifact.abi,
    functionName: 'tokenBalance',
    args: [account.address],
  });
  assert.equal((balance as bigint) < BOT_DEPOSIT, true);

  // The bot's own logs should report the purchase it just made on-chain.
  const success = await waitForLog(
    logStart,
    (l) => l.event === 'purchase_success',
    5_000,
  );
  assert.ok(success, 'bot did not log purchase_success');
  assert.equal(success!.numTickets, String(BOT_TICKETS_PER_ROUND));
  assert.equal(success!.ticketPrice, MINIMUM_PRICE.toString());
});

test('bot waits for the gas price to drop before purchasing', async () => {
  const {
    address,
    firstRoundStart: start,
    roundDuration,
  } = await deployTickets(5);
  const account = privateKeyToAccount(botKeys[1]);
  await waitForTimestamp(start);
  await fundDeposit(account, address, BOT_DEPOSIT);

  // Price gas out of the bot's budget so its fee check fails and it polls instead of buying.
  await testClient.setNextBlockBaseFeePerGas({ baseFeePerGas: 5_000n * GWEI });
  const fromBlock = await publicClient.getBlockNumber();
  const logStart = botLogs.length;
  botAbort = new AbortController();
  run(
    makeBotConfig(botKeys[1], address, { maxTransactionFee: 10n ** 16n }),
    botAbort.signal,
  );

  // 1s into the bot's first purchase round (round 1): gas is still high, so it must not have bought.
  await waitForTimestamp(start + BigInt(roundDuration) + 1n);
  assert.equal(
    (await getPurchases(address, account.address, fromBlock)).length,
    0,
  );
  // Logs confirm WHY: the fee never fit the budget, so the bot never attempted a purchase.
  assert.equal(
    botLogs.slice(logStart).filter((l) => l.event === 'purchase_attempt')
      .length,
    0,
  );

  // Drop the gas price; the bot's next poll should now go through.
  await testClient.setNextBlockBaseFeePerGas({ baseFeePerGas: 1n * GWEI });
  const logs = await waitForPurchase(
    address,
    account.address,
    fromBlock,
    10_000,
  );
  assert.equal(logs.length > 0, true);
  // Once gas dropped, the bot attempted and completed the purchase.
  const success = await waitForLog(
    logStart,
    (l) => l.event === 'purchase_success',
    5_000,
  );
  assert.ok(success, 'bot did not log purchase_success after gas dropped');
});

test('bot skips a round on contract revert, then recovers', async () => {
  const {
    address,
    firstRoundStart: start,
    roundDuration,
  } = await deployTickets(5);
  const account = privateKeyToAccount(botKeys[2]);
  await waitForTimestamp(start);

  // Unfunded: purchaseTickets reverts with InsufficientTokenBalance, which the bot sees as an
  // estimateGas revert and skips -- the same path it takes when a round is sold out (MaxTicketsSold).
  const fromBlock = await publicClient.getBlockNumber();
  const logStart = botLogs.length;
  botAbort = new AbortController();
  run(makeBotConfig(botKeys[2], address), botAbort.signal);

  // Round 1: the purchase would revert, so the bot must skip it (buy nothing) without crashing.
  await waitForTimestamp(start + BigInt(roundDuration) + 1n);
  assert.equal(
    (await getPurchases(address, account.address, fromBlock)).length,
    0,
  );
  // Logs confirm the bot took the revert-skip path rather than skipping for some other reason.
  const revertSkip = await waitForLog(
    logStart,
    (l) => l.event === 'skip' && l.reason === 'revert',
    5_000,
  );
  assert.ok(revertSkip, 'bot did not log a revert skip');

  // Fund it; a later round should succeed, proving the revert didn't kill the bot's loop.
  await fundDeposit(account, address, BOT_DEPOSIT);
  const logs = await waitForPurchase(
    address,
    account.address,
    fromBlock,
    20_000,
  );
  assert.equal(logs.length > 0, true);
  assert.equal((logs[0]!.args as PurchaseArgs).round >= 2n, true);
  // ...and it recovered: a purchase_success after the revert proves the loop survived.
  const success = await waitForLog(
    logStart,
    (l) => l.event === 'purchase_success',
    5_000,
  );
  assert.ok(success, 'bot did not recover with a purchase_success');
});
