import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const sql = readFileSync(new URL('../supabase/migrations/20261030100000_add_my_dormant_admin_tenants_reader.sql', import.meta.url), 'utf8');
test('discovery has no caller-selected authority or optional PII surface', () => {
  assert.match(sql, /get_my_dormant_admin_tenants_v1\(\)/);
  assert.match(sql, /returns table \(tenant_id uuid, tenant_slug text, display_name text, city text, tenant_status text\)/);
  assert.doesNotMatch(sql, /auth\.users|public\.profiles|platform_admin/);
  assert.match(sql, /v_subject uuid := auth\.uid\(\)/);
  assert.match(sql, /errcode='42501'/);
});
test('discovery grants only function execute and bounds without truncation', () => {
  assert.match(sql, /grant execute on function public\.get_my_dormant_admin_tenants_v1\(\) to authenticated/);
  assert.doesNotMatch(sql, /grant select|create table|create policy|alter table|\blimit\b/i);
  assert.match(sql, /> 100/);
  assert.match(sql, /errcode='54000'/);
});
