import { getAddress, type Address, type Hex } from 'viem';

function required(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing required env var: ${name}`);
  return v;
}

export interface Config {
  rpcUrl: string;
  ticketsPerRound: number;
  maxPricePerTicket: bigint;
  maxTransactionFee: bigint;
  privateKey: Hex;
  ticketsAddress: Address;
}

export function loadConfig(): Config {
  const privateKey = required('PRIVATE_KEY');
  if (!/^0x[0-9a-fA-F]{64}$/.test(privateKey)) {
    throw new Error('PRIVATE_KEY must be a 0x-prefixed 32-byte hex string');
  }
  return {
    rpcUrl: required('RPC_URL'),
    ticketsPerRound: parseInt(required('TICKETS_PER_ROUND'), 10),
    maxPricePerTicket: BigInt(required('MAX_PRICE_PER_TICKET')),
    maxTransactionFee: BigInt(required('MAX_TRANSACTION_FEE')),
    privateKey: privateKey as Hex,
    ticketsAddress: getAddress(required('TICKETS_ADDRESS')),
  };
}
