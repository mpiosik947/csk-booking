import { defineConfig, devices } from '@playwright/test';
// Isolated presentation tests: no application server, credentials, auth or DB fixtures.
export default defineConfig({
  testDir: './e2e', testMatch: 'csk-admin-visual.spec.ts', workers: 1,
  outputDir: '../test-results/admin-visual', reporter: 'list',
  use: { ...devices['Desktop Chrome'], screenshot: 'only-on-failure' },
});
