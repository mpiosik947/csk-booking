// LOCAL ONLY. Schema-only bootstrap; historical migrations replayed without current default ACLs.
import { spawnSync } from 'node:child_process';
import { readFileSync, readdirSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { runDispatchRaces } from './c2b-dispatch-races.mjs';
const container='supabase_db_csk-booking', scratch='c2b_'+randomBytes(8).toString('hex');
function docker(args,input){const r=spawnSync('docker',args,{input,encoding:'utf8',maxBuffer:64*1024*1024});if(r.status)throw Error(r.stderr+'\n'+r.stdout.slice(-5000));return r.stdout;}
function sql(db,input,superuser=false){return docker(superuser?['exec','-i',container,'sh','-c','PGPASSWORD="$POSTGRES_PASSWORD" exec psql -X -At -v ON_ERROR_STOP=1 -U supabase_admin -d "$1"','sh',db]:['exec','-i',container,'psql','-X','-At','-v','ON_ERROR_STOP=1','-U','postgres','-d',db],input);}
const ports=docker(['port',container,'5432/tcp']);
if(!ports.trim().split(/\r?\n/).every(l=>/^(?:0\.0\.0\.0|127\.0\.0\.1|\[::\]):54322$/.test(l)))throw Error('LOCAL_ONLY');
let created=false;
try{
 sql('postgres',`create database ${scratch} template template0;`);created=true;
 const dump=docker(['exec',container,'pg_dump','-U','postgres','-d','postgres','--schema-only']);
 sql(scratch,dump.split('\n').map(l=>/^(?:GRANT|REVOKE).* ON (?:TABLE|SEQUENCE|FUNCTION) public\./.test(l)?'SET SESSION AUTHORIZATION postgres;\n'+l+'\nRESET SESSION AUTHORIZATION;':l).join('\n'),true);
 sql(scratch,'drop schema public cascade;');
 sql(scratch,'create schema public authorization pg_database_owner; grant usage on schema public to public;',true);
 const dir=new URL('../../supabase/migrations/',import.meta.url);
 const chain=readdirSync(dir).filter(n=>/^\d{14}_.*\.sql$/.test(n)&&n<='20261019100000_zzz.sql').sort();
 for(const name of chain){sql(scratch,'begin;\n'+readFileSync(new URL(name,dir),'utf8').replace(/\r\n/g,'\n')+`\ninsert into supabase_migrations.schema_migrations(version) values ('${name.slice(0,14)}');\ncommit;`);console.log('APPLIED '+name);}
 console.log('SECURITY_DEFINER='+sql(scratch,"select count(*) from pg_proc where pronamespace='public'::regnamespace and prosecdef").trim());
 console.log('CATALOG='+sql(scratch,"select json_agg(x) from (select oid::regprocedure::text as signature, md5(replace(replace(pg_get_functiondef(oid),E'\\r\\n',E'\\n'),E'\\r',E'\\n')) as fingerprint from pg_proc where pronamespace='public'::regnamespace and proname in ('prepare_confirmation_email','prepare_event_reserve_promotions')) x").trim());
 const schema=()=>docker(['exec',container,'pg_dump','-U','postgres','-d',scratch,'--schema-only','--schema=public']).replace(/\r\n/g,'\n').split('\n').filter(line=>!/^\\(?:un)?restrict /.test(line)).join('\n');
 const counts=()=>sql(scratch,"select json_build_array((select count(*) from auth.users),(select count(*) from public.tenants),(select count(*) from public.events),(select count(*) from public.event_registrations),(select count(*) from public.email_deliveries))").trim();
 const schemaBefore=schema(),countsBefore=counts();
 await runDispatchRaces(scratch);
 const testdir=new URL('../../supabase/tests/',import.meta.url);let pass=0;const failed=[];
 for(const name of readdirSync(testdir).filter(n=>n.endsWith('.sql')).sort()){
  try{const result=sql(scratch,readFileSync(new URL(name,testdir),'utf8'));if(/^not ok /m.test(result))throw Error(result);console.log('PASS '+name);pass++;}
  catch(error){failed.push(name);console.log('FAIL '+name+'\n'+error.message);}
 }
 console.log(JSON.stringify({pass,failed}));
 if(schema()!==schemaBefore)throw Error('TEST_SCHEMA_DRIFT');
 if(counts()!==countsBefore)throw Error('FIXTURE_REMAINS');
 console.log('TEST_SCHEMA_DIFF=0; FIXTURE_CLEANUP=0');
 if(failed.length)process.exitCode=1;
}finally{if(created){sql('postgres',`drop database ${scratch};`);console.log('SCRATCH_CLEANUP=0');}}
