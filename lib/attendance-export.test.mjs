import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import ts from 'typescript';
import * as render from './attendance-export.ts';
import * as contracts from './instructor-contracts.ts';
const id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const event={id,title:'Event B <script>alert(1)</script>',description:null,event_date:'2026-12-01',start_time:'10:00:00',end_time:'11:00:00',location:'Sala B',status:'upcoming',participants_available:true};
const row={registration_id:'PRIVATE_ID',display_name:'Żółć; "Test"\nNowa linia',registration_status:'registered',attendance_status:'present',attendance_version:0};
const data={tenant:'Tenant B',event,rows:[row]};
for(const prefix of ['', ' ', '\t','\r\n','\u0000\u001f'])for(const formula of ['=SUM(1,1)','+cmd','-10+20','@evil'])test(`formula ${JSON.stringify(prefix+formula)}`,()=>{
 const csv=render.attendanceCsv({...data,rows:[{...row,display_name:prefix+formula}]});assert.ok(csv.includes(`"'${prefix+formula}"`));
});
test('CSV encoding, escaping and PII allowlist',()=>{const csv=render.attendanceCsv(data);assert.ok(csv.startsWith('\uFEFF'));assert.ok(csv.endsWith('\r\n'));assert.ok(csv.includes('"Żółć; ""Test""\nNowa linia"'));assert.match(csv,/Obecny/);assert.doesNotMatch(csv,/PRIVATE_ID|registration_id|attendance_version|CSK|csk|email|phone/);});
test('print HTML escaping and minimal table',()=>{const html=render.attendancePrint(data);assert.doesNotMatch(html,/<script|PRIVATE_ID|registration_id/);assert.match(html,/&lt;script&gt;/);assert.match(html,/@media print/);assert.match(html,/Żółć; &quot;Test&quot;/);});
test('fixed sanitized filename',()=>{for(const title of ['../../evil','a\\b','\r\nX: injected'])assert.equal(render.attendanceFilename({...event,title}),'lista-obecnosci-2026-12-01.csv');assert.equal(render.attendanceFilename({...event,event_date:'../../evil'}),'lista-obecnosci-wydarzenie.csv');});
test('no truncation or reserve export',()=>{assert.throws(()=>render.attendanceCsv({...data,rows:Array(101).fill(row)}));assert.throws(()=>render.attendancePrint({...data,rows:[{...row,registration_status:'reserve'}]}));assert.doesNotThrow(()=>render.attendanceCsv({...data,rows:Array(100).fill(row)}));});
function route({allowed=true,available=true,denyRows=false,total=1,rows=[row],wrongEvent=false}={}){
 const calls=[];const source=readFileSync(new URL('../app/api/instructor/[slug]/events/[eventId]/attendance/[format]/route.ts',import.meta.url),'utf8');
 const code=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;const exports={};
 new Function('require','exports',code)(name=>name.includes('attendance-export')?render:name.includes('instructor-contracts')?contracts:{
  getStaffRouteContext:async(slug,roles)=>{assert.deepEqual(roles,['instructor']);return allowed?{ok:true,value:{tenant:{tenantId:'verified-'+slug,name:'Tenant B'}}}:{ok:false};},
  getTenantRequestClient:async()=>({rpc:async(name,args)=>{calls.push({name,args});return name==='get_my_instructor_events_v1'?{data:{items:[{...event,id:wrongEvent?'other':id,participants_available:available}],total:1}}:denyRows?{error:{code:'42501'}}:{data:{items:rows,total}};}})
 },exports);
 return {calls,get:(format='csv')=>exports.GET(new Request('https://local.test/?tenant_id=forged'),{params:Promise.resolve({slug:'tenant-b',eventId:id,format})})};
}
for(const format of ['csv','print']){
 test(`${format} unauthorized no fetch/count`,async()=>{const r=route({allowed:false});assert.equal((await r.get(format)).status,403);assert.equal(r.calls.length,0);});
 test(`${format} cancelled / retention unavailable denies before participant fetch`,async()=>{const r=route({available:false});assert.equal((await r.get(format)).status,403);assert.equal(r.calls.length,1);});
 test(`${format} revoked between reads denies`,async()=>{const r=route({denyRows:true});const res=await r.get(format);assert.equal(res.status,403);assert.doesNotMatch(await res.text(),/Tenant B|Żółć/);});
 test(`${format} correct scoped reader, cache and DTO`,async()=>{const r=route();const res=await r.get(format);assert.equal(res.status,200);assert.match(res.headers.get('cache-control'),/private, no-store/);assert.equal(res.headers.get('vary'),'Cookie');assert.equal(res.headers.get('x-content-type-options'),'nosniff');assert.equal(r.calls[0].args.p_tenant_id,'verified-tenant-b');assert.equal(r.calls[1].args.p_event_id,id);assert.equal(r.calls[1].args.p_section,'participants');assert.equal(r.calls[1].args.p_limit,100);assert.doesNotMatch(await res.text(),/PRIVATE_ID/);});
 test(`${format} oversized explicit error; mismatched count fail closed`,async()=>{assert.equal((await route({total:101}).get(format)).status,422);assert.equal((await route({total:2}).get(format)).status,403);assert.equal((await route({wrongEvent:true}).get(format)).status,403);});
}
