import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: ".", testMatch: "public-test-mode.local.spec.mjs", workers: 1, retries: 0,
  timeout: 60000, expect: { timeout: 15000 },
  use: { baseURL: "https://127.0.0.1:3108", ignoreHTTPSErrors: true, screenshot: "only-on-failure" },
});
