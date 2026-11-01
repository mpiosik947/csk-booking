import {spawn,spawnSync} from 'node:child_process';import {randomUUID} from 'node:crypto';import assert from 'node:assert/strict';
const db=process.argv[2];assert.match(db??'',/^sbr3_[a-f0-9]{16}$/);
const base=['exec','-i','supabase_db_csk-booking','psql','-X','-qAt','-v','ON_ERROR_STOP=1','-U','postgres','-d',db];
const q=s=>"'"+String(s).replaceAll("'","''")+"'";
const sql=s=>{const r=spawnSync('docker',base,{input:s,encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr);return r.stdout.trim();};
const pa=randomUUID(),prefix='draftrace-'+randomUUID().slice(0,8);
const claims=`select set_config('request.jwt.claim.sub',${q(pa)},true);set local role authenticated;`;
const call=(slug,key)=>`select public.platform_create_tenant_draft_v1('Race',${q(slug)},${q(slug+'-public')},'City',null,${q(key)});`;
function run(statement){const p=spawn('docker',base,{windowsHide:true});let out='',err='',readyResolve;const ready=new Promise(r=>readyResolve=r);const done=new Promise(r=>{p.stdout.on('data',b=>{out+=b;if(out.includes('LOCKED'))readyResolve();});p.stderr.on('data',b=>err+=b);p.on('close',code=>{readyResolve();r({code,out,err});});});p.stdin.end("set statement_timeout='10s';"+statement);return {ready,done};}
let count=0;const check=(name,value)=>{assert.ok(value,name);console.log('PASS '+name);count++;};
try{
 sql(`insert into auth.users(id,email,email_confirmed_at,is_anonymous) values(${q(pa)},${q(pa+'@example.invalid')},now(),false);insert into public.platform_admins(user_id,status) values(${q(pa)},'active');`);
 for(const mode of ['same-key','same-slug','different-slugs']){
  const slug=prefix+'-'+mode,key=randomUUID(),secondSlug=mode==='different-slugs'?slug+'-b':slug,secondKey=mode==='same-key'?key:randomUUID();
  const a=run('begin;'+claims+call(slug,key)+"select 'LOCKED';select pg_sleep(0.4);commit;");await a.ready;
  const b=run('begin;'+claims+call(secondSlug,secondKey)+'commit;');const [x,y]=await Promise.all([a.done,b.done]);
  check(mode+' result',x.code===0&&(mode==='same-slug'?y.code!==0&&/duplicate key/.test(y.err):y.code===0));
  check(mode+' cardinality',sql(`select count(*) from public.tenants where slug in (${q(slug)},${q(secondSlug)});`)===(mode==='different-slugs'?'2':'1'));
  // Response loss is retried against the same durable key, after COMMIT.
  check(mode+' lost-response replay',sql('begin;'+claims+call(slug,key)+'rollback;').includes('"initial_public_access_state": "coming_soon"'));
 }
 check('no membership for any created tenant',sql(`select count(*) from public.tenant_memberships where tenant_id in(select tenant_id from public.platform_tenant_creation_requests where actor_user_id=${q(pa)});`)==='0');
 check('one creation audit per tenant',sql(`select count(*) from public.platform_audit_logs where actor_user_id=${q(pa)} and action='tenant_created';`)==='4');
 console.log('CONCURRENCY PASS '+count);
}finally{
 sql(`begin;create temporary table cleanup_ids as select tenant_id from public.platform_tenant_creation_requests where actor_user_id=${q(pa)};delete from public.tenant_public_access_controls where tenant_id in(select tenant_id from cleanup_ids);delete from public.platform_audit_logs where actor_user_id=${q(pa)};delete from public.platform_tenant_creation_requests where actor_user_id=${q(pa)};delete from public.tenant_public_profiles where tenant_id in(select tenant_id from cleanup_ids);delete from public.tenants where id in(select tenant_id from cleanup_ids);delete from public.platform_admins where user_id=${q(pa)};delete from auth.users where id=${q(pa)};commit;`);
 assert.equal(sql(`select count(*) from public.tenants where slug like ${q(prefix+'%')};`),'0');console.log('CONCURRENCY FIXTURES 0');
}
