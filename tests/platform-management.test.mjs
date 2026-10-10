import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
import vm from 'node:vm';
import ts from 'typescript';
import {createClient} from '@supabase/supabase-js';
import {ManagementSession,adminRpc} from '../lib/platform-management-session.ts';
import {readCandidate,readAdmins,readPlanPreview,readLifecycle,readEligibility,expectedState,candidateActions,managementError,noticeLabel,fallback} from '../lib/platform-management.ts';
import {fixture,response,rpcResponse,tenantId,actorId,userId,email,readerNames} from './fixtures/platform-management.mjs';

function harness(override=()=>undefined) {
 const f=fixture(),calls=[];
 const session=new ManagementSession(tenantId,async(name,args)=>{
   calls.push({name,args:structuredClone(args)});
   const result=await override(name,args,f);return result??structuredClone(rpcResponse(f,name,args));
 },f.detail,randomUUID);
 return {session,f,calls};
}
test('projections bind tenant/email, reject unknown states and discard PII',()=>{
 const f=fixture(),secret={phone:'PRIVATE',customer_notes:'PRIVATE'};
 for(const [parser,value]of[[readAdmins,f.admins],[readLifecycle,f.lifecycle],[readEligibility,f.eligibility]]){
  assert.ok(parser({...value,...secret},tenantId));assert.equal(parser(value,actorId),null);assert.ok(!JSON.stringify(parser({...value,...secret},tenantId)).includes('PRIVATE'));
 }
 assert.equal(readCandidate(f.candidate,'different@example.invalid'),null);
 assert.equal(readCandidate({...f.candidate,membership:{exists:false,role:'admin',status:'active'}},email),null);
 assert.equal(readCandidate({...f.candidate,membership:{exists:true,role:'owner',status:'active'}},email),null);
 assert.deepEqual(readCandidate({...f.candidate,...secret},` ${email.toUpperCase()} `),f.candidate);
 assert.equal(readLifecycle({...f.lifecycle,revision:Number.MAX_SAFE_INTEGER+1},tenantId),null);
 assert.equal(readPlanPreview(f.preview,tenantId,'wrong-plan'),null);
 assert.equal(readEligibility({...f.eligibility,eligibility:{can_hard_delete:true}},tenantId),null);
});
for(const [role,status,actions]of[[null,null,['add']],['user','active',['add']],['employee','active',['add']],['instructor','active',['add']],['admin','active',['demote','suspend']],['admin','suspended',['reactivate']],['user','suspended',[]],['employee','suspended',[]],['instructor','suspended',[]],['admin','pending',[]],['user','pending',[]]]){
 test(`R1 expected state and actions: ${role}/${status}`,async()=>{
  const h=harness();h.f.candidate.membership={exists:role!==null,role,status};await h.session.refresh();await h.session.findCandidate(email);
  const parsed=h.session.snapshot().candidate.data;
  assert.deepEqual(candidateActions(parsed),actions);assert.deepEqual(expectedState(parsed),role?{role,status}:null);
  for(const action of Object.keys(adminRpc)){
   h.session.prepareAdmin(action);const a=h.session.snapshot().attempt;
   assert.equal(!!a,actions.includes(action));if(a){assert.deepEqual(a.payload.p_expected_state,role?{role,status}:null);assert.equal(a.rpc,adminRpc[action]);h.session.cancel();}
  }
 });
}
for(const [action,role,status]of[['add',null,null],['add','user','active'],['add','employee','active'],['add','instructor','active'],['reactivate','admin','suspended'],['demote','admin','active'],['suspend','admin','active']]){
 test(`admin writer shape, receipt, canonical refresh: ${action}/${role}/${status}`,async()=>{
  const h=harness();h.f.candidate.membership={exists:!!role,role,status};await h.session.refresh();await h.session.findCandidate(email);h.session.prepareAdmin(action);await h.session.confirm();
  const call=h.calls.find(c=>c.name===adminRpc[action]);assert.deepEqual(Object.keys(call.args).sort(),['p_expected_state','p_request_id','p_tenant_id','p_user_id']);assert.equal(call.args.p_user_id,userId);assert.equal(call.args.p_tenant_id,tenantId);assert.match(call.args.p_request_id,/^[0-9a-f-]{36}$/);assert.deepEqual(call.args.p_expected_state,role?{role,status}:null);
  assert.equal(h.session.snapshot().attempt,null);for(const name of readerNames)assert.equal(h.calls.filter(c=>c.name===name).length,2);
 });
}
for(const status of ['suspended','pending']){
 test(`real-contract mock denies direct demotion of admin/${status} without changing state`,()=>{
  const f=fixture();f.candidate.membership={exists:true,role:'admin',status};f.admins.admins[0].membership_status=status;
  const before=structuredClone(f),result=rpcResponse(f,adminRpc.demote,{p_tenant_id:tenantId,p_user_id:userId,p_expected_state:{role:'admin',status},p_request_id:randomUUID()});
  assert.deepEqual(result,{data:null,error:{code:'55000',message:'NOT_ACTIVE_TENANT_ADMIN'}});assert.deepEqual(f,before);
  const mapped=managementError({...result.error,details:'PRIVATE SQL stack'});
  assert.equal(mapped.kind,'rejected');assert.equal(mapped.message,'Ta operacja wymaga aktywnego administratora. Odśwież dane użytkownika.');assert.doesNotMatch(mapped.message,/55000|NOT_ACTIVE_TENANT_ADMIN|PRIVATE|SQL/);
 });
}
test('reactivation waits for canonical admin refresh and fresh R1 before allowing active actions',async()=>{
 let reads=0,release,started;const refreshing=new Promise(resolve=>started=resolve);
 const h=harness(async name=>{if(name==='platform_get_tenant_admin_management_v1'&&++reads===2){started();await new Promise(resolve=>release=resolve);}});
 h.f.candidate.membership={exists:true,role:'admin',status:'suspended'};h.f.admins.admins[0].membership_status='suspended';
 await h.session.refresh();await h.session.findCandidate(email);h.session.prepareAdmin('reactivate');const confirmation=h.session.confirm();await refreshing;
 assert.equal(h.session.snapshot().busy,true);assert.equal(h.session.snapshot().admins.data,null);assert.equal(h.session.snapshot().candidate.data,null);
 h.session.prepareAdmin('demote');assert.equal(h.session.snapshot().attempt,null);assert.equal(h.calls.filter(c=>c.name===adminRpc.demote).length,0);
 release();await confirmation;
 assert.equal(h.session.snapshot().admins.data.admins[0].membership_status,'active');assert.equal(h.session.snapshot().candidate.data,null);
 h.session.prepareAdmin('demote');assert.equal(h.session.snapshot().attempt,null);
 await h.session.findCandidate(email);assert.deepEqual(candidateActions(h.session.snapshot().candidate.data),['demote','suspend']);
 h.session.prepareAdmin('demote');assert.deepEqual(h.session.snapshot().attempt.payload.p_expected_state,{role:'admin',status:'active'});
 assert.equal(h.calls.filter(c=>c.name===adminRpc.reactivate).length,1);assert.equal(h.calls.filter(c=>c.name==='platform_get_tenant_admin_management_v1').length,2);assert.equal(h.calls.filter(c=>c.name===adminRpc.demote).length,0);
});
test('reactivation receipt alone cannot enable demotion when canonical reader fails',async()=>{
 let reads=0;const h=harness(name=>name==='platform_get_tenant_admin_management_v1'&&++reads===2?{data:null,error:{code:'XX000',message:'PRIVATE'}}:undefined);
 h.f.candidate.membership={exists:true,role:'admin',status:'suspended'};await h.session.refresh();await h.session.findCandidate(email);h.session.prepareAdmin('reactivate');await h.session.confirm();
 assert.equal(h.session.snapshot().admins.data,null);await h.session.findCandidate(email);assert.equal(h.session.snapshot().candidate.data,null);h.session.prepareAdmin('demote');assert.equal(h.session.snapshot().attempt,null);assert.equal(h.calls.filter(c=>c.name===adminRpc.demote).length,0);
});
test('NOT_ACTIVE_TENANT_ADMIN after an active lookup refreshes suspension without retry or optimistic mutation',async()=>{
 let rejectedState;
 // Inject the stable rejection to test defensive UI handling; real expected-state
 // conflicts also have their separate PT409 regression above/below.
 const h=harness((name,args,f)=>{if(name===adminRpc.demote){f.candidate.membership.status='suspended';f.admins.admins[0].membership_status='suspended';rejectedState=structuredClone(f);return {data:null,error:{code:'55000',message:'NOT_ACTIVE_TENANT_ADMIN',details:'PRIVATE SQL stack'}};}});
 h.f.candidate.membership={exists:true,role:'admin',status:'active'};await h.session.refresh();await h.session.findCandidate(email);h.session.prepareAdmin('demote');await h.session.confirm();
 assert.deepEqual(h.f,rejectedState);assert.equal(h.session.snapshot().attempt,null);assert.equal(h.session.snapshot().message,'Ta operacja wymaga aktywnego administratora. Odśwież dane użytkownika.');
 assert.deepEqual(h.session.snapshot().candidate.data.membership,{exists:true,role:'admin',status:'suspended'});assert.equal(h.session.snapshot().admins.data.admins[0].membership_status,'suspended');assert.deepEqual(candidateActions(h.session.snapshot().candidate.data),['reactivate']);
 assert.equal(h.calls.filter(c=>c.name===adminRpc.demote).length,1);assert.equal(h.calls.filter(c=>c.name==='platform_get_tenant_admin_management_v1').length,2);assert.equal(h.calls.filter(c=>c.name==='platform_lookup_tenant_admin_candidate_v1').length,2);
 h.session.prepareAdmin('demote');await h.session.confirm();assert.equal(h.calls.filter(c=>c.name===adminRpc.demote).length,1);
});
test('list selection must re-read R1, wrong account and unavailable reader cannot mutate',async()=>{
 const h=harness();await h.session.refresh();h.session.prepareAdmin('demote');assert.equal(h.session.snapshot().attempt,null);
 await h.session.findCandidate(email,actorId);assert.equal(h.session.snapshot().candidate.data,null);h.session.prepareAdmin('add');assert.equal(h.session.snapshot().attempt,null);
});
test('plan preview gates BOTH can_apply and blockers; v2 preserves int64 string revision',async()=>{
 const h=harness();await h.session.refresh();
 for(const [apply,blockers]of[[false,[]],[true,[{code:'EVENTS_OPEN',count:1}]]]){h.f.preview.can_apply=apply;h.f.preview.blockers=blockers;await h.session.selectPlan('booking_only_v1');h.session.preparePlan();assert.equal(h.session.snapshot().attempt,null);}
 h.f.preview.can_apply=true;h.f.preview.blockers=[];await h.session.selectPlan('booking_only_v1');h.session.preparePlan();await h.session.confirm();
 const call=h.calls.find(c=>c.name==='platform_change_tenant_plan_v2');assert.equal(call.args.p_expected_revision,'9007199254740993');assert.equal(call.args.p_target_plan_key,'booking_only_v1');assert.match(call.args.p_change_request_id,/^[0-9a-f-]{36}$/);assert.equal(h.session.snapshot().detail.data.plan.plan_key,'booking_only_v1');assert.ok(!h.calls.some(c=>/set_tenant_plan|change_tenant_plan_v1|set_tenant_state/.test(c.name)));
});
test('ambiguous transport retries frozen UUID/payload; no double submit or new action',async()=>{
 let release,number=0;
 const h=harness(async name=>{if(name===adminRpc.add && ++number===1){await new Promise(r=>release=r);throw Error('Network failed');}});
 await h.session.refresh();await h.session.findCandidate(email);h.session.prepareAdmin('add');const first=h.session.confirm();await h.session.confirm();h.session.prepareLifecycle('archive');assert.equal(h.calls.filter(c=>c.name===adminRpc.add).length,1);release();await first;
 h.session.cancel();assert.equal(h.session.snapshot().attempt.phase,'uncertain');await h.session.findCandidate('another@example.invalid');await h.session.refresh();await h.session.confirm();
 const writes=h.calls.filter(c=>c.name===adminRpc.add);assert.equal(writes.length,2);assert.deepEqual(writes[0].args,writes[1].args);
 await h.session.findCandidate(email);h.session.prepareAdmin('suspend');await h.session.confirm();assert.notEqual(h.calls.find(c=>c.name===adminRpc.suspend).args.p_request_id,writes[0].args.p_request_id);
});
for(const [operation,code,kind]of[['plan','PLAN_STALE','plan-stale'],['add','STALE_MEMBERSHIP_STATE','member-stale'],['archive','TENANT_REVISION_STALE','lifecycle-stale']]){
 test(`${code}: refresh and new confirmation, never automatic retry`,async()=>{
  const h=harness(name=>name===(operation==='plan'?'platform_change_tenant_plan_v2':operation==='archive'?'platform_archive_tenant_v1':adminRpc.add)?{data:null,error:{code:'PT409',message:code}}:undefined);
  await h.session.refresh();if(operation==='plan'){await h.session.selectPlan('booking_only_v1');h.session.preparePlan();}else if(operation==='add'){await h.session.findCandidate(email);h.session.prepareAdmin('add');}else h.session.prepareLifecycle('archive');
  const writer=h.session.snapshot().attempt.rpc;await h.session.confirm();assert.equal(h.session.snapshot().attempt,null);assert.equal(h.calls.filter(c=>c.name===writer).length,1);assert.equal(h.session.snapshot().message,managementError({code:'PT409',message:code}).message);assert.equal(managementError({code:'PT409',message:code}).kind,kind);
 });
}
for(const [code,sqlstate]of[['LAST_ACTIVE_ADMIN','23514'],['INSTRUCTOR_HAS_OPEN_OBLIGATIONS','55000']]){
 test(`${code} is safe, backend-enforced, non-retrying`,async()=>{
  const h=harness(name=>name===adminRpc.add?{data:null,error:{code:sqlstate,message:code,details:'customer PRIVATE'}}:undefined);await h.session.refresh();await h.session.findCandidate(email);h.session.prepareAdmin('add');await h.session.confirm();assert.equal(h.session.snapshot().message,noticeLabel(code));assert.equal(h.session.snapshot().attempt,null);assert.equal(h.calls.filter(c=>c.name===adminRpc.add).length,1);
 });
}
test('archive/restore exact revision and fresh dormant/nonpublic state without activation',async()=>{
 const h=harness();await h.session.refresh();h.session.prepareLifecycle('restore');assert.equal(h.session.snapshot().attempt,null);
 h.session.prepareLifecycle('archive');await h.session.confirm();assert.equal(h.session.snapshot().detail.data.tenant.status,'archived');h.session.prepareLifecycle('archive');assert.equal(h.session.snapshot().attempt,null);h.session.prepareLifecycle('restore');await h.session.confirm();
 assert.equal(h.session.snapshot().detail.data.tenant.status,'dormant');assert.equal(h.session.snapshot().detail.data.public_profile.is_public,false);
 assert.equal(h.calls.find(c=>c.name==='platform_archive_tenant_v1').args.p_expected_revision,17);assert.equal(h.calls.find(c=>c.name==='platform_restore_archived_tenant_v1').args.p_expected_revision,18);assert.ok(!h.calls.some(c=>/set_tenant_state|delete|purge/.test(c.name)&&c.name!=='platform_get_tenant_delete_eligibility_v1'));
});
test('reader failures isolate sections; any authority denial wipes whole page even with concurrent readers',async()=>{
 const h=harness(name=>name==='platform_get_tenant_admin_management_v1'?{data:null,error:{code:'XX000',message:'PRIVATE'}}:undefined);await h.session.refresh();assert.equal(h.session.snapshot().admins.data,null);assert.ok(h.session.snapshot().plans.data);h.session.prepareAdmin('add');assert.equal(h.session.snapshot().attempt,null);
 for(const rpc of [...readerNames,'platform_lookup_tenant_admin_candidate_v1','platform_get_tenant_plan_change_preview_v1',adminRpc.add]){
  const denied=harness(name=>name===rpc?{data:null,error:{code:'42501',message:'PRIVATE'}}:undefined);await denied.session.refresh();await denied.session.findCandidate(email);await denied.session.selectPlan('booking_only_v1');denied.session.prepareAdmin('add');await denied.session.confirm();assert.equal(denied.session.snapshot().denied,true,rpc);for(const k of ['detail','plans','admins','lifecycle','eligibility','candidate','preview'])assert.equal(denied.session.snapshot()[k].data,null,rpc);
 }
});
test('safe mapper never renders raw error or unknown reason',()=>{
 assert.equal(managementError({code:'22023',message:'secret SQL',details:'PRIVATE'}).message,fallback);assert.equal(noticeLabel('UNKNOWN_DEPENDENCY',true),'Zależność techniczna blokuje trwałe usunięcie.');assert.equal(managementError({message:'Failed to fetch'}).kind,'uncertain');
});
test('unknown prototype-named codes cannot escape safe text mapping',()=>{
 for(const code of ['__proto__','constructor','toString']){assert.equal(typeof noticeLabel(code,true),'string');assert.equal(managementError({code:'22023',message:code}).message,fallback);}
});
for(const operation of ['plan','archive','restore']){
 test(`${operation} preserves exact UUID and revision after lost acknowledgement`,async()=>{
  let first=true;const writer=operation==='plan'?'platform_change_tenant_plan_v2':operation==='archive'?'platform_archive_tenant_v1':'platform_restore_archived_tenant_v1';
  const h=harness((name,args,f)=>{if(name===writer&&first){first=false;response(f,name,args);throw Error('Lost response after commit');}});
  if(operation==='restore'){h.f.lifecycle.tenant.status='archived';h.f.detail.tenant.status='archived';}
  await h.session.refresh();if(operation==='plan'){await h.session.selectPlan('booking_only_v1');h.session.preparePlan();}else h.session.prepareLifecycle(operation);
  await h.session.confirm();assert.equal(h.session.snapshot().attempt.phase,'uncertain');const payload=h.calls.find(c=>c.name===writer).args;await h.session.confirm();assert.deepEqual(h.calls.filter(c=>c.name===writer).map(c=>c.args),[payload,payload]);
 });
}
test('actual Supabase SDK serializes management writes as POST with the approved payload',async()=>{
 const requests=[];
 const client=createClient('https://management-tests.example.invalid','synthetic-local-anon-key',{auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false},global:{fetch:async(url,init)=>{requests.push({url:String(url),method:init.method,body:JSON.parse(init.body)});return new Response(JSON.stringify({code:'changed'}),{status:200,headers:{'Content-Type':'application/json'}});}}});
 for(const name of [Object.values(adminRpc),'platform_change_tenant_plan_v2','platform_archive_tenant_v1','platform_restore_archived_tenant_v1'].flat()){
  const payload={p_tenant_id:tenantId,p_request_id:randomUUID()};await client.rpc(name,payload).abortSignal(AbortSignal.timeout(1000));const req=requests.at(-1);assert.equal(req.method,'POST');assert.ok(req.url.endsWith(`/rest/v1/rpc/${name}`));assert.deepEqual(req.body,payload);
 }
});

const read=path=>readFileSync(new URL(`../${path}`,import.meta.url),'utf8');
test('real tenant route scopes the component lifetime to actor and tenant',()=>{
 assert.ok(read('app/platform-admin/tenants/[id]/page.tsx').includes('key={`${auth.user.id}:${id}`}'));
 assert.match(read('app/platform-admin/tenants/[id]/TenantDetail.tsx'),/session\.invalidate\(\)/);
 const b=new ManagementSession(actorId,async()=>({data:null,error:null}),null,randomUUID);
 assert.equal(b.snapshot().preview.data,null);assert.equal(b.snapshot().lifecycle.data,null);
 assert.equal(b.snapshot().candidate.data,null);assert.equal(b.snapshot().attempt,null);
 assert.equal(b.snapshot().target,'');assert.equal(b.snapshot().email,'');
});
for(const [role,pa,loggedIn,allow]of[['PA',true,true,true],['tenant admin',false,true,false],['employee',false,true,false],['instructor',false,true,false],['user',false,true,false],['anon',false,false,false],['combined PA + tenant admin',true,true,true]]){
 test(`actual server guard role matrix: ${role}`,async()=>{
  const exports={},calls=[],client={auth:{getUser:async()=>({data:{user:loggedIn?{id:actorId}:null},error:null})},rpc:async(name,args)=>{calls.push({name,args});return {data:pa,error:null};}};
  const navigation={notFound:()=>{throw Error('404');},redirect:()=>{throw Error('LOGIN');}};
  const source=ts.transpileModule(read('lib/server/platform-admin.ts'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  vm.runInNewContext(source,{exports,require:name=>name==='server-only'?{}:name==='next/navigation'?navigation:{getTenantRequestClient:async()=>client}});
  if(allow)assert.equal(await exports.requirePlatformAdmin(),client);else await assert.rejects(exports.requirePlatformAdmin(),loggedIn?/404/:/LOGIN/);
  assert.deepEqual(calls.map(c=>c.name),loggedIn?['is_platform_admin_v1']:[]);
 });
}
test('route retains guard; detail/list have no legacy writer, table reads or destructive handler',()=>{
 assert.match(read('app/platform-admin/tenants/[id]/page.tsx'),/await requirePlatformAdmin\(\)/);
 const sources=['lib/platform-management.ts','lib/platform-management-session.ts','app/platform-admin/tenants/[id]/TenantDetail.tsx','app/platform-admin/tenants/[id]/ManagementCards.tsx'].map(read).join('\n');
 assert.doesNotMatch(sources,/\.from\(|SERVICE_ROLE|profiles\.role|platform_set_tenant_plan_v1|platform_change_tenant_plan_v1|supabase[^\n]*\.delete\(|hard_delete_tenant|purge_tenant/);
 assert.doesNotMatch(read('app/platform-admin/PlatformTenants.tsx'),/platform_set_tenant_plan_v1|platform_assign_initial_admin_v1|platform_lookup_initial_admin_v1/);
 assert.match(sources,/platform_lookup_tenant_admin_candidate_v1/);assert.match(sources,/platform_change_tenant_plan_v2/);
});
