import fs from 'node:fs';
import path from 'node:path';
import {spawn,spawnSync} from 'node:child_process';
import {randomUUID} from 'node:crypto';
const db=process.argv[2];
if(!/^onboard_1a_[0-9a-f]{16}$/.test(db))throw Error('LOCAL_TARGET_DENIED');
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
(async()=>{
 sql(`begin;insert into auth.users(id,email,email_confirmed_at,is_anonymous) values(${q(pa)},${q(pa+'@example.invalid')},now(),false),(${q(owner)},${q(owner+'@example.invalid')},now(),false),(${q(other)},${q(other+'@example.invalid')},now(),false);insert into public.profiles(id,user_id,email,role) select id,id,email,'user' from auth.users where id in(${q(pa)},${q(owner)},${q(other)}) on conflict(user_id) do nothing;insert into public.platform_admins(user_id,status) values(${q(pa)},'active');commit;`);
 const key=randomUUID(),slug=prefix+'-same';
 const first=run(`begin;${claims(pa)}${bundle(pa,owner,key,slug)}select 'LOCKED';select pg_sleep(1);commit;`);
 await first.ready;const second=run(`begin;set local lock_timeout='5s';${claims(pa)}${bundle(pa,owner,key,slug)}commit;`);
 const pair=await Promise.all([first.done,second.done]);
 check('concurrent identical request succeeds twice, no deadlock',pair.every(r=>r.code===0));
 check('one tenant, one ledger, three audits',sql(`select (select count(*) from public.tenants where slug=${q(slug)})||':'||(select count(*) from public.platform_tenant_creation_requests where actor_user_id=${q(pa)} and creation_request_id=${q(key)})||':'||(select count(*) from public.platform_audit_logs where tenant_id=(select id from public.tenants where slug=${q(slug)}));`)==='1:1:3');
 const collision=prefix+'-collision';
 const left=run(`begin;${claims(pa)}${bundle(pa,owner,randomUUID(),collision)}select 'LOCKED';select pg_sleep(1);commit;`);
 await left.ready;const right=run(`begin;set local lock_timeout='5s';${claims(pa)}${bundle(pa,other,randomUUID(),collision)}commit;`);
 const collisions=await Promise.all([left.done,right.done]);
 check('parallel slug collision fails unique, not deadlock',collisions[0].code===0&&collisions[1].code!==0&&/duplicate key/.test(collisions[1].stderr)&&!/deadlock/i.test(collisions[1].stderr));
 for(const crossNamespace of [false,true]) {
  const publicSlug=prefix+(crossNamespace?'-cross-public':'-shared-public');
  const firstSlug=prefix+(crossNamespace?'-cross-first':'-public-first');
  const secondSlug=crossNamespace?publicSlug:prefix+'-public-second';
  const initial=run(`begin;${claims(pa)}${bundle(pa,owner,randomUUID(),firstSlug,publicSlug)}select 'LOCKED';select pg_sleep(1);commit;`);
  await initial.ready;
  const contender=run(`begin;set local lock_timeout='5s';${claims(pa)}${bundle(pa,other,randomUUID(),secondSlug,crossNamespace?secondSlug+'-public':publicSlug)}commit;`);
  const outcomes=await Promise.all([initial.done,contender.done]);
  check(crossNamespace?'parallel cross-table namespace collision denied':'parallel public slug collision denied',outcomes[0].code===0&&outcomes[1].code!==0&&/tenant_slug_conflict|duplicate key/.test(outcomes[1].stderr)&&!/deadlock/i.test(outcomes[1].stderr)&&sql(`select count(*) from public.tenants where slug=${q(secondSlug)};`)==='0');
 }
 const sameOwner=run(`begin;${claims(pa)}${bundle(pa,owner,randomUUID(),prefix+'-owner-first')}select 'LOCKED';select pg_sleep(1);commit;`);
 await sameOwner.ready;
 const sameOwnerSecond=run(`begin;set local lock_timeout='5s';${claims(pa)}${bundle(pa,owner,randomUUID(),prefix+'-owner-second')}commit;`);
 check('parallel distinct requests for same global admin serialize', (await Promise.all([sameOwner.done,sameOwnerSecond.done])).every(r=>r.code===0));
 const banned=run(`begin;update auth.users set banned_until=now()+interval '1 day' where id=${q(other)};select 'LOCKED';select pg_sleep(1);commit;`);
 await banned.ready;const whileBanned=run(`begin;${claims(pa)}${bundle(pa,other,randomUUID(),prefix+'-ban')}commit;`);
 const banResults=await Promise.all([banned.done,whileBanned.done]);
 check('account ban race fails NOWAIT without deadlock',banResults[0].code===0&&banResults[1].code!==0&&/could not obtain lock/.test(banResults[1].stderr)&&!/deadlock/i.test(banResults[1].stderr));
 sql(`update auth.users set banned_until=null where id=${q(other)};`);
 const deleting=run(`begin;delete from auth.users where id=${q(other)};select 'LOCKED';select pg_sleep(1);commit;`);
 await deleting.ready;const whileDeleting=run(`begin;${claims(pa)}${bundle(pa,other,randomUUID(),prefix+'-delete')}commit;`);
 const deleteResults=await Promise.all([deleting.done,whileDeleting.done]);
 check('Auth delete race fails closed without deadlock',deleteResults[0].code===0&&deleteResults[1].code!==0&&/could not obtain lock|Account cannot be assigned/.test(deleteResults[1].stderr)&&!/deadlock/i.test(deleteResults[1].stderr));
 // A dedicated local plan avoids modifying baseline catalog fixtures.
 const plan=(prefix+'-plan').replaceAll('-','_');sql(`insert into public.saas_plans(plan_key,status) values(${q(plan)},'active');`);
 const planRace=run(`begin;update public.saas_plans set status='inactive' where plan_key=${q(plan)};select 'LOCKED';select pg_sleep(1);commit;`);
 await planRace.ready;
 const waiting=run(`begin;set local lock_timeout='5s';${claims(pa)}select public.platform_create_tenant_bundle_v2('Concurrency',${q(prefix+'-plan-tenant')},${q(prefix+'-plan-public')},'City',${q(plan)},${q(owner)},${q(randomUUID())});commit;`);
 const planResults=await Promise.all([planRace.done,waiting.done]);
 check('plan state race fails closed without deadlock',planResults[0].code===0&&planResults[1].code!==0&&/Plan unavailable|could not obtain lock/.test(planResults[1].stderr)&&!/deadlock/i.test(planResults[1].stderr));
 const afterPlan=await run(`begin;${claims(pa)}select public.platform_create_tenant_bundle_v2('Concurrency',${q(prefix+'-plan-tenant')},${q(prefix+'-plan-public')},'City',${q(plan)},${q(owner)},${q(randomUUID())});commit;`).done;
 check('retry rechecks inactive plan',afterPlan.code!==0&&/Plan unavailable/.test(afterPlan.stderr));
 const tenant=sql(`select id from public.tenants where slug=${q(slug)};`);
 const activationBan=run(`begin;update auth.users set banned_until=now()+interval '1 day' where id=${q(owner)};select 'LOCKED';select pg_sleep(1);commit;`);
 await activationBan.ready;
 const whileActivationBan=run(`begin;${claims(pa)}select public.platform_set_tenant_state_v1(${q(tenant)},'activate');commit;`);
 const activationBanResults=await Promise.all([activationBan.done,whileActivationBan.done]);
 check('activation/admin account race fails closed',activationBanResults[0].code===0&&activationBanResults[1].code!==0&&/could not obtain lock|Onboarding account busy/.test(activationBanResults[1].stderr)&&sql(`select status from public.tenants where id=${q(tenant)};`)==='dormant');
 sql(`update auth.users set banned_until=null where id=${q(owner)};`);
 const config=run(`begin;${claims(owner)}select public.tenant_setup_get_lane_configuration_v1(${q(tenant)});select 'LOCKED';select pg_sleep(1);commit;`);
 await config.ready;const activation=run(`begin;set local lock_timeout='5s';${claims(pa)}select public.platform_set_tenant_state_v1(${q(tenant)},'activate');commit;`);
 const stateResults=await Promise.all([config.done,activation.done]);
 check('draft setup/state row locks serialize without deadlock',stateResults.every(r=>r.code===0));
 const rejected=run(`begin;${claims(owner)}select public.tenant_setup_get_lane_configuration_v1(${q(tenant)});commit;`);
 const denied=await rejected.done;
 check('draft RPC refuses tenant after activation',denied.code!==0&&/Draft configuration not allowed/.test(denied.stderr));
 const roleChange=run(`begin;select pg_advisory_xact_lock(hashtextextended(${q(tenant)},9401));update public.tenant_memberships set role='employee' where tenant_id=${q(tenant)} and user_id=${q(owner)};select 'LOCKED';select pg_sleep(1);insert into public.audit_logs(tenant_id,actor_user_id,actor_name,actor_role,action,target_type,target_id,target_name,details) values(${q(tenant)},${q(owner)},'Synthetic','admin','tenant_user_role_updated','tenant_user_role',${q(owner)},'Synthetic','{}');commit;`);
 await roleChange.ready;
 const roleActivation=run(`begin;${claims(pa)}select public.platform_set_tenant_state_v1(${q(tenant)},'publish');commit;`);
 const roleResults=await Promise.all([roleChange.done,roleActivation.done]);
 check('role/audit FK vs state has no lock inversion',roleResults[0].code===0&&roleResults[1].code!==0&&/Tenant setup incomplete/.test(roleResults[1].stderr)&&!/deadlock/i.test(roleResults[1].stderr));
 check('race failures leave no failed bundle',sql(`select count(*) from public.tenants where slug in(${q(prefix+'-ban')},${q(prefix+'-delete')},${q(prefix+'-plan-tenant')});`)==='0');
 if(process.argv[3]) fs.writeFileSync(path.resolve(process.argv[3]),JSON.stringify({local_database:db,results,production_writes:0},null,2));
})().catch(error=>{console.error(error.message);process.exitCode=1;}).finally(()=>{
 // Delete only this run's synthetic fixtures, in the prevalidated local scratch database.
 sql(`begin;
 delete from public.platform_tenant_creation_requests where actor_user_id=${q(pa)};
 delete from public.platform_audit_logs where tenant_id in(select id from public.tenants where slug like ${q(prefix+'%')});
 delete from public.audit_logs where tenant_id in(select id from public.tenants where slug like ${q(prefix+'%')});
 delete from public.tenant_plan_assignments where tenant_id in(select id from public.tenants where slug like ${q(prefix+'%')});
 delete from public.tenants where slug like ${q(prefix+'%')};
 delete from public.saas_plans where plan_key=${q((prefix+'-plan').replaceAll('-','_'))};
 delete from auth.users where id in(${q(pa)},${q(owner)},${q(other)});
 commit;`);
 check('own synthetic concurrency fixtures removed',sql(`select count(*) from public.tenants where slug like ${q(prefix+'%')};`)==='0');
 if(process.argv[3]) fs.writeFileSync(path.resolve(process.argv[3]),JSON.stringify({local_database:db,results,production_writes:0},null,2));
});
