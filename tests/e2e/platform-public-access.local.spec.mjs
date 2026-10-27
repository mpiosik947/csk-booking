import {test,expect} from '@playwright/test';
import {createServerClient} from '@supabase/ssr';
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';

// Explicit disposable local configuration only. Never load project/production env.
const configPath=process.env.PUBLIC_TEST_MODE_FIXTURE_FILE;
const fixture=JSON.parse(fs.readFileSync(configPath,'utf8'));
for(const url of [fixture.app,fixture.origin])assert.equal(new URL(url).hostname,'127.0.0.1');
assert.match(fixture.scratchDatabase,/^sbr3_[a-f0-9]{16}$/);
const A='e7310000-0000-4000-8000-000000000001',B='e7320000-0000-4000-8000-000000000001';
const reader='platform_get_tenant_public_access_v1',writer='platform_set_tenant_public_access_v1';
const users={admin:'ptm2-0@example.invalid',employee:'ptm2-1@example.invalid',instructor:'ptm2-2@example.invalid',customer:'ptm1-customer@example.invalid',foreign:'ptm2-5@example.invalid',suspended:'ptm2-3@example.invalid',removed:'ptm2-7@example.invalid',pa:'ptm2-6@example.invalid'};
async function login(context,role){
  const cookies=[];
  const client=createServerClient(fixture.origin,fixture.anonKey,{cookieOptions:{secure:true},cookies:{getAll:()=>[],setAll:items=>cookies.push(...items)}});
  const {data,error}=await client.auth.signInWithPassword({email:users[role],password:fixture.password});
  expect(error).toBeNull();
  await context.addCookies(cookies.map(({name,value})=>({name,value,domain:'127.0.0.1',path:'/',secure:true,sameSite:'Lax'})));
  return data.session.access_token;
}
async function rpc(name,args,token=fixture.anonKey){
  const response=await fetch(`${fixture.origin}/rest/v1/rpc/${name}`,{method:'POST',headers:{apikey:fixture.anonKey,authorization:`Bearer ${token}`,'content-type':'application/json'},body:JSON.stringify(args)});
  return {status:response.status,body:await response.json()};
}
test.beforeEach(async({context})=>{
  await context.route('**/*',route=>new URL(route.request().url()).hostname==='127.0.0.1'?route.continue():route.abort());
});

for(const role of ['admin','employee','instructor','customer','foreign','suspended','removed','anonymous']){
  test(`${role}: control hidden and real JWT cannot write selected or forged tenant`,async({page,context})=>{
    const token=role==='anonymous'?fixture.anonKey:await login(context,role);
    const response=await page.goto(`/platform-admin/tenants/${A}`);
    if(role==='anonymous')await expect(page).toHaveURL(/\/login\?/);else expect(response.status()).toBe(404);
    await expect(page.getByRole('region',{name:'Publiczna dostępność obiektu',exact:true})).toHaveCount(0);
    for(const tenant of [A,B]){
      const result=await rpc(writer,{p_tenant_id:tenant,p_state:'coming_soon',p_expected_state:'live',p_expected_revision:null,p_request_id:randomUUID()},token);
      expect([401,403]).toContain(result.status);expect(result.body.code).toBe('42501');
      const read=await rpc(reader,{p_tenant_id:tenant},token);expect([401,403]).toContain(read.status);
    }
  });
}

test('real UI PA login: A live -> coming_soon -> live; B unchanged; JWT and audit request binding',async({page,context},testInfo)=>{
  const writes=[],errors=[];
  const expectedActor=fixture.users.find(u=>u.email===users.pa).id;
  page.on('pageerror',error=>errors.push(error.message));
  page.on('request',request=>{
    if(!request.url().endsWith('/rest/v1/rpc/'+writer))return;
    const bearer=request.headers().authorization?.replace(/^Bearer /,'');
    const claims=JSON.parse(Buffer.from(bearer.split('.')[1],'base64url').toString('utf8'));
    // Inspect only; never persist the credential. PostgREST independently verifies JWT.
    expect(claims.role).toBe('authenticated');expect(claims.sub).toBe(expectedActor);
    expect(request.method()).toBe('POST');
    const payload=request.postDataJSON();expect(payload.p_tenant_id).toBe(A);
    expect(Object.keys(payload).sort()).toEqual(['p_expected_revision','p_expected_state','p_request_id','p_state','p_tenant_id']);
    writes.push({payload,actor:claims.sub,role:claims.role,at:new Date().toISOString()});
  });
  await page.goto('/login?redirectTo=%2F');
  await page.getByLabel('E-mail',{exact:true}).fill(users.pa);await page.getByLabel('Hasło',{exact:true}).fill(fixture.password);
  await page.getByRole('button',{name:'Zaloguj się',exact:true}).click();
  await page.waitForURL(fixture.app+'/');
  await page.goto(`/platform-admin/tenants/${A}`);
  const card=page.getByRole('region',{name:'Publiczna dostępność obiektu',exact:true});
  await expect(page.getByRole('button',{name:'Odśwież stan',exact:true})).toBeEnabled();
  // Read B through its normal PA UI before any A write; keep its state isolated.
  const bPage=await context.newPage();await bPage.goto(`${fixture.app}/platform-admin/tenants/${B}`);
  const bCard=bPage.getByRole('region',{name:'Publiczna dostępność obiektu',exact:true});
  await expect(bCard).toContainText('Bieżący stan: LIVE');
  async function change(label,expected){
    await card.getByRole('button',{name:label,exact:true}).click();
    await expect(page.getByRole('dialog')).toContainText('[TEST][PUBLIC-TEST-MODE-2] A');
    const responsePromise=page.waitForResponse(r=>r.url().endsWith('/rest/v1/rpc/'+writer)&&r.request().method()==='POST');
    await page.getByRole('dialog').getByRole('button',{name:'Potwierdź operację',exact:true}).click();
    const response=await responsePromise;expect(response.status()).toBe(200);expect((await response.json()).changed).toBe(true);
    await expect(page.getByRole('dialog')).toHaveCount(0);await expect(card).toContainText('Bieżący stan: '+expected);
    await bPage.reload();await expect(bCard).toContainText('Bieżący stan: LIVE');
  }
  // Shared local regression fixtures start in coming_soon. Establish live using
  // the same real PA UI, then exercise the requested live -> soon -> live cycle.
  await expect(card).toContainText('Bieżący stan: DOSTĘPNA WKRÓTCE');
  await change('Ustaw: Aktywna','LIVE');
  await card.getByRole('button',{name:'Ustaw: Wkrótce',exact:true}).click();
  await page.getByRole('dialog').getByRole('button',{name:'Anuluj',exact:true}).click();expect(writes).toHaveLength(1);
  await change('Ustaw: Wkrótce','DOSTĘPNA WKRÓTCE');
  await page.screenshot({path:testInfo.outputPath('real-pa-coming-soon.png'),fullPage:true});
  const anon=await context.browser().newContext({ignoreHTTPSErrors:true});
  try{
    await anon.route('**/*',route=>new URL(route.request().url()).hostname==='127.0.0.1'?route.continue():route.abort());
    const publicPage=await anon.newPage();await publicPage.goto(fixture.app+'/');
    await expect(publicPage.locator('a[href="/ptm1-public-a"]')).toHaveCount(0);await expect(publicPage.locator('a[href="/ptm2-public-b"]')).toBeVisible();
    await publicPage.goto(fixture.app+'/t/ptm1-synthetic-a/booking');await expect(publicPage.getByRole('heading',{name:/Dostępna wkrótce/})).toBeVisible();
    expect((await rpc('get_public_booking_configuration_v2',{p_tenant_id:A})).status).toBe(423);
    expect((await rpc('get_public_event_list_v3',{p_tenant_id:A})).status).toBe(423);
    await change('Ustaw: Aktywna','LIVE');
    await publicPage.reload();await expect(publicPage.getByRole('heading',{name:'Zarezerwuj oś',exact:true})).toBeVisible();
  }finally{await anon.close();await bPage.close();}
  expect(writes).toHaveLength(3);expect(new Set(writes.map(w=>w.payload.p_request_id)).size).toBe(3);expect(errors).toEqual([]);
  fs.writeFileSync(path.join(path.dirname(configPath),'public-access-requests.json'),JSON.stringify({result:'PASS',db:fixture.scratchDatabase,tenant:A,otherTenant:B,actor:expectedActor,writes,productionWrite:false},null,2));
});
