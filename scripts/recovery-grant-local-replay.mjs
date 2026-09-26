import { spawnSync } from "node:child_process";
import { readFileSync, readdirSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { recoveryConcurrency } from './recovery-grant-concurrency.mjs';

const container = "supabase_db_csk-booking";
const scratch = `p10e_isolated_${randomBytes(8).toString("hex")}`;
function docker(args, input) {
  const result = spawnSync("docker", args, { input, encoding: "utf8", maxBuffer: 32 * 1024 * 1024 });
  if (result.status !== 0) throw new Error((result.stderr || "Local Docker command failed") + '\n' + (result.stdout || '').slice(-5000));
  return result.stdout;
}
function sql(database, input, restoreSchema = false) {
  if (restoreSchema) {
    if (database !== scratch) throw new Error("RESTORE_MUST_TARGET_EMPTY_SCRATCH");
    return docker(["exec", "-i", container, "sh", "-c", 'PGPASSWORD="$POSTGRES_PASSWORD" exec psql -X -At -v ON_ERROR_STOP=1 -U supabase_admin -d "$1"', "sh", database], input);
  }
  return docker(["exec", "-i", container, "psql", "-X", "-At", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", database], input);
}
function schema(database, publicOnly = false) {
  return docker(["exec", container, "pg_dump", "-U", "postgres", "-d", database, "--schema-only", ...(publicOnly ? ["--schema=public"] : [])]);
}

const ports = docker(["port", container, "5432/tcp"]);
if (!ports.trim().split(/\r?\n/).every(line => /^(?:0\.0\.0\.0|127\.0\.0\.1|\[::\]):54322$/.test(line))) throw new Error("LOCAL_DB_GATE_FAILED");


const source = schema("postgres"); // Schema only: no users, business data, tokens or passwords.
let created = false;
try {
  sql("postgres", `create database ${scratch} template template0;`);
  created = true;
  // Public application objects are owned by postgres. Restore their ACLs as that
  // owner, not the schema-restoring superuser (which would change grantor identity).
  const restore = source.split('\n').map(line => /^(?:GRANT|REVOKE).* ON (?:TABLE|SEQUENCE|FUNCTION) public\./.test(line)
    ? 'SET SESSION AUTHORIZATION postgres;\n' + line + '\nRESET SESSION AUTHORIZATION;' : line).join('\n');
  sql(scratch, restore, true);
  // Only the new empty scratch database is rebuilt, never the running app DB.
  sql(scratch, 'drop schema public cascade;');
  // Do not pre-seed current public default ACLs: the historical baseline installs
  // its own defaults after creating its tables. Moving those defaults earlier
  // incorrectly grants service_role direct access to owner-only technical tables.
  // Recreating a named schema does not recreate PostgreSQL's initial public-schema
  // USAGE grant. Restore that managed baseline only, not current TABLE/FUNCTION defaults.
  sql(scratch, 'create schema public authorization pg_database_owner; grant usage on schema public to public;', true);
  const migrationDir = new URL('../supabase/migrations/', import.meta.url);
  const chain = readdirSync(migrationDir).filter(n => /^\d{14}_.*\.sql$/.test(n) && n <= '20261012100000_zzz.sql').sort();
  if (!chain.at(-1)?.startsWith('20261012100000_')) throw new Error('CHAIN_HEAD_MISMATCH');
  const replay = chain.map(name => `reset all; reset role;\n\\echo APPLYING_LOCAL ${name}\nbegin;\n` + readFileSync(new URL(name, migrationDir), 'utf8') + `\ninsert into supabase_migrations.schema_migrations(version) values ('${name.slice(0,14)}');\ncommit;\n`).join('\n');
  sql(scratch, replay);
  console.log('ISOLATED_MIGRATION_HEAD=20261012100000; COMPLETE_CHAIN=' + chain.length);
  const inventory = sql(scratch, "select count(*) from pg_proc where pronamespace='public'::regnamespace and prosecdef; select to_regclass('public.tenant_public_pricing_items') is not null and to_regprocedure('public.admin_get_tenant_content_v1(text)') is not null and to_regprocedure('public.admin_update_tenant_content_v1(text,jsonb,jsonb,timestamp with time zone)') is not null and to_regprocedure('public.get_public_tenant_content_v1(text)') is not null;");
  if (inventory.trim() !== "107\nt") throw new Error("ISOLATED_INVENTORY_FAILED: " + inventory);
  console.log("ISOLATED_SECURITY_DEFINER=107; TCM_OBJECTS=PRESENT");
  const technicalAcl = sql(scratch, "select count(*) from pg_class c cross join lateral aclexplode(coalesce(c.relacl,acldefault('r',c.relowner))) a where c.relnamespace='public'::regnamespace and c.relname in('confirmation_email_rate_limits','lane_booking_family_configuration_versions') and a.grantee='service_role'::regrole;");
  if (technicalAcl.trim() !== '0') throw new Error('TECHNICAL_TABLE_SERVICE_ACL_DRIFT');
  console.log('TECHNICAL_TABLE_SERVICE_ROLE_GRANTS=0; MATCHES_PRODUCTION_ACL_AUDIT');
  const normalized = text => text.replace(/\r\n?/g, '\n').split('\n').filter(line => !/^\\(?:un)?restrict /.test(line)).join('\n');
  const baselineSchema = normalized(schema(scratch, true));
  const liveSchema = normalized(schema("postgres", true));
  if (baselineSchema !== liveSchema) {
    const aclQuery="select n.nspowner::regrole::text||':'||coalesce(string_agg(a.grantor::regrole::text||'/'||a.grantee::text||'/'||a.privilege_type||'/'||a.is_grantable::text,',' order by a.grantor,a.grantee,a.privilege_type),'') from pg_namespace n left join lateral aclexplode(n.nspacl) a on true where n.nspname='public' group by n.nspowner;";
    console.log('PUBLIC_SCHEMA_REPLAY_ACL='+sql(scratch,aclQuery).trim());
    console.log('PUBLIC_SCHEMA_LOCAL_ACL='+sql('postgres',aclQuery).trim());
    const a=baselineSchema.split('\n'),b=liveSchema.split('\n'),i=a.findIndex((line,index)=>line!==b[index]);
    throw new Error('LOCAL_REPLAY_SCHEMA_DIFF line='+i+' replay='+a.slice(i,i+5).join('\n')+' local='+b.slice(i,i+5).join('\n'));
  }
  console.log('LOCAL_REPLAY_SCHEMA_DIFF=0');
  const focused = readFileSync(new URL("../supabase/tests/20261012100000_one_time_recovery_grants_test.sql", import.meta.url), "utf8");
  const output = sql(scratch, focused);
  if (/not ok/m.test(output)) throw new Error("FOCUSED_SQL_FAILED");
  console.log(output);
  await recoveryConcurrency(scratch);
  let assertions = 0, files = 0;
  const failures = [];
  const testDir = new URL('../supabase/tests/', import.meta.url);
  for (const name of readdirSync(testDir).filter(n => n.endsWith('.sql') && (!/^\d/.test(n) || n <= '20261012100000_zzz.sql')).sort()) {
    try {
    const result = sql(scratch, readFileSync(new URL(name, testDir), 'utf8'));
    if (/^not ok /m.test(result)) throw new Error('FULL_DB_ASSERTION_FAILED: ' + name + '\n' + result);
    const count = (result.match(/^ok \d+/gm) || []).length;
    assertions += count; files++;
    console.log('SQL_PASS ' + name + ' assertions=' + count);
    } catch (error) { failures.push(name); console.log('SQL_FAIL '+name+'\n'+error.message); }
  }
  if(failures.length) throw Error('FULL_DB_FAILED_FILES='+failures.join(','));
  console.log('ISOLATED_FULL_DB=' + assertions + '/' + assertions + '; files=' + files);
  if (normalized(schema(scratch, true)) !== baselineSchema) throw new Error('POST_TEST_SCHEMA_DRIFT');
  console.log('POST_TEST_SCHEMA_DIFF=0');
  console.log("NOTE: API/E2E runs separately against the same locally applied migration target.");

} finally {
  if (created) {
    sql("postgres", `drop database ${scratch};`);
    if (sql("postgres", `select count(*) from pg_database where datname='${scratch}';`).trim() !== "0") throw new Error("SCRATCH_CLEANUP_FAILED");
    console.log("SCRATCH_DATABASE_REMAINING=0");
  }
}
