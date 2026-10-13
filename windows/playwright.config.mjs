import { defineConfig } from '@playwright/test';
export default defineConfig({ testDir: './tests/smoke', workers: 1, timeout: 60_000, expect: { timeout: process.platform === 'linux' ? 15_000 : 5_000 }, retries: 0, reporter: [['list'], ['json', { outputFile: 'playwright-report/smoke-results.json' }]], use: { trace: 'retain-on-failure' } });
