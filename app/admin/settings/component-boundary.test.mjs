import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
const read = path => readFileSync(new URL(path, import.meta.url), "utf8");

test("settings page has no custom tenant prop or implicit tenant selection", () => {
  const page = read("./page.tsx");
  assert.match(page, /export default function AdminSettingsPage\(\)/);
  assert.match(page, /notFound\(\)/);
  assert.doesNotMatch(page, /tenantSlug|supabase|profiles|csk|searchParams/);
});

test("scoped settings route imports a component, not a page entrypoint", () => {
  const shell = read("../../t/[slug]/[...path]/page.tsx");
  assert.match(shell, /admin\/settings\/TenantAdminSettings/);
  assert.match(shell, /TenantAdminSettings tenantSlug=\{slug\}/);
  assert.doesNotMatch(shell, /admin\/settings\/page/);
  assert.match(read("./TenantAdminSettings.tsx"), /tenantSlug: string/);
});

test("draft setup remains independent of full settings and TCM", () => {
  const route = read("../../tenant-setup/[slug]/page.tsx");
  const form = read("../../tenant-setup/TenantOnboardingSettings.tsx");
  assert.match(route, /TenantOnboardingSettings/);
  assert.match(form, /admin_get_tenant_public_settings_v1/);
  assert.match(form, /admin_update_tenant_public_settings_v1/);
  assert.doesNotMatch(route + form, /admin_get_tenant_content_v1|admin_update_tenant_content_v1|admin\/settings/);
});
