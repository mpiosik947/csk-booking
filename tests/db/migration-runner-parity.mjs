// Mandatory before production authorization for complex migrations. Uses the
// installed official CLI apply path, never a harness-added BEGIN/COMMIT.
// Input must be an isolated canonical local baseline. The clone is always dropped.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {randomBytes, createHash} from 'node:crypto';

const [baseline, migration, outputDirectory] = process.argv.slice(2);
assert.match(baseline ?? '', /^(?:sbr[23]|migration_baseline)_[a-f0-9]{16}$/);
assert.match(migration ?? '', /^\d{14}_[a-z0-9_]+\.sql$/);
assert.ok(outputDirectory, 'Usage: baseline_db migration.sql output_directory');
assert.ok(!process.env.SUPABASE_CLI_BINARY_OVERRIDE, 'Unexpected CLI override');
const root = process.cwd(), output = path.resolve(outputDirectory);
const container = 'supabase_db_csk-booking';
const cli = path.join(root, 'node_modules/supabase/dist/supabase.js');
const expectedVersion = JSON.parse(fs.readFileSync(path.join(root, 'package.json'))).devDependencies.supabase;
const db = 'migration_parity_' + randomBytes(8).toString('hex');
fs.mkdirSync(output, {recursive:true});
const project = fs.mkdtempSync(path.join(output, 'runner-parity-'));
const migrations = path.join(project, 'supabase/migrations');
fs.mkdirSync(migrations, {recursive:true});
fs.writeFileSync(path.join(project, 'supabase/config.toml'), 'project_id = "migration-runner-parity"\n');
const run = (command, args, input) => spawnSync(command, args, {input, encoding:'utf8', maxBuffer:32e6, windowsHide:true, timeout:120000});
function docker(args, input) {
  const r = run('docker', args, input);
  assert.equal(r.status, 0, 'Local Docker failed');
  return r.stdout.trim();
}
function sql(target, query) {
  assert.ok(target === 'postgres' || target === baseline || target === db);
  return docker(['exec','-i',container,'psql','-X','-At','-v','ON_ERROR_STOP=1','-U','postgres','-d',target], query);
}
const ports = docker(['port',container,'5432/tcp']).split(/\r?\n/);
assert.ok(ports.every(p => /^(?:0\.0\.0\.0|127\.0\.0\.1|\[::\]):54322$/.test(p)), 'Local port required');
const version = run(process.execPath, [cli,'--version']);
assert.equal(version.status, 0);
assert.equal(version.stdout.trim(), expectedVersion, 'Installed CLI differs from pinned project version');
const names = fs.readdirSync(path.join(root,'supabase/migrations')).filter(n => /^\d{14}_.*\.sql$/.test(n) && n <= migration).sort();
assert.equal(names.at(-1), migration);
const expectedLedger = names.slice(0,-1).map(n => n.slice(0,14));
assert.deepEqual(sql(baseline,'select version from supabase_migrations.schema_migrations order by version;').split(/\r?\n/).filter(Boolean), expectedLedger, 'Baseline chain mismatch');
for (const name of names) fs.copyFileSync(path.join(root,'supabase/migrations',name),path.join(migrations,name));
const bytes = fs.readFileSync(path.join(migrations,migration));
const secret = docker(['exec',container,'printenv','POSTGRES_PASSWORD']);
assert.ok(secret);
const url = `postgresql://postgres:${encodeURIComponent(secret)}@127.0.0.1:54322/${db}?sslmode=disable`;
const sanitize = value => (value ?? '').replaceAll(url,'[LOCAL_SCRATCH_URL]').replaceAll(secret,'[REDACTED]').replaceAll(encodeURIComponent(secret),'[REDACTED]');
let created = false;
const report = {result:'FAIL', cliVersion:version.stdout.trim(), migration, sha256:createHash('sha256').update(bytes).digest('hex'), externalTransactionWrapper:false, productionWrite:false};
try {
  sql('postgres',`create database ${db} template ${baseline};`);
  created = true;
  const args = [cli,'db','push','--db-url',url,'--workdir',project,'--yes'];
  const applied = run(process.execPath,args);
  report.exit = applied.status;
  report.stdout = sanitize(applied.stdout);
  report.stderr = sanitize(applied.stderr);
  assert.equal(applied.status,0,'RUNNER_PARITY_APPLY_FAILED');
  assert.deepEqual(sql(db,'select version from supabase_migrations.schema_migrations order by version;').split(/\r?\n/),names.map(n=>n.slice(0,14)));
  assert.equal(sql(db,`select count(*) from supabase_migrations.schema_migrations where version='${migration.slice(0,14)}';`),'1');
  report.publicSequences = Number(sql(db,"select count(*) from pg_class where relnamespace='public'::regnamespace and relkind='S';"));
  assert.equal(report.publicSequences,0,'SEC_002B');
  report.ledgerEntries = names.length;
  report.result = 'PASS';
} finally {
  if (created) sql('postgres',`drop database ${db};`);
  report.scratchDatabasesRemaining = Number(sql('postgres',`select count(*) from pg_database where datname='${db}';`));
  assert.equal(report.scratchDatabasesRemaining,0);
  fs.writeFileSync(path.join(output,'runner-parity-apply.json'),JSON.stringify(report,null,2));
}
console.log(JSON.stringify({...report,stdout:undefined,stderr:undefined},null,2));
