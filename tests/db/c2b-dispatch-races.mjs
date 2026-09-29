import { spawn, spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';

export async function runDispatchRaces(database) {
 if (!/^c2b_[a-f0-9]{16}$/.test(database)) throw Error('ISOLATED_LOCAL_ONLY');
 const args=['exec','-i','supabase_db_csk-booking','psql','-X','-qAt','-v','ON_ERROR_STOP=1','-U','postgres','-d',database];
 const sql=s=>{const r=spawnSync('docker',args,{input:s,encoding:'utf8',timeout:20000});if(r.status)throw Error(r.stderr);return r.stdout.trim()};
 function held(statement){const child=spawn('docker',args);let output='',errors='',resolveReady;
  const ready=new Promise(r=>{resolveReady=r});
  const done=new Promise((resolve,reject)=>{child.stdout.on('data',d=>{output+=d;if(output.includes('LOCK_HELD'))resolveReady()});child.stderr.on('data',d=>errors+=d);child.on('error',reject);child.on('close',code=>code?reject(Error(errors)):resolve(output));});
  child.stdin.end(statement+"\nselect 'LOCK_HELD'; select pg_sleep(0.5); commit;");
  return {ready:Promise.race([ready,done.then(()=>{if(!output.includes('LOCK_HELD'))throw Error('NO_LOCK')})]),done};
 }
 for(const kind of ['registration','acceptance','promotion']) for(const scenario of ['cancel-first','admit-first','crash','hard-failure','uncertain']){
  const [tenant,staff,user,event,registration]=Array.from({length:5},randomUUID);
  const auth=id=>`select set_config('request.jwt.claim.sub','${id}',true); select set_config('request.jwt.claims','{"sub":"${id}","role":"authenticated"}',true);`;
  const cancel=`${auth(staff)} set local role authenticated; select public.admin_cancel_event_v1('${event}');`;
  const claim=kind==='registration'?`${auth(user)} set local role authenticated; select public.prepare_confirmation_email('event_registration_confirmation','${registration}');`:
    kind==='acceptance'?`set local role service_role; select public.claim_event_reserve_acceptance_email_v1('${registration}');`:
    `set local role service_role; select coalesce(jsonb_agg(x),'[]') from public.prepare_event_reserve_promotions('${event}') x;`;
  const claimValue=output=>{const rows=output.split(/\r?\n/).filter(l=>l.startsWith('{')||l.startsWith('['));return JSON.parse(rows.at(-1))};
  const ready=result=>kind==='promotion'?result.length===1:result.code==='ready';
  const claimId=result=>kind==='promotion'?result[0].claim_id:result.claim_id;
  try{
   sql(`begin;
    insert into public.tenants(id,slug,name,status) values('${tenant}','c2b-race-${tenant}','Synthetic','active');
    insert into public.tenant_plan_assignments(tenant_id,plan_id,status) select '${tenant}',id,'active' from public.saas_plans where plan_key='current_full_v1';
    insert into auth.users(id,email,email_confirmed_at) values('${staff}','${staff}@example.invalid',now()),('${user}','${user}@example.invalid',now());
    insert into public.tenant_memberships(tenant_id,user_id,role,status) values('${tenant}','${staff}','admin','active'),('${tenant}','${user}','user','active');
    insert into public.events(id,tenant_id,title,event_date,start_time,end_time,max_participants,is_active) values('${event}','${tenant}','Synthetic',current_date+30,'10:00','11:00',10,true);
    insert into public.event_registrations(id,event_id,tenant_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status,promotion_token,promotion_confirmed_at)
    values('${registration}','${event}','${tenant}','${user}','Synthetic','test@example.invalid','000','${kind==='promotion'?'reserve':'registered'}','pending',${kind==='acceptance'?"'synthetic-token'":"null"},${kind==='acceptance'?'now()':'null'});
    ${kind==='acceptance'?`insert into public.email_deliveries(message_type,record_id,tenant_id,recipient_user_id,delivery_state) values('event_reserve_acceptance_confirmation','${registration}','${tenant}','${user}','pending');`:''}
    commit;`);
   let admitted, id;
   if(scenario==='cancel-first'){
    const first=held('begin;'+cancel);await first.ready;
    const result=claimValue(sql('begin;'+claim+'commit;'));await first.done;
    assert.equal(ready(result),false);console.log(`RACE ${kind}/${scenario}: PASS provider_calls=0`);
   }else{
    const first=held('begin;'+claim);await first.ready;
    sql('begin;'+cancel+'commit;');admitted=claimValue((await first.done).split('LOCK_HELD')[0]);
    assert.equal(ready(admitted),true);id=claimId(admitted);
    assert.equal(sql(`set role service_role; select public.check_event_email_dispatch_lease_v1('${id}','${kind}');`),'t');
    if(scenario!=='admit-first'){
     if(scenario==='hard-failure'){
      sql(kind==='promotion'?`set role service_role; select public.complete_event_reserve_promotion('${registration}','${id}',false,'email_send_failed');`:
       kind==='acceptance'?`set role service_role; select public.complete_event_reserve_acceptance_email_v1('${id}',false,null);`:
       `set role service_role; select public.complete_confirmation_email('${id}',false,null,'email_send_failed');`);
     }else{
      sql(kind==='promotion'?`update public.event_registrations set promotion_last_attempt_at=clock_timestamp()-interval '10 minutes',promotion_claim_expires_at=clock_timestamp()-interval '1 minute' where id='${registration}';`:
       `update public.email_deliveries set last_attempt_at=clock_timestamp()-interval '10 minutes',claim_expires_at=clock_timestamp()-interval '1 minute' where claim_id='${id}';`);
     }
     assert.equal(sql(`set role service_role; select public.check_event_email_dispatch_lease_v1('${id}','${kind}');`),'f');
     assert.equal(ready(claimValue(sql('begin;'+claim+'commit;'))),false);
    }
    assert.equal(sql(`select count(*) from public.email_deliveries where record_id='${registration}' and message_type='event_cancellation';`),'1');
    console.log(`RACE ${kind}/${scenario}: PASS ${scenario==='admit-first'?'admitted_attempt_allowed':'retry_provider_calls=0'}`);
   }
  }finally{
   sql(`begin; delete from public.email_deliveries where tenant_id='${tenant}'; delete from public.event_registrations where event_id='${event}'; delete from public.events where id='${event}'; delete from public.tenant_plan_assignments where tenant_id='${tenant}'; delete from public.tenant_public_profiles where tenant_id='${tenant}'; delete from auth.users where id in('${staff}','${user}'); delete from public.tenants where id='${tenant}'; commit;`);
   assert.equal(sql(`select count(*) from public.tenants where id='${tenant}';`),'0');
  }
 }
 console.log('RACE_FIXTURE_CLEANUP=0');
}
