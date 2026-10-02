import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { createClient } from "@supabase/supabase-js";
import { expect, test, type Page } from "@playwright/test";
import { getLocalSupabaseTestEnvironment } from "./local-supabase";

const env = getLocalSupabaseTestEnvironment(), database = process.env.ONBOARD_1B_DATABASE;
if (!/^onboard_1b_[0-9a-f]{16}$/.test(database ?? "")) throw Error("Disposable ONBOARD-1B database required");
const sql = (statement: string) => execFileSync("docker", ["exec", "supabase_db_csk-booking", "psql", "-X", "-At", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", database!, "-c", statement], { encoding: "utf8" }).trim();
const service = createClient(env.supabaseUrl, env.serviceRoleKey, { auth: { persistSession: false, autoRefreshToken: false } });
const run = randomUUID(), password = `Local-${run}!Aa9`, emails = ["pa", "owner", "normal", "second", "employee", "instructor", "suspended"].map(role => `${role}-${run}@example.invalid`), users: string[] = [];
const clients = emails.map(() => createClient(env.supabaseUrl, env.anonKey, { auth: { persistSession: false, autoRefreshToken: false } }));
const slugs: string[] = [];
test.describe.configure({ mode: "serial" });

async function login(page: Page, index = 0) {
  await page.goto("/login?redirectTo=%2Fdashboard"); await page.getByLabel("E-mail", { exact: true }).fill(emails[index]); await page.getByLabel("Hasło", { exact: true }).fill(password);
  await page.getByRole("button", { name: "Zaloguj się", exact: true }).click(); await expect(page).toHaveURL(/\/dashboard$/);
}
async function fillWizard(page: Page, slug: string, publicSlug = `pub-${slug}`) {
  await page.goto("/platform-admin/tenants/new");
  await page.getByLabel("Nazwa obiektu", { exact: true }).fill(`Local ${slug}`); await page.getByLabel("Miejscowość", { exact: true }).fill("Testowo");
  await page.getByRole("button", { name: "Dalej", exact: true }).click();
  await page.getByLabel("Adres techniczny").fill(slug); await page.getByLabel("Adres publiczny").fill(publicSlug);
  await page.getByRole("button", { name: "Dalej", exact: true }).click(); await page.getByRole("radio", { name: /booking_only_v1/ }).check();
  await page.getByRole("button", { name: "Dalej", exact: true }).click(); await page.getByLabel("E-mail administratora").fill(emails[1]);
  await page.getByRole("button", { name: "Sprawdź konto", exact: true }).click(); await expect(page.getByText("Potwierdzone konto może zostać administratorem.")).toBeVisible();
  await page.getByRole("button", { name: "Dalej", exact: true }).click(); await expect(page.getByText("Stan początkowy: DORMANT · PRIVATE · NOT PUBLISHED.")).toBeVisible();
  for(const width of [320,375,768,1440]) { await page.setViewportSize({width,height:900}); expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true); }
  await page.setViewportSize({width:320,height:900}); await page.screenshot({path:'../onboard-1b-wizard/wizard-320.png',fullPage:true});
  await page.getByRole("button", { name: "Dalej", exact: true }).click();
}
function payload(slug: string, overrides = {}) { return { p_name: `Local ${slug}`, p_city: "Testowo", p_tenant_slug: slug, p_public_slug: `pub-${slug}`, p_plan_key: "booking_only_v1", p_initial_admin_user_id: users[1], p_creation_request_id: randomUUID(), ...overrides }; }

test.beforeAll(async () => {
  expect(sql("select max(version) from supabase_migrations.schema_migrations")).toBe("20261028100000");
  for (let i = 0; i < emails.length; i++) {
    const created = await service.auth.admin.createUser({ email: emails[i], password, email_confirm: true });
    if (created.error || !created.data.user) throw Error("Local synthetic account creation failed"); users.push(created.data.user.id);
    const signed = await clients[i].auth.signInWithPassword({ email: emails[i], password }); expect(signed.error).toBeNull();
  }
  sql(`select public.operator_bootstrap_platform_admin_v1('${users[0]}'); insert into public.platform_admins(user_id,status) values('${users[6]}','suspended');`);
});
test.afterAll(async () => {
  for (const slug of slugs) sql(`delete from public.platform_tenant_creation_requests where tenant_id in(select id from public.tenants where slug='${slug}'); delete from public.platform_audit_logs where tenant_id in(select id from public.tenants where slug='${slug}'); delete from public.audit_logs where tenant_id in(select id from public.tenants where slug='${slug}'); delete from public.tenant_memberships where tenant_id in(select id from public.tenants where slug='${slug}'); delete from public.tenant_public_profiles where tenant_id in(select id from public.tenants where slug='${slug}'); delete from public.tenant_plan_assignments where tenant_id in(select id from public.tenants where slug='${slug}'); delete from public.tenants where slug='${slug}';`);
  for (const id of users) { sql(`delete from public.platform_audit_logs where actor_user_id='${id}'; delete from public.platform_admins where user_id='${id}';`); const deleted=await service.auth.admin.deleteUser(id); expect(deleted.error).toBeNull(); }
  expect(sql(`select count(*) from auth.users where email like '%${run}@example.invalid'`)).toBe("0");
});

test("wizard commits once, recovers a lost response after reload, and reads fresh detail", async ({ page }) => {
  await login(page); await page.goto("/platform-admin"); await page.getByRole("link", { name: "Dodaj nową strzelnicę" }).click();
  const slug=`w-${randomUUID()}`; slugs.push(slug); await fillWizard(page,slug);
  const seen: string[]=[]; page.on("request",r=> { if(r.url().includes('/rest/v1/')) seen.push(r.url()); });
  let sent: ReturnType<typeof payload> | undefined;
  await page.route("**/rest/v1/rpc/platform_create_tenant_bundle_v2", async route => {
    sent=route.request().postDataJSON(); const committed=await route.fetch(); expect(committed.ok()).toBe(true); await route.abort("failed");
  }, { times: 1 });
  await page.getByRole("button", { name: "Utwórz strzelnicę", exact: true }).evaluate(element => { (element as HTMLButtonElement).click(); (element as HTMLButtonElement).click(); }); await expect(page.locator("[role=alert][tabindex]")).toContainText("potwierdzić");
  expect(sent).toBeDefined(); const id=sql(`select tenant_id from public.platform_tenant_creation_requests where creation_request_id='${sent!.p_creation_request_id}'`);
  await page.reload(); await expect(page.getByRole("button", { name: "Sprawdź / ponów utworzenie" })).toBeVisible();
  await page.getByRole("button", { name: "Wstecz", exact: true }).click(); await page.getByRole("button", { name: "Dalej", exact: true }).click();
  let replay: unknown; await page.route("**/rest/v1/rpc/platform_create_tenant_bundle_v2", route=> { replay=route.request().postDataJSON(); return route.continue(); },{times:1});
  await page.getByRole("button", { name: "Sprawdź / ponów utworzenie" }).click(); await expect(page).toHaveURL(new RegExp(`/platform-admin/tenants/${id}\\?created=1$`)); expect(replay).toEqual(sent);
  expect(sql(`select count(*) from public.platform_tenant_creation_requests where tenant_id='${id}'`)).toBe("1"); expect(sql(`select count(*) from public.platform_audit_logs where tenant_id='${id}'`)).toBe("3"); expect(sql(`select count(*) from public.tenants where slug='${slug}'`)).toBe("1");
  await expect(page.getByText("Status: dormant · Niepubliczny")).toBeVisible(); await expect(page.getByText(emails[1],{exact:false})).toBeVisible();
  expect(sql(`select (select count(*) from public.shooting_lanes where tenant_id='${id}')+(select count(*) from public.tenant_domains where tenant_id='${id}')`)).toBe("0");
  await expect(page.getByText("Aktywacja: Wymaga konfiguracji")).toBeVisible(); await page.reload(); await expect(page.getByText("Status: dormant · Niepubliczny")).toBeVisible();
  await page.getByRole("button",{name:"Odśwież stan"}).click(); await expect(page.getByText("Status: dormant · Niepubliczny")).toBeVisible();
  expect(await page.evaluate(()=>Object.keys(sessionStorage).some(k=>k.startsWith('strzelajtu:onboard:')))).toBe(false);
  for(const width of [320,375,768,1440]) { await page.setViewportSize({width,height:900}); expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true); }
  await page.screenshot({path:'../onboard-1b-wizard/detail-1440.png',fullPage:true});
  expect(seen.every(url=>url.includes('/rpc/'))).toBe(true); expect(seen.some(url=>url.endsWith('/platform_create_tenant_v1'))).toBe(false);
  expect(seen.filter(url=>url.endsWith('/platform_create_tenant_bundle_v2'))).toHaveLength(2);
  const detail=await clients[0].rpc('platform_get_tenant_onboarding_detail_v1',{p_tenant_id:id}); expect(detail.error).toBeNull(); expect(Object.keys(detail.data.admins[0]).sort()).toEqual(['email','user_id']);
  const conflict=await clients[0].rpc('platform_create_tenant_bundle_v2',{...sent,p_plan_key:'current_full_v1'}); expect(conflict.error?.message).toContain('payload conflict');
  const status=await page.request.get(`/pub-${slug}`); expect(status.status()).toBe(404);
  expect((await page.goto(`/tenant-setup/${slug}`))?.status()).toBe(404);
});

test("namespace, catalog and eligibility failures are atomic and safely editable", async ({page}) => {
  await login(page); const slug=`w-${randomUUID()}`; slugs.push(slug); await fillWizard(page,slug);
  sql("update public.saas_plans set status='inactive' where plan_key='booking_only_v1'");
  try { await page.getByRole('button',{name:'Utwórz strzelnicę',exact:true}).click(); await expect(page.locator("[role=alert][tabindex]")).toContainText('plan nie jest już dostępny'); await expect(page.getByRole('heading',{name:'Plan',exact:true})).toBeVisible(); await expect(page.getByRole('radio',{name:/booking_only_v1/})).toHaveCount(0); }
  finally { sql("update public.saas_plans set status='active' where plan_key='booking_only_v1'"); }
  expect(sql(`select count(*) from public.tenants where slug='${slug}'`)).toBe('0');
  await page.getByRole('button',{name:'Rozpocznij nowe tworzenie'}).click(); await page.getByRole('radio',{name:/booking_only_v1/}).check(); await page.getByRole('button',{name:'Dalej',exact:true}).click();
  for(const state of ["email_confirmed_at=null", "banned_until=now()+interval '1 day'", "deleted_at=now()"]){
    sql(`update auth.users set ${state} where id='${users[1]}'`);
    await page.getByLabel('E-mail administratora').fill(emails[1]); await page.getByRole('button',{name:'Sprawdź konto',exact:true}).click(); await expect(page.getByText('Wybrane konto:',{exact:false})).toHaveCount(0);
    sql(`update auth.users set email_confirmed_at=now(),banned_until=null,deleted_at=null where id='${users[1]}'`);
  }
  await page.getByLabel('E-mail administratora').fill(`unknown-${run}@example.invalid`); await page.getByRole('button',{name:'Sprawdź konto',exact:true}).click(); await expect(page.getByText('Wybrane konto:',{exact:false})).toHaveCount(0);
  await page.getByLabel('E-mail administratora').fill(emails[1]); await page.getByRole('button',{name:'Sprawdź konto',exact:true}).click(); await expect(page.getByText('Potwierdzone konto może zostać administratorem.')).toBeVisible();
  await page.getByRole('button',{name:'Dalej',exact:true}).click(); await page.getByRole('button',{name:'Dalej',exact:true}).click();
  sql(`update auth.users set banned_until=now()+interval '1 day' where id='${users[1]}'`);
  try { await page.getByRole('button',{name:'Utwórz strzelnicę',exact:true}).click(); await expect(page.locator("[role=alert][tabindex]")).toContainText('konto nie może'); await expect(page.getByRole('heading',{name:'Administrator',exact:true})).toBeVisible(); await expect(page.getByText('Wybrane konto:',{exact:false})).toHaveCount(0); }
  finally { sql(`update auth.users set banned_until=null where id='${users[1]}'`); }
  await page.getByRole('button',{name:'Rozpocznij nowe tworzenie'}).click(); await page.getByRole('button',{name:'Sprawdź konto',exact:true}).click(); await expect(page.getByText('Potwierdzone konto może zostać administratorem.')).toBeVisible(); await page.getByRole('button',{name:'Dalej',exact:true}).click(); await page.getByRole('button',{name:'Dalej',exact:true}).click(); await page.getByRole('button',{name:'Utwórz strzelnicę',exact:true}).click(); await expect(page).toHaveURL(/\/tenants\/[0-9a-f-]{36}\?created=1$/);
  for(const overrides of [{p_tenant_slug:slug},{p_public_slug:`pub-${slug}`},{p_public_slug:slug},{p_tenant_slug:`pub-${slug}`},{p_tenant_slug:'admin'},{p_tenant_slug:'bad--slug'}]){
    const fresh=`f-${randomUUID()}`; const result=await clients[0].rpc('platform_create_tenant_bundle_v2',payload(fresh,overrides)); expect(result.error).not.toBeNull(); expect(sql(`select count(*) from public.tenants where slug='${fresh}'`)).toBe('0');
  }
  await page.goto('/platform-admin/tenants/new'); await page.getByLabel('Nazwa obiektu',{exact:true}).fill('Test'); await page.getByLabel('Miejscowość',{exact:true}).fill('Testowo'); await page.getByRole('button',{name:'Dalej',exact:true}).click();
  for(const value of ['admin','bad--slug']){ await page.getByLabel('Adres techniczny').fill(value); await page.getByLabel('Adres publiczny').fill('valid-public'); await page.getByRole('button',{name:'Dalej',exact:true}).click(); await expect(page.locator("[role=alert][tabindex]")).toBeVisible(); await expect(page.getByRole('heading',{name:'Adresy',exact:true})).toBeVisible(); }
});

test("anonymous, user, tenant roles and suspended PA cannot enter wizard or detail", async ({browser,baseURL}) => {
  const id=sql(`select id from public.tenants where slug='${slugs[0]}'`);
  sql(`insert into public.tenant_memberships(tenant_id,user_id,role,status) values('${id}','${users[4]}','employee','active'),('${id}','${users[5]}','instructor','active');`);
  for(const index of [-1,1,2,4,5,6]){
    const context=await browser.newContext({baseURL}); try{ const page=await context.newPage(); if(index>=0) await login(page,index);
      for(const path of ['/platform-admin/tenants/new',`/platform-admin/tenants/${id}`]){ const response=await page.goto(path); if(index<0) await expect(page).toHaveURL(/\/login/); else expect(response?.status()).toBe(404); }
      if(index>=0) for(const name of ['platform_list_active_plans_v1','platform_get_tenant_onboarding_detail_v1']){ const r=await clients[index].rpc(name,name.includes('detail')?{p_tenant_id:id}:{}); expect(r.error).not.toBeNull(); }
    }finally{await context.close();}
  }
});

test("dormant business remains off, empty setup works, and detail follows canonical multi-admin changes", async ({ page, browser, baseURL }) => {
  const slug=slugs[0], id=sql(`select id from public.tenants where slug='${slug}'`);
  for(const feature of ['booking','events','staff','instructors','checkin','reports']) { const result=await clients[1].rpc('get_my_tenant_feature_access_v1',{p_tenant_id:id,p_feature_key:feature}); expect(result.error).toBeNull(); expect(result.data).toBe(false); }
  const self=await clients[2].rpc('self_onboard_tenant_v1',{p_tenant_slug:slug}); expect(self.error).not.toBeNull();
  const publicBooking=await clients[2].rpc('get_public_booking_configuration_v2',{p_tenant_id:id}); expect(publicBooking.error).not.toBeNull();
  const context=await browser.newContext({baseURL}); try {
    const owner=await context.newPage(); await login(owner,1); await owner.goto(`/tenant-setup/${slug}`); await expect(owner.getByRole('heading',{name:'Ustawienia publiczne'})).toBeVisible();
    await owner.goto(`/tenant-setup/${slug}?tab=lanes`); expect(sql(`select count(*) from public.shooting_lanes where tenant_id='${id}'`)).toBe('0');
  }finally{await context.close();}
  expect((await clients[0].rpc('platform_set_tenant_plan_v1',{p_tenant_id:id,p_plan_key:'current_full_v1'})).error).toBeNull();
  expect((await clients[0].rpc('platform_set_tenant_state_v1',{p_tenant_id:id,p_action:'activate'})).error).toBeNull();
  // The target is a synthetic member fixture; promotion uses the canonical tenant-admin RPC.
  sql(`insert into public.tenant_memberships(tenant_id,user_id,role,status) values('${id}','${users[3]}','user','active');`);
  const promoted=await clients[1].rpc('admin_set_user_role_v2',{p_tenant_id:id,p_target_user_id:users[3],p_new_role:'admin'}); expect(promoted.error).toBeNull(); expect(promoted.data.ok).toBe(true);
  await login(page); await page.goto(`/platform-admin/tenants/${id}`); await expect(page.getByText(emails[1],{exact:false})).toBeVisible(); await expect(page.getByText(emails[3],{exact:false})).toBeVisible(); await expect(page.getByText('Status: active · Niepubliczny')).toBeVisible();
  await page.reload(); await expect(page.getByText(emails[3],{exact:false})).toBeVisible();
  const demoted=await clients[1].rpc('admin_set_user_role_v2',{p_tenant_id:id,p_target_user_id:users[3],p_new_role:'user'}); expect(demoted.error).toBeNull(); expect(demoted.data.ok).toBe(true);
  await page.getByRole('button',{name:'Odśwież stan'}).click(); await expect(page.getByText(emails[3],{exact:false})).toHaveCount(0);
});

test("changed recovered payload is denied in the UI and requires an explicit new attempt", async ({page}) => {
  await login(page); const slug=`w-${randomUUID()}`; slugs.push(slug); await fillWizard(page,slug);
  await page.route('**/rest/v1/rpc/platform_create_tenant_bundle_v2',async route=>{const committed=await route.fetch(); expect(committed.ok()).toBe(true); await route.abort('failed');},{times:1});
  await page.getByRole('button',{name:'Utwórz strzelnicę',exact:true}).click(); await expect(page.locator('[role=alert][tabindex]')).toContainText('potwierdzić');
  await page.evaluate(()=>{const key=Object.keys(sessionStorage).find(k=>k.startsWith('strzelajtu:onboard:'))!;const value=JSON.parse(sessionStorage.getItem(key)!);value.payload.p_plan_key='current_full_v1';sessionStorage.setItem(key,JSON.stringify(value));});
  await page.reload(); await page.getByRole('button',{name:'Sprawdź / ponów utworzenie'}).click(); await expect(page.locator('[role=alert][tabindex]')).toContainText('innymi danymi');
  await expect(page.getByRole('button',{name:'Sprawdź / ponów utworzenie'})).toBeDisabled(); expect(sql(`select count(*) from public.tenants where slug='${slug}'`)).toBe('1'); expect(sql(`select count(*) from public.platform_tenant_creation_requests where tenant_id=(select id from public.tenants where slug='${slug}')`)).toBe('1');
  await page.getByRole('button',{name:'Rozpocznij nowe tworzenie'}).click(); await expect(page.getByLabel('Nazwa obiektu',{exact:true})).toBeEnabled();
});

test("a committed receipt survives unavailable detail; reopening never resubmits the bundle", async ({page}) => {
  await login(page); const slug=`w-${randomUUID()}`; slugs.push(slug); await fillWizard(page,slug); let sends=0;
  page.on('request',r=>{if(r.url().endsWith('/rpc/platform_create_tenant_bundle_v2')) sends++;});
  await page.route('**/rest/v1/rpc/platform_get_tenant_onboarding_detail_v1',route=>route.fulfill({status:503,contentType:'application/json',body:JSON.stringify({message:'Synthetic local failure'})}),{times:1});
  await page.getByRole('button',{name:'Utwórz strzelnicę',exact:true}).click(); await expect(page.locator('[role=alert][tabindex]')).toContainText('Utworzenie potwierdzone');
  await page.reload(); await page.getByRole('button',{name:'Otwórz utworzony obiekt'}).click(); await expect(page).toHaveURL(/\/tenants\/[0-9a-f-]{36}\?created=1$/); expect(sends).toBe(1);
});

test("namespace collisions are safely shown by the wizard without a partial tenant", async ({page}) => {
  await login(page); await fillWizard(page,slugs[0]); await page.getByRole('button',{name:'Utwórz strzelnicę',exact:true}).click(); await expect(page.locator('[role=alert][tabindex]')).toContainText('adres jest już zajęty');
  expect(sql(`select count(*) from public.tenants where slug='${slugs[0]}'`)).toBe('1'); await page.getByRole('button',{name:'Rozpocznij nowe tworzenie'}).click(); await expect(page.getByLabel('Adres techniczny')).toBeEnabled();
});
