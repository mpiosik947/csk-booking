import {test,expect} from '@playwright/test';import {createServerClient} from '@supabase/ssr';import fs from 'node:fs';import {randomUUID} from 'node:crypto';import {execFileSync} from 'node:child_process';import assert from 'node:assert/strict';
const fixture=JSON.parse(fs.readFileSync(process.env.PUBLIC_TEST_MODE_FIXTURE_FILE,'utf8'));
for(const u of [fixture.app,fixture.origin])assert.equal(new URL(u).hostname,'127.0.0.1');assert.match(fixture.scratchDatabase,/^sbr3_[a-f0-9]{16}$/);
async function expectFieldGuides(page) {
 const controls = page.locator('input:visible, select:visible, textarea:visible');
 const problems = await controls.evaluateAll(elements => elements.flatMap(control => {
   const label = (control.getAttribute('aria-label') || Array.from(control.labels || []).map(l => l.textContent).join(' ')).trim();
   const ids = (control.getAttribute('aria-describedby') || '').trim().split(/\s+/);
   const descriptions = ids.map(id => document.getElementById(id)?.textContent || '');
   const outside = [...(control.labels || []), control].some(el => {
     const rect = el.getBoundingClientRect();
     return rect.width > 0 && (rect.left < -1 || rect.right > innerWidth + 1);
   });
   return !label || outside || descriptions.some(text => !text.trim()) ? [label || control.tagName] : [];
 }));
 expect(problems).toEqual([]);
 expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
}
const sql=q=>execFileSync('docker',['exec','supabase_db_csk-booking','psql','-X','-At','-v','ON_ERROR_STOP=1','-U','postgres','-d',fixture.scratchDatabase,'-c',q],{encoding:'utf8'}).trim();
async function auth(context,email){const cookies=[];const client=createServerClient(fixture.origin,fixture.anonKey,{cookieOptions:{secure:true},cookies:{getAll:()=>[],setAll:c=>cookies.push(...c)}});const {data,error}=await client.auth.signInWithPassword({email,password:fixture.password});expect(error).toBeNull();await context.addCookies(cookies.map(({name,value})=>({name,value,domain:'127.0.0.1',path:'/',secure:true,sameSite:'Lax'})));return data.session.access_token;}
async function rpc(name,args,token=fixture.anonKey){const r=await fetch(fixture.origin+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:fixture.anonKey,authorization:'Bearer '+token,'content-type':'application/json'},body:JSON.stringify(args)});return {status:r.status,body:await r.json()};}
test.beforeEach(async({context})=>{await context.route('**/*',r=>new URL(r.request().url()).hostname==='127.0.0.1'?r.continue():r.abort());});
test('PA configures Tenant C without membership: sections, lanes, retries, conflicts, preview, mobile and archive/restore',async({page,context,browser},info)=>{
 const token=await auth(context,'ptm2-6@example.invalid'),slug='config-ui-'+randomUUID().slice(0,8);let id;
 // Protect the canonical CSK and both existing synthetic tenants while provisioning C.
 const existingState = () => sql(`select count(*) || '|' || md5(jsonb_agg(jsonb_build_array(to_jsonb(t),to_jsonb(p),to_jsonb(a),to_jsonb(c)) order by t.id)::text)
   from public.tenants t join public.tenant_public_profiles p on p.tenant_id=t.id
   join public.tenant_plan_assignments a on a.tenant_id=t.id left join public.tenant_public_access_controls c on c.tenant_id=t.id
   where t.slug in ('csk','ptm1-synthetic-a','ptm2-b')`);
 const baseline=existingState();expect(baseline).toMatch(/^3\|[a-f0-9]{32}$/);
 const safe=()=>{expect(sql(`select t.status||'|'||p.is_public||'|'||c.public_access_state||'|'||(select count(*) from public.tenant_memberships where tenant_id=t.id) from public.tenants t join public.tenant_public_profiles p on p.tenant_id=t.id join public.tenant_public_access_controls c on c.tenant_id=t.id where t.id='${id}'`)).toBe('dormant|false|coming_soon|0');};
 const section=async n=>{
   const nav=page.getByRole('navigation',{name:'Sekcje konfiguracji'});
   const select=nav.getByRole('combobox',{name:'Przejdź do kroku'});
   if(await select.isVisible())await select.selectOption(String(n));else await nav.getByRole('button').nth(n).click();
 };
 const save=async()=>{await page.getByRole('button',{name:'Zapisz zmiany',exact:true}).click();await expect(page.locator('footer[aria-label="Działania kroku"]').getByRole('status')).toContainText('Zapisano');safe();};
 try{
  await page.goto('/platform-admin/tenants/new');
  await expect(page.getByLabel('Nazwa obiektu',{exact:true})).toBeVisible();
  for(const width of [320,375,768,1440]){
    await page.setViewportSize({width,height:950});await expectFieldGuides(page);
  }
  await page.getByLabel('Nazwa obiektu',{exact:true}).fill('Tenant C config');await page.getByLabel('Miejscowość',{exact:true}).fill('Testowo');
  await page.getByLabel('Adres panelu obiektu').fill(slug);await page.getByLabel('Adres strony obiektu').fill(slug+'-public');
  await page.getByRole('button',{name:'Utwórz szkic i kontynuuj'}).click();await expect(page).toHaveURL(/\/setup(?:\?|$)/);
  id=page.url().split('/').at(-2);assert.match(id,/^[a-f0-9-]{36}$/);await expect(page.getByLabel('Nazwa obiektu')).toHaveValue('Tenant C config');safe();
  await page.getByLabel('Nazwa obiektu').fill('');await expect(page.locator('footer[aria-label="Działania kroku"]').getByRole('status')).toHaveText('Masz niezapisane zmiany');
  await page.getByRole('button',{name:'Zapisz zmiany',exact:true}).click();
  await expect(page.getByLabel('Nazwa obiektu')).toHaveAccessibleDescription(/Wymagane.*Podaj nazwę obiektu/);
  await expect(page.getByLabel('Nazwa obiektu')).toHaveAttribute('aria-invalid','true');
  await expect(page.getByLabel('Nazwa obiektu')).toBeFocused();
  await page.getByLabel('Nazwa obiektu').fill('Partial acknowledgement');
  await page.getByLabel('Adres strzelnicy',{exact:true}).fill('Still unsaved');
  let frozen;
  await page.route('**/rest/v1/rpc/platform_save_draft_configuration_v1',async r=>{
    frozen=r.request().postDataJSON();expect(frozen.p_section).toBe('identity');await r.fetch();await r.abort('failed');
  }, {times:1});
  await page.getByRole('button',{name:'Zapisz i przejdź dalej'}).click();
  await expect(page.getByRole('button',{name:'Sprawdź / ponów zapis'})).toBeEnabled();
  await page.route('**/rest/v1/rpc/platform_save_draft_configuration_v1',async r=>{expect(r.request().postDataJSON()).toEqual(frozen);await r.continue();},{times:1});
  await page.getByRole('button',{name:'Sprawdź / ponów zapis'}).click();
  await expect(page.locator('footer [role=status]')).toHaveText('Masz niezapisane zmiany');
  await expect(page.getByLabel('Adres strzelnicy',{exact:true})).toHaveValue('Still unsaved');
  await page.getByLabel('Nazwa obiektu').fill('Tenant C configured');await page.getByLabel('Nazwa wyświetlana').fill('Public C');
  await page.getByLabel('Adres strzelnicy',{exact:true}).fill('Synthetic venue');
  await page.getByLabel('Telefon kontaktowy').fill('000000000');await page.getByLabel('E-mail kontaktowy').fill('venue@example.invalid');
  const changes=[];const track=req=>{if(req.url().endsWith('/rpc/platform_save_draft_configuration_v1'))changes.push(req.postDataJSON());};
  page.on('request',track);await page.getByRole('button',{name:'Zapisz i przejdź dalej'}).click();
  await expect(page.getByRole('heading',{name:'Osie i stanowiska',exact:true})).toBeFocused();
  expect(changes.map(w=>w.p_section)).toEqual(['identity','profile']);expect(changes[1].p_expected_revision).not.toBe(changes[0].p_expected_revision);
  page.off('request',track);await section(0);
  await page.getByLabel('Nazwa wyświetlana').fill('Unsaved C');
  const previousUrl=page.url();let rejected=false;
  page.once('dialog',async d=>{rejected=true;await d.dismiss();});await page.evaluate(()=>history.back());
  await expect.poll(()=>rejected).toBe(true);await expect(page).toHaveURL(previousUrl);
  await expect(page.getByLabel('Nazwa wyświetlana')).toHaveValue('Unsaved C');page.once('dialog',d=>d.dismiss());await section(1);await expect(page.getByLabel('Nazwa wyświetlana')).toHaveValue('Unsaved C');page.once('dialog',d=>d.dismiss());await page.getByRole('link',{name:'Lista obiektów',exact:true}).click();await expect(page.getByLabel('Nazwa wyświetlana')).toHaveValue('Unsaved C');page.once('dialog',d=>d.accept());await section(4);
  await page.getByRole('link',{name:'Lista obiektów',exact:true}).click();
  await page.getByRole('link',{name:'Kontynuuj konfigurację',exact:true}).and(page.locator(`a[href*="${id}"]`)).click();
  await expect(page.getByRole('heading',{name:'Strona i wygląd',exact:true})).toBeVisible();
  await page.getByLabel('Logo obiektu').fill('/brand/strzelajtu/logo-symbol.png');await page.getByLabel('Zdjęcie główne').fill('/brand/strzelajtu/logo-symbol.png');await save();
  await section(3);await page.getByLabel('Godzina otwarcia').fill('10:00');await page.getByLabel('Godzina zamknięcia').fill('18:00');await save();
  await section(1);await page.getByRole('button',{name:'Dodaj oś',exact:true}).click();const dialog=page.getByRole('dialog');await dialog.getByRole('radio',{name:/Ze stanowiskami/}).check();await dialog.getByLabel('Nazwa osi',{exact:true}).fill('Oś C');await dialog.getByLabel('Nazwa stanowiska',{exact:true}).fill('Stanowisko C');
  for(const el of await dialog.getByLabel(/^Cena (całej osi|stanowiska) za godzinę$/).all())await el.fill('25');
  for(const el of await dialog.getByRole('checkbox',{name:/^(Oś|Stanowisko) w użyciu$/}).all())await el.check();
  for(const el of await dialog.getByRole('checkbox',{name:/^Rezerwacje online/}).all())await el.check();
  await dialog.getByRole('checkbox',{name:/^Rezerwacja stanowisk/}).check();
  await dialog.getByRole('button',{name:'Przejdź do podsumowania'}).click();let first,second,writes=0;
  await page.route('**/rest/v1/rpc/platform_save_draft_configuration_v1',async route=>{writes++;first=route.request().postDataJSON();const response=await route.fetch();expect(response.ok(),await response.text()).toBe(true);await route.abort('failed');},{times:1});
  await dialog.getByRole('button',{name:'Utwórz oś'}).evaluate(el=>{el.click();el.click();});await expect(page.getByRole('button',{name:'Sprawdź / ponów zapis'})).toBeEnabled();await expect(page.getByRole('alert').filter({hasText:'Nie potwierdzono'})).toBeVisible();expect(writes).toBe(1);safe();
  expect(sql(`select count(*) from public.shooting_lanes where tenant_id='${id}'`)).toBe('2');
  await page.reload();await page.route('**/rest/v1/rpc/platform_save_draft_configuration_v1',async route=>{second=route.request().postDataJSON();await route.continue();},{times:1});await page.getByRole('button',{name:'Sprawdź / ponów zapis'}).click();await expect(page.locator('footer[aria-label="Działania kroku"]').getByRole('status')).toContainText('Zapisano');expect(second).toEqual(first);safe();expect(sql(`select count(*) from public.shooting_lanes where tenant_id='${id}'`)).toBe('2');
  await section(2);await page.getByRole('button',{name:'Edytuj rezerwacje i ceny'}).click();await page.getByRole('dialog').getByRole('checkbox',{name:'Rezerwacja całej osi',exact:true}).uncheck();await expect(page.getByRole('dialog').getByRole('button',{name:'Zapisz zmiany',exact:true})).toBeDisabled();await page.getByRole('dialog').getByRole('checkbox',{name:'Rezerwacje online',exact:true}).uncheck();await page.getByRole('dialog').getByRole('button',{name:'Zapisz zmiany',exact:true}).click();await page.getByRole('dialog').getByRole('button',{name:'Potwierdź zapis',exact:true}).click();await expect(page.getByRole('dialog')).toHaveCount(0);safe();
  const eventsLink = page.getByRole('checkbox', {name:'Pokaż wydarzenia',exact:true});
  const about = page.getByRole('checkbox', {name:'Pokaż sekcję „O obiekcie”'});
  const priceList = page.getByRole('checkbox', {name:'Pokaż cennik informacyjny'});
  const assignPlan = async key => {
    await page.getByRole('combobox', {name:'Pakiet obiektu'}).selectOption(key);
    await expect(eventsLink).toBeDisabled();
    await page.getByRole('button', {name:'Sprawdź zmianę planu'}).click();
    await expect(page.getByText('Potwierdź wybór przy zapisie tego kroku.')).toBeVisible();
    page.once('dialog', d => d.accept());
    await save();
  };
  await section(4);
  await expect(page.getByLabel('Oferta obiektu')).toHaveCount(0);
  await expect(page.getByRole('button', {name:'Dodaj pozycję cennika'})).toHaveCount(0);
  await page.getByRole('button', {name:'Wybierz widoczne sekcje w kroku „Funkcje obiektu”'}).click();
  await expect(eventsLink).toHaveAccessibleDescription(/Najpierw przypisz pakiet/);
  await assignPlan('booking_only_v1');
  await expect(eventsLink).toBeDisabled();
  await expect(eventsLink).toHaveAccessibleDescription(/Funkcja niedostępna w wybranym pakiecie/);
  await expect(page.getByRole('listitem').filter({has:page.getByText('Lista rezerwowa',{exact:true})})).toContainText('Funkcja niedostępna');
  await assignPlan('current_full_v1');
  const fullConfig=(await rpc('platform_get_draft_configuration_v1',{p_tenant_id:id},token)).body;
  expect((await rpc('platform_save_draft_configuration_v1',{p_tenant_id:id,p_expected_revision:fullConfig.revision,p_request_id:randomUUID(),p_section:'profile',p_payload:{opening_hours:'10:00-18:00'}},token)).status).toBe(200);
  await page.getByRole('button',{name:'Odczytaj bieżące dane'}).click();
  await expect(eventsLink).toBeEnabled();
  await expect(eventsLink).not.toBeChecked();
  await eventsLink.focus();await page.keyboard.press('Space');await expect(eventsLink).toBeChecked();
  await expect(page.getByRole('combobox',{name:'Pakiet obiektu'})).toBeDisabled();
  await expect(page.locator('#draft-actions [role=status]')).toHaveText('Masz niezapisane zmiany');
  page.once('dialog', d => d.dismiss());await page.getByRole('button',{name:'Konfiguruj osie',exact:true}).first().click();
  await expect(eventsLink).toBeChecked();
  await about.check();await priceList.check();
  const beforeFlags=await rpc('platform_get_draft_configuration_v1',{p_tenant_id:id},token);
  expect(beforeFlags.body.profile.show_events).toBe(false);
  let featureAttempt;
  await page.route('**/rest/v1/rpc/platform_save_draft_configuration_v1',async route=>{
    featureAttempt=route.request().postDataJSON();
    expect(featureAttempt.p_payload).toEqual({show_about:true,show_pricing:true,show_events:true});
    expect(featureAttempt.p_expected_revision).toBe(beforeFlags.body.revision);
    expect((await route.fetch()).ok()).toBe(true);
    await route.abort('failed');
  },{times:1});
  await page.getByRole('button',{name:'Zapisz zmiany',exact:true}).click();
  await expect(page.getByRole('button',{name:'Sprawdź / ponów zapis'})).toBeEnabled();
  await page.route('**/rest/v1/rpc/platform_save_draft_configuration_v1',async route=>{
    expect(route.request().postDataJSON()).toEqual(featureAttempt);await route.continue();
  },{times:1});
  await page.getByRole('button',{name:'Sprawdź / ponów zapis'}).click();
  await expect(page.locator('#draft-actions [role=status]')).toHaveText('Zapisano');safe();
  const persisted=await rpc('platform_get_draft_configuration_v1',{p_tenant_id:id},token);
  expect(persisted.body.revision).not.toBe(beforeFlags.body.revision);
  expect(persisted.body.profile).toMatchObject({show_events:true,show_pricing:true,show_about:true,is_public:false,opening_hours:"10:00-18:00"});
  await assignPlan('booking_only_v1');await expect(eventsLink).toBeDisabled();await expect(eventsLink).not.toBeChecked();
  await expect(eventsLink).toHaveAccessibleDescription(/Zapisany wybór zostaje zachowany/);
  expect((await rpc('platform_get_draft_configuration_v1',{p_tenant_id:id},token)).body.profile.show_events).toBe(true);
  await page.goto('/platform-admin/tenants/'+id+'/preview');
  await expect(page.getByText('Wydarzenia w planie: nie · Odnośnik po publikacji: nie.')).toBeVisible();
  await page.getByRole('link',{name:'Wróć do konfiguracji'}).click();await section(5);
  await assignPlan('current_full_v1');await expect(eventsLink).toBeChecked();
  await eventsLink.uncheck();
  const other=(await rpc('platform_get_draft_configuration_v1',{p_tenant_id:id},token)).body;
  expect((await rpc('platform_save_draft_configuration_v1',{p_tenant_id:id,p_expected_revision:other.revision,p_request_id:randomUUID(),p_section:'profile',p_payload:{about_audience:'Another editor'}},token)).status).toBe(200);
  await page.getByRole('button',{name:'Zapisz zmiany',exact:true}).click();
  await expect(page.getByRole('alert').filter({hasText:'innym oknie'})).toBeVisible();
  await expect(eventsLink).toBeDisabled();await expect(eventsLink).not.toBeChecked();
  page.once('dialog',d=>d.accept());await page.getByRole('button',{name:'Odczytaj bieżące dane'}).click();
  await expect(eventsLink).toBeChecked();
  await section(4);await page.getByRole('button',{name:'Dodaj pozycję cennika'}).click();await page.getByLabel('Nazwa usługi',{exact:true}).fill('Trening');await page.getByLabel('Jednostka ceny',{exact:true}).fill('godzina');await page.getByLabel('Cena informacyjna',{exact:true}).fill('35');await save();
  await section(4);await page.getByLabel('Krótki opis').fill('Synthetic description');await page.getByLabel('Oferta obiektu').fill('Synthetic offer');await page.getByLabel('Dla kogo').fill('Dorośli');await save();
  await page.getByLabel('Krótki opis').fill('Preserved conflict text');const current=await rpc('platform_get_draft_configuration_v1',{p_tenant_id:id},token);expect((await rpc('platform_save_draft_configuration_v1',{p_tenant_id:id,p_expected_revision:current.body.revision,p_request_id:randomUUID(),p_section:'profile',p_payload:{about_audience:'Other session'}},token)).status).toBe(200);
  await page.getByRole('button',{name:'Zapisz i przejdź dalej',exact:true}).click();await expect(page.getByRole('alert').filter({hasText:'innym oknie'})).toBeVisible();await expect(page.getByLabel('Krótki opis')).toHaveValue('Preserved conflict text');page.once('dialog',d=>d.accept());await page.getByRole('button',{name:'Odczytaj bieżące dane'}).click();await expect(page.getByLabel('Dla kogo')).toHaveValue('Other session');safe();
  await section(5);await about.uncheck();await priceList.uncheck();await save();
  await section(4);await expect(page.getByLabel('Oferta obiektu')).toHaveCount(0);
  await expect(page.getByRole('button',{name:'Dodaj pozycję cennika'})).toHaveCount(0);
  await section(5);await about.check();await priceList.check();await save();
  await section(4);await expect(page.getByLabel('Oferta obiektu')).toHaveValue('Synthetic offer');
  await expect(page.getByLabel('Cena informacyjna',{exact:true})).toHaveValue('35');
  await section(6);
  const featureSummary=page.getByRole('article').filter({has:page.getByRole('heading',{name:'Funkcje obiektu',exact:true})});
  await expect(featureSummary).toContainText('Check-in / QR');await expect(featureSummary).toContainText('Pokaż wydarzenia');
  await expect(featureSummary).toContainText('Brak niezarchiwizowanych partnerów');
  await section(6);await page.getByRole('link',{name:'Lista obiektów',exact:true}).click();await page.getByRole('link',{name:'Kontynuuj konfigurację',exact:true}).click();
  await expect(page.getByRole('heading',{name:'Podsumowanie',exact:true})).toBeVisible();
  await section(0);await expect(page.getByLabel('Nazwa obiektu')).toHaveValue('Tenant C configured');
  for(const width of [320,375,768,1440]){await page.setViewportSize({width,height:950});for(const n of [0,1,2,3,4,5,6]){
    await section(n);await expectFieldGuides(page);
    await expect(page.locator('#draft-actions')).toContainText(`Krok ${n+1} z 7`);
    const bar=await page.locator('#draft-actions').boundingBox();expect(bar.y+bar.height).toBeLessThanOrEqual(951);
    const content=await page.locator("[data-wizard-scroll]").boundingBox();expect(content.y+content.height).toBeLessThanOrEqual(bar.y+1);
    if(n === 5){
      await expect(eventsLink).toBeChecked();
      await expect(page.locator('#draft-step-form input[type=checkbox]')).toHaveCount(7);
      const eventCard=page.getByRole('listitem').filter({has:page.getByText('Wydarzenia i szkolenia',{exact:true})});
      await eventCard.scrollIntoViewIfNeeded();
      await expect(eventCard).toContainText('Dostępna w pakiecie');
      await page.screenshot({path:info.outputPath(`features-${width}.png`),fullPage:true});
      await eventsLink.scrollIntoViewIfNeeded();
      await expect(eventsLink).toHaveAccessibleDescription(/Włączona/);
      await page.screenshot({path:info.outputPath(`visibility-${width}.png`),fullPage:true});
    }
    if(n === 0) await page.screenshot({path:info.outputPath(`contact-${width}.png`),fullPage:true});
    if(n === 1){
      const add=page.getByRole('button',{name:'Dodaj oś'});
      await add.click();await expectFieldGuides(page);
      await page.getByRole('dialog').screenshot({path:info.outputPath(`new-lane-${width}.png`)});
      await page.keyboard.press('Escape');await expect(page.getByRole('dialog')).toHaveCount(0);await expect(add).toBeFocused();
      await page.getByRole('button',{name:'Edytuj oś i stanowiska'}).click();await expectFieldGuides(page);
      await page.keyboard.press('Escape');await expect(page.getByRole('dialog')).toHaveCount(0);await expect(page.getByRole('button',{name:'Edytuj oś i stanowiska'})).toBeFocused();
    }
  }await section(6);await page.screenshot({path:info.outputPath('wizard-'+width+'.png'),fullPage:true});}
  await page.getByRole('button',{name:'Wstecz',exact:true}).focus();await page.keyboard.press('Enter');await expect(page.getByRole('heading',{name:'Funkcje obiektu',exact:true})).toBeFocused();await section(6);
  await page.getByRole('link',{name:'Prywatny podgląd zapisanej strony'}).click();await expect(page.getByRole('heading',{name:'Test zapisanej konfiguracji'})).toBeVisible();await expect(page.getByText('Synthetic venue',{exact:false})).toBeVisible();await expect(page.getByText('Stanowisko C',{exact:false})).toBeVisible();await expect(page.getByText('Trening: 35.00 PLN / godzina',{exact:false})).toBeVisible();await expect(page.getByRole('heading',{name:'Partnerzy i sponsorzy',exact:true})).toBeVisible();
  const anonymous=await browser.newContext({ignoreHTTPSErrors:true});try{const p=await anonymous.newPage();for(const path of ['/'+slug+'-public','/t/'+slug+'/booking','/t/'+slug+'/events'])expect((await p.goto(fixture.app+path)).status()).toBe(404);}finally{await anonymous.close();}
  for(const name of ['get_public_booking_configuration_v2','get_public_event_list_v3'])expect((await rpc(name,{p_tenant_id:id})).status).toBe(423);
  await page.goto('/platform-admin/tenants/'+id);await page.getByRole('button',{name:'Archiwizuj obiekt',exact:true}).click();await page.getByRole('dialog').getByRole('button',{name:'Potwierdź operację'}).click();await expect(page.getByRole('button',{name:'Przywróć obiekt do konfiguracji'})).toBeVisible();
  await page.goto('/platform-admin');await expect(page.getByRole('link',{name:'Przywróć',exact:true}).and(page.locator(`a[href*="${id}"]`))).toHaveAttribute('href',`/platform-admin/tenants/${id}#archiwizacja`);
  await page.goto('/platform-admin/tenants/'+id+'/setup');await section(0);await expect(page.getByLabel('Nazwa obiektu')).toBeDisabled();await expect(page.getByText(/Obiekt zarchiwizowany/)).toBeVisible();
  await page.getByRole('link',{name:'Zarządzaj obiektem'}).click();await page.getByRole('button',{name:'Przywróć obiekt do konfiguracji'}).click();await page.getByRole('dialog').getByRole('button',{name:'Potwierdź operację'}).click();await expect(page.getByRole('button',{name:'Archiwizuj obiekt',exact:true})).toBeVisible();await page.goto('/platform-admin/tenants/'+id+'/setup');await section(0);await expect(page.getByLabel('Nazwa obiektu')).toHaveValue('Tenant C configured');safe();
  const final=(await rpc('platform_get_draft_configuration_v1',{p_tenant_id:id},token)).body;expect(final.profile.public_email).toBe('venue@example.invalid');expect(final.profile.logo_path).toBe('/brand/strzelajtu/logo-symbol.png');expect(final.pricing_items).toHaveLength(1);expect(final.lanes.families).toHaveLength(1);expect(final.plan.plan_key).toBe('current_full_v1');expect(final.profile.about_offer).toBe('Synthetic offer');
  expect(existingState()).toBe(baseline);
  await context.clearCookies();await page.reload();await expect(page).toHaveURL(/\/login/);
 }catch(e){console.error("PRIMARY_SCENARIO_FAILURE",e.message);throw e;}finally{
  if(!id)id=sql(`select id from public.tenants where slug='${slug}'`);
  if(id){assert.match(id,/^[a-f0-9-]{36}$/);const state=(await rpc('platform_get_draft_configuration_v1',{p_tenant_id:id},token)).body;if(state.status==='archived')await rpc('platform_restore_archived_tenant_v1',{p_tenant_id:id,p_expected_revision:state.lifecycle_revision,p_request_id:randomUUID()},token);
   sql(`begin;delete from public.audit_logs where tenant_id='${id}';delete from public.platform_plan_change_requests where tenant_id='${id}';delete from public.tenant_plan_assignments where tenant_id='${id}';delete from public.platform_tenant_lifecycle_requests where tenant_id='${id}';delete from app_private.draft_configuration_requests where tenant_id='${id}';delete from public.lane_booking_durations where lane_id in(select id from public.shooting_lanes where tenant_id='${id}');delete from public.lane_booking_rules where lane_id in(select id from public.shooting_lanes where tenant_id='${id}');delete from public.lane_pricing_rules where lane_id in(select id from public.shooting_lanes where tenant_id='${id}');delete from public.lane_booking_family_configuration_versions where root_lane_id in(select id from public.shooting_lanes where tenant_id='${id}');delete from public.shooting_lanes where tenant_id='${id}';delete from public.tenant_public_pricing_items where tenant_id='${id}';delete from app_private.tenant_public_access_changes where tenant_id='${id}';delete from public.tenant_public_access_controls where tenant_id='${id}';delete from public.platform_audit_logs where tenant_id='${id}';delete from public.platform_tenant_creation_requests where tenant_id='${id}';delete from public.tenant_public_profiles where tenant_id='${id}';delete from public.tenants where id='${id}';commit;`);
  }expect(sql(`select count(*) from public.tenants where slug='${slug}'`)).toBe('0');
 }
});
for(const [role,email] of [['Tenant Admin','ptm2-0@example.invalid'],['employee','ptm2-1@example.invalid'],['instructor','ptm2-2@example.invalid'],['customer','ptm1-customer@example.invalid'],['anonymous',null]])test(role+' cannot enter configuration or call its contracts',async({context,page})=>{
 const token=email?await auth(context,email):fixture.anonKey,id='e7310000-0000-4000-8000-000000000001';const response=await page.goto('/platform-admin/tenants/'+id+'/setup');if(email)expect(response.status()).toBe(404);else await expect(page).toHaveURL(/\/login/);
 expect([401,403]).toContain((await rpc('platform_get_draft_configuration_v1',{p_tenant_id:id},token)).status);
 expect([401,403]).toContain((await rpc('platform_save_draft_configuration_v1',{p_tenant_id:id,p_expected_revision:'a'.repeat(64),p_request_id:randomUUID(),p_section:'profile',p_payload:{description:'Forbidden'}},token)).status);
});
