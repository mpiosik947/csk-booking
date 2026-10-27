import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {ManagementSession} from '../lib/platform-management-session.ts';
import {readPublicAccess} from '../lib/platform-management.ts';
import {fixture,rpcResponse,tenantId} from './fixtures/platform-management.mjs';

const reader='platform_get_tenant_public_access_v1',writer='platform_set_tenant_public_access_v1';
function harness(override=()=>undefined) {
  const f=fixture(),calls=[];
  const session=new ManagementSession(tenantId,async(name,args)=>{
    calls.push({name,args:structuredClone(args)});
    return (await override(name,args,f))??structuredClone(rpcResponse(f,name,args));
  },f.detail,randomUUID);
  return {f,calls,session,writes:()=>calls.filter(c=>c.name===writer)};
}

test('PA state projection accepts only known states and real revisions, without opaque fields',()=>{
  const revision=randomUUID();
  assert.deepEqual(readPublicAccess({state:'live',revision:null,secret:'PRIVATE'}),{state:'live',revision:null});
  assert.deepEqual(readPublicAccess({state:'coming_soon',revision}),{state:'coming_soon',revision});
  for(const value of [null,[],{}, {state:'live'}, {state:'unknown',revision}, {state:'coming_soon',revision:null}, {state:'live',revision:'bad'}, {state:'__proto__',revision}])assert.equal(readPublicAccess(value),null);
});

test('live -> coming_soon -> live uses exact tenant, expected state/revision and fresh request IDs',async()=>{
  const h=harness();await h.session.refresh();
  for(const state of ['coming_soon','live']){
    const before=h.session.snapshot().publicAccess.data;
    h.session.preparePublicAccess();assert.equal(h.writes().length,state==='live'?1:0);
    await h.session.confirm();const call=h.writes().at(-1);
    assert.deepEqual(Object.keys(call.args).sort(),['p_expected_revision','p_expected_state','p_request_id','p_state','p_tenant_id']);
    assert.deepEqual({...call.args,p_request_id:null},{p_tenant_id:tenantId,p_state:state,p_expected_state:before.state,p_expected_revision:before.revision,p_request_id:null});
    assert.equal(h.session.snapshot().publicAccess.data.state,state);
    assert.notEqual(h.session.snapshot().publicAccess.data.revision,before.revision);
    assert.equal(h.session.snapshot().attempt,null);
    assert.equal(h.calls.at(-1).name,reader);
  }
  assert.notEqual(h.writes()[0].args.p_request_id,h.writes()[1].args.p_request_id);
});

test('cancel confirmation makes no write; missing/invalid reader result cannot prepare a write',async()=>{
  const h=harness();await h.session.refresh();h.session.preparePublicAccess();h.session.cancel();await h.session.confirm();assert.equal(h.writes().length,0);
  for(const data of [null,{state:'coming_soon',revision:null},{state:'paused',revision:randomUUID()}]){
    const bad=harness(name=>name===reader?{data,error:null}:undefined);await bad.session.refresh();bad.session.preparePublicAccess();await bad.session.confirm();
    assert.equal(bad.session.snapshot().publicAccess.data,null);assert.equal(bad.writes().length,0);
  }
});

test('double confirmation and refresh while pending cannot cause repeated writes or optimistic state',async()=>{
  let release;const h=harness(name=>name===writer?new Promise(resolve=>{release=resolve;}):undefined);
  await h.session.refresh();h.session.preparePublicAccess();const pending=h.session.confirm();
  await h.session.confirm();await h.session.refresh();h.session.preparePublicAccess();
  assert.equal(h.writes().length,1);assert.equal(h.session.snapshot().busy,true);assert.equal(h.session.snapshot().publicAccess.data,null);
  h.f.publicAccess={state:'coming_soon',revision:randomUUID()};release({data:{...h.f.publicAccess,changed:true},error:null});await pending;
  assert.equal(h.session.snapshot().publicAccess.data.state,'coming_soon');assert.equal(h.session.snapshot().busy,false);
});

for(const message of ['PUBLIC_ACCESS_STATE_CONFLICT','PUBLIC_ACCESS_REQUEST_CONFLICT','TENANT_PUBLIC_ACCESS_RETRY']){
  test(`${message}: re-read state; no automatic retry`,async()=>{
    const h=harness((name,args,f)=>{if(name===writer){f.publicAccess={state:'coming_soon',revision:randomUUID()};return {data:null,error:{code:'PT409',message}};}});
    await h.session.refresh();h.session.preparePublicAccess();await h.session.confirm();
    assert.equal(h.writes().length,1);assert.equal(h.session.snapshot().attempt,null);assert.equal(h.session.snapshot().publicAccess.data.state,'coming_soon');assert.match(h.session.snapshot().message,/ponownie potwierdź/);
  });
}

for(const error of [{status:401},{status:403},{code:'401'},{code:'403'},{code:'42501'},{code:'PGRST301'},{code:'PGRST302'},{code:'PGRST303'}]){
  test(`authority denial clears state and disables writer: ${JSON.stringify(error)}`,async()=>{
    for(const failed of [reader,writer]){
      const h=harness(name=>name===failed?{data:null,error}:undefined);await h.session.refresh();h.session.preparePublicAccess();await h.session.confirm();
      assert.equal(h.session.snapshot().denied,true);assert.equal(h.session.snapshot().publicAccess.data,null);assert.equal(h.session.snapshot().attempt,null);
      const count=h.writes().length;h.session.preparePublicAccess();await h.session.confirm();assert.equal(h.writes().length,count);
    }
  });
}

test('lost acknowledgement retries only the identical frozen request and hides unconfirmed state',async()=>{
  let receipt;const h=harness((name,args,f)=>{if(name===writer){if(!receipt){f.publicAccess={state:args.p_state,revision:randomUUID()};receipt={...f.publicAccess,changed:true};throw Error('Lost acknowledgement');}return {data:receipt,error:null};}});
  await h.session.refresh();h.session.preparePublicAccess();await h.session.confirm();
  assert.equal(h.session.snapshot().attempt.phase,'uncertain');assert.equal(h.session.snapshot().publicAccess.data,null);
  h.session.cancel();h.session.preparePublicAccess();await h.session.refresh();assert.equal(h.writes().length,1);
  await h.session.confirm();assert.deepEqual(h.writes()[1],h.writes()[0]);assert.equal(h.session.snapshot().publicAccess.data.state,'coming_soon');
});

test('raw HTTP 401/403 from the Supabase response fail closed even without a PostgREST code',async()=>{
  for(const status of [401,403])for(const failed of [reader,writer]){
    const h=harness(name=>name===failed?{data:null,error:{message:'Unauthorized'},status}:undefined);
    await h.session.refresh();h.session.preparePublicAccess();await h.session.confirm();
    assert.equal(h.session.snapshot().denied,true);assert.equal(h.session.snapshot().publicAccess.data,null);
  }
});

test('failed canonical read after accepted write does not claim known current state',async()=>{
  let reads=0;const h=harness(name=>name===reader&&++reads>1?{data:null,error:{code:'XX000',message:'PRIVATE'}}:undefined);
  await h.session.refresh();h.session.preparePublicAccess();await h.session.confirm();
  assert.equal(h.session.snapshot().publicAccess.data,null);assert.match(h.session.snapshot().message,/aktualna dostępność jest nieznana/);
  h.session.preparePublicAccess();await h.session.confirm();assert.equal(h.writes().length,1);
});

test('definite business rejection re-reads unchanged live state and never renders raw SQL error',async()=>{
  const h=harness(name=>name===writer?{data:null,error:{code:'22023',message:'PRIVATE SQL'}}:undefined);
  await h.session.refresh();h.session.preparePublicAccess();await h.session.confirm();
  assert.equal(h.session.snapshot().publicAccess.data.state,'live');assert.equal(h.session.snapshot().attempt,null);assert.doesNotMatch(h.session.snapshot().message,/PRIVATE/);
});

test('malformed acknowledgement is uncertain; auth loss invalidates late successful writer response',async()=>{
  const bad=harness(name=>name===writer?{data:{state:'coming_soon',revision:null,changed:true},error:null}:undefined);
  await bad.session.refresh();bad.session.preparePublicAccess();await bad.session.confirm();assert.equal(bad.session.snapshot().attempt.phase,'uncertain');
  let release;const h=harness(name=>name===writer?new Promise(resolve=>{release=resolve;}):undefined);
  await h.session.refresh();h.session.preparePublicAccess();const pending=h.session.confirm();h.session.deny();
  release({data:{state:'coming_soon',revision:randomUUID(),changed:true},error:null});await pending;
  assert.equal(h.session.snapshot().publicAccess.data,null);assert.equal(h.session.snapshot().denied,true);
});
