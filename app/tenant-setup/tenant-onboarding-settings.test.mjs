import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = p => readFileSync(new URL(p, import.meta.url), 'utf8');
const form = read('./TenantOnboardingSettings.tsx');
const route = read('./[slug]/page.tsx');

test('draft setup is independent of TCM UI and RPC contracts', () => {
  assert.match(route, /import TenantOnboardingSettings/);
  assert.doesNotMatch(route, /AdminSettingsPage|admin\/settings/);
  assert.match(form, /rpc\("admin_get_tenant_public_settings_v1"/);
  assert.match(form, /rpc\("admin_update_tenant_public_settings_v1"/);
  assert.doesNotMatch(form, /tenant_content_v1|pricing_items|about_offer|about_audience|public_map_url/);
});

test('setup retains independent server gate and optimistic concurrency', () => {
  assert.match(route, /auth.getUser\(\)/);
  assert.match(route, /admin_get_tenant_public_settings_v1/);
  assert.match(route, /notFound\(\)/);
  assert.match(form, /p_expected_updated_at:settings.updated_at/);
  assert.doesNotMatch(form + route, /profiles\.role|SERVICE_ROLE|is_platform_admin/);
});

test('setup preserves plan-limited visibility without plan/lifecycle mutation', () => {
  assert.match(form, /disabled=\{!entitled\}/);
  assert.doesNotMatch(form, /platform_set_tenant|tenant_plan_assignments|p_tenant_id/);
  assert.match(form, /feature_access/);
});
