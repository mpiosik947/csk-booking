import test from 'node:test';import assert from 'node:assert/strict';import {randomUUID} from 'node:crypto';
import {parseConfigAttempt,configReceipt,configError,configStorageKey,parseConfiguration,profileTextKeys,profileFlagKeys} from '../lib/platform-draft-configuration.ts';
const attempt=()=>({tenantId:randomUUID(),revision:'a'.repeat(64),requestId:randomUUID(),section:'create_lane',payload:{root:{name:'C'},positions:[]}});
test('configuration recovery preserves exact request, revision and payload; tenant and actor storage isolate attempts',()=>{
 const a=attempt();assert.deepEqual(parseConfigAttempt(JSON.stringify(a),a.tenantId),a);
 assert.equal(parseConfigAttempt(JSON.stringify(a),randomUUID()),null);
 for(const patch of [{revision:'0'},{requestId:'x'},{section:'publish'},{payload:[]}])assert.equal(parseConfigAttempt(JSON.stringify({...a,...patch}),a.tenantId),null);
 const actor=randomUUID();assert.notEqual(configStorageKey(actor,a.tenantId),configStorageKey(actor,randomUUID()));assert.notEqual(configStorageKey(actor,a.tenantId),configStorageKey(randomUUID(),a.tenantId));
});
test('only a receipt bound to tenant, request and section confirms a save',()=>{
 const a=attempt(),mutation={ok:true,changed:true,code:'created'},receipt={tenant_id:a.tenantId,request_id:a.requestId,section:a.section,revision:'b'.repeat(64),mutation};
 assert.deepEqual(configReceipt(receipt,a),mutation);
 for(const key of ['tenant_id','request_id','section','revision','mutation'])assert.equal(configReceipt({...receipt,[key]:'wrong'},a),null);
 assert.equal(configReceipt({...receipt,mutation:{ok:false}},a),null);
});
test('conflicts, authority denial and transport uncertainty remain distinct without exposing SQL',()=>{
 assert.equal(configError({code:'PT409'}).kind,'conflict');assert.equal(configError({code:'42501'}).kind,'denied');assert.equal(configError({code:'23514'}).kind,'invalid');for(const status of [401,403])assert.equal(configError({status}).kind,'denied');for(const code of ['401','403','PGRST301','PGRST302','PGRST303'])assert.equal(configError({code}).kind,'denied');assert.equal(configError({}).kind,'uncertain');assert.doesNotMatch(configError({message:'PRIVATE SQL'}).message,/PRIVATE|SQL/);
});
test('configuration parser enforces draft safety and selector while projecting only configuration fields',()=>{
 const id=randomUUID(),profile={...Object.fromEntries(profileTextKeys.map(k=>[k,null])),...Object.fromEntries(profileFlagKeys.map(k=>[k,false])),display_name:'C',city:'City',social_links:{},is_public:false,public_slug:'c-public'};
 const row={tenant_id:id,name:'C',tenant_slug:'tenant-c',status:'dormant',revision:'a'.repeat(64),memberships:0,public_access_state:'coming_soon',profile,pricing_items:[],lanes:{contract_version:2,families:[]},plan:null,feature_access:{booking:false,events:false,instructors:false},customer_email:'PRIVATE'};
 assert.equal(parseConfiguration(row,id).name,'C');assert.doesNotMatch(JSON.stringify(parseConfiguration(row,id)),/PRIVATE|customer_email/);
 const plan={plan_key:'example',status:'active',plan_status:'active',features:[{key:'booking',active:true},{key:'events',active:false}]};
 const assigned=parseConfiguration({...row,plan,partners:[{name:'internal-only'}]},id);
 assert.deepEqual(assigned.planFeatures,['booking']);assert.equal(assigned.partnerCount,1);
 assert.doesNotMatch(JSON.stringify(assigned),/internal-only/);
 for(const disabled of [{status:'suspended'},{plan_status:'inactive'}]){
   assert.deepEqual(parseConfiguration({...row,plan:{...plan,...disabled}},id).planFeatures,[]);
 }
 assert.equal(parseConfiguration({...row,plan:{...plan,features:[{key:'booking',active:'false'}]}},id),null);
 for(const patch of [{tenant_id:randomUUID()},{memberships:1},{status:'active'},{public_access_state:'live'},{profile:{...profile,is_public:true}},{lanes:{}}])assert.equal(parseConfiguration({...row,...patch},id),null);
});
