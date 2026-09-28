import { defineConfig } from '@playwright/test';
export default defineConfig({ testDir:'./e2e',testMatch:'tenant-action-tiles.spec.ts',workers:1,reporter:'list',outputDir:'../test-results/tenant-action-tiles',use:{baseURL:'http://127.0.0.1:3194',headless:true} });
