import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { randomBytes } from "node:crypto";

const container = "supabase_db_csk-booking";
const scratch = `tcm_schema_${randomBytes(8).toString("hex")}`;
function docker(args, input) {
  const result = spawnSync("docker", args, { input, encoding: "utf8", maxBuffer: 32 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(result.stderr || "Local Docker command failed");
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
function normalize(value) {
  return value.replace(/\r\n?/g, "\n").split("\n").filter(line => !/^\\(?:un)?restrict /.test(line)).join("\n");
}

const ports = docker(["port", container, "5432/tcp"]);
if (!ports.trim().split(/\r?\n/).every(line => /^(?:0\.0\.0\.0|127\.0\.0\.1|\[::\]):54322$/.test(line))) throw new Error("LOCAL_DB_GATE_FAILED");
const migration = readFileSync(new URL("../supabase/migrations/20261010100000_add_tenant_public_content.sql", import.meta.url), "utf8");
const expected = normalize(schema("postgres", true));
const source = schema("postgres"); // Schema only: no users, business data, tokens or passwords.
let created = false;
try {
  sql("postgres", `create database ${scratch} template template0;`);
  created = true;
  sql(scratch, source, true);
  // Reconstruct only this task's pre-migration schema in the EMPTY scratch database.
  sql(scratch, `
drop function public.admin_get_tenant_content_v1(text);
drop function public.admin_update_tenant_content_v1(text,jsonb,jsonb,timestamptz);
drop function public.get_public_tenant_content_v1(text);
drop table public.tenant_public_pricing_items;
alter table public.tenant_public_profiles drop column about_offer,drop column about_audience,drop column public_map_url;
do $undo$
declare d text;
begin
 d:=replace(replace(pg_get_functiondef('public.set_audit_log_tenant_id()'::regprocedure),chr(13)||chr(10),chr(10)),chr(13),chr(10));
 d:=replace(d,'new.action not in (''tenant_public_profile_updated'',''public_about_updated'',''public_contact_updated'')','new.action is distinct from ''tenant_public_profile_updated''');
 d:=replace(d,'    when ''tenant_public_pricing_item'' then
      if new.action not in (''pricing_item_created'',''pricing_item_updated'',''pricing_item_disabled'',''pricing_order_changed'') then raise exception ''invalid_pricing_audit''; end if;
      select item.tenant_id into v_tenant_id from public.tenant_public_pricing_items item where item.id=new.target_id;
','');
 if md5(d)<>'7695b54796226d5e95d1594692a5f891' then raise exception 'scratch baseline fingerprint mismatch'; end if;
 execute d;
end;$undo$;
`);
  sql(scratch, `begin;\n${migration}\ncommit;`);
  const actual = normalize(schema(scratch, true));
  if (actual !== expected) {
    const a = actual.split("\n"), e = expected.split("\n");
    const line = a.findIndex((value, index) => value !== e[index]);
    throw new Error(`SCHEMA_DIFF_FAILED at line ${line + 1}`);
  }
  console.log("LOCAL_SCHEMA_REPLAY_DIFF=0");
} finally {
  if (created) {
    sql("postgres", `drop database ${scratch};`);
    if (sql("postgres", `select count(*) from pg_database where datname='${scratch}';`).trim() !== "0") throw new Error("SCRATCH_CLEANUP_FAILED");
    console.log("SCRATCH_DATABASE_REMAINING=0");
  }
}
