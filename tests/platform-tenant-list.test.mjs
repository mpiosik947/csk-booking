import test from "node:test";
import assert from "node:assert/strict";
import { cardFacts, configurationLabel, lifecycleLabel, matchesTenant, primaryAction, readTenantPage } from "../lib/platform-tenant-list.ts";

const id="12345000-0000-4000-8000-000000000004";
const row={id,name:"Nazwa publiczna",tenant_slug:"obiekt-a",public_slug:"strzelnica-a",city:"Testowo",status:"dormant",is_public:false,
  is_platform_draft:true,plan_key:null,created_at:"2026-01-01T00:00:00Z",private_note:"do not project"};
const page=(rows=[row])=>({page:1,page_size:25,total:rows.length,items:rows});
const tenant=readTenantPage(page(),1).items[0];
const facts={internalName:"Nazwa wewnętrzna",admins:0,email:null,access:"coming_soon",proof:null,planActive:false,activationReady:null};

test("paged list accepts missing public profiles but rejects wrong pages, lifecycle and ambiguous flags",()=>{
  assert.equal(readTenantPage(page(),2),null);
  assert.equal(readTenantPage(page([{...row,name:null,public_slug:null,is_public:null}]),1).items.length,1);
  assert.doesNotMatch(JSON.stringify(tenant),/private_note|do not project/);
  for(const patch of [{status:"unknown"},{is_platform_draft:1},{created_at:"invalid"},{id:"bad"}]) {
    assert.equal(readTenantPage(page([{...row,...patch}]),1),null);
  }
});

test("only current server proof on a private, unassigned draft offers handover",()=>{
  const draft={...tenant,plan:"booking_only_v1"};
  const valid={...facts,planActive:true,proof:{current:true,checks:[]}};
  assert.equal(primaryAction(draft,valid).href,`/platform-admin/tenants/${id}/setup?step=summary`);
  for(const changed of [{proof:{current:false,checks:[]}},{proof:null},{access:null},{access:"live"},{admins:1}]) {
    assert.notEqual(primaryAction(draft,{...valid,...changed}).label,"Przekaż administratorowi");
  }
  assert.equal(primaryAction({...draft,published:true},valid).label,"Kontynuuj konfigurację");
  assert.equal(primaryAction({...draft,status:"archived"},valid).label,"Przywróć");
  assert.equal(primaryAction({...draft,draft:false},{...facts,admins:1}).label,"Otwórz obiekt");
  assert.equal(configurationLabel(draft,{...facts,proof:{current:false,checks:[{key:"plan",severity:"BLOCKER",result:"FAIL"}]}}),"Do uzupełnienia: Funkcje obiektu");
  assert.equal(lifecycleLabel({...draft,draft:false},{...facts,admins:1}),"Przekazany administratorowi");
  assert.equal(lifecycleLabel({...draft,status:"suspended"},facts),"Zawieszony");
});

test("list searches the real names and both slugs, excluding administrator PII",()=>{
  for(const query of ["publiczna","WEWNĘTRZNA","strzelnica-a"," Obiekt-A "])assert.ok(matchesTenant(tenant,facts,query));
  assert.ok(!matchesTenant(tenant,{...facts,email:"private@example.invalid"},"private@"));
});

test("an inconsistent or missing snapshot cannot stand in for confirmed admin/readiness data",async()=>{
  assert.equal(await cardFacts(tenant,async()=>({tenant_id:id,handover:null})),null);
  const archived={...tenant,status:"archived",draft:false};
  const detail={tenant:{tenant_id:id,name:"Wewnętrzna",technical_slug:"obiekt-a",status:"archived"},
    public_profile:{display_name:"Obiekt",city:"Testowo",public_slug:"strzelnica-a",is_public:false},plan:null,
    admins:[{user_id:id,email:"admin@example.invalid"}],readiness:{create_ready:true,activation_ready:false,public_ready:false,
    booking_ready:false,booking_required:true,publication_gate_enforced:false,checks:{}}};
  const read=async name=>name==="platform_get_tenant_onboarding_detail_v1"?detail:{state:"coming_soon",revision:id};
  const single=await cardFacts(archived,read);
  assert.equal(single.admins,1);assert.equal(single.email,"admin@example.invalid");assert.equal(single.access,"coming_soon");
  detail.admins.push({user_id:"12345000-0000-4000-8000-000000000005",email:"second@example.invalid"});
  const multiple=await cardFacts(archived,read);assert.equal(multiple.admins,2);assert.equal(multiple.email,null);
  detail.tenant.status="active";assert.equal(await cardFacts(archived,read),null);
});
