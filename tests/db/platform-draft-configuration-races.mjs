import {spawn,spawnSync} from 'node:child_process';import {randomUUID} from 'node:crypto';import assert from 'node:assert/strict';
const db=process.argv[2];assert.match(db??'',/^sbr3_[a-f0-9]{16}$/);
const base=['exec','-i','supabase_db_csk-booking','psql','-X','-qAt','-v','ON_ERROR_STOP=1','-U','postgres','-d',db],q=s=>"'"+String(s).replaceAll("'","''")+"'";
const sql=s=>{const r=spawnSync('docker',base,{input:s,encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr);return r.stdout.trim();};
const pa=randomUUID(),slug='configrace-'+randomUUID().slice(0,8),claims=`select set_config('request.jwt.claim.sub',${q(pa)},true);set local role authenticated;`;
const rpc=s=>sql('begin;'+claims+s+'rollback;').split('\n').at(-1);let tid;let count=0;
const check=(name,value)=>{assert.ok(value,name);console.log('PASS '+name);count++;};
function run(statement){const p=spawn('docker',base,{windowsHide:true});let out='',err='',notify;const ready=new Promise(r=>notify=r),done=new Promise(r=>{p.stdout.on('data',b=>{out+=b;if(out.includes('LOCKED'))notify();});p.stderr.on('data',b=>err+=b);p.on('close',code=>{notify();r({code,out,err});});});p.stdin.end("set statement_timeout='10s';"+statement);return {ready,done};}
const read=()=>JSON.parse(rpc(`select public.platform_get_draft_configuration_v1(${q(tid)});`));
const save=(rev,key,value)=>`select public.platform_save_draft_configuration_v1(${q(tid)},${q(rev)},${q(key)},'profile',${q(JSON.stringify({description:value}))}::jsonb);`;
try{
 sql(`insert into auth.users(id,email,email_confirmed_at,is_anonymous) values(${q(pa)},${q(pa+'@example.invalid')},now(),false);insert into public.platform_admins(user_id,status) values(${q(pa)},'active');`);
 tid=JSON.parse(sql('begin;'+claims+`select public.platform_create_tenant_draft_v1('Race',${q(slug)},${q(slug+'-public')},'City',null,${q(randomUUID())});commit;`).split('\n').at(-1)).tenant_id;
 for(const mode of ['same-request','same-revision']){
  const rev=read().revision,key=randomUUID(),secondKey=mode==='same-request'?key:randomUUID();
  const a=run('begin;'+claims+save(rev,key,mode)+"select 'LOCKED';select pg_sleep(0.5);commit;");await a.ready;
  const b=run('begin;'+claims+save(rev,secondKey,mode)+'commit;');const[x,y]=await Promise.all([a.done,b.done]);
  check(mode+' serialized result',x.code===0&&(mode==='same-request'?y.code===0:y.code!==0&&/lock|DRAFT_CONFIGURATION_STALE/.test(y.err)));
  check(mode+' exactly one audit',sql(`select count(*) from public.platform_audit_logs where tenant_id=${q(tid)} and details->>'request_id'=${q(key)};`)==='1');
  check(mode+' exact committed retry',JSON.parse(rpc(save(rev,key,mode))).request_id===key);
 }
 let rev=read().revision;
 const archive=`select public.platform_archive_tenant_v1(${q(tid)},${q(read().lifecycle_revision)},${q(randomUUID())});`;
 // Hold the same target-row lock as the existing lifecycle writer; the new writer must fail fast.
 const a=run(`begin;select 1 from public.tenants where id=${q(tid)} for update;select 'LOCKED';select pg_sleep(0.5);rollback;`);await a.ready;
 const b=run('begin;'+claims+save(rev,randomUUID(),'must-not-write')+'commit;');const[x,y]=await Promise.all([a.done,b.done]);check('lifecycle lock blocks concurrent configuration',x.code===0&&y.code!==0&&/lock/.test(y.err));
 sql('begin;'+claims+archive+'commit;');const denied=await run('begin;'+claims+save(rev,randomUUID(),'must-not-write')+'commit;').done;check('archive wins and denies configuration',denied.code!==0&&/DRAFT_CONFIGURATION_UNAVAILABLE/.test(denied.err));
 check('prior section survives archive',read().profile.description==='same-revision');
 check('zero memberships',sql(`select count(*) from public.tenant_memberships where tenant_id=${q(tid)};`)==='0');
 console.log('CONFIGURATION CONCURRENCY PASS '+count);
}finally{
 if(tid && read().status==='archived')sql('begin;'+claims+`select public.platform_restore_archived_tenant_v1(${q(tid)},${q(read().lifecycle_revision)},${q(randomUUID())});commit;`);
 if(tid)sql(`begin;delete from public.audit_logs where tenant_id=${q(tid)};delete from app_private.draft_configuration_requests where tenant_id=${q(tid)};delete from public.platform_tenant_lifecycle_requests where tenant_id=${q(tid)};delete from public.tenant_public_access_controls where tenant_id=${q(tid)};delete from public.platform_audit_logs where tenant_id=${q(tid)};delete from public.platform_tenant_creation_requests where tenant_id=${q(tid)};delete from public.tenant_public_profiles where tenant_id=${q(tid)};delete from public.tenants where id=${q(tid)};commit;`);
 sql(`delete from public.platform_admins where user_id=${q(pa)};delete from auth.users where id=${q(pa)};`);check('fixtures cleaned',sql(`select count(*) from public.tenants where slug=${q(slug)};`)==='0');
}
