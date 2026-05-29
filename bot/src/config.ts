import { getAddress, type Address, type Hex } from 'viem';

function required(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing required env var: ${name}`);
  return v;
}

export interface Config {
  rpcUrl: string;
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
    privateKey: privateKey as Hex,
    ticketsAddress: getAddress(required('TICKETS_ADDRESS')),
  };
}
