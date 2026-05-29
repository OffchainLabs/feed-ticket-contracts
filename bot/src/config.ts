import { getAddress, type Address, type Hex } from 'viem';

function required(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing required env var: ${name}`);
  return v;
}

function parseHash(name: string): Hex {
  const v = required(name);
  if (!/^0x[0-9a-fA-F]{64}$/.test(v)) {
    throw new Error(`${name} must be a 0x-prefixed 32-byte hex string`);
  }
  return v as Hex;
}

export interface Config {
  rpcUrl: string;
  ticketsPerRound: number;
  maxPricePerTicket: bigint;
  maxTransactionFee: bigint;
  privateKey: Hex;
  ticketsAddress: Address;
  apiKeyHash: Hex;
}

export function loadConfig(): Config {
  return {
    rpcUrl: required('RPC_URL'),
    ticketsPerRound: parseInt(required('TICKETS_PER_ROUND'), 10),
    maxPricePerTicket: BigInt(required('MAX_PRICE_PER_TICKET')),
    maxTransactionFee: BigInt(required('MAX_TRANSACTION_FEE')),
    privateKey: parseHash('PRIVATE_KEY'),
    ticketsAddress: getAddress(required('TICKETS_ADDRESS')),
    apiKeyHash: parseHash('API_KEY_HASH'),
  };
}
