import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { execFile, execFileSync } from 'node:child_process';
import { promisify } from 'node:util';

// Explicit local container only. No database URL, token or linked CLI accepted.
const container = 'supabase_db_csk-booking';
const context = execFileSync('docker', ['context', 'inspect', '--format', '{{.Endpoints.docker.Host}}'], { encoding: 'utf8' }).trim();
assert.match(context, /^npipe:\/\//, 'Windows local Docker engine required');
const ports = execFileSync('docker', ['port', container, '5432/tcp'], { encoding: 'utf8' });
assert.match(ports, /:54322\b/, 'Local Supabase port must be 54322');
const database = process.env.PRODUCT10E_ISOLATED_DATABASE || 'postgres';
assert.ok(database === 'postgres' || /^p10e_isolated_[0-9a-f]{16}$/.test(database), 'Explicit local database required');
const args = ['exec', container, 'psql', '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', database, '-c'];
const run = promisify(execFile);
const sql = text => execFileSync('docker', [...args, text], { encoding: 'utf8' }).trim();
const parallel = statements => Promise.all(statements.map(async text => {
  try { const { stdout } = await run('docker', [...args, text]); return { ok: true, stdout }; }
  catch (error) { return { ok: false, error: error.stderr ?? String(error) }; }
}));
const pa = randomUUID(), admin1 = randomUUID(), admin2 = randomUUID();
const prefix = `p10e-race-${randomUUID().slice(0, 8)}`;
const users = [pa, admin1, admin2];
const actor = statement => `begin; set local lock_timeout='5s'; select set_config('request.jwt.claim.sub','${pa}',true); set local role authenticated; ${statement}; commit;`;
let checks = 0;
try {
  sql(`begin; insert into auth.users(id,email,email_confirmed_at) values ${users.map(id => `('${id}','${id}@example.invalid',now())`).join(',')}; insert into public.platform_admins(user_id,status) values('${pa}','active'); commit;`);
  const create = (technical, publicSlug) => actor(`select public.platform_create_tenant_v1('Synthetic concurrency','${technical}','${publicSlug}','Testowo')`);
  const sameTechnical = await parallel([create(`${prefix}-one`, `${prefix}-pub1`), create(`${prefix}-one`, `${prefix}-pub2`)]);
  assert.equal(sameTechnical.filter(x => x.ok).length, 1); assert.match(sameTechnical.find(x => !x.ok).error, /duplicate|unique/i); checks++;
  const samePublic = await parallel([create(`${prefix}-two`, `${prefix}-pub3`), create(`${prefix}-three`, `${prefix}-pub3`)]);
  assert.equal(samePublic.filter(x => x.ok).length, 1); assert.match(samePublic.find(x => !x.ok).error, /duplicate|unique/i); checks++;
  const tenant = sql(`select id from public.tenants where slug='${prefix}-one'`); assert.match(tenant, /^[0-9a-f-]{36}$/);
  const plans = await parallel(['current_full_v1', 'booking_only_v1'].map(plan => actor(`select public.platform_set_tenant_plan_v1('${tenant}','${plan}')`)));
  assert.ok(plans.every(x => x.ok)); assert.equal(sql(`select count(*) from public.tenant_plan_assignments where tenant_id='${tenant}'`), '1'); checks++;
  const incomplete = await parallel([actor(`select public.platform_set_tenant_state_v1('${tenant}','activate')`), actor(`select public.platform_set_tenant_state_v1('${tenant}','activate')`)]);
  assert.ok(incomplete.every(x => !x.ok && /setup incomplete/i.test(x.error)));
  assert.equal(sql(`select status from public.tenants where id='${tenant}'`), 'dormant'); checks++;
  const admins = await parallel([admin1, admin2].map(id => actor(`select public.platform_assign_initial_admin_v1('${tenant}','${id}')`)));
  assert.equal(admins.filter(x => x.ok).length, 1);
  assert.match(admins.find(x => !x.ok).error, /already assigned/);
  assert.equal(sql(`select count(*) from public.tenant_memberships where tenant_id='${tenant}' and role='admin' and status='active'`), '1'); checks++;
  sql(actor(`select public.platform_set_tenant_state_v1('${tenant}','activate')`));
  sql(actor(`select public.platform_set_tenant_plan_v1('${tenant}','current_full_v1')`));
  // Suspension holds the same tenant row lock which new-obligation triggers read.
  const race = await parallel([
    actor(`select public.platform_set_tenant_state_v1('${tenant}','suspend'); select pg_sleep(0.3)`),
    `begin; select pg_sleep(0.1); select set_config('app.product10d_test_enforce','on',true);
      insert into public.events(tenant_id,title,event_date,start_time,end_time,location,price,max_participants,is_active)
      values('${tenant}','Synthetic race',current_date+7,'10:00','11:00','Testowo',0,10,true); commit;`,
  ]);
  assert.ok(race[0].ok); assert.equal(race[1].ok, false);
  assert.match(race[1].error, /New business unavailable|feature_not_available/);
  assert.equal(sql(`select count(*) from public.events where tenant_id='${tenant}'`), '0'); checks++;
  console.log(`PRODUCT-10E CONCURRENCY: ${checks}/${checks} PASS; deadlocks=0`);
} finally {
  // Exact synthetic prefix and exact user UUIDs only; no general environment cleanup.
  sql(`begin;
    delete from public.events where tenant_id in(select id from public.tenants where slug like '${prefix}-%');
    delete from public.platform_audit_logs where tenant_id in(select id from public.tenants where slug like '${prefix}-%');
    delete from public.tenant_memberships where tenant_id in(select id from public.tenants where slug like '${prefix}-%');
    delete from public.tenant_plan_assignments where tenant_id in(select id from public.tenants where slug like '${prefix}-%');
    delete from public.tenant_public_profiles where tenant_id in(select id from public.tenants where slug like '${prefix}-%');
    delete from public.tenants where slug like '${prefix}-%';
    delete from public.platform_admins where user_id='${pa}';
    delete from auth.users where id in(${users.map(id => `'${id}'`).join(',')}); commit;`);
  assert.equal(sql(`select (select count(*) from public.tenants where slug like '${prefix}-%')+(select count(*) from auth.users where id in(${users.map(id => `'${id}'`).join(',')}))`), '0');
  console.log('PRODUCT-10E CONCURRENCY FIXTURE CLEANUP: 0');
}
