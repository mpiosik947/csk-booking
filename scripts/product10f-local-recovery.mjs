import { spawnSync } from 'node:child_process';
import { readFileSync, readdirSync } from 'node:fs';
if (!process.argv.includes('--rebuild-local')) throw Error('EXPLICIT_LOCAL_REBUILD_FLAG_REQUIRED');
const container = 'supabase_db_csk-booking';
function docker(args, input) {
  const r = spawnSync('docker', args, {input, encoding:'utf8', maxBuffer:64*1024*1024});
  if(r.status!==0) throw Error((r.stderr||'')+'\n'+(r.stdout||'').slice(-3000));
  return r.stdout;
}
const ports=docker(['port',container,'5432/tcp']).trim().split(/\r?\n/);
if(!ports.length || !ports.every(p=>/^(?:0\.0\.0\.0|127\.0\.0\.1|\[::\]):54322$/.test(p))) throw Error('LOCAL_TARGET_GATE');
const args=['exec','-i',container,'psql','-X','-At','-v','ON_ERROR_STOP=1','-U','postgres','-d','postgres'];
if(docker(args,"select (select count(*) from auth.users)+(select count(*) from storage.objects);").trim()!=='0') throw Error('NONEMPTY_MANAGED_DATA_STOP');
const dir=new URL('../supabase/migrations/',import.meta.url);
const chain=readdirSync(dir).filter(n=>/^\d{14}_.*\.sql$/.test(n)).sort();
if(chain.at(-1)!=='20261011100000_add_verified_tenant_domains.sql') throw Error('CHAIN_HEAD_GATE');
// Recreate the local application schema, not individual grants. Schema-scoped
// default ACLs disappear with the schema and are restored in historical order.
// Use the same connection role and per-migration transactions as fresh replay.
// A managed operator recreates only the schema; postgres runs canonical history.
const replay=chain.map(name=>`RESET ALL; RESET ROLE;\nBEGIN;\n`+readFileSync(new URL(name,dir),'utf8')+`\nINSERT INTO supabase_migrations.schema_migrations(version) VALUES('${name.slice(0,14)}');\nCOMMIT;\n`).join('\n');
const sql=`BEGIN; SET LOCAL lock_timeout='10s'; DROP SCHEMA public CASCADE;
CREATE SCHEMA public AUTHORIZATION pg_database_owner; GRANT USAGE ON SCHEMA public TO PUBLIC;
TRUNCATE supabase_migrations.schema_migrations; COMMIT;`;
docker(['exec','-i',container,'sh','-c','PGPASSWORD="$POSTGRES_PASSWORD" exec psql -X -At -v ON_ERROR_STOP=1 -U supabase_admin -d postgres'],sql);
docker(args,replay+"\nNOTIFY pgrst, 'reload schema';");
console.log('LOCAL_REBUILT=YES; CANONICAL_MIGRATIONS='+chain.length);
console.log(docker(args,"select max(version) from supabase_migrations.schema_migrations; select count(*) from pg_proc where pronamespace='public'::regnamespace and prosecdef; select c.relname,coalesce((select array_agg(a.privilege_type order by a.privilege_type) from aclexplode(c.relacl) a where a.grantee='service_role'::regrole),ARRAY[]::text[]) from pg_class c where c.relnamespace='public'::regnamespace and c.relname in('confirmation_email_rate_limits','lane_booking_family_configuration_versions') order by c.relname;"));
