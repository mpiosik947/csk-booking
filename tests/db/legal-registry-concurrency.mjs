// Real two-session lock tests. Accepts only a disposable local canonical DB.
import fs from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import { spawn, spawnSync } from "node:child_process";

const [baseline, output] = process.argv.slice(2);
assert.match(baseline ?? "", /^sbr3_[a-f0-9]{16}$/);
assert.ok(output);
const container = "supabase_db_csk-booking";
const db = "legal_race_" + randomBytes(8).toString("hex");
const children = new Set();
function sql(target, query) {
  assert.ok([baseline, db, "postgres"].includes(target));
  const r = spawnSync("docker", ["exec", "-i", container, "psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", target], { input: query, encoding: "utf8", windowsHide: true });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout.trim();
}
const quote = value => "'" + String(value).replaceAll("'", "''") + "'";
const actor = id => `select set_config('request.jwt.claim.sub',${quote(id)},true); set local role authenticated;`;
const bundle = id => JSON.parse(sql(db, `begin;${actor(id)} select jsonb_agg(jsonb_build_object('document_version_id',x->'document_version_id','content_hash',x->'content_hash','kind',x->'kind')) from jsonb_array_elements(public.get_my_legal_requirements_v1()->'required_documents') x; rollback;`).split(/\r?\n/).at(-1));
const accept = (id, request, presented) => `${actor(id)}select public.accept_my_account_legal_v1(${quote(request)},${quote(JSON.stringify(presented))},'{"acceptance":true,"acknowledgement":true,"self_declaration":true}');`;
const publish = (version, expected) => `select app_private.legal_publish_version_core_v1(${quote(version)},${quote(expected)});`;
function session(label, query, hold) {
  const name = db + "_" + label;
  const p = spawn("docker", ["exec", "-i", container, "psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=verbose", "-U", "postgres", "-d", db], { windowsHide: true });
  children.add(p);
  const state = { p, name, out: "", err: "", done: false };
  p.stdout.on("data", chunk => state.out += chunk);
  p.stderr.on("data", chunk => state.err += chunk);
  state.exit = new Promise(resolve => p.on("exit", code => { state.done = true; children.delete(p); resolve(code); }));
  p.stdin.write(`set application_name=${quote(name)};begin;set local statement_timeout='15s';${query}\nselect 'HELD';\n`);
  if (!hold) p.stdin.end("commit;\n");
  return state;
}
async function waitFor(check, label) {
  const deadline = Date.now() + 10000;
  while (!check()) {
    assert.ok(Date.now() < deadline, label);
    await new Promise(resolve => setTimeout(resolve, 40));
  }
}
const results = [];
async function race(label, firstQuery, secondQuery, secondState) {
  const first = session(label + "_first", firstQuery, true);
  await waitFor(() => first.out.includes("HELD") || first.done, "first lock holder");
  assert.equal(first.done, false, first.err);
  const second = session(label + "_second", secondQuery, false);
  await waitFor(() => second.done || sql(db, `select count(*) from pg_stat_activity where application_name=${quote(second.name)} and wait_event_type='Lock';`) === "1", "contender must block");
  assert.equal(second.done, false, "Contender bypassed expected lock: " + second.err);
  first.p.stdin.end("commit;\n");
  assert.equal(await first.exit, 0, first.err);
  const code = await second.exit;
  if (secondState === "00000") assert.equal(code, 0, second.err);
  else { assert.notEqual(code, 0); assert.ok(second.err.includes(secondState), second.err); }
  results.push({ label, observedLockWait: true, first: "00000", second: secondState, pass: true });
}

let created = false;
const report = { pass: false, results, productionWrite: false };
try {
  assert.equal(sql(baseline, "select max(version) from supabase_migrations.schema_migrations;"), "20261106100000");
  assert.equal(sql(baseline, "select count(*) from auth.users;"), "0");
  sql("postgres", `create database ${db} template ${baseline};`); created = true;
  const helpers = fs.readFileSync("supabase/tests/20261106100000_legal_registry_foundation_test.sql", "utf8").split("do $tests$")[0];
  const ids = [randomUUID(), randomUUID(), randomUUID()];
  const setup = `${helpers}
  insert into auth.users(id,email,email_confirmed_at,is_anonymous) select id,id||'@legal-race.invalid',now(),false from unnest(array[${ids.map(id => quote(id) + "::uuid").join(",")}])id;
  insert into public.profiles(id,user_id,email,role) select id,id,email,'user' from auth.users on conflict(user_id) do nothing;
  create temporary table fixture(label text,id uuid);
  do $seed$ declare kind text; doc uuid; v uuid; begin
  foreach kind in array array['platform_terms','platform_privacy_notice','adult_self_declaration'] loop
   doc:=gen_random_uuid();insert into public.legal_documents(id,document_type,scope_type) values(doc,kind,'platform');
   v:=pg_temp.version(doc,'v1');perform app_private.legal_publish_version_core_v1(v,null);
   if kind='platform_terms' then
    insert into fixture values('v1',v),('v2',pg_temp.version(doc,'v2')),('v3',pg_temp.version(doc,'v3')),('v4',pg_temp.version(doc,'v4')),('v5',pg_temp.version(doc,'v5'));
   end if;
  end loop;end;$seed$;
  select jsonb_object_agg(label,id) from fixture;commit;`;
  const versions = JSON.parse(sql(db, setup).split(/\r?\n/).find(line => line.startsWith("{")));
  const request = randomUUID(), old = bundle(ids[0]);
  await race("duplicate_account", accept(ids[0], request, old), accept(ids[0], request, old), "00000");
  assert.equal(sql(db, "select count(*) from app_private.legal_actions;"), "1");
  await race("publication_before_submit", publish(versions.v2, versions.v1), accept(ids[1], randomUUID(), old), "PT409");
  assert.equal(sql(db, `select count(*) from app_private.legal_subjects where user_id=${quote(ids[1])};`), "0");
  await race("submit_before_publication", accept(ids[1], randomUUID(), bundle(ids[1])), publish(versions.v3, versions.v2), "00000");
  assert.equal(sql(db, `select count(*) from app_private.legal_acceptances where document_version_id=${quote(versions.v2)};`), "1");
  await race("two_publishers", publish(versions.v4, versions.v3), publish(versions.v5, versions.v3), "PT409");
  await race("accept_then_anonymize", accept(ids[2], randomUUID(), bundle(ids[2])), `${actor(ids[2])}select public.anonymize_my_account_v1();`, "00000");
  assert.equal(sql(db, `select count(*) from app_private.legal_subjects where user_id=${quote(ids[2])};`), "0");
  assert.equal(sql(db, "select count(*) from app_private.legal_acceptances;"), "9");
  report.pass = true;
} finally {
  for (const p of children) p.kill();
  if (created) sql("postgres", `drop database ${db} with (force);`);
  report.scratchDatabasesRemaining = Number(sql("postgres", `select count(*) from pg_database where datname=${quote(db)};`));
  assert.equal(report.scratchDatabasesRemaining, 0);
  fs.mkdirSync(output, { recursive: true });
  fs.writeFileSync(path.join(output, "legal-concurrency.json"), JSON.stringify(report, null, 2));
}
console.log(JSON.stringify(report));
