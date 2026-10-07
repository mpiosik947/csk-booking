// Local-only, destructive scratch fixtures: caller must drop this disposable DB
// after the suite. Never accepts postgres, a production URL, or a remote target.
import fs from 'node:fs';
import {spawn, spawnSync} from 'node:child_process';
import {randomUUID} from 'node:crypto';
const [db, report] = process.argv.slice(2);
if (!/^pam_1d_[a-f0-9]{16}$/.test(db ?? '') || !report) throw Error('LOCAL_SCRATCH_REQUIRED');
const container = 'supabase_db_csk-booking';
const args = ['exec','-i',container,'psql','-X','-At','-v','VERBOSITY=verbose','-v','ON_ERROR_STOP=1','-U','postgres','-d',db];
const results = [];
const children = new Set();
function sql(q) {
  const r = spawnSync('docker', args, {input:q, encoding:'utf8'});
  if (r.status) throw Error(r.stderr);
  return r.stdout.trim();
}
const actor = (u,q) => `select set_config('app.product10d_test_enforce','on',true);select set_config('request.jwt.claims','{"sub":"${u}","role":"authenticated"}',true);select set_config('request.jwt.claim.sub','${u}',true);set local role authenticated;${q};reset role;`;
function setup(kind) {
  const x = Object.fromEntries(['pa','admin','user','tenant','lane','event','domain','request'].map(k=>[k,randomUUID()]));
  sql(`begin;
  insert into auth.users(id,email,email_confirmed_at,is_anonymous)values ${[x.pa,x.admin,x.user].map(u=>`('${u}','${u}@example.invalid',now(),false)`).join(',')};
  insert into public.profiles(id,user_id,email,full_name,phone)select id,id,email,'Synthetic','000000000' from auth.users where id in('${x.pa}','${x.admin}','${x.user}')on conflict(user_id)do update set full_name='Synthetic',phone='000000000';
  insert into public.platform_admins(user_id,status)values('${x.pa}','active');
  insert into public.tenants(id,name,slug,status)values('${x.tenant}','Synthetic race','pam1d-${x.tenant}','active');
  insert into public.tenant_public_profiles(tenant_id,public_slug,display_name,city,is_public,show_booking,show_events,show_instructor,show_pricing)values('${x.tenant}','pam1dpublic-${x.tenant}','Synthetic','Synthetic',false,false,false,false,false);
  insert into public.tenant_memberships(tenant_id,user_id,role,status)values('${x.tenant}','${x.admin}','admin','active'),('${x.tenant}','${x.user}','user','active');
  insert into public.tenant_plan_assignments(tenant_id,plan_id,status)select '${x.tenant}',id,'active' from public.saas_plans where plan_key='current_full_v1';
  ${kind==='reservation'?`
  insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,whole_lane_bookable,positions_bookable)values('${x.lane}','${x.tenant}','Synthetic lane','test',true,2,60,901,'PLN','lane',true,false);
  insert into public.lane_booking_rules(lane_id,online_bookable,max_people_online)values('${x.lane}',true,2);
  insert into public.lane_booking_durations(lane_id,duration_minutes,is_active)values('${x.lane}',60,true);
  insert into public.lane_pricing_rules(lane_id,day_group,min_shooters,max_shooters,label,hourly_price,display_order,is_active)values('${x.lane}','mon_thu',1,2,'Synthetic',10,1,true),('${x.lane}','fri_sun',1,2,'Synthetic',10,1,true);`:''}
  ${kind==='registration'?`insert into public.events(id,tenant_id,title,event_date,start_time,end_time,is_active)values('${x.event}','${x.tenant}','Synthetic event',current_date+7,'10:00','11:00',true);`:''}
  ${kind==='domain'?`insert into public.tenant_domains(id,tenant_id,hostname,domain_type,status,verified_at,verification_expires_at)values('${x.domain}','${x.tenant}','${x.domain}.example.invalid','custom_domain','verified',now(),now()+interval '1 day');`:''}
  ${kind==='activation'?`update public.tenants set status='suspended' where id='${x.tenant}';`:''}
  commit;`);
  x.revision = Number(sql(`select lifecycle_revision from public.tenants where id='${x.tenant}';`));
  return x;
}
const life = (x,op,revision=x.revision,request=randomUUID()) => actor(x.pa,`select public.${op==='archive'?'platform_archive_tenant_v1':'platform_restore_archived_tenant_v1'}('${x.tenant}',${revision},'${request}')`);

const read = x=>actor(x.pa,`select public.platform_get_tenant_delete_eligibility_v1('${x.tenant}')`);
function value(out){const line=out.trim().split(/\r?\n/).find(l=>l.startsWith('{"tenant"'));if(!line)throw Error('MISSING_DTO '+out);return JSON.parse(line);}
function session(){const p=spawn('docker',args,{windowsHide:true});children.add(p);let out='',err='';p.stdout.on('data',s=>out+=s);p.stderr.on('data',s=>err+=s);const done=new Promise(resolve=>p.on('close',code=>{children.delete(p);resolve({code,out,err});}));return {p,done,output:()=>out};}
async function until(check,label){const end=Date.now()+8000;while(Date.now()<end){if(check())return;await new Promise(r=>setTimeout(r,50));}throw Error('WAIT_TIMEOUT '+label);}
const same=(a,b)=>JSON.stringify(a)===JSON.stringify(b);
try{
 for(const kind of ['reservation','registration','archive','restore','admin','plan','domain','audit']){
  const x=setup(kind);
  if(kind==='restore')sql('begin;'+life(x,'archive')+'commit;');
  const before=value(sql('begin;'+read(x)+'rollback;'));
  const key=Math.floor(Math.random()*1000000000)+1000000;
  const writer=session();
  writer.p.stdin.write(`begin;set local statement_timeout='12s';select pg_advisory_xact_lock(${key});select 'HOLDER_READY';\n`);
  await until(()=>writer.output().includes('HOLDER_READY'),'writer ready');
  const reader=session();
  // Snapshot is fixed before waiting on the advisory gate in this ONE statement.
  // The function runs after the concurrent writer commits but must retain the old view.
  reader.p.stdin.end(`begin;set local statement_timeout='12s';set local application_name='pam1d_snapshot_reader';${actor(x.pa,`with gate as materialized (select pg_advisory_xact_lock(${key})) select public.platform_get_tenant_delete_eligibility_v1('${x.tenant}') from gate`)}commit;`);
  await until(()=>sql("select exists(select 1 from pg_stat_activity where datname=current_database() and application_name='pam1d_snapshot_reader' and wait_event_type='Lock');")==='t','reader snapshot blocked');
  const mutation=kind==='reservation'?actor(x.user,`select public.create_reservation_v2('${x.lane}',current_date+7,'12:00',60,1,'${x.request}')`):
   kind==='registration'?actor(x.user,`select public.register_for_event('${x.event}',false)`):
   kind==='archive'?life(x,'archive'):kind==='restore'?life(x,'restore',1):
   kind==='admin'?actor(x.pa,`select public.platform_add_tenant_admin_v1('${x.tenant}','${x.user}','{"role":"user","status":"active"}'::jsonb,'${randomUUID()}')`):
   kind==='plan'?actor(x.pa,`select public.platform_change_tenant_plan_v2('${x.tenant}','booking_only_v1','1','${randomUUID()}')`):
   kind==='domain'?actor(x.pa,`select public.platform_manage_tenant_domain_v1('${x.tenant}','activate','${x.domain}')`):
   `insert into public.audit_logs(tenant_id,action,target_type,target_id)values('${x.tenant}','tenant_public_profile_updated','tenant_public_profile','${x.tenant}');`;
  writer.p.stdin.end(mutation+'commit;');
  const w=await writer.done,r=await reader.done;
  if(w.code||r.code)throw Error(kind+': '+w.err+r.err);
  const observed=value(r.out),after=value(sql('begin;'+read(x)+'rollback;'));
  const positive=kind==='reservation'?after.dependency_summary.reservations===1:
   kind==='registration'?after.dependency_summary.event_registrations===1:
   kind==='archive'?after.tenant.status==='archived':kind==='restore'?after.tenant.status==='dormant':
   kind==='admin'?after.dependency_summary.platform_admin_management_requests===1:
   kind==='plan'?after.dependency_summary.platform_plan_change_requests===1:
   kind==='domain'?sql(`select status from public.tenant_domains where id='${x.domain}';`)==='active':
   after.dependency_summary.audit_logs===before.dependency_summary.audit_logs+1;
  const result={scenario:kind,writerCommitted:positive,exactBeforeSnapshot:same(before,observed),canHardDelete:observed.eligibility.can_hard_delete,deadlock:/40P01/.test(w.err+r.err),timeout:/57014/.test(w.err+r.err)};
  result.pass=positive&&result.exactBeforeSnapshot&&!result.canHardDelete&&!result.deadlock&&!result.timeout;results.push(result);console.log(JSON.stringify(result));if(!result.pass)throw Error('RACE_FAILED '+kind);
 }
}catch(e){console.error(e.message);process.exitCode=1;}
finally{for(const p of children){p.stdin.end('rollback;');}fs.writeFileSync(report,JSON.stringify({db,results,productionWrites:0},null,2));}
