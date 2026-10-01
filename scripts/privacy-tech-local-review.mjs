import { spawnSync } from 'node:child_process';
import { readFileSync, readdirSync, writeFileSync, existsSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { resolve } from 'node:path';

const container = 'supabase_db_csk-booking';
const root = process.cwd();
const evidence = resolve(root, '..');
const statePath = resolve(evidence, 'privacy-tech-1-state.json');
const command = process.argv[2];
function docker(args, input) {
  const r = spawnSync('docker', args, { input, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (r.status !== 0) throw Error(`Local Docker failed: ${(r.stderr || r.error?.code || '').slice(-3000)}`);
  return r.stdout;
}
function sql(db, input, managed = false) {
  if (!/^privacy_tech_[0-9a-f]{16}$/.test(db) && db !== 'postgres') throw Error('INVALID_LOCAL_TARGET');
  return managed
    ? docker(['exec', '-i', container, 'sh', '-c', 'PGPASSWORD="$POSTGRES_PASSWORD" exec psql -X -At -v ON_ERROR_STOP=1 -U supabase_admin -d "$1"', 'sh', db], input)
    : docker(['exec', '-i', container, 'psql', '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', db], input);
}
const normalized = s => s.replace(/\r\n?/g, '\n').split('\n').filter(l => !/^\\(?:un)?restrict /.test(l)).join('\n');
function schema(db) { return normalized(docker(['exec', container, 'pg_dump', '-U', 'postgres', '-d', db, '--schema-only', '--schema=public'])); }
function catalog(db) {
  return sql(db, readFileSync(resolve(evidence, 'privacy-tech-1-catalog-readonly.sql'), 'utf8')).trim().split(/\r?\n/).filter(l => /^[a-z_]+\|/.test(l)).map(l => ({ section: l.slice(0, l.indexOf('|')), evidence: JSON.parse(l.slice(l.indexOf('|') + 1)) }));
}
function compare(db) {
  const actual = catalog(db);
  const production = JSON.parse(readFileSync(resolve(evidence, 'privacy-tech-1-production-catalog.json'), 'utf8'));
  const mismatches = [];
  for (const section of ['functions', 'columns', 'constraints', 'tables']) {
    const a = actual.find(x => x.section === section).evidence;
    const b = production.find(x => x.section === section).evidence;
    if (JSON.stringify(a) !== JSON.stringify(b)) {
      const key = section === 'functions' ? x => x.signature : section === 'columns' ? x => x.table + '.' + x.column : section === 'constraints' ? x => x.table + '.' + x.name : x => x.name;
      const am = new Map(a.map(x => [key(x), x])), bm = new Map(b.map(x => [key(x), x]));
      for (const k of new Set([...am.keys(), ...bm.keys()])) if (JSON.stringify(am.get(k)) !== JSON.stringify(bm.get(k))) mismatches.push({ section, key: k, local: am.get(k), production: bm.get(k) });
    }
  }
  writeFileSync(resolve(evidence, 'privacy-tech-1-baseline-schema-diff.json'), JSON.stringify(mismatches, null, 2));
  console.log('BASELINE_SCHEMA_DIFF=' + mismatches.length);
  if (mismatches.length) throw Error('BASELINE_SCHEMA_DRIFT: see schema diff evidence');
  writeFileSync(resolve(evidence, 'privacy-tech-1-baseline-schema.sql'), schema(db));
}
const ports = docker(['port', container, '5432/tcp']).trim().split(/\r?\n/);
if (!ports.every(p => /^(?:0\.0\.0\.0|127\.0\.0\.1|\[::\]):54322$/.test(p))) throw Error('LOCAL_ONLY_GATE');
if (command === 'prepare') {
  if (existsSync(statePath)) throw Error('EXISTING_SCRATCH_STATE');
  const db = 'privacy_tech_' + randomBytes(8).toString('hex');
  sql('postgres', `create database ${db} template template0;`);
  writeFileSync(statePath, JSON.stringify({ db }));
  try {
    const source = docker(['exec', container, 'pg_dump', '-U', 'postgres', '-d', 'postgres', '--schema-only']);
    const restore = source.split('\n').map(l => /^(?:GRANT|REVOKE).* ON (?:TABLE|SEQUENCE|FUNCTION) public\./.test(l) ? 'SET SESSION AUTHORIZATION postgres;\n' + l + '\nRESET SESSION AUTHORIZATION;' : l).join('\n');
    sql(db, restore, true);
    sql(db, 'drop schema public cascade;');
    sql(db, 'create schema public authorization pg_database_owner; grant usage on schema public to public;', true);
    const dir = resolve(root, 'supabase/migrations');
    const chain = readdirSync(dir).filter(n => /^\d{14}_.*\.sql$/.test(n) && n <= '20261025100000_zzz.sql').sort();
    for (const name of chain) {
      sql(db, 'reset all; reset role;\nbegin;\n' + readFileSync(resolve(dir, name), 'utf8') + `\ninsert into supabase_migrations.schema_migrations(version) values ('${name.slice(0, 14)}');\ncommit;`);
    }
    console.log('BASELINE_CHAIN=' + chain.length + '; DB=' + db);
    compare(db);
  } catch (e) { console.error(e.message); process.exitCode = 1; }
} else {
  const { db } = JSON.parse(readFileSync(statePath, 'utf8'));
  if (!/^privacy_tech_[0-9a-f]{16}$/.test(db)) throw Error('INVALID_SCRATCH');
  if (command === 'sql') console.log(sql(db, readFileSync(resolve(process.argv[3]), 'utf8')));
  else if (command === 'compare') compare(db);
  else if (command === 'full-db') {
    const before = schema(db); let assertions = 0, files = 0; const failures = [];
    for (const name of readdirSync(resolve(root, 'supabase/tests')).filter(n => n.endsWith('.sql')).sort()) {
      try {
        const out = sql(db, readFileSync(resolve(root, 'supabase/tests', name), 'utf8'));
        if (/^not ok /m.test(out)) throw Error(out);
        const count = (out.match(/^ok \d+/gm) || []).length; assertions += count; files++;
        console.log('SQL_PASS ' + name + ' assertions=' + count);
      } catch (e) { failures.push(name); console.log('SQL_FAIL ' + name + '\n' + e.message.slice(-5000)); }
    }
    console.log('FULL_DB_ASSERTIONS=' + assertions + '; FILES=' + files + '; FAILURES=' + failures.length);
    if (schema(db) !== before) throw Error('POST_TEST_SCHEMA_DRIFT');
    console.log('POST_TEST_SCHEMA_DIFF=0');
    if (failures.length) throw Error('FULL_DB_FAILED=' + failures.join(','));
  } else if (command === 'snapshot') {
    writeFileSync(resolve(evidence, 'privacy-tech-1-candidate-schema.sql'), schema(db));
    writeFileSync(resolve(evidence, 'privacy-tech-1-candidate-catalog.json'), JSON.stringify(catalog(db), null, 2));
  } else if (command === 'cleanup') {
    sql('postgres', `drop database ${db};`);
    if (sql('postgres', `select count(*) from pg_database where datname='${db}';`).trim() !== '0') throw Error('CLEANUP_FAILED');
    console.log('SCRATCH_DATABASE_REMAINING=0');
  } else throw Error('UNKNOWN_COMMAND');
}
