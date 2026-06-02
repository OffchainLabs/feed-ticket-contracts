import { loadConfig } from './config.js';
import { run } from './bot.js';

const controller = new AbortController();
process.on('SIGINT', () => controller.abort());
process.on('SIGTERM', () => controller.abort());
run(loadConfig(), controller.signal);
