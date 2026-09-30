import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

const sql=readFileSync(new URL('../../supabase/migrations/20261025100000_add_owned_confirmation_readers.sql',import.meta.url),'utf8');
for(const [kind,path,resource] of [
  ['event','../../app/api/send-event-registration-confirmation/route.ts','registration'],
  ['booking','../../app/api/send-reservation-confirmation/route.ts','reservation'],
]) {
  test(`${kind} confirmation uses only owner-bound resource reader`,()=>{
    const route=readFileSync(new URL(path,import.meta.url),'utf8');
    assert.match(route,new RegExp(`rpc\\("read_owned_${kind}_confirmation_v1", \\{ p_${resource}_id: ${resource}Id \\}\\)`));
    assert.doesNotMatch(route,/\.from\(/);
    assert.match(route,/deliverConfirmationEmail/);
    assert.match(route,/prepare_confirmation_email/);
    assert.match(route,/complete_confirmation_email/);
  });
  test(`${kind} reader has narrow authenticated ACL`,()=>{
    assert.ok(sql.includes(`revoke all on function public.read_owned_${kind}_confirmation_v1(uuid) from public, anon, authenticated, service_role;`));
    assert.ok(sql.includes(`grant execute on function public.read_owned_${kind}_confirmation_v1(uuid) to authenticated;`));
    assert.ok(sql.includes(`alter function public.read_owned_${kind}_confirmation_v1(uuid) owner to postgres;`));
  });
}
test('migration does not widen RLS or change singleton/public helpers',()=>{
  assert.doesNotMatch(sql,/create\s+policy|alter\s+policy|drop\s+policy|is_active_public_tenant_v1|profiles\.role|grant\s+select/i);
  assert.equal((sql.match(/r\.user_id = auth\.uid\(\)/g)||[]).length,2);
  assert.equal((sql.match(/set search_path = pg_catalog, public, pg_temp/g)||[]).length,2);
  assert.match(sql,/e\.tenant_id = r\.tenant_id/);
  assert.match(sql,/l\.tenant_id = r\.tenant_id/);
  assert.match(sql,/e\.cancelled_at is null/);
});
