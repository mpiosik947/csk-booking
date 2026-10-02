import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const sql=readFileSync(new URL('../supabase/migrations/20261028100000_add_platform_onboarding_safe_readers.sql',import.meta.url),'utf8');
test('safe readers expose two explicit postgres-owned authenticated wrappers',()=>{
 assert.equal((sql.match(/create function public\./g)||[]).length,2);
 assert.equal((sql.match(/stable security definer/g)||[]).length,2);
 assert.equal((sql.match(/if not public\.is_platform_admin_v1\(\)/g)||[]).length,2);
 assert.equal((sql.match(/owner to postgres/g)||[]).length,2);
 assert.equal((sql.match(/set search_path='pg_catalog','public','pg_temp'/g)||[]).length,2);
 assert.equal((sql.match(/from public,anon,authenticated,service_role/g)||[]).length,2);
 assert.equal((sql.match(/to authenticated;/g)||[]).length,2);
});
test('catalog is dynamic, active, deterministic and does not expose assignments',()=>{
 const catalog=sql.split('create function public.platform_get_tenant_onboarding_detail_v1')[0];
 assert.match(catalog,/where p.status='active'/);
 assert.match(catalog,/pf.plan_id=p.id and f.active/);
 assert.match(catalog,/order by f.feature_key/);assert.match(catalog,/order by p.plan_key/);
 assert.doesNotMatch(catalog,/booking_only_v1|current_full_v1|tenant_plan_assignments|auth.users/);
});
test('detail resolves only selected tenant active admins and delegates readiness',()=>{
 const detail=sql.split('create function public.platform_get_tenant_onboarding_detail_v1')[1];
 assert.match(detail,/where t.id=p_tenant_id/);
 assert.match(detail,/m.tenant_id=t.id and m.role='admin' and m.status='active'/);
 assert.match(detail,/jsonb_build_object\('user_id',m.user_id,'email',u.email\)/);
 assert.match(detail,/order by m.user_id/);
 assert.match(detail,/public.tenant_onboarding_readiness_core_v2\(t.id\)/);
 assert.doesNotMatch(detail,/\bpublic\.profiles\b|reservations|event_registrations|audit_logs|admin_note/);
});
test('readers add no mutation, table ACL, policy, trigger or fallback path',()=>{
 assert.doesNotMatch(sql,/\b(insert|update|delete)\s+(into|from|public\.)|create table|alter table|create policy|alter policy|create trigger|select \*|to_jsonb\(/i);
 assert.doesNotMatch(sql,/profiles.role|raw_user_meta_data|platform_create_tenant_v1|['"]csk['"]/);
});
