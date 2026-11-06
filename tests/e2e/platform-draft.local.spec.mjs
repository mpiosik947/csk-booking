import {test,expect} from '@playwright/test';import {createServerClient} from '@supabase/ssr';import fs from 'node:fs';import {randomUUID} from 'node:crypto';import {execFileSync} from 'node:child_process';import assert from 'node:assert/strict';
const fixture=JSON.parse(fs.readFileSync(process.env.PUBLIC_TEST_MODE_FIXTURE_FILE,'utf8'));
for(const u of [fixture.app,fixture.origin])assert.equal(new URL(u).hostname,'127.0.0.1');assert.match(fixture.scratchDatabase,/^sbr3_[a-f0-9]{16}$/);
const sql=q=>execFileSync('docker',['exec','supabase_db_csk-booking','psql','-X','-At','-v','ON_ERROR_STOP=1','-U','postgres','-d',fixture.scratchDatabase,'-c',q],{encoding:'utf8'}).trim();
async function auth(context,email){const cookies=[];const client=createServerClient(fixture.origin,fixture.anonKey,{cookieOptions:{secure:true},cookies:{getAll:()=>[],setAll:c=>cookies.push(...c)}});const {data,error}=await client.auth.signInWithPassword({email,password:fixture.password});expect(error).toBeNull();await context.addCookies(cookies.map(({name,value})=>({name,value,domain:'127.0.0.1',path:'/',secure:true,sameSite:'Lax'})));return data.session.access_token;}
async function rpc(name,args,token=fixture.anonKey){const r=await fetch(fixture.origin+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:fixture.anonKey,authorization:'Bearer '+token,'content-type':'application/json'},body:JSON.stringify(args)});return {status:r.status,body:await r.json()};}
test.beforeEach(async({context})=>{await context.route('**/*',r=>new URL(r.request().url()).hostname==='127.0.0.1'?r.continue():r.abort());});
test('PA draft: double submit, lost response, zero memberships, private routes, reopen and archive/restore',async({page,context,browser})=>{
 await page.goto('/login?redirectTo=%2Fplatform-admin');await page.getByLabel('E-mail',{exact:true}).fill('ptm2-6@example.invalid');await page.getByLabel('Hasło',{exact:true}).fill(fixture.password);await page.getByRole('button',{name:'Zaloguj się',exact:true}).click();await expect(page).toHaveURL(/\/platform-admin$/);
 await page.getByRole('link',{name:'Dodaj nowy obiekt'}).click();const slug='draft-ui-'+randomUUID().slice(0,8);let id;
 try{
 await page.getByLabel('Nazwa obiektu',{exact:true}).fill('Tenant C local');await page.getByLabel('Miejscowość',{exact:true}).fill('Testowo');
 await page.getByLabel('Adres panelu obiektu').fill(slug);await page.getByLabel('Adres strony obiektu').fill(slug+'-public');
 await expect(page.getByText('Utworzysz niepubliczny szkic',{exact:false})).toBeVisible();await expect(page.getByLabel('E-mail administratora')).toHaveCount(0);
 for(const width of [320,375,768,1440]){await page.setViewportSize({width,height:900});expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);}
 let sent;
 await page.route('**/rest/v1/rpc/platform_create_tenant_draft_v1',async route=>{sent=route.request().postDataJSON();const r=await route.fetch();expect(r.ok()).toBe(true);await route.abort('failed');},{times:1});
 await page.getByRole('button',{name:'Utwórz szkic i kontynuuj',exact:true}).evaluate(el=>{el.click();el.click();});await expect(page.getByRole('alert').filter({hasText:'potwierdzić'})).toContainText('potwierdzić');expect(sent.p_plan_key).toBeNull();expect(sent).not.toHaveProperty('p_initial_admin_user_id');
 id=sql(`select id from public.tenants where slug='${slug}'`);expect(id).toMatch(/^[0-9a-f-]{36}$/);
 await page.reload();await page.getByRole('button',{name:'Sprawdź / ponów utworzenie'}).click();await expect(page).toHaveURL(new RegExp('/'+id+'/setup'));
 await expect(page.getByText('Administratorzy lokalni: 0.',{exact:false})).toBeVisible();
 expect(sql(`select count(*) from public.tenant_memberships where tenant_id='${id}'`)).toBe('0');expect(sql(`select count(*) from public.platform_audit_logs where tenant_id='${id}' and action='tenant_created'`)).toBe('1');
 const anonymous=await browser.newContext({ignoreHTTPSErrors:true});try{const p=await anonymous.newPage();for(const path of ['/'+slug+'-public','/t/'+slug+'/booking','/t/'+slug+'/events'])expect((await p.goto(fixture.app+path)).status()).toBe(404);await p.goto(fixture.app+'/');await expect(p.getByText('Tenant C local',{exact:true})).toHaveCount(0);}finally{await anonymous.close();}
 for(const name of ['get_public_booking_configuration_v2','get_public_event_list_v3'])expect((await rpc(name,{p_tenant_id:id})).status).toBe(423);
 expect(await rpc('get_public_tenant_partners_v1',{p_public_slug:slug+'-public'})).toEqual({status:200,body:[]});
 await page.getByRole('link',{name:'Zarządzaj obiektem'}).click();await expect(page.getByRole('button',{name:'Archiwizuj obiekt',exact:true})).toBeEnabled();await expect(page.getByRole('button',{name:'Znajdź konto'})).toHaveCount(0);await expect(page.getByRole('button',{name:'Ustaw: Aktywna'})).toHaveCount(0);
 await page.getByRole('button',{name:'Archiwizuj obiekt',exact:true}).click();await page.getByRole('dialog').getByRole('button',{name:'Potwierdź operację'}).click();await expect(page.getByRole('button',{name:'Przywróć obiekt do konfiguracji'})).toBeVisible();
 await page.getByRole('button',{name:'Przywróć obiekt do konfiguracji'}).click();await page.getByRole('dialog').getByRole('button',{name:'Potwierdź operację'}).click();await expect(page.getByRole('button',{name:'Archiwizuj obiekt',exact:true})).toBeVisible();
 await page.goto('/platform-admin');await page.getByRole('link',{name:'Kontynuuj konfigurację',exact:true}).click();await expect(page).toHaveURL(new RegExp('/'+id+'/setup'));await page.getByRole('navigation',{name:'Sekcje konfiguracji'}).getByRole('button').nth(0).click();await expect(page.getByLabel('Nazwa obiektu')).toHaveValue('Tenant C local');
 expect(sql(`select t.status||'|'||p.is_public||'|'||c.public_access_state from public.tenants t join public.tenant_public_profiles p on p.tenant_id=t.id join public.tenant_public_access_controls c on c.tenant_id=t.id where t.id='${id}'`)).toBe('dormant|false|coming_soon');
 await context.clearCookies();await page.reload();await expect(page).toHaveURL(/\/login/);
 }finally{if(!id)id=sql(`select id from public.tenants where slug='${slug}'`);if(id){assert.match(id,/^[0-9a-f-]{36}$/);sql(`begin;delete from public.platform_tenant_lifecycle_requests where tenant_id='${id}';delete from app_private.tenant_public_access_changes where tenant_id='${id}';delete from public.tenant_public_access_controls where tenant_id='${id}';delete from public.platform_audit_logs where tenant_id='${id}';delete from public.platform_tenant_creation_requests where tenant_id='${id}';delete from public.tenant_public_profiles where tenant_id='${id}';delete from public.tenants where id='${id}';commit;`);}expect(sql(`select count(*) from public.tenants where slug='${slug}'`)).toBe('0');}
});

test('directory uses actual CSK and isolated A/B data, searchable addresses and keyboard actions at four widths',async({page,context},info)=>{
 await auth(context,'ptm2-6@example.invalid');await page.goto('/platform-admin');
 await expect(page.getByRole('heading',{name:'Obiekty',exact:true})).toBeVisible();
 await expect(page.getByRole('link',{name:'Dodaj nowy obiekt',exact:true})).toHaveAttribute('href','/platform-admin/tenants/new');
 const search=page.getByRole('searchbox',{name:'Szukaj obiektu'});
 await search.fill('CSK-KRUTLA');await expect(page.getByRole('article')).toHaveCount(1);
 await expect(page.getByRole('article')).toContainText('Pakiet całość');
 await search.fill('ptm1-public-a');
 const a=page.getByRole('article');await expect(a).toHaveCount(1);await expect(a).toContainText('Dostępna wkrótce');await expect(a).toContainText('ptm2-0@example.invalid');
 await search.fill('ptm2-public-b');
 const b=page.getByRole('article');await expect(b).toHaveCount(1);await expect(b).toContainText('ptm2-5@example.invalid');
 await expect(b.locator('dt').filter({hasText:'Status strony'}).locator('..')).toContainText('Dostępna');
 for(const width of [320,375,768,1440]){
   await page.setViewportSize({width,height:900});
   const menu=b.locator('summary');
   await menu.focus();await page.keyboard.press('Enter');const link=b.getByRole('link',{name:'Zmień pakiet'});
   await expect(link).toHaveAttribute('href',/\#pakiet$/);await link.focus();await page.keyboard.press('Escape');
   await expect(menu).toBeFocused();await expect(link).toBeHidden();
   expect(await b.evaluate(el=>el.scrollWidth<=el.clientWidth && document.documentElement.scrollWidth<=innerWidth)).toBe(true);
   await page.screenshot({path:info.outputPath('directory-'+width+'.png'),fullPage:true});
 }
 await page.getByLabel('Stan obiektu').selectOption('archived');await expect(b).toHaveCount(0);
 await page.getByRole('button',{name:'Wyczyść wyszukiwanie i filtr'}).click();await expect(page.getByRole('article').first()).toBeVisible();
});

test('directory filters all pages, handles empty/error states and removes cards and CTA after PA denial',async({page,context})=>{
 await auth(context,'ptm2-6@example.invalid');
 const rows=Array.from({length:26},(_,i)=>({id:'12345678-1234-4123-8123-'+String(i).padStart(12,'0'),
   name:i===25?'BardzoDługaNazwa'.repeat(8):'Obiekt '+i,tenant_slug:'obj-'+i,public_slug:'public-'+i,city:'Testowo',
   status:i===25?'suspended':'active',is_public:false,is_platform_draft:false,plan_key:'booking_only_v1',created_at:'2026-01-'+String(i+1).padStart(2,'0')+'T12:00:00Z'}));
 let mode='list';
 await page.route('**/rpc/platform_list_tenants_v1',route=>{
   const n=route.request().postDataJSON().p_page,items=mode==='empty'?[]:rows.slice((n-1)*25,n*25);
   const status=mode==='denied'?403:mode==='failure'?500:200;
   return route.fulfill({status,json:status===200?{page:n,page_size:25,total:mode==='empty'?0:rows.length,items}:{code:status===403?'42501':'error'}});
 });
 await page.route('**/rpc/platform_get_tenant_onboarding_detail_v1',route=>{
   const t=rows.find(row=>row.id===route.request().postDataJSON().p_tenant_id);
   return route.fulfill({json:{tenant:{tenant_id:t.id,name:'Wewnętrzna '+t.tenant_slug,technical_slug:t.tenant_slug,status:t.status},
     public_profile:{display_name:t.name,city:t.city,public_slug:t.public_slug,is_public:false},
     plan:{plan_key:t.plan_key,status:'active',assignment_status:'active',enabled_feature_keys:['booking']},
     admins:[],readiness:{create_ready:false,activation_ready:false,public_ready:false,booking_ready:false,booking_required:true,publication_gate_enforced:false,checks:{}}}});
 });
 await page.route('**/rpc/platform_get_tenant_public_access_v1',r=>r.fulfill({json:{state:'live',revision:null}}));
 await page.goto('/platform-admin');await expect(page.getByText('Strona 1 z 2')).toBeVisible();
 await page.getByRole('button',{name:'Następna'}).click();await expect(page.getByRole('article')).toHaveCount(1);
 await page.getByRole('searchbox').fill('Wewnętrzna obj-25');await expect(page.getByRole('article')).toHaveCount(1);
 await page.getByLabel('Stan obiektu').selectOption('suspended');
 const card=page.getByRole('article');await expect(card).toContainText('Pakiet minimum');await expect(card).toContainText('Brak aktywnego administratora');
 for(const width of [320,375,768,1440]){await page.setViewportSize({width,height:900});expect(await card.evaluate(el=>el.scrollWidth<=el.clientWidth && document.documentElement.scrollWidth<=innerWidth)).toBe(true);}
 mode='failure';await page.getByRole('button',{name:'Odśwież listę'}).click();await expect(page.getByRole('main').getByRole('alert')).toContainText('Nie można odczytać');
 await expect(page.getByText('Nie masz jeszcze żadnego obiektu.')).toHaveCount(0);
 mode='empty';await page.getByRole('button',{name:'Odśwież listę'}).click();await expect(page.getByText('Nie masz jeszcze żadnego obiektu.')).toBeVisible();
 await expect(page.getByRole('link',{name:'Dodaj pierwszy obiekt'})).toHaveAttribute('href','/platform-admin/tenants/new');
 mode='denied';await page.getByRole('button',{name:'Odśwież listę'}).click();await expect(page.getByRole('heading',{name:'Brak dostępu'})).toBeVisible();
 await expect(page.getByRole('article')).toHaveCount(0);await expect(page.locator('a[href="/platform-admin/tenants/new"]')).toHaveCount(0);
});

test("browser Back can retain or discard an uncreated draft without a write", async ({ page, context }) => {
  await auth(context,"ptm2-6@example.invalid");
  const creates=[];
  page.on("request", r=>{if(r.url().endsWith("/rpc/platform_create_tenant_draft_v1"))creates.push(r.url());});
  await page.goto("/platform-admin");
  await page.getByRole("link",{name:"Dodaj nowy obiekt"}).click();
  await page.getByLabel("Nazwa obiektu",{exact:true}).fill("Niezapisany test");
  const first=page.waitForEvent("dialog");
  await page.evaluate(()=>{setTimeout(()=>history.back(),0);});
  await (await first).dismiss();
  await expect(page.getByLabel("Nazwa obiektu",{exact:true})).toHaveValue("Niezapisany test");
  const second=page.waitForEvent("dialog");
  await page.evaluate(()=>{setTimeout(()=>history.back(),0);});
  await (await second).accept();
  await expect(page).toHaveURL(/\/platform-admin$/);
  expect(creates).toEqual([]);
});
for(const [role,email] of [['Tenant Admin','ptm2-0@example.invalid'],['employee','ptm2-1@example.invalid'],['instructor','ptm2-2@example.invalid'],['customer','ptm1-customer@example.invalid'],['anonymous',null]])test(role+' cannot create via route, RPC or forged fields',async({context,page})=>{
 const token=email?await auth(context,email):fixture.anonKey;const r=await page.goto('/platform-admin/tenants/new');if(email)expect(r.status()).toBe(404);else await expect(page).toHaveURL(/\/login/);
 const payload={p_name:'Forbidden',p_tenant_slug:'forbidden-'+randomUUID().slice(0,8),p_public_slug:'forbidden-pub-'+randomUUID().slice(0,8),p_city:'City',p_plan_key:null,p_creation_request_id:randomUUID()};
 expect([401,403]).toContain((await rpc('platform_create_tenant_draft_v1',payload,token)).status);expect((await rpc('platform_create_tenant_draft_v1',{...payload,platform_admin:true,actor_user_id:fixture.users.find(u=>u.email==='ptm2-6@example.invalid').id},token)).status).toBeGreaterThanOrEqual(400);
});
