import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readAttempt,receiptId,storageKey} from '../lib/platform-draft.ts';
import {classifyError} from '../lib/platform-wizard.ts';
const attempt=()=>({version:2,requestId:randomUUID(),payload:{p_name:'Tenant C',p_city:'City',p_tenant_slug:'tenant-c',p_public_slug:'tenant-c-public',p_plan_key:null},state:'uncertain'});
test('draft retry persists optional-plan payload without administrator and rejects legacy/forged recovery',()=>{
 const a=attempt();assert.deepEqual(readAttempt(JSON.stringify(a)),a);
 for(const bad of [{...a,version:1},{...a,payload:{...a.payload,p_initial_admin_user_id:randomUUID()}},{...a,payload:{...a.payload,p_plan_key:{}}},{...a,state:'confirmed'},{...a,payload:{...a.payload,p_tenant_slug:'admin'}}])assert.equal(readAttempt(JSON.stringify(bad)),null);
 assert.notEqual(storageKey(randomUUID()),storageKey(randomUUID()));
});
test('draft receipt binds request, resource selectors, optional plan and explicit private states',()=>{
 const a=attempt(),p=a.payload,id=randomUUID(),r={tenant_id:id,creation_request_id:a.requestId,name:p.p_name,city:p.p_city,tenant_slug:p.p_tenant_slug,public_slug:p.p_public_slug,plan_key:null,initial_status:'dormant',initial_is_public:false,initial_public_access_state:'coming_soon'};
 assert.equal(receiptId(r,a),id);for(const field of Object.keys(r))assert.equal(receiptId({...r,[field]:'wrong'},a),null,field);
});
test('slug collision survives reload as a failed attempt with the same recovery payload',()=>{
 const failure=classifyError({code:'23505',message:'duplicate key value violates unique constraint'});
 assert.equal(failure.kind,'slug');
 const saved={...attempt(),state:'failed',failure:failure.kind};
 assert.deepEqual(readAttempt(JSON.stringify(saved)),saved);
});
