import base from "./playwright.config";
import { defineConfig } from "@playwright/test";

export default defineConfig({
  ...base,
  use: { ...base.use, baseURL: "http://127.0.0.1:3001" },
  webServer: {
    ...base.webServer,
    command: "npm.cmd run start -- --hostname 127.0.0.1 --port 3001",
    url: "http://127.0.0.1:3001/login",
    reuseExistingServer: false,
    timeout: 120000,
  },
});
