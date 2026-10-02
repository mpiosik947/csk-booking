import base from './playwright.config';
import { defineConfig } from '@playwright/test';

export default defineConfig({
  ...base,
  testMatch: ['**/platform-wizard.spec.ts', '**/platform-onboarding.spec.ts'],
  timeout: 120_000,
  use: { ...base.use, baseURL: 'http://127.0.0.1:3101', trace: 'off', screenshot: 'off' },
  webServer: {
    ...base.webServer,
    command: 'npm.cmd run start -- --hostname 127.0.0.1 --port 3101',
    url: 'http://127.0.0.1:3101/login',
    reuseExistingServer: false,
  },
});
