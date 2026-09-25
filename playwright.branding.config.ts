import { defineConfig } from "@playwright/test";
import { getLocalSupabaseTestEnvironment } from "./tests/e2e/local-supabase";
const local = getLocalSupabaseTestEnvironment();
export default defineConfig({
  testDir: "./tests/e2e",
  testMatch: "platform-branding.spec.ts",
  workers: 1,
  reporter: "list",
  use: { baseURL: "http://127.0.0.1:3101", screenshot: "only-on-failure" },
  webServer: {
    command: "npm.cmd run start -- --hostname 127.0.0.1 --port 3101",
    url: "http://127.0.0.1:3101/login",
    reuseExistingServer: false,
    env: { NEXT_PUBLIC_SUPABASE_URL: local.supabaseUrl, NEXT_PUBLIC_SUPABASE_ANON_KEY: local.anonKey },
  },
});
