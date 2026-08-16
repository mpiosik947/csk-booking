import { defineConfig, devices } from "@playwright/test";
import { getLocalSupabaseTestEnvironment } from "./tests/e2e/local-supabase";

const localSupabase = getLocalSupabaseTestEnvironment();

export default defineConfig({
  testDir: "./tests/e2e",
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 60_000,
  expect: { timeout: 10_000 },
  reporter: "list",
  outputDir: "test-results",
  use: {
    baseURL: "http://127.0.0.1:3000",
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    video: "off",
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
  webServer: {
    command: "npm.cmd run dev -- --hostname 127.0.0.1 --port 3000",
    url: "http://127.0.0.1:3000/login",
    reuseExistingServer: true,
    timeout: 120_000,
    env: {
      NEXT_PUBLIC_SUPABASE_URL: localSupabase.supabaseUrl,
      NEXT_PUBLIC_SUPABASE_ANON_KEY: localSupabase.anonKey,
      SUPABASE_SERVICE_ROLE_KEY: localSupabase.serviceRoleKey,
    },
  },
});
