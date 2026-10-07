// Local-only, destructive scratch fixtures: caller must drop this disposable DB
// after the suite. Never accepts postgres, a production URL, or a remote target.
import fs from 'node:fs';
import {spawn, spawnSync} from 'node:child_process';
import {randomUUID} from 'node:crypto';
const [db, report] = process.argv.slice(2);
if (!/^pam_1c_r3_[a-f0-9]{16}$/.test(db ?? '') || !report) throw Error('LOCAL_SCRATCH_REQUIRED');
const container = 'supabase_db_csk-booking';
const args = ['exec','-i',container,'psql','-X','-At','-v','VERBOSITY=verbose','-v','ON_ERROR_STOP=1','-U','postgres','-d',db];
const results = [];
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
  insert into public.tenants(id,name,slug,status)values('${x.tenant}','Synthetic race','pam1cr3-${x.tenant}','active');
  insert into public.tenant_public_profiles(tenant_id,public_slug,display_name,city,is_public,show_booking,show_events,show_instructor,show_pricing)values('${x.tenant}','pam1cr3public-${x.tenant}','Synthetic','Synthetic',false,false,false,false,false);
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
const activate = x=>actor(x.pa,`select public.platform_set_tenant_state_v1('${x.tenant}','activate')`);
function state(x) {
  return JSON.parse(sql(`select jsonb_build_object('status',t.status,'revision',t.lifecycle_revision,'public',p.is_public,'reservations',(select count(*) from public.reservations where tenant_id=t.id),'registrations',(select count(*) from public.event_registrations where tenant_id=t.id),'active_admins',(select count(*) from public.tenant_memberships where tenant_id=t.id and role='admin' and status='active'),'archive_audits',(select count(*) from public.platform_audit_logs where tenant_id=t.id and action='tenant_archived'),'effective_domain',exists(select 1 from public.tenant_domains d where d.tenant_id=t.id and d.status='active' and public.resolve_public_tenant_domain_v1(d.hostname) is not null)) from public.tenants t join public.tenant_public_profiles p on p.tenant_id=t.id where t.id='${x.tenant}';`));
}
async function race(label,x,first,second,expect) {
  let outA='',errA='',outB='',errB='',b,doneB;
  const a=spawn('docker',args,{windowsHide:true});const doneA=new Promise(r=>a.on('close',r));
  a.stderr.on('data',v=>errA+=v);
  a.stdout.on('data',v=>{outA+=v;if(!b&&outA.includes('RACE_HOLD')){
    b=spawn('docker',args,{windowsHide:true});doneB=new Promise(r=>b.on('close',r));
    b.stdout.on('data',v=>outB+=v);b.stderr.on('data',v=>errB+=v);
    b.stdin.end(`begin;set local application_name='pam1cr3_contender';set local lock_timeout='5s';set local statement_timeout='8s';${second}commit;`);
  }});
  a.stdin.end(`begin;set local lock_timeout='5s';set local statement_timeout='8s';${first}select 'RACE_HOLD';select pg_sleep(1.5);select jsonb_build_object('contender_waiting',exists(select 1 from pg_stat_activity where datname=current_database() and application_name='pam1cr3_contender' and wait_event_type='Lock'));commit;`);
  const exitA=await doneA;if(!b)throw Error(label+' holder failed: '+errA);const exitB=await doneB;
  const r={label,exitA,exitB,outA,errA,outB,errB,state:state(x),deadlock:/40P01/.test(errA+errB),timeout:/57014|lock timeout/.test(errA+errB)};
  r.pass=exitA===0&&!r.deadlock&&!r.timeout&&expect(r);
  results.push(r);console.log(JSON.stringify({label,pass:r.pass,state:r.state,error:r.errB}));
  if(!r.pass)throw Error('RACE_FAILED '+label);return r;
}
function check(label,passed,evidence) {results.push({label,pass:passed,evidence});if(!passed)throw Error(label);console.log('PASS '+label);}
try {
  const x=setup('restore');sql('begin;'+life(x,'archive')+'commit;');
  await race('restore vs stale activation',x,life(x,'restore',1),activate(x),r=>r.exitB!==0&&/PT409: TENANT_REVISION_STALE/.test(r.errB)&&r.outA.includes('"contender_waiting": true')&&r.state.status==='dormant'&&!r.state.public&&r.state.revision===2);
  const fresh=sql('begin;'+activate(x)+'commit;');
  check('fresh committed post-restore activation',state(x).status==='active'&&state(x).revision===3&&!state(x).public,fresh);
  const y=setup('restore');sql('begin;'+life(y,'archive')+'commit;');
  const first=`select 1 from public.tenants where id='${y.tenant}' for no key update;${actor(y.pa,`do $proof$ begin begin perform public.platform_set_tenant_state_v1('${y.tenant}','activate');raise exception 'UNEXPECTED_ACTIVATION';exception when sqlstate '55000' then raise notice 'EXPECTED_INVALID_TRANSITION';end;end;$proof$`)}`;
  await race('activation lock first while archived',y,first,life(y,'restore',1),r=>r.errA.includes('EXPECTED_INVALID_TRANSITION')&&r.exitB!==0&&/55P03/.test(r.errB)&&r.state.status==='archived'&&!r.state.public);
  sql('begin;'+life(y,'restore',1)+'commit;');check('restore safely retries after invalid activation',state(y).status==='dormant'&&!state(y).public,state(y));
  for(const kind of ['archive','restore','plan','admin','activation','publication','domain','reservation','registration','replay']) {
    const z=setup(kind);const request=randomUUID();const archive=life(z,'archive',z.revision,request);
    const second=kind==='archive'?life(z,'archive'):kind==='restore'?life(z,'restore'):kind==='replay'?archive:
      kind==='activation'?activate(z):kind==='publication'?actor(z.pa,`select public.platform_set_tenant_state_v1('${z.tenant}','publish')`):
      kind==='plan'?actor(z.pa,`select public.platform_change_tenant_plan_v2('${z.tenant}','booking_only_v1','1','${randomUUID()}')`):
      kind==='admin'?actor(z.pa,`select public.platform_add_tenant_admin_v1('${z.tenant}','${z.user}','{"role":"user","status":"active"}'::jsonb,'${randomUUID()}')`):
      kind==='domain'?actor(z.pa,`select public.platform_manage_tenant_domain_v1('${z.tenant}','activate','${z.domain}')`):
      kind==='reservation'?actor(z.user,`select public.create_reservation_v2('${z.lane}',current_date+7,'12:00',60,1,'${z.request}')`):
      actor(z.user,`select public.register_for_event('${z.event}',false)`);
    if(!['archive','restore','replay'].includes(kind)) {
      const positive=sql('begin;'+second+`select 'CONTROL_STATE='||jsonb_build_object('reservations',(select count(*) from public.reservations where tenant_id='${z.tenant}'),'registrations',(select count(*) from public.event_registrations where tenant_id='${z.tenant}'))::text;rollback;`);
      check(kind+' positive control',kind==='reservation'?positive.includes('"reservations": 1'):kind==='registration'?positive.includes('"registrations": 1'):true,positive);
    }
    await race('archive vs '+kind,z,archive,second,r=>r.state.status==='archived'&&!r.state.public&&!r.state.effective_domain&&r.state.reservations===0&&r.state.registrations===0&&r.state.active_admins===1&&(kind!=='activation'||/PT409: TENANT_REVISION_STALE/.test(r.errB)));
    if(kind==='replay') {const replay=sql('begin;'+archive+'commit;');check('duplicate retry returns cached result and one audit',state(z).archive_audits===1&&state(z).revision===1,replay);}
  }
} catch(e) {console.error(e.message);process.exitCode=1;}
finally {fs.writeFileSync(report,JSON.stringify({db,results,productionWrites:0},null,2));}
