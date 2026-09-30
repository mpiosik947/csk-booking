import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import ts from 'typescript';
import {resolveStaffTenantContext} from './tenant-context-core.ts';
import {instructorEmailContent,deliverInstructorEmailBatch} from './instructor-email-core.ts';
const event={event_id:'10000000-0000-0000-0000-000000000001',title:'Event <script>alert(1)</script>',event_date:'2026-11-30',start_time:'10:00:00',end_time:'11:00:00',location:'Range & field'};
const tenant={tenantId:'20000000-0000-0000-0000-000000000001',tenantSlug:'tenant-b',publicSlug:'range-b',displayName:'Obiekt B',canonicalPublicUrl:'https://strzelajtu.pl/range-b'};
for(const kind of ['instructor_assignment','instructor_removal','instructor_event_cancellation'])test(`${kind} branded minimal HTML/text and Tenant B isolation`,()=>{
 const result=instructorEmailContent(tenant,kind,event);
 assert.match(result.subject,/^StrzelajTu.pl \/ Obiekt B — /);
 assert.match(result.html,/data-operational-email="strzelajtu"/);
 assert.match(result.html,/&lt;script&gt;/);assert.doesNotMatch(result.html,/<script>/);
 for(const value of ['Obiekt B','2026-11-30','10:00–11:00','Range & field'])assert.ok(result.text.includes(value));
 assert.doesNotMatch(JSON.stringify(result),/CSK|csk|Krutla|customer_email|attendance|payment|verification/);
 if(kind==='instructor_assignment')assert.match(result.text,/https:\/\/strzelajtu.pl\/t\/tenant-b\/instructor\/events\/10000000-0000-0000-0000-000000000001/);
 else assert.doesNotMatch(result.html,/<a href=/);
});
test('subjects exact',()=>{
 for(const [kind,label] of [['instructor_assignment','przypisano Cię do szkolenia'],['instructor_removal','zmiana obsady szkolenia'],['instructor_event_cancellation','szkolenie zostało anulowane']])
  assert.equal(instructorEmailContent(tenant,kind,event).subject,`StrzelajTu.pl / Obiekt B — ${label}`);
});
function fixture(){let sends=0;const completions=[];const keys=[];
 const payload={...event,kind:'instructor_assignment',assignment_id:'generation',tenant_id:tenant.tenantId,recipient_email:'synthetic@example.invalid',idempotency_key:'instructor_assignment/generation'};
 const deps={claim:async()=>[{claim_id:'lease',delivery_id:'delivery'}],read:async()=>payload,tenant:async()=>tenant,
  send:async(_to,_content,key)=>{sends++;keys.push(key);return 'provider';},
  complete:async(...args)=>{completions.push(args);return true;}};
 return {deps,payload,completions,keys,sends:()=>sends};
}
test('provider key stable across retries',async()=>{const f=fixture();await deliverInstructorEmailBatch(f.deps);await deliverInstructorEmailBatch(f.deps);assert.deepEqual(f.keys,['instructor_assignment/generation','instructor_assignment/generation']);});
test('cancel before admission: no claim no send',async()=>{const f=fixture();f.deps.claim=async()=>[];await deliverInstructorEmailBatch(f.deps);assert.equal(f.sends(),0);});
test('admission wins: exact admitted attempt can proceed; no recall claim',async()=>{const f=fixture();assert.equal((await deliverInstructorEmailBatch(f.deps)).sent,1);});
test('lease expired before provider: zero send',async()=>{const f=fixture();let reads=0;f.deps.read=async()=>++reads===1?f.payload:null;await deliverInstructorEmailBatch(f.deps);assert.equal(f.sends(),0);});
test('cross tenant context fails closed',async()=>{const f=fixture();f.deps.tenant=async()=>({...tenant,tenantId:'another'});await deliverInstructorEmailBatch(f.deps);assert.equal(f.sends(),0);});
test('forged identity fails closed',async()=>{const f=fixture();f.payload.idempotency_key='other';await deliverInstructorEmailBatch(f.deps);assert.equal(f.sends(),0);});
test('timeout uncertain is not sent',async()=>{const f=fixture();f.deps.send=async()=>{throw Error('timeout');};assert.equal((await deliverInstructorEmailBatch(f.deps)).sent,0);assert.deepEqual(f.completions,[['lease',false,null]]);});
test('provider success marker failure is uncertain',async()=>{const f=fixture();f.deps.complete=async()=>{throw Error('db');};assert.equal((await deliverInstructorEmailBatch(f.deps)).sent,0);assert.equal(f.sends(),1);});
test('oversized batch fails closed',async()=>{const f=fixture();f.deps.claim=async()=>Array(6).fill({});await assert.rejects(deliverInstructorEmailBatch(f.deps));assert.equal(f.sends(),0);});
test('eventId is a resource selector, never caller-selected tenant or recipient authority',()=>{
 const runtime=readFileSync(new URL('./instructor-email.ts',import.meta.url),'utf8');
 assert.match(runtime,/import "server-only"/);assert.match(runtime,/authorize_instructor_email_batch_v1/);
 const route=readFileSync(new URL('../../app/api/send-instructor-emails/route.ts',import.meta.url),'utf8');
 assert.match(route,/Object.keys\(body\).join\(\) !== "eventId"/);assert.doesNotMatch(route,/body\.(tenant|user|email)/);
});

function routeFixture(allowed=true){
 const calls=[];
 const db={auth:{getUser:async()=>({})},rpc:async(name,args)=>{calls.push(['authorize',name,args]);return {data:allowed,error:null};}};
 const mocks={
  '@supabase/supabase-js':{createClient:()=>db},
  '@/lib/server/auth-user-verification':{verifyAuthUser:async()=>({ok:true})},
  '@/lib/server/instructor-email':{sendInstructorEmailBatch:async(actor,id)=>{assert.equal(actor,db);calls.push(['send',id]);return {sent:0,attempted:0,pending:false};}},
 };
 const source=readFileSync(new URL('../../app/api/send-instructor-emails/route.ts',import.meta.url),'utf8');
 const output=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
 const compiled={exports:{}};
 new Function('require','module','exports',output)(name=>{assert.ok(Object.hasOwn(mocks,name));return mocks[name];},compiled,compiled.exports);
 return {calls,post:body=>compiled.exports.POST(new Request('https://example.invalid/api/send-instructor-emails',{
  method:'POST',headers:{authorization:'Bearer synthetic-test-only','content-type':'application/json'},body:JSON.stringify(body),
 }))};
}
test('protected route authorizes the exact resource before processing',async()=>{
 const f=routeFixture();assert.equal((await f.post({eventId:event.event_id})).status,200);
 assert.deepEqual(f.calls,[['authorize','authorize_instructor_email_batch_v1',{p_event_id:event.event_id}],['send',event.event_id]]);
});
test('DB authorization denial prevents all route processing',async()=>{
 const f=routeFixture(false);assert.equal((await f.post({eventId:event.event_id})).status,403);
 assert.equal(f.calls.length,1);assert.equal(f.calls[0][0],'authorize');
});
for(const key of ['tenant_id','user_id','email','recipient_email','instructor_id','delivery_id'])test(`route rejects caller authority field ${key}`,async()=>{
 const f=routeFixture();assert.equal((await f.post({eventId:event.event_id,[key]:'forged'})).status,400);assert.deepEqual(f.calls,[]);
});
test('malformed resource selector fails closed before authorization',async()=>{
 const f=routeFixture();assert.equal((await f.post({eventId:'arbitrary'})).status,400);assert.deepEqual(f.calls,[]);
});
test('suspended tenant remains blocked in normal staff UI context',async()=>{
 let authCalls=0;const rpcCalls=[];
 const client={auth:{getUser:async()=>{authCalls++;return {data:{user:{id:event.event_id}},error:null};}},
  rpc:async name=>{rpcCalls.push(name);return {data:[{tenant_id:tenant.tenantId,tenant_slug:'tenant-b',tenant_name:'Tenant B',tenant_status:'suspended'}],error:null};}};
 assert.deepEqual(await resolveStaffTenantContext(client,'tenant-b',['admin','employee']),{ok:false,code:'not_found'});
 assert.equal(authCalls,0);assert.deepEqual(rpcCalls,['resolve_active_tenant_by_slug_v1']);
 const layout=readFileSync(new URL('../../app/t/[slug]/layout.tsx',import.meta.url),'utf8');
 assert.match(layout,/if \(!context.ok\) notFound\(\)/);
});
