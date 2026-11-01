import {spawn,spawnSync} from 'node:child_process';import {randomUUID} from 'node:crypto';import assert from 'node:assert/strict';
const db=process.argv[2];assert.match(db??'',/^sbr3_[a-f0-9]{16}$/);
const base=['exec','-i','supabase_db_csk-booking','psql','-X','-qAt','-v','ON_ERROR_STOP=1','-U','postgres','-d',db],q=s=>"'"+String(s).replaceAll("'","''")+"'";
const sql=s=>{const r=spawnSync('docker',base,{input:s,encoding:'utf8',windowsHide:true});assert.equal(r.status,0,r.stderr);return r.stdout.trim();};
const pa=randomUUID(),slug='readinessrace-'+randomUUID().slice(0,8),claims=`select set_config('request.jwt.claim.sub',${q(pa)},true);set local role authenticated;`;
const rpc=(s,commit=false)=>sql('begin;'+claims+s+(commit?'commit;':'rollback;')).split('\n').at(-1);let tid,count=0;
const check=(name,value)=>{assert.ok(value,name);console.log('PASS '+name);count++;};
function run(statement){const p=spawn('docker',base,{windowsHide:true});let out='',err='',notify;const ready=new Promise(r=>notify=r),done=new Promise(r=>{p.stdout.on('data',b=>{out+=b;if(out.includes('LOCKED'))notify();});p.stderr.on('data',b=>err+=b);p.on('close',code=>{notify();r({code,out,err});});});p.stdin.end("set statement_timeout='8s';"+statement);return {ready,done};}
const read=()=>JSON.parse(rpc(`select public.platform_get_draft_readiness_v1(${q(tid)});`));
const validate=rev=>`select public.platform_validate_draft_readiness_v1(${q(tid)},${q(rev)});`;
const save=(rev,value)=>`select public.platform_save_draft_configuration_v1(${q(tid)},${q(rev)},${q(randomUUID())},'profile',${q(JSON.stringify({description:value}))}::jsonb);`;
try{
 sql(`insert into auth.users(id,email,email_confirmed_at,is_anonymous) values(${q(pa)},${q(pa+'@example.invalid')},now(),false);insert into public.platform_admins(user_id,status) values(${q(pa)},'active');`);
 tid=JSON.parse(rpc(`select public.platform_create_tenant_draft_v1('Race',${q(slug)},${q(slug+'-public')},'City','booking_only_v1',${q(randomUUID())});`,true)).tenant_id;
 const family={root:{name:'Lane',is_active:true,max_shooters:2,whole_lane_bookable:true,positions_bookable:false,online_bookable:true,max_people_online:2,booking_step_minutes:60,durations_minutes:[60],pricing:['mon_thu','fri_sun'].map(day_group=>({day_group,min_shooters:1,max_shooters:2,label:'Price',hourly_price:10}))},positions:[]};
 rpc(`select public.platform_save_draft_configuration_v1(${q(tid)},${q(read().current_revision)},${q(randomUUID())},'create_lane',${q(JSON.stringify(family))}::jsonb);`,true);
 check('initial validation passes',JSON.parse(rpc(validate(read().current_revision),true)).validation_current);
 let rev=read().current_revision;
 let a=run('begin;'+claims+save(rev,'save-first')+"select 'LOCKED';select pg_sleep(0.7);commit;");await a.ready;
 let b=run('begin;'+claims+validate(rev)+'commit;');let [x,y]=await Promise.all([a.done,b.done]);
 check('save first excludes concurrent validation',x.code===0&&y.code!==0&&/lock/.test(y.err));check('committed change stales old proof',read().stale&&!read().validation_current);
 rev=read().current_revision;
 a=run('begin;'+claims+validate(rev)+"select 'LOCKED';select pg_sleep(0.7);commit;");await a.ready;
 b=run('begin;'+claims+save(rev,'must-not-commit')+'commit;');[x,y]=await Promise.all([a.done,b.done]);
 check('validation first excludes config writer',x.code===0&&y.code!==0&&/lock/.test(y.err));check('proof is current after rejected race',read().validation_current);
 rpc(save(rev,'immediate-after'),true);check('mutation immediately after validation invalidates',!read().validation_current);
 rev=read().current_revision;
 a=run('begin;'+claims+validate(rev)+"select 'LOCKED';select pg_sleep(0.7);commit;");await a.ready;
 b=run('begin;'+claims+validate(rev)+'commit;');[x,y]=await Promise.all([a.done,b.done]);
 check('two validations serialized',x.code===0&&(y.code===0||/lock/.test(y.err)));
 const proof=read();check('retry after lost response is identical',JSON.stringify(JSON.parse(rpc(validate(rev),true)))===JSON.stringify(proof));
 check('single proof and one passed event per revision',sql(`select count(*)=1 from app_private.draft_readiness_validations where tenant_id=${q(tid)};`)==='t'&&sql(`select count(*)=1 from public.platform_audit_logs where tenant_id=${q(tid)} and action='readiness_validation_passed' and details->>'revision'=${q(rev)};`)==='t');
 // A direct material-table update is serialized by the epoch even without a configuration RPC.
 a=run('begin;'+claims+validate(rev)+"select 'LOCKED';select pg_sleep(0.7);commit;");await a.ready;
 b=run(`begin;update public.lane_pricing_rules set hourly_price=11 where lane_id in(select id from public.shooting_lanes where tenant_id=${q(tid)});commit;`);[x,y]=await Promise.all([a.done,b.done]);
 check('hidden price writer finishes only with stale proof',x.code===0&&y.code===0&&!read().validation_current&&read().stale);
 const stale=await run('begin;'+claims+validate(rev)+'commit;').done;check('stale client cannot validate',stale.code!==0&&/READINESS_STALE/.test(stale.err));
 check('no memberships or publication',sql(`select t.status='dormant' and not p.is_public and c.public_access_state='coming_soon' and not exists(select 1 from public.tenant_memberships where tenant_id=t.id) from public.tenants t join public.tenant_public_profiles p on p.tenant_id=t.id join public.tenant_public_access_controls c on c.tenant_id=t.id where t.id=${q(tid)};`)==='t');
}finally{
 if(tid)sql(`begin;delete from public.audit_logs where tenant_id=${q(tid)};delete from public.platform_plan_change_requests where tenant_id=${q(tid)};delete from public.tenant_plan_assignments where tenant_id=${q(tid)};delete from app_private.draft_configuration_requests where tenant_id=${q(tid)};delete from public.lane_booking_durations where lane_id in(select id from public.shooting_lanes where tenant_id=${q(tid)});delete from public.lane_booking_rules where lane_id in(select id from public.shooting_lanes where tenant_id=${q(tid)});delete from public.lane_pricing_rules where lane_id in(select id from public.shooting_lanes where tenant_id=${q(tid)});delete from public.lane_booking_family_configuration_versions where root_lane_id in(select id from public.shooting_lanes where tenant_id=${q(tid)});delete from public.shooting_lanes where tenant_id=${q(tid)};delete from public.tenant_public_access_controls where tenant_id=${q(tid)};delete from public.platform_audit_logs where tenant_id=${q(tid)};delete from public.platform_tenant_creation_requests where tenant_id=${q(tid)};delete from public.tenant_public_profiles where tenant_id=${q(tid)};delete from public.tenants where id=${q(tid)};commit;`);
 sql(`delete from public.platform_admins where user_id=${q(pa)};delete from auth.users where id=${q(pa)};`);check('fixtures cleaned',sql(`select count(*) from public.tenants where slug=${q(slug)};`)==='0');
}
console.log('READINESS CONCURRENCY PASS '+count);
