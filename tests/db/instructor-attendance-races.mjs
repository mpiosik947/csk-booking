import {spawn,spawnSync} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import assert from 'node:assert/strict';
export async function runAttendanceRaces(database){
 if(!/^c2b_[a-f0-9]{16}$/.test(database))throw Error('ISOLATED_LOCAL_ONLY');
 const args=['exec','-i','supabase_db_csk-booking','psql','-X','-qAt','-v','ON_ERROR_STOP=1','-U','postgres','-d',database];
 const sql=q=>{const r=spawnSync('docker',args,{input:q,encoding:'utf8',timeout:20000});if(r.status)throw Error(r.stderr);return r.stdout.trim();};
 function hold(q,seconds=0.6){const child=spawn('docker',args);let out='',err='',readyResolve;const ready=new Promise(r=>readyResolve=r);
  const done=new Promise((resolve,reject)=>{child.stdout.on('data',d=>{out+=d;if(out.includes('LOCK_HELD'))readyResolve();});child.stderr.on('data',d=>err+=d);child.on('error',reject);child.on('close',c=>c?reject(Error(err)):resolve(out));});
  child.stdin.end(q+`\nselect 'LOCK_HELD';select pg_sleep(${seconds});commit;`);return {ready:Promise.race([ready,done]),done};}
 const [t,a,i,r,e]=Array.from({length:5},randomUUID);
 const auth=u=>`select set_config('request.jwt.claim.sub','${u}',true);select set_config('request.jwt.claims','{"sub":"${u}","role":"authenticated"}',true);set local role authenticated;`;
 const writer=(u,status='present')=>`${auth(u)}select public.set_event_registration_attendance_v1('${r}','${status}',0);`;
 const attempt=(u,status='present')=>sql(`begin;create function pg_temp.try_attendance() returns text language plpgsql as $$begin perform public.set_event_registration_attendance_v1('${r}','${status}',0);return 'ALLOW';exception when others then return sqlstate;end;$$;grant execute on function pg_temp.try_attendance() to authenticated;${auth(u)}select pg_temp.try_attendance();commit;`).split(/\r?\n/).at(-1);
 try{
  sql(`insert into public.tenants(id,slug,name,status)values('${t}','i1d-race-${t}','Synthetic','active');
   insert into public.tenant_plan_assignments(tenant_id,plan_id,status)select '${t}',id,'active' from public.saas_plans where plan_key='current_full_v1';
   insert into auth.users(id,email)select x,x||'@example.invalid' from unnest(array['${a}','${i}']::uuid[])x;
   insert into public.profiles(id,user_id,email)select id,id,email from auth.users where id in('${a}','${i}') on conflict(user_id)do nothing;
   delete from public.tenant_memberships where user_id in('${a}','${i}');
   insert into public.tenant_memberships(tenant_id,user_id,role,status)values('${t}','${a}','admin','active'),('${t}','${i}','instructor','active');
   insert into public.events(id,tenant_id,title,event_date,start_time,end_time)values('${e}','${t}','Synthetic',(now() at time zone 'Europe/Warsaw'+interval '30 minutes')::date,(now() at time zone 'Europe/Warsaw'+interval '30 minutes')::time,(now() at time zone 'Europe/Warsaw'+interval '31 minutes')::time);
   insert into public.event_registrations(id,tenant_id,event_id,customer_name,customer_email,customer_phone)values('${r}','${t}','${e}','Synthetic','recipient@example.invalid','0');
   insert into public.event_instructors(tenant_id,event_id,instructor_user_id,assigned_by)values('${t}','${e}','${i}','${a}');`);
  const reset=()=>sql(`delete from public.events where id='${e}';
   update public.tenant_memberships set status='active',role='instructor' where user_id='${i}' and tenant_id='${t}';
   insert into public.events(id,tenant_id,title,event_date,start_time,end_time)values('${e}','${t}','Synthetic',(now() at time zone 'Europe/Warsaw'+interval '30 minutes')::date,(now() at time zone 'Europe/Warsaw'+interval '30 minutes')::time,(now() at time zone 'Europe/Warsaw'+interval '31 minutes')::time);
   insert into public.event_registrations(id,tenant_id,event_id,customer_name,customer_email,customer_phone)values('${r}','${t}','${e}','Synthetic','recipient@example.invalid','0');
   insert into public.event_instructors(tenant_id,event_id,instructor_user_id,assigned_by)values('${t}','${e}','${i}','${a}');`);
  for(const [name,first,actor,want] of [
   ['two instructors',writer(i),i,'40001'],['instructor vs admin',writer(i),a,'40001'],
   ['cancellation wins',`${auth(a)}select public.admin_cancel_event_v1('${e}');`,i,'42501'],
   ['unassignment wins',`select 1 from public.events where id='${e}' for update;update public.event_instructors set unassigned_at=clock_timestamp(),unassigned_by='${a}' where event_id='${e}';`,i,'42501'],
   ['suspension wins',`update public.tenant_memberships set status='suspended' where user_id='${i}' and tenant_id='${t}';`,i,'42501'],
   ['role change wins',`update public.tenant_memberships set role='user' where user_id='${i}' and tenant_id='${t}';`,i,'42501'],
  ]){reset();const h=hold('begin;'+first);await h.ready;assert.equal(attempt(actor,'no_show'),want,name);await h.done;console.log('RACE PASS '+name);}
  reset();const h=hold('begin;'+writer(i));await h.ready;
  sql(`begin;${auth(a)}select public.admin_cancel_event_v1('${e}');commit;`);await h.done;
  assert.equal(sql(`select attendance_status from public.event_registrations where id='${r}'`),'present');console.log('RACE PASS attendance wins cancellation; history retained');
  for(const [name,change] of [
   ['unassignment',`update public.event_instructors set unassigned_at=clock_timestamp(),unassigned_by='${a}' where event_id='${e}'`],
   ['suspension',`update public.tenant_memberships set status='suspended' where user_id='${i}' and tenant_id='${t}'`],
  ]){reset();const lock=hold('begin;'+writer(i));await lock.ready;sql(`begin;${change};commit;`);await lock.done;
   assert.equal(sql(`select attendance_status from public.event_registrations where id='${r}'`),'present');console.log('RACE PASS attendance wins '+name);}
  reset();
  sql(`update public.events set event_date=((clock_timestamp()-interval '24 hours'+interval '2 seconds') at time zone 'Europe/Warsaw')::date,
   start_time='00:00',end_time=((clock_timestamp()-interval '24 hours'+interval '2 seconds') at time zone 'Europe/Warsaw')::time where id='${e}';`);
  const deadline=hold(`begin;select 1 from public.events where id='${e}' for update;`,3);
  await deadline.ready;assert.equal(attempt(i),'42501','deadline rechecked after event lock wait');await deadline.done;
  assert.equal(sql(`select attendance_version from public.event_registrations where id='${r}'`),'0');console.log('RACE PASS deadline evaluated after lock wait');
 }finally{
  sql(`delete from public.events where tenant_id='${t}';delete from public.tenant_memberships where tenant_id='${t}';delete from public.profiles where user_id in('${a}','${i}');delete from auth.users where id in('${a}','${i}');delete from public.tenant_plan_assignments where tenant_id='${t}';delete from public.audit_logs where tenant_id='${t}';delete from public.tenants where id='${t}';`);
 }
}
