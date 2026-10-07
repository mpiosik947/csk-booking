import {defineConfig} from '@playwright/test';
export default defineConfig({testDir:'.',testMatch:'platform-management.spec.ts',workers:1,fullyParallel:false,retries:0,timeout:30000,expect:{timeout:5000},reporter:'list',outputDir:'../../../pam-1e-ui/browser-results',use:{browserName:'chromium',trace:'retain-on-failure',screenshot:'only-on-failure',video:'off'}});
