import {defineConfig} from '@playwright/test';
export default defineConfig({testDir:'.',testMatch:'platform-draft-configuration.local.spec.mjs',workers:1,retries:0,timeout:180000,expect:{timeout:15000},use:{actionTimeout:15000,baseURL:'https://127.0.0.1:3108',ignoreHTTPSErrors:true,screenshot:'only-on-failure'}});
