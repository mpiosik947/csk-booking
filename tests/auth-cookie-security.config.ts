import { defineConfig, devices } from '@playwright/test';

if (!process.env.AUTH_COOKIE_E2E_FIXTURE) throw new Error('Disposable TLS Auth fixture required.');
export default defineConfig({
  testDir: './e2e', testMatch: 'auth-cookie-security.spec.mjs', workers: 1, retries: 0,
  timeout: 60000, expect: { timeout: 10000 }, reporter: 'list',
  outputDir: process.env.AUTH_COOKIE_E2E_OUTPUT ?? '../test-results/auth-cookie-security',
  use: { ...devices['Desktop Chrome'], ignoreHTTPSErrors: true, trace: 'off', screenshot: 'off' },
});
