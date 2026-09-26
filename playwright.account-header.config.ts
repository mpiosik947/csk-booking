import { defineConfig } from "@playwright/test";
import branding from "./playwright.branding.config";
export default defineConfig({ ...branding, testMatch: "global-account-header.spec.ts" });
