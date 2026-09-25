import { spawn, spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';

export async function domainConcurrency(database) {
 if(!/^p10e_isolated_[0-9a-f]{16}$/.test(database))throw Error('ISOLATED_DATABASE_REQUIRED');
 const args=['exec','-i','supabase_db_csk-booking','psql','-X','-At','-v','ON_ERROR_STOP=1','-U','postgres','-d',database];
 const sql=q=>{const r=spawnSync('docker',args,{input:q,encoding:'utf8'});if(r.status!==0)throw Error(r.stderr);return r.stdout.trim();};
 const a=randomUUID(),b=randomUUID(),pa=randomUUID(),d=randomUUID(),e=randomUUID();
 const run=q=>new Promise((resolve,reject)=>{const p=spawn('docker',args);let out='',err='';p.stdout.on('data',v=>out+=v);p.stderr.on('data',v=>err+=v);p.on('error',reject);p.on('close',code=>resolve({code,out,err}));p.stdin.end(`begin;set local statement_timeout='10s';set local request.jwt.claims='{"sub":"${pa}","role":"authenticated"}';set local role authenticated;${q};commit;`);});
 try {
  sql(`begin;insert into auth.users(id,email) values('${pa}','domain-race@example.invalid');insert into public.platform_admins(user_id,status) values('${pa}','active');insert into public.tenants(id,name,slug,status) values('${a}','Race A','domain-race-a','dormant'),('${b}','Race B','domain-race-b','dormant');insert into public.tenant_domains(id,tenant_id,hostname,domain_type,status,verified_at,verification_expires_at) values('${d}','${a}','race-first.test','custom_domain','verified',now(),now()+interval '1 day'),('${e}','${a}','race-second.test','custom_domain','active',now(),now()+interval '1 day');commit;`);
  const dup=await Promise.all([a,b].map(t=>run(`select public.platform_manage_tenant_domain_v1('${t}','add',null,'race-duplicate.test')`)));
  assert.equal(dup.filter(r=>r.code===0).length,1);assert.ok(dup.some(r=>r.err.includes('duplicate key')));
  const active=await Promise.all([1,2].map(()=>run(`select public.platform_manage_tenant_domain_v1('${a}','activate','${d}')`)));
  assert.equal(active.filter(r=>r.code===0).length,1);
  const primary=await Promise.all(Array.from({length:8},(_,i)=>run(`select public.platform_manage_tenant_domain_v1('${a}','set_primary','${i%2?d:e}')`)));
  assert.ok(primary.every(r=>r.code===0));assert.equal(sql(`select count(*) from public.tenant_domains where tenant_id='${a}' and is_primary;`),'1');
  assert.ok([...dup,...active,...primary].every(r=>!/deadlock/i.test(r.err)));
  console.log('DOMAIN_CONCURRENCY=3/3 PASS; DEADLOCKS=0; DUPLICATE_HOST=DENY; PRIMARY_UNIQUE=PASS');
 } finally {
  sql(`begin;delete from public.platform_audit_logs where tenant_id in('${a}','${b}');delete from public.tenant_domains where tenant_id in('${a}','${b}');delete from public.platform_admins where user_id='${pa}';delete from public.profiles where user_id='${pa}';delete from auth.users where id='${pa}';delete from public.tenants where id in('${a}','${b}');commit;`);
  assert.equal(sql(`select (select count(*) from public.tenants where id in('${a}','${b}'))+(select count(*) from auth.users where id='${pa}');`),'0');
  console.log('DOMAIN_CONCURRENCY_FIXTURE_CLEANUP=0');
 }
}
