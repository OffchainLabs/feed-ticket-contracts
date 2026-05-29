import { createPublicClient, createWalletClient, getContract, http } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { Config, loadConfig } from './config.js';
import { ticketsAbi } from './ticketsAbi.js';

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
  void tickets;
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
