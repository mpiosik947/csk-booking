import { defineConfig, devices } from '@playwright/test';
export default defineConfig({testDir:'./e2e',testMatch:['instructor-workflow.spec.ts','attendance-export.spec.ts'],workers:1,
  outputDir:'../test-results/instructor-browser/screenshots',reporter:'list',
  use:{...devices['Desktop Chrome']}});
