import { spawn, type ChildProcess } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import {
  createPublicClient,
  createWalletClient,
  encodeFunctionData,
  getAddress,
  http,
  parseEther,
  type Abi,
  type Address,
  type Hex,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { foundry } from 'viem/chains';

const ANVIL_PORT = 8545;
const ANVIL_BLOCK_TIME = '0.25';
const RPC_URL = `http://127.0.0.1:${ANVIL_PORT}`;

// anvil dev accounts
const DEPLOYER_KEY = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';
const BENEFICIARY_KEY = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d';

// parameters for the test deployment
const ROUND_DURATION_SECONDS = 2;
const TARGET_TICKETS_PER_ROUND = 100;
const MAX_TICKETS_PER_ROUND = 200;
const MINIMUM_PRICE = parseEther('1');
const PRICE_UPDATE_FRACTION = 50;
const GRANDFATHER_PERIOD_FRACTION = 100;
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

const publicClient = createPublicClient({ chain: foundry, transport: http(RPC_URL), pollingInterval: 200, cacheTime: 0 });
const walletClient = createWalletClient({ account: deployer, chain: foundry, transport: http(RPC_URL) });

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
  const hash = await walletClient.deployContract({ abi: artifact.abi, bytecode: artifact.bytecode, args, account: deployer, chain: foundry });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (!receipt.contractAddress) throw new Error('deployment produced no contract address');
  return getAddress(receipt.contractAddress);
}

before(async () => {
  anvil = spawn('anvil', ['--port', String(ANVIL_PORT), '--block-time', ANVIL_BLOCK_TIME], { stdio: 'ignore' });
  await waitForAnvil();

  tokenAddress = await deploy(erc20Mock, []);
  const ticketsImpl = await deploy(ticketsArtifact, [tokenAddress]);

  const { timestamp } = await publicClient.getBlock({ blockTag: 'latest' });
  firstRoundStart = timestamp + FIRST_ROUND_LEAD_SECONDS;
  const initData = encodeFunctionData({
    abi: ticketsArtifact.abi,
    functionName: 'initialize',
    args: [{
      defaultAdmin: deployer.address,
      beneficiarySetter: deployer.address,
      marketParamsSetter: deployer.address,
      beneficiary: beneficiary.address,
      roundDuration: ROUND_DURATION_SECONDS,
      targetTicketsPerRound: TARGET_TICKETS_PER_ROUND,
      maxTicketsPerRound: MAX_TICKETS_PER_ROUND,
      minimumPrice: MINIMUM_PRICE,
      priceUpdateFraction: PRICE_UPDATE_FRACTION,
      grandfatherPeriodFraction: GRANDFATHER_PERIOD_FRACTION,
      firstRoundStart,
    }],
  });

  ticketsAddress = await deploy(proxyArtifact, [ticketsImpl, deployer.address, initData]);

  await waitForTimestamp(firstRoundStart);
}, { timeout: 30_000 });

after(() => {
  anvil?.kill('SIGKILL');
});

function read(functionName: string) {
  return publicClient.readContract({ address: ticketsAddress, abi: ticketsArtifact.abi, functionName });
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
