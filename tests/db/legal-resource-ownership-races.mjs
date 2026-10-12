// Real sessions, synthetic data, no production connection or runtime RPC changes.
import fs from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import { sql, quote, session, waitFor, cleanup, localDatabase } from "./legal-local-harness.mjs";

const [baseline, output] = process.argv.slice(2);
localDatabase(baseline); assert.ok(output);
const db = "legal_ownership_" + randomBytes(8).toString("hex");
const report = { pass: false, cases: [], isolationLevels: ["read committed", "repeatable read", "serializable"], deadlocks: 0, unexpectedTimeouts: 0, productionWrite: false };
async function race(label, firstQuery, secondQuery, expected, isolation = "read committed") {
  const first = session(db, "owner_first"), second = session(db, "owner_second");
  await Promise.all([first.ready, second.ready]);
  await first.query(`begin isolation level ${isolation}; ${firstQuery}`);
  let done = false;
  const contender = second.query(`begin isolation level ${isolation}; ${secondQuery} commit;`).then(value => ({ value, state: "00000" }), error => ({ error: error.message, state: error.message.match(/ERROR:\s+([A-Z0-9]{5}):/)?.[1] })).then(value => { done = true; return value; });
  await waitFor(() => done || sql(db, `select count(*) from pg_stat_activity where application_name=${quote(second.name)} and wait_event_type='Lock';`) === "1", label + " must wait on first session");
  assert.equal(done, false, "Expected real overlap: " + label);
  await first.query("commit;");
  const result = await contender;
  assert.equal(result.state, expected, label + ": " + JSON.stringify(result));
  await Promise.all([first.close(), second.close()]);
  report.cases.push({ label, isolation, first: "00000", second: expected, observedLockWait: true, pass: true });
}
try {
  assert.equal(sql(baseline, "select max(version) from supabase_migrations.schema_migrations;"), "20261106100000");
  assert.equal(sql(baseline, "select count(*) from auth.users;"), "0");
  sql("postgres", `create database ${db} template ${baseline};`);
  const prefix = fs.readFileSync("supabase/tests/20261106110000_legal_resource_ownership_test.sql", "utf8").split("-- LEGAL_OWNERSHIP_TESTS:")[0];
  sql(db, prefix + "\ncommit;");
  const fixtures = JSON.parse(sql(db, "select jsonb_object_agg(side,to_jsonb(f)) from legal_test.fixture f;"));
  const columns = Object.fromEntries(["reservations", "event_registrations"].map(table => [table, sql(db, `select string_agg(quote_ident(attname),',' order by attnum) from pg_attribute where attrelid='public.${table}'::regclass and attnum>0 and not attisdropped and attgenerated='';`)]));
  function freshResource(table, side, id, newId = randomUUID()) {
    return `do $atomic$ declare copy public.${table}; new_id uuid:=${quote(newId)}; begin
      select * into copy from public.${table} where id=${quote(id)};
      copy.id:=new_id;
      ${table === "reservations" ? "copy.creation_request_id:=gen_random_uuid(); copy.check_in_token:=gen_random_uuid(); copy.reservation_status:='cancelled';" : "copy.registration_status:='cancelled';"}
      insert into public.${table} (${columns[table]}) select ${columns[table]} from jsonb_populate_record(null::public.${table},to_jsonb(copy));
      update legal_test.fixture set ${table === "reservations" ? "reservation" : "registration"}=new_id where side=${quote(side)};
    end;$atomic$;`;
  }
  for (const isolation of report.isolationLevels) for (const side of ["A", "B"]) for (const table of ["reservations", "event_registrations"]) {
    sql(db, freshResource(table, side, table === "reservations" ? fixtures[side].reservation : fixtures[side].registration));
    fixtures[side] = JSON.parse(sql(db, `select to_jsonb(f) from legal_test.fixture f where side=${quote(side)};`));
    const f = fixtures[side], other = fixtures[side === "A" ? "B" : "A"];
    const kind = table === "reservations" ? "booking" : "event_registration";
    const id = table === "reservations" ? f.reservation : f.registration;
    const reparent = `set local role service_role; update public.${table} set tenant_id=${quote(other.tenant)} where id=${quote(id)};`;
    // A fresh resource makes every scenario a first-evidence race.
    const evidence = `select legal_test.evidence(${quote(side)},${quote(kind)});`;
    await race(`${side}/${table}/evidence-vs-reparent`, evidence, reparent, "23514", isolation);
    // Evidence from the successful first session is now present; parent remains original.
    assert.equal(sql(db, `select tenant_id from public.${table} where id=${quote(id)};`), f.tenant);
    // The future atomic core is simulated locally, without adding a runtime RPC.
    // A concurrent session cannot see the new row before commit, and cannot reparent
    // it after commit. Test both visibility boundaries using its known future UUID.
    const newId = randomUUID(), creator = session(db, "atomic_creator"), attacker = session(db, "atomic_attacker");
    await Promise.all([creator.ready, attacker.ready]);
    await creator.query(`begin isolation level ${isolation};${freshResource(table, side, id, newId)} ${evidence}`);
    const attempt = `update public.${table} set tenant_id=${quote(other.tenant)} where id=${quote(newId)}`;
    const invisible = await attacker.query(`begin isolation level ${isolation};set local role service_role;with changed as (${attempt} returning id) select count(*) from changed;commit;`);
    assert.equal(invisible, "0", "An uncommitted resource must not be visible");
    await creator.query("commit;");
    const denied = await attacker.query(`begin;set local role service_role;${attempt};commit;`).then(() => "00000", error => error.message.match(/ERROR:\s+([A-Z0-9]{5}):/)?.[1]);
    assert.equal(denied, "23514");
    await Promise.all([creator.close(), attacker.close()]);
    report.cases.push({ label: `${side}/${table}/atomic-create-and-evidence-vs-reparent`, isolation, beforeCommitRowsAffected: 0, afterCommitState: denied, pass: true });
    fixtures[side] = JSON.parse(sql(db, `select to_jsonb(f) from legal_test.fixture f where side=${quote(side)};`));
    const mutable = table === "reservations" ? "admin_note='Synthetic concurrent update'" : "promotion_last_attempt_at=clock_timestamp()";
    const normal = `set local role service_role;update public.${table} set ${mutable} where id=${quote(id)};`;
    // PostgreSQL intentionally rejects competing RR/serializable writes with 40001;
    // ordinary app writes are RC and must serialize successfully, with no ownership error.
    await race(`${side}/${table}/normal-updates`, normal, normal, "00000");
  }
  // Parent writer first: a caught reparent denial does not prevent a later normal
  // update; first-evidence insertion waits for that write and then remains coherent.
  for (const side of ["A", "B"]) for (const table of ["reservations", "event_registrations"]) {
    sql(db, freshResource(table, side, table === "reservations" ? fixtures[side].reservation : fixtures[side].registration));
    fixtures[side] = JSON.parse(sql(db, `select to_jsonb(f) from legal_test.fixture f where side=${quote(side)};`));
    const f = fixtures[side], other = fixtures[side === "A" ? "B" : "A"], id = table === "reservations" ? f.reservation : f.registration;
    const q = `update public.${table} set tenant_id=${quote(other.tenant)} where id=${quote(id)}`;
    await race(`${side}/${table}/denied-reparent-then-normal-write-vs-first-evidence`,
      `select legal_test.ok('denied first',legal_test.try_as('service_role',${quote(q)})->>'state'='23514');
       update public.${table} set tenant_id=tenant_id where id=${quote(id)};`,
      `select legal_test.evidence(${quote(side)},${quote(table === "reservations" ? "booking" : "event_registration")});`, "00000");
  }
  // Separate tenants create complete evidence simultaneously without a shared tenant lock.
  for (const side of ["A", "B"]) sql(db, freshResource("reservations", side, fixtures[side].reservation));
  const a = session(db, "tenant_a"), b = session(db, "tenant_b");
  await Promise.all([a.ready, b.ready]);
  await Promise.all([a.query("begin; select legal_test.evidence('A','booking');"), b.query("begin; select legal_test.evidence('B','booking');")]);
  await Promise.all([a.query("commit;"), b.query("commit;")]);
  await Promise.all([a.close(), b.close()]);
  assert.equal(sql(db, "select count(*) from app_private.legal_actions a left join public.reservations r on r.id=a.reservation_id left join public.event_registrations e on e.id=a.event_registration_id where a.tenant_id is distinct from coalesce(r.tenant_id,e.tenant_id);"), "0");
  report.cases.push({ label: "A/B independent concurrent complete evidence", pass: true });
  report.pass = true;
} finally {
  cleanup(db); report.scratchDatabasesRemaining = 0;
  fs.mkdirSync(output, { recursive: true });
  fs.writeFileSync(path.join(output, "ownership-concurrency.json"), JSON.stringify(report, null, 2));
}
console.log(JSON.stringify({ ...report, cases: report.cases.length }));
