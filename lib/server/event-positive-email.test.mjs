import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import ts from 'typescript';
// Load this small server boundary with only the server-only marker removed.
const source=readFileSync(new URL('./event-positive-email.ts',import.meta.url),'utf8').replace('import "server-only";','');
const js=ts.transpile(source,{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022});
const {requireEventDispatchLease}=await import('data:text/javascript;base64,'+Buffer.from(js).toString('base64'));
for(const [name,data,error] of [['expired/replaced',false,null],['missing',null,null],['transport error',null,{code:'failure'}],['malformed','true',null]])
test(`${name} attempt cannot call provider`,async()=>{let sends=0;await assert.rejects(async()=>{await requireEventDispatchLease({rpc:async()=>({data,error})},'claim','registration');sends++});assert.equal(sends,0)});
test('exact unexpired admitted attempt can proceed after later cancellation',async()=>{
 let calls=0;const db={rpc:async(name,args)=>{assert.equal(name,'check_event_email_dispatch_lease_v1');assert.deepEqual(args,{p_claim_id:'claim',p_kind:'acceptance'});return {data:true,error:null}}};
 await requireEventDispatchLease(db,'claim','acceptance');calls++;assert.equal(calls,1);
});
test('claim admission locks the same event row as cancellation',()=>{
 const sql=readFileSync(new URL('../../supabase/migrations/20261019100000_add_event_wide_cancellation.sql',import.meta.url),'utf8');
 assert.match(sql,/select \* into e from public.events where id=p_event_id for update/);
 assert.equal((sql.match(/cancelled_at is null for update/g)||[]).length,2);
 assert.match(sql,/where r.id=p_registration_id for update of e;[\s\S]*?e.cancelled_at is not null/);
});
