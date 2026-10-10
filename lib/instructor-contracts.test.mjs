import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import ts from 'typescript';
import * as contracts from './instructor-contracts.ts';
import { parseInstructorOptions, eventEditRevision, assignmentError } from './admin/events/instructor-assignments.ts';
const eventId='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const event={id:eventId,title:'Synthetic training',description:null,event_date:'2026-12-01',start_time:'10:00:00',end_time:'11:00:00',location:null,status:'upcoming',participants_available:true};
const participant={registration_id:'registration',display_name:'Synthetic person',registration_status:'registered',attendance_status:'unmarked',attendance_version:0};
for(const field of ['email','phone','user_id','billing','verification','admin_notes','memberships']) {
  test(`DTO strips ${field}`,()=>{
    assert.deepEqual(contracts.parseInstructorEvent({...event,[field]:'PRIVATE'}),event);
    assert.deepEqual(contracts.parseInstructorParticipant({...participant,[field]:'PRIVATE'}),participant);
  });
}
for(const status of ['cancelled','participant','unknown',null]) test(`participant ${status} fails closed`,()=>{
  assert.throws(()=>contracts.parseInstructorParticipant({...participant,registration_status:status}));
});
test('pagination rejects malformed counts and rows',()=>{
  for(const total of [-1,1.2,null,'1']) assert.throws(()=>contracts.parseInstructorPage({items:[],total},contracts.parseInstructorEvent));
  assert.throws(()=>contracts.parseInstructorPage({items:[{}],total:1},contracts.parseInstructorEvent));
});
test('lookup projects only user_id/display_name',()=>{
  assert.deepEqual(parseInstructorOptions([{user_id:'i',display_name:'Instructor',email:'PRIVATE'}]),[{user_id:'i',display_name:'Instructor'}]);
  assert.throws(()=>parseInstructorOptions([null]));
});
test('canonical event revision sorts lanes and normalizes time without authority',()=>{
  const result=eventEditRevision({...event,price:0,max_participants:5,is_active:true,laneIds:['b','a']});
  assert.deepEqual(result.lane_ids,['a','b']);assert.equal(result.start_time,'10:00:00');
  assert.equal(result.cancelled_at,null);assert.equal(result.tenant_id,undefined);
  assert.match(assignmentError('40001'),/Nic nie zapisano/);
});
function route({allowed=true,available=true,participantDenied=false}={}) {
  const calls=[];
  const source=readFileSync(new URL('../app/api/instructor/[slug]/events/route.ts',import.meta.url),'utf8');
  const code=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  const exports={};
  new Function('require','exports',code)(name=>name.includes('instructor-contracts')?contracts:{
    getStaffRouteContext:async(slug,roles)=>{assert.deepEqual(roles,['instructor']);return allowed?{ok:true,value:{tenant:{tenantId:`verified-${slug}`}}}:{ok:false};},
    getTenantRequestClient:async()=>({rpc:async(name,args)=>{
      calls.push({name,args});
      if(name==='get_my_instructor_events_v1')return {data:{items:[{...event,participants_available:available,email:'PRIVATE'}],total:1}};
      return participantDenied?{error:{code:'42501'}}:{data:{items:[{...participant,email:'PRIVATE'}],total:1}};
    }}),
  },exports);
  return {calls,get:(query='')=>exports.GET(new Request(`http://localhost/api/instructor/a/events${query}`),{params:Promise.resolve({slug:'a'})})};
}
test('HTTP denies before RPC without instructor membership',async()=>{
  const r=route({allowed:false});assert.equal((await r.get()).status,403);assert.equal(r.calls.length,0);
});
test('HTTP derives tenant context and allowlists DTO; private no-store',async()=>{
  const r=route();const response=await r.get('?tenant_id=forged');
  assert.equal(r.calls[0].args.p_tenant_id,'verified-a');assert.match(response.headers.get('cache-control'),/private, no-store/);
  assert.equal(response.headers.get('vary'),'Cookie');assert.doesNotMatch(await response.text(),/PRIVATE|email/);
});
test('HTTP removal between metadata and PII reads denies entire response',async()=>{
  const r=route({participantDenied:true});const response=await r.get(`?eventId=${eventId}`);
  assert.equal(response.status,403);assert.doesNotMatch(await response.text(),/Synthetic/);
});
test('cancelled/expired metadata returns no participant data and makes no PII RPC',async()=>{
  const r=route({available:false});const response=await r.get(`?eventId=${eventId}`);
  assert.equal((await response.json()).participants,null);assert.equal(r.calls.length,1);
});
for(const query of ['?eventId=bad','?page=-1','?page=0.5','?scope=all','?section=private'])test(`HTTP invalid input ${query}`,async()=>{
  const r=route();assert.equal((await r.get(query)).status,403);assert.equal(r.calls.length,0);
});
test('admin save uses a single atomic contract and both revisions',()=>{
  const source=readFileSync(new URL('../app/admin/events/page.tsx',import.meta.url),'utf8');
  assert.match(source,/admin_create_event_with_instructors_v1/);assert.match(source,/admin_update_event_with_instructors_v1/);
  assert.match(source,/p_expected_event_revision: eventRevision/);assert.match(source,/p_expected_assignment_revision: assignmentRevision/);
  assert.doesNotMatch(source,/rpc\("admin_set_event_instructors_v1"|\.from\("event_instructors"\)/);
});
test('instructor reader retains lifecycle invalidation and no persistent PII cache',()=>{
  const source=readFileSync(new URL('../app/instructor/InstructorEvents.tsx',import.meta.url),'utf8');
  // Polling cadence/terminal denial are verified with the browser controlled-clock suite.
  assert.match(source,/cache: "no-store"/);
  assert.match(source,/pagehide/);assert.match(source,/visibilitychange/);assert.match(source,/onAuthStateChange/);
  assert.doesNotMatch(source,/localStorage|sessionStorage|service_role|\.from\(|method:.*POST|check.?in|window\.print/i);
});
test('attendance DTO excludes internal actor and timestamps',()=>{
 assert.deepEqual(contracts.parseInstructorParticipant({...participant,attendance_marked_by:'PRIVATE',attendance_marked_at:'PRIVATE'}),participant);
});
for(const value of [-1,1.2,null,'1',Number.MAX_SAFE_INTEGER+1])test(`attendance invalid version ${value}`,()=>{
 assert.throws(()=>contracts.parseInstructorParticipant({...participant,attendance_version:value}));
});
test('attendance component calls only resource-derived versioned RPC, never direct table update',()=>{
 const source=readFileSync(new URL('../app/instructor/AttendanceControls.tsx',import.meta.url),'utf8');
 assert.match(source,/set_event_registration_attendance_v1/);assert.match(source,/p_expected_attendance_version: row.attendance_version/);
 assert.doesNotMatch(source,/\.from\(|p_tenant_id|p_user_id|p_event_id|service_role/);
 assert.match(source,/40001/);assert.match(source,/onRefresh\(outcome\)/);
});
