import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const platform = read('supabase/migrations/20261009100000_add_platform_tenant_onboarding.sql');
const continuity = read('supabase/migrations/20261009110000_add_tenant_continuity.sql');

test('platform role is explicitly provisioned and never inferred from profile role', () => {
  assert.match(platform, /create table public\.platform_admins/);
  assert.doesNotMatch(platform, /insert into public\.platform_admins|profiles\.role|raw_user_meta_data/);
  assert.match(platform, /if not public\.is_platform_admin_v1\(\)/);
});
test('creation is draft/private with no implicit plan and no rename path', () => {
  const create = platform.split('create function public.platform_create_tenant_v1')[1].split('create function')[0];
  assert.match(create, /'dormant'/); assert.match(create, /false,false,false,false/);
  assert.doesNotMatch(create, /tenant_plan_assignments|current_full_v1|booking_only_v1/);
  assert.doesNotMatch(platform, /set slug\s*=|set public_slug\s*=/i);
});
test('initial admin grant is draft-only and refuses an existing admin', () => {
  assert.match(platform, /Initial admin assignment requires draft tenant/);
  assert.match(platform, /Initial admin already assigned/);
  assert.doesNotMatch(platform, /update public\.profiles/);
});
test('platform page uses server-side authority and no service key', () => {
  assert.match(read('app/platform-admin/page.tsx'), /await requirePlatformAdmin\(\)/);
  assert.match(read('lib/server/platform-admin.ts'), /auth.getUser\(\)/);
  assert.match(read('lib/server/platform-admin.ts'), /is_platform_admin_v1/);
  assert.doesNotMatch(read('app/platform-admin/PlatformTenants.tsx'), /SERVICE_ROLE|profiles\.role/);
});
test('external settlement is an idempotent record, not a charge or unpaid toggle', () => {
  assert.match(continuity, /unique\(tenant_id,idempotency_key\)/);
  assert.match(continuity, /Idempotency key conflicts/);
  assert.doesNotMatch(continuity, /set payment_status\s*=/i);
  assert.match(read('app/continuity/ContinuityPanel.tsx'), /To nie wykonuje zwrotu ani płatności/);
});
test('continuity has no promotion side effect or platform authority', () => {
  assert.doesNotMatch(continuity, /is_platform_admin|prepare_event_reserve_promotions|promoteEventReserve/);
  assert.match(continuity, /m.status='active'/);
  assert.match(continuity, /t.status in \('active','suspended'\)/);
});
test('private preview is independently authorized and cannot publish', () => {
  const preview = read('supabase/migrations/20261009120000_add_private_tenant_setup.sql');
  assert.match(preview, /if not public\.is_platform_admin_v1\(\)/);
  assert.doesNotMatch(preview, /set is_public\s*=/i);
  assert.match(read('app/platform-admin/tenants/[id]/preview/page.tsx'), /requirePlatformAdmin/);
});
test('new routes contain no implicit CSK authority', () => {
  for (const file of ['app/platform-admin/PlatformTenants.tsx','app/continuity/ContinuityPanel.tsx','lib/server/platform-admin.ts'])
    assert.doesNotMatch(read(file), /first.active|['"]csk['"]|profiles\.role/);
});
