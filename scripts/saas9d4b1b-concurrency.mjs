import { randomUUID } from "node:crypto";
import { spawn, spawnSync } from "node:child_process";

const container = "supabase_db_csk-booking";
const tenant = "c5c00000-0000-4000-8000-000000000001";
// Reuse the same local race fixture for the C2-D versioned tenant contracts.
const selectedTenant = process.argv.includes("--selected-tenant");
const runId = randomUUID().replaceAll("-", "");
const adminA = randomUUID();
const adminB = randomUUID();
const customer = randomUUID();

function psqlSync(sql) {
  const result = spawnSync(
    "docker",
    ["exec", "-i", container, "psql", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres", "-At"],
    { input: sql, encoding: "utf8" },
  );
  if (result.status !== 0) throw new Error(result.stderr || result.stdout);
  return result.stdout.trim();
}

function roleCall(actor, target) {
  const sql = `begin;
select pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object('sub','${actor}','role','authenticated')::text,true);
select pg_catalog.set_config('request.jwt.claim.sub','${actor}',true);
set local role authenticated;
select public.${selectedTenant ? "admin_set_user_role_v2" : "admin_set_user_role_v1"}(${selectedTenant ? `'${tenant}'::uuid,` : ""}'${target}'::uuid,'user');
commit;`;
  return new Promise((resolve, reject) => {
    const child = spawn("docker", ["exec", "-i", container, "psql", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres", "-At"]);
    let output = "";
    let error = "";
    child.stdout.on("data", (chunk) => (output += chunk));
    child.stderr.on("data", (chunk) => (error += chunk));
    child.on("close", (code) => (code === 0 ? resolve(output) : reject(new Error(error || output))));
    child.stdin.end(sql);
  });
}

function profileCall(actor, expression) {
  const sql = `begin;
select pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object('sub','${actor}','role','authenticated')::text,true);
select pg_catalog.set_config('request.jwt.claim.sub','${actor}',true);
set local role authenticated;
select ${expression};
commit;`;
  return new Promise((resolve, reject) => {
    const child = spawn("docker", ["exec", "-i", container, "psql", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres", "-At"]);
    let output = "";
    let error = "";
    child.stdout.on("data", (chunk) => (output += chunk));
    child.stderr.on("data", (chunk) => (error += chunk));
    child.on("close", (code) => (code === 0 ? resolve(output) : reject(new Error(error || output))));
    child.stdin.end(sql);
  });
}

const setup = `
insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values
('${adminA}','00000000-0000-0000-0000-000000000000','authenticated','authenticated','saas9d4b1b-a-${runId}@example.invalid','',now(),'{}','{}',now(),now()),
('${adminB}','00000000-0000-0000-0000-000000000000','authenticated','authenticated','saas9d4b1b-b-${runId}@example.invalid','',now(),'{}','{}',now(),now()),
('${customer}','00000000-0000-0000-0000-000000000000','authenticated','authenticated','saas9d4b1b-customer-${runId}@example.invalid','',now(),'{}','{}',now(),now());
insert into public.profiles(user_id,role,first_name,last_name,full_name,email)
values
('${adminA}','admin','[TEST]','Concurrency A','[TEST][SAAS-9D-4B-1B] Concurrency A','saas9d4b1b-a-${runId}@example.invalid'),
('${adminB}','admin','[TEST]','Concurrency B','[TEST][SAAS-9D-4B-1B] Concurrency B','saas9d4b1b-b-${runId}@example.invalid'),
('${customer}','user','[TEST]','Concurrent Customer','[TEST][SAAS-9D-4B-1B] Concurrent Customer','saas9d4b1b-customer-${runId}@example.invalid');
`;
const cleanup = `
delete from public.audit_logs where actor_user_id in('${adminA}'::uuid,'${adminB}'::uuid) or target_id in('${adminA}'::uuid,'${adminB}'::uuid,'${customer}'::uuid);
delete from public.tenant_memberships where user_id in('${adminA}'::uuid,'${adminB}'::uuid,'${customer}'::uuid);
delete from public.profiles where user_id in('${adminA}'::uuid,'${adminB}'::uuid,'${customer}'::uuid);
delete from auth.users where id in('${adminA}'::uuid,'${adminB}'::uuid,'${customer}'::uuid);
`;

try {
  psqlSync(setup);
  const deadlocksBefore = Number(psqlSync("select deadlocks from pg_stat_database where datname=current_database();"));
  const results = await Promise.all([roleCall(adminA, adminB), roleCall(adminB, adminA)]);
  const activeAdmins = Number(psqlSync(`select count(*) from public.tenant_memberships where tenant_id='${tenant}' and status='active' and role='admin' and user_id in('${adminA}'::uuid,'${adminB}'::uuid);`));
  const changed = Number(psqlSync(`select count(*) from public.audit_logs where action='tenant_user_role_updated' and target_id in('${adminA}'::uuid,'${adminB}'::uuid);`));
  const deadlocksAfter = Number(psqlSync("select deadlocks from pg_stat_database where datname=current_database();"));
  if (activeAdmins !== 1 || changed !== 1 || deadlocksAfter !== deadlocksBefore) {
    throw new Error(`invariant failure: activeAdmins=${activeAdmins}, changedAudits=${changed}, deadlocks=${deadlocksAfter - deadlocksBefore}, results=${results.join(" | ")}`);
  }
  console.log("SAAS9D4B1B_CONCURRENCY_PASS active_admins=1 changed_audits=1 deadlocks=0 contamination=0");
  const remainingAdmin = psqlSync(`select user_id from public.tenant_memberships where tenant_id='${tenant}' and status='active' and role='admin' and user_id in('${adminA}'::uuid,'${adminB}'::uuid);`);
  await Promise.all([
    profileCall(remainingAdmin, `public.${selectedTenant ? "update_tenant_profile_identity_v2" : "update_profile_identity"}(${selectedTenant ? `'${tenant}'::uuid,` : ""}'${customer}'::uuid,'Concurrent','Identity')`),
    profileCall(remainingAdmin, `public.${selectedTenant ? "update_tenant_profile_contact_details_v2" : "update_profile_contact_details"}(${selectedTenant ? `'${tenant}'::uuid,` : ""}'${customer}'::uuid,'555000111','00-001','Warszawa','Concurrent','1',null)`),
  ]);
  const profileState = psqlSync(`select (first_name='Concurrent' and last_name='Identity' and phone='555000111')::int from public.profiles where user_id='${customer}'::uuid;`);
  const profileAudits = Number(psqlSync(`select count(*) from public.audit_logs where target_id='${customer}'::uuid and action in('tenant_user_identity_updated','tenant_user_contact_updated');`));
  const deadlocksFinal = Number(psqlSync("select deadlocks from pg_stat_database where datname=current_database();"));
  if (profileState !== "1" || profileAudits !== 2 || deadlocksFinal !== deadlocksBefore) {
    throw new Error(`profile concurrency failure: state=${profileState}, audits=${profileAudits}, deadlocks=${deadlocksFinal - deadlocksBefore}`);
  }
  console.log("SAAS9D4B1B_PROFILE_CONCURRENCY_PASS identity=1 contact=1 audits=2 deadlocks=0 lost_updates=0");
} finally {
  psqlSync(cleanup);
  const remaining = Number(psqlSync(`select (select count(*) from auth.users where id in('${adminA}'::uuid,'${adminB}'::uuid,'${customer}'::uuid))+(select count(*) from public.profiles where user_id in('${adminA}'::uuid,'${adminB}'::uuid,'${customer}'::uuid))+(select count(*) from public.tenant_memberships where user_id in('${adminA}'::uuid,'${adminB}'::uuid,'${customer}'::uuid))+(select count(*) from public.audit_logs where actor_user_id in('${adminA}'::uuid,'${adminB}'::uuid) or target_id in('${adminA}'::uuid,'${adminB}'::uuid,'${customer}'::uuid));`));
  if (remaining !== 0) throw new Error(`fixture cleanup failed: ${remaining}`);
  console.log("SAAS9D4B1B_CONCURRENCY_FIXTURE_CLEANUP=0");
}
