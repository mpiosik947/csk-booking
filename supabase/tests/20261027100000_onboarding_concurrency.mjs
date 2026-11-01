import {spawn,spawnSync} from 'node:child_process';
import {randomUUID} from 'node:crypto';
const db=process.argv[2];
if(!/^(?:onboard_1a|sbr3)_[0-9a-f]{16}$/.test(db))throw Error('LOCAL_TARGET_DENIED');
const args=['exec','-i','supabase_db_csk-booking','psql','-X','-At','-v','ON_ERROR_STOP=1','-U','postgres','-d',db];
const q=x=>"'"+String(x).replaceAll("'","''")+"'";
function sql(text){const r=spawnSync('docker',args,{input:text,encoding:'utf8'});if(r.status!==0)throw Error(r.stderr);return r.stdout.trim();}
function run(text){
 const child=spawn('docker',args,{stdio:['pipe','pipe','pipe']});let stdout='',stderr='',readyResolve,readyReject;
 const ready=new Promise((resolve,reject)=>{readyResolve=resolve;readyReject=reject;});
 // Sessions without a marker need no readiness waiter.
 ready.catch(()=>{});
 const done=new Promise(resolve=>{child.stdout.on('data',b=>{stdout+=b; if(stdout.includes('LOCKED'))readyResolve();});child.stderr.on('data',b=>stderr+=b);child.on('close',code=>{if(!stdout.includes('LOCKED'))readyReject(Error(stderr));resolve({code,stdout,stderr});});child.stdin.end("set statement_timeout='10s';\n"+text);});
 return {ready,done};
}
const results=[];
function check(label,value){if(!value)throw Error('FAIL '+label);results.push({label,pass:true});console.log('PASS '+label);}
const pa=randomUUID(),owner=randomUUID(),other=randomUUID();
const prefix='o1acon-'+randomUUID().replaceAll('-','').slice(0,12);
function claims(actor){return `select set_config('request.jwt.claims',${q(JSON.stringify({sub:actor,role:'authenticated'}))},true);select set_config('request.jwt.claim.sub',${q(actor)},true);set local role authenticated;`;}
function bundle(actor,user,key,slug,publicSlug=slug+'-public'){if(actor!==pa)throw Error('Fixture actor mismatch');return `select public.platform_create_tenant_bundle_v2('Concurrency',${q(slug)},${q(publicSlug)},'City','booking_only_v1',${q(user)},${q(key)});`;}
// NEW-TENANT-2D retires NEW legacy bundles. Current creation/configuration/handover
// races live in tests/db/platform-*-races.mjs; keep this regression for closure
// and exact read-only receipt replay, not the retired first-admin bypass.
const tid=randomUUID(),key=randomUUID(),slug=prefix+'-historical';
try{
 sql('begin;insert into auth.users(id,email,email_confirmed_at,is_anonymous) values '+[pa,owner,other].map(id=>'('+q(id)+','+q(id+'@example.invalid')+',now(),false)').join(',')+';insert into public.platform_admins(user_id,status) values('+q(pa)+',\'active\');commit;');
 const newKey=randomUUID();
 for(const mode of ['same-key','different-key','different-user']){
  const a=run('begin;'+claims(pa)+bundle(pa,owner,newKey,prefix+'-new')+'commit;');
  const b=run('begin;'+claims(pa)+bundle(pa,mode==='different-user'?other:owner,mode==='same-key'?newKey:randomUUID(),prefix+'-new')+'commit;');
  const pair=await Promise.all([a.done,b.done]);check(mode+' new bundles both denied without deadlock',pair.every(r=>r.code!==0&&/HANDOVER_REQUIRED/.test(r.stderr)&&!/deadlock/i.test(r.stderr)));
 }
 check('new requests persist zero tenant/receipt/audit',sql('select (select count(*) from public.tenants where slug like '+q(prefix+'%')+')+(select count(*) from public.platform_tenant_creation_requests where actor_user_id='+q(pa)+')+(select count(*) from public.platform_audit_logs where actor_user_id='+q(pa)+');')==='0');
 // Historical receipt fixture: no RPC under test is replaced or spoofed.
 sql('begin;insert into public.tenants(id,name,slug,status) values('+q(tid)+',\'Concurrency\','+q(slug)+',\'dormant\');insert into public.platform_tenant_creation_requests(actor_user_id,creation_request_id,payload_hash,tenant_id,creation_kind) values('+q(pa)+','+q(key)+',encode(sha256(convert_to(jsonb_build_object(\'name\',\'Concurrency\',\'city\',\'City\',\'tenant_slug\','+q(slug)+',\'public_slug\','+q(slug+'-public')+',\'plan_key\',\'booking_only_v1\',\'admin\','+q(owner)+'::uuid)::text,\'UTF8\')),\'hex\'),'+q(tid)+',\'legacy\');commit;');
 const first=run('begin;'+claims(pa)+bundle(pa,owner,key,slug)+"select 'LOCKED';select pg_sleep(0.5);commit;");await first.ready;
 const second=run('begin;'+claims(pa)+bundle(pa,owner,key,slug)+'commit;');const pair=await Promise.all([first.done,second.done]);
 check('parallel historical receipt replay succeeds',pair.every(r=>r.code===0));
 const receipts=pair.map(r=>JSON.parse(r.stdout.split('\n').find(line=>line.startsWith('{')&&line.includes('initial_admin_user_id'))));check('historical receipts are identical',JSON.stringify(receipts[0])===JSON.stringify(receipts[1]));
 check('replay creates no membership or audit',sql('select (select count(*) from public.tenant_memberships where tenant_id='+q(tid)+')+(select count(*) from public.platform_audit_logs where tenant_id='+q(tid)+');')==='0');
 const conflict=await run('begin;'+claims(pa)+bundle(pa,other,key,slug)+'commit;').done;check('changed user on same receipt rejected',conflict.code!==0&&/payload conflict/.test(conflict.stderr));
 sql('update public.platform_admins set status=\'suspended\' where user_id='+q(pa)+';');const denied=await run('begin;'+claims(pa)+bundle(pa,owner,key,slug)+'commit;').done;check('historical replay rechecks PA authority',denied.code!==0&&/Not authorized/.test(denied.stderr));
}finally{
 sql('begin;delete from public.platform_tenant_creation_requests where actor_user_id='+q(pa)+';delete from public.tenants where id='+q(tid)+';delete from public.platform_admins where user_id='+q(pa)+';delete from auth.users where id in('+[pa,owner,other].map(q).join(',')+');commit;');
 check('legacy race fixtures removed',sql('select (select count(*) from public.tenants where slug like '+q(prefix+'%')+')+(select count(*) from auth.users where id in('+[pa,owner,other].map(q).join(',')+'));')==='0');
}
console.log('LEGACY BUNDLE CLOSURE CONCURRENCY PASS '+results.length);
