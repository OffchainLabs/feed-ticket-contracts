import { defineConfig } from '@wagmi/cli';
import { foundry } from '@wagmi/cli/plugins';

export default defineConfig({
  out: 'src/ticketsAbi.ts',
  plugins: [
    foundry({
      project: '..',
      include: ['Tickets.sol/**', 'ITickets.sol/**'],
    }),
  ],
});
