import { defineConfig } from '@playwright/test';
export default defineConfig({ testDir: './tests/smoke', workers: 1, timeout: 60_000, retries: 0, reporter: [['list']], use: { trace: 'retain-on-failure' } });
