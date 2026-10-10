import { defineConfig, devices } from '@playwright/test';

// The fixture file is created outside the repository by a disposable local Auth/DB harness.
if (!process.env.INSTRUCTOR_E2E_FIXTURE) throw new Error('Set INSTRUCTOR_E2E_FIXTURE to the disposable local fixture JSON.');
export default defineConfig({
  testDir: './e2e', testMatch: 'instructor-first-load.spec.ts', workers: 1, retries: 0,
  timeout: 30000, expect: { timeout: 5000 }, reporter: 'list',
  outputDir: process.env.INSTRUCTOR_E2E_OUTPUT ?? '../test-results/instructor-real',
  use: { ...devices['Desktop Chrome'], trace: 'off', screenshot: 'only-on-failure' },
});
