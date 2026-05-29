import { createPublicClient, createWalletClient, http } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { loadConfig } from './config.js';

async function main(): Promise<void> {
  const config = loadConfig();
  const account = privateKeyToAccount(config.privateKey);
  const transport = http(config.rpcUrl);
  const publicClient = createPublicClient({ transport });
  const walletClient = createWalletClient({ account, transport });
  void walletClient;
  void publicClient;
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
