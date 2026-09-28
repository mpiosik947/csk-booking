import { defineConfig } from '@playwright/test';
export default defineConfig({
  testDir: './e2e', testMatch: 'reminder-handler.spec.ts', workers: 1,
  outputDir: '../test-results/reminder-http', reporter: 'list',
  use: { baseURL: 'http://127.0.0.1:3197' },
  webServer: {
    cwd: process.cwd(),
    command: 'node node_modules/next/dist/bin/next start --hostname 127.0.0.1 --port 3197',
    url: 'http://127.0.0.1:3197', reuseExistingServer: false,
    env: { REMINDER_CRON_SECRET: '' }, timeout: 60000,
  },
});
