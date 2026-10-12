// Exact official-runner migration under concurrent local reads/writes and a hostile lock holder.
import fs from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { randomBytes, createHash } from "node:crypto";
import { sql, quote, session, waitFor, pause, cleanup, localDatabase, container } from "./legal-local-harness.mjs";

const [baseline, outputDirectory] = process.argv.slice(2);
localDatabase(baseline); assert.ok(outputDirectory);
const output = path.resolve(outputDirectory), db = "legal_window_" + randomBytes(8).toString("hex");
const migration = "20261106100000_add_legal_registry_foundation.sql";
const bytes = fs.readFileSync("supabase/migrations/" + migration);
const cli = path.resolve("node_modules/supabase/dist/supabase.js");
const report = { pass: false, productionWrite: false, migration, sha256: createHash("sha256").update(bytes).digest("hex"), externalTransactionWrapper: false, migrationLockTimeout: "500ms", migrationStatementTimeout: "15s", workerLockTimeout: "1s", workerStatementTimeout: "5s", deadlocks: 0, unexpectedTimeouts: 0, rowsPerTable: 10002, workers: [] };
fs.mkdirSync(output, { recursive: true });
const project = fs.mkdtempSync(path.join(output, "window-project-"));
fs.mkdirSync(path.join(project, "supabase/migrations"), { recursive: true });
fs.writeFileSync(path.join(project, "supabase/config.toml"), 'project_id = "local-legal-window"\n');
for (const name of fs.readdirSync("supabase/migrations").filter(n => /^\d{14}_.*\.sql$/.test(n)).sort()) {
  assert.ok(name <= migration, "Unexpected future migration");
  fs.copyFileSync("supabase/migrations/" + name, path.join(project, "supabase/migrations", name));
}
function dockerRead(args) {
  const r = spawnSync("docker", args, { encoding: "utf8", windowsHide: true }); assert.equal(r.status, 0); return r.stdout.trim();
}
assert.ok(!process.env.SUPABASE_CLI_BINARY_OVERRIDE);
assert.ok(dockerRead(["port", container, "5432/tcp"]).split(/\r?\n/).every(p => /^(?:0\.0\.0\.0|127\.0\.0\.1|\[::\]):54322$/.test(p)));
const version = spawnSync(process.execPath, [cli, "--version"], { encoding: "utf8", windowsHide: true });
assert.equal(version.stdout.trim(), "2.109.1"); report.cliVersion = version.stdout.trim();
const secret = dockerRead(["exec", container, "printenv", "POSTGRES_PASSWORD"]);
assert.ok(secret);
const url = `postgresql://postgres:${encodeURIComponent(secret)}@127.0.0.1:54322/${db}?sslmode=disable`;
function apply() {
  const started = Date.now(), p = spawn(process.execPath, [cli, "db", "push", "--db-url", url, "--workdir", project, "--yes"], { windowsHide: true });
  let out = "", err = "";
  p.stdout.on("data", c => out += c); p.stderr.on("data", c => err += c);
  const sanitize = s => s.replaceAll(url, "[LOCAL_SCRATCH_URL]").replaceAll(secret, "[REDACTED]").replaceAll(encodeURIComponent(secret), "[REDACTED]");
  return new Promise(resolve => p.on("exit", exit => resolve({ exit, elapsedMs: Date.now() - started, stdout: sanitize(out), stderr: sanitize(err) })));
}
let running = true;
try {
  assert.equal(sql(baseline, "select count(*)||'|'||max(version) from supabase_migrations.schema_migrations;"), "152|20261105100000");
  assert.equal(sql(baseline, "select count(*) from auth.users;"), "0");
  sql("postgres", `create database ${db} template ${baseline};`);
  const setup = fs.readFileSync("supabase/tests/20261106110000_legal_resource_ownership_test.sql", "utf8").split("-- LEGAL_FIXTURE_DOCUMENTS:")[0];
  sql(db, setup + "\ncommit;");
  const fixture = JSON.parse(sql(db, "select to_jsonb(f) from legal_test.fixture f where side='A';"));
  const operations = [];
  for (const table of ["reservations", "event_registrations"]) {
    const columns = sql(db, `select string_agg(quote_ident(attname),',' order by attnum) from pg_attribute where attrelid='public.${table}'::regclass and attnum>0 and not attisdropped and attgenerated='';`);
    const id = table === "reservations" ? fixture.reservation : fixture.registration;
    const mutate = table === "reservations" ? "copy.creation_request_id:=gen_random_uuid();copy.check_in_token:=gen_random_uuid();copy.reservation_status:='cancelled';" : "copy.registration_status:='cancelled';";
    const insert = `do $insert$ declare copy public.${table}; begin
      select * into copy from public.${table} where id=${quote(id)};copy.id:=gen_random_uuid();${mutate}
      insert into public.${table} (${columns}) select ${columns} from jsonb_populate_record(null::public.${table},to_jsonb(copy));end;$insert$;`;
    sql(db, `do $populate$ declare copy public.${table}; begin
      select * into copy from public.${table} where id=${quote(id)};
      for i in 1..10000 loop copy.id:=gen_random_uuid();${mutate}
       insert into public.${table} (${columns}) select ${columns} from jsonb_populate_record(null::public.${table},to_jsonb(copy));
      end loop;end;$populate$; analyze public.${table};`);
    assert.equal(sql(db, `select count(*) from public.${table};`), "10002");
    operations.push([table + "/SELECT", `select id from public.${table} where id=${quote(id)};`]);
    operations.push([table + "/INSERT", insert]);
    operations.push([table + "/UPDATE", `update public.${table} set ${table === "reservations" ? "admin_note='Synthetic migration-window'" : "promotion_last_attempt_at=clock_timestamp()"} where id=${quote(id)};`]);
  }
  const physical = () => sql(db, "select jsonb_agg(jsonb_build_object('table',c.oid::regclass::text,'filenode',c.relfilenode,'indexes',(select jsonb_agg(indexrelid order by indexrelid) from pg_index where indrelid=c.oid)) order by c.oid) from pg_class c where c.oid in ('public.reservations'::regclass,'public.event_registrations'::regclass);");
  const before = physical();
  // A real old writer holds RowExclusiveLock before CREATE TRIGGER is attempted.
  const holder = session(db, "hostile_writer"), reader = session(db, "hostile_read"), writer = session(db, "queued_write"), hostileObserver = session(db, "hostile_observer");
  await Promise.all([holder.ready, reader.ready, writer.ready, hostileObserver.ready]);
  await hostileObserver.query("set statement_timeout='10s';create temporary table hostile_samples(t timestamptz,mode text,granted boolean);");
  await holder.query(`begin; update public.reservations set admin_note=admin_note where id=${quote(fixture.reservation)};`);
  const hostileSampling = hostileObserver.query(`do $sample$ declare deadline timestamptz:=clock_timestamp()+interval '5 seconds'; begin
    while clock_timestamp()<deadline loop
     insert into hostile_samples select clock_timestamp(),mode,granted from pg_locks
      where database=(select oid from pg_database where datname=current_database()) and relation='public.reservations'::regclass
       and mode='ShareRowExclusiveLock' and not granted;
     perform pg_sleep(0.001);
    end loop;end;$sample$;`);
  const started = Date.now(); let finished = false;
  const hostileApply = apply().then(r => { finished = true; return r; });
  await waitFor(() => finished || sql(db, "select count(*) from pg_locks where relation='public.reservations'::regclass and mode='ShareRowExclusiveLock' and not granted;") === "1", "Official migration must wait on CREATE TRIGGER", 10000);
  assert.equal(finished, false);
  const queueObservedAt = Date.now();
  const readStart = Date.now(); await reader.query("select count(*) from public.reservations;");
  const readMs = Date.now() - readStart;
  const writeStart = Date.now();
  // An insert avoids the holder's tuple lock; only the migration lock queue can delay it.
  let writeMs;
  const queuedWrite = writer.query(operations.find(([label]) => label === "reservations/INSERT")[1]).then(() => { writeMs = Date.now() - writeStart; });
  const hostile = await hostileApply;
  const queueUpperBoundMs = Date.now() - queueObservedAt;
  await queuedWrite;
  assert.notEqual(hostile.exit, 0); assert.match(hostile.stderr, /55P03|lock timeout/);
  assert.doesNotMatch(hostile.stderr, /25P01|SET LOCAL can only/);
  await hostileSampling;
  const sampledWait = JSON.parse(await hostileObserver.query("select jsonb_build_object('samples',count(*),'ms',extract(epoch from max(t)-min(t))*1000) from hostile_samples;"));
  assert.ok(sampledWait.samples > 20 && sampledWait.ms >= 400 && sampledWait.ms < 700, "Expected the actual 500ms lock timeout: " + JSON.stringify(sampledWait));
  assert.equal(sql(db, "select count(*) from supabase_migrations.schema_migrations;"), "152");
  assert.equal(sql(db, "select count(*) from pg_proc where proname='legal_resource_tenant_immutable_v1';"), "0");
  assert.equal(sql(db, "select count(*) from pg_trigger where tgname='aa_legal_resource_tenant_immutable';"), "0");
  assert.equal(sql(db, "select count(*) from pg_class where relname in ('legal_documents','legal_document_versions','legal_actions','legal_subjects','legal_acceptances');"), "0");
  report.hostile = { ...hostile, queueObserved: true, queueUpperBoundMs, sampledWait, totalObservedMs: Date.now() - started, readMs, queuedWriteMs: writeMs, atomicRollback: true, pass: true };
  await holder.query("rollback;"); await Promise.all([holder.close(), reader.close(), writer.close(), hostileObserver.close()]);
  // A server-side sampler avoids client round-trip blind spots around brief metadata locks.
  const observer = session(db, "lock_observer"); await observer.ready;
  await observer.query("set statement_timeout='15s';create temporary table lock_samples(t timestamptz,mode text,granted boolean,relation text,pid integer,query text);");
  const observation = observer.query(`do $sample$ declare deadline timestamptz:=clock_timestamp()+interval '6 seconds'; begin
    while clock_timestamp()<deadline loop
     perform pg_stat_clear_snapshot();
     insert into lock_samples select clock_timestamp(),l.mode,l.granted,l.relation::regclass::text,l.pid,left(a.query,180)
      from pg_locks l join pg_stat_activity a on a.pid=l.pid
      where l.database=(select oid from pg_database where datname=current_database()) and l.locktype='relation'
       and l.relation in ('public.reservations'::regclass,'public.event_registrations'::regclass)
       and a.pid<>pg_backend_pid();
     perform pg_sleep(0.001);
    end loop;end;$sample$;`);
  const connections = operations.map(([label]) => session(db, label.replaceAll("/", "_")));
  await Promise.all(connections.map(c => c.ready));
  const times = operations.map(() => []);
  const workloads = connections.map(async (connection, i) => {
    while (running) {
      const result = await connection.query(`select clock_timestamp() as op_started \\gset\n${operations[i][1]}\nselect json_build_object('ms',extract(epoch from clock_timestamp()-:'op_started'::timestamptz)*1000);`);
      times[i].push(Number(JSON.parse(result.split(/\r?\n/).findLast(line => line.startsWith("{"))).ms));
      await pause(5);
    }
  });
  // Attach rejection handling immediately; every worker must remain healthy until stopped.
  const allWorkloads = Promise.all(workloads);
  allWorkloads.catch(() => {});
  await pause(100);
  const healthy = await apply();
  await pause(100); running = false;
  await allWorkloads; await Promise.all(connections.map(c => c.close()));
  await observation;
  const samples = JSON.parse(await observer.query("select coalesce(jsonb_agg(to_jsonb(s)),'[]'::jsonb) from (select mode,granted,relation,pid,min(t) as first,max(t) as last,extract(epoch from max(t)-min(t))*1000 as sampled_ms,count(*) as samples,min(query) as query from lock_samples group by mode,granted,relation,pid order by relation,mode,pid) s;"));
  await observer.close();
  assert.equal(healthy.exit, 0, healthy.stderr);
  assert.doesNotMatch(healthy.stderr, /25P01|SET LOCAL can only/);
  assert.equal(sql(db, "select count(*)||'|'||max(version) from supabase_migrations.schema_migrations;"), "153|20261106100000");
  assert.equal(physical(), before, "Hot table rewrite or index change");
  assert.ok(!samples.some(s => s.mode === "AccessExclusiveLock"), "Unexpected hot-table ACCESS EXCLUSIVE");
  assert.ok(samples.some(s => s.mode === "ShareRowExclusiveLock" && s.granted), "Metadata lock not observed");
  report.healthy = { ...healthy, pass: true, hotTableRewrite: false, hotTableIndexDelta: 0, lockSamples: samples };
  report.workers = times.map((values, i) => {
    assert.ok(values.length >= 2); const sorted = [...values].sort((a,b) => a-b), maxMs = Math.max(...values);
    assert.ok(maxMs < 1000, operations[i][0] + " unacceptable blocking");
    return { operation: operations[i][0], completed: values.length, maxMs, p95Ms: sorted[Math.floor(sorted.length * 0.95)], pass: true };
  });
  report.pass = true;
} finally {
  running = false; cleanup(db); report.scratchDatabasesRemaining = 0;
  fs.writeFileSync(path.join(output, "migration-window.json"), JSON.stringify(report, null, 2));
}
console.log(JSON.stringify({ pass: report.pass, workers: report.workers, hostile: report.hostile, productionWrite: false }));
