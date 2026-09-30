import {spawn,spawnSync} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import assert from 'node:assert/strict';
export async function runInstructorEmailRaces(database){
 if(!/^c2b_[a-f0-9]{16}$/.test(database))throw Error('ISOLATED_LOCAL_ONLY');
 const args=['exec','-i','supabase_db_csk-booking','psql','-X','-qAt','-v','ON_ERROR_STOP=1','-U','postgres','-d',database];
 const sql=q=>{const r=spawnSync('docker',args,{input:q,encoding:'utf8',timeout:20000});if(r.status)throw Error(r.stderr);return r.stdout.trim();};
 function hold(q){const child=spawn('docker',args);let out='',err='',readyResolve;const ready=new Promise(r=>readyResolve=r);
  const done=new Promise((resolve,reject)=>{child.stdout.on('data',d=>{out+=d;if(out.includes('LOCK_HELD'))readyResolve();});child.stderr.on('data',d=>err+=d);child.on('error',reject);child.on('close',c=>c?reject(Error(err)):resolve(out));});
  child.stdin.end(q+"\nselect 'LOCK_HELD';select pg_sleep(0.6);commit;");return {ready:Promise.race([ready,done]),done};}
 const [t,a,i,e]=Array.from({length:4},randomUUID);
 const actor=`select set_config('request.jwt.claim.sub','${a}',true);`;
 const claim=`select public.claim_instructor_email_batch_v1('${e}');`;
 const cancel=`${actor}select public.admin_cancel_event_v1('${e}');`;
 const remove=`select 1 from public.events where id='${e}' for update;update public.event_instructors set unassigned_at=clock_timestamp(),unassigned_by='${a}' where event_id='${e}' and unassigned_at is null;`;
 try{
  sql(`insert into public.tenants(id,slug,name,status)values('${t}','i1f-race-${t}','Synthetic','active');
   insert into public.tenant_plan_assignments(tenant_id,plan_id,status)select '${t}',id,'active' from public.saas_plans where plan_key='current_full_v1';
   insert into auth.users(id,email)select x,x||'@example.invalid' from unnest(array['${a}','${i}']::uuid[])x;
   insert into public.profiles(id,user_id,email)select id,id,email from auth.users where id in('${a}','${i}') on conflict(user_id)do nothing;
   delete from public.tenant_memberships where user_id in('${a}','${i}');
   insert into public.tenant_memberships(tenant_id,user_id,role,status)values('${t}','${a}','admin','active'),('${t}','${i}','instructor','active');`);
  const reset=()=>sql(`delete from public.email_deliveries where tenant_id='${t}';delete from public.events where id='${e}';
   update public.tenants set status='active' where id='${t}';
   insert into public.events(id,tenant_id,title,event_date,start_time,end_time)values('${e}','${t}','Synthetic',current_date+30,'10:00','11:00');
   insert into public.event_instructors(tenant_id,event_id,instructor_user_id,assigned_by)values('${t}','${e}','${i}','${a}');`);
  for(const [name,first] of [['cancellation wins',cancel],['removal wins',remove],['suspension wins',`update public.tenants set status='suspended' where id='${t}';`]]){
   reset();const h=hold('begin;'+first);await h.ready;sql(claim);await h.done;
   assert.equal(sql(`select count(*) from public.email_deliveries where tenant_id='${t}' and message_type='instructor_assignment' and attempt_count>0`),'0');console.log('RACE PASS '+name);
  }
  for(const [name,second] of [['cancellation',cancel],['removal',remove]]){
   reset();const h=hold('begin;'+claim);await h.ready;sql('begin;'+second+'commit;');await h.done;
   const lease=sql(`select claim_id from public.email_deliveries where tenant_id='${t}' and message_type='instructor_assignment'`);
   assert.equal(sql(`select public.read_instructor_email_attempt_v1('${lease}') is not null`),'t');
   console.log('RACE PASS admission before '+name+'; admitted attempt may proceed');
   sql(`update public.email_deliveries set claim_expires_at=clock_timestamp()-interval '1 second' where claim_id='${lease}';`);
   sql(claim);assert.equal(sql(`select attempt_count from public.email_deliveries where tenant_id='${t}' and message_type='instructor_assignment'`),'1');
   console.log('RACE PASS crash lease expiry after '+name+' denies positive retry');
  }
  reset();const h=hold('begin;'+claim);await h.ready;assert.equal(sql(claim),'[]');await h.done;
  assert.equal(sql(`select attempt_count from public.email_deliveries where tenant_id='${t}'`),'1');console.log('RACE PASS concurrent claim one winner');
  const lease=sql(`select claim_id from public.email_deliveries where tenant_id='${t}'`);
  sql(`select public.complete_instructor_email_v1('${lease}',false,null);begin;${cancel}commit;`);
  sql(claim);assert.equal(sql(`select attempt_count from public.email_deliveries where tenant_id='${t}' and message_type='instructor_assignment'`),'1');
  console.log('RACE PASS failed/uncertain positive attempt not readmitted after cancellation');
 }finally{
  sql(`delete from public.email_deliveries where tenant_id='${t}';delete from public.events where id='${e}';delete from public.audit_logs where tenant_id='${t}';delete from public.tenant_memberships where tenant_id='${t}';delete from public.tenant_plan_assignments where tenant_id='${t}';delete from public.tenants where id='${t}';delete from auth.users where id in('${a}','${i}');`);
 }
}
