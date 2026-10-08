import {test,expect,type Page} from '@playwright/test';
import {startManagementBrowser} from '../fixtures/platform-management-browser.mjs';
import {fixture,rpcResponse,tenantId,email,userId,readerNames} from '../fixtures/platform-management.mjs';

type Call={name:string;args:Record<string,unknown>};
type Model=ReturnType<typeof fixture>;
let server:Awaited<ReturnType<typeof startManagementBrowser>>;
test.beforeAll(async()=>{server=await startManagementBrowser();});
test.afterAll(async()=>{await server?.close();});
async function mount(page:Page,f=fixture(),override?:(call:Call,f:Model)=>unknown){
 const calls:Call[]=[],unexpected:string[]=[],errors:string[]=[];
 page.on('pageerror',error=>errors.push(error.message));
 await page.route('**/*',async route=>{
  const req=route.request(),url=new URL(req.url());
  if(url.pathname.startsWith('/rpc/')){
   expect(req.method()).toBe('POST');const call={name:url.pathname.slice(5),args:req.postDataJSON()};calls.push(call);
   const overridden=await override?.(call,f);
   if(overridden==='abort'){await route.abort();return;}
   await route.fulfill({json:overridden??rpcResponse(f,call.name,call.args)});return;
  }
  if(url.origin!==server.url||!['/','/app.js','/style.css'].includes(url.pathname))unexpected.push(req.url());
  await route.continue();
 });
 await page.goto(server.url);await expect(page.getByRole('button',{name:'Odśwież stan',exact:true})).toBeEnabled();
 return {calls,f,unexpected,errors};
}
const section=(page:Page,name:string)=>page.getByRole('region',{name,exact:true});
async function lookup(page:Page){await page.getByLabel('Dokładny e-mail konta').fill(email);await page.getByRole('button',{name:'Znajdź konto',exact:true}).click();await expect(section(page,'Administratorzy obiektu').getByText(`Konto: ${email}`)).toBeVisible();}
async function confirm(page:Page){await page.getByRole('dialog').getByRole('button',{name:'Potwierdź operację',exact:true}).click();}

test('plan preview, warnings, blocked apply, keyboard modal, v2 payload and safe network',async({page})=>{
 const h=await mount(page);const plan=section(page,'Plan / pakiet');
 await expect(plan.getByText('Bieżący plan: Pakiet całość')).toBeVisible();
 Object.assign(h.f.preview,{blockers:[{code:'EVENTS_OPEN',count:1}]});
 await page.getByLabel('Docelowy plan').selectOption('booking_only_v1');await expect(plan.getByRole('button',{name:'Zmień plan',exact:true})).toBeDisabled();await expect(plan.getByText('Przyszłe wydarzenia wymagają obsługi.',{exact:false})).toBeVisible();
 Object.assign(h.f.preview,{blockers:[],features_added:['reports']});
 await page.getByLabel('Docelowy plan').selectOption('current_full_v1');await page.getByLabel('Docelowy plan').selectOption('booking_only_v1');
 const trigger=plan.getByRole('button',{name:'Zmień plan',exact:true});await trigger.click();
 const dialog=page.getByRole('dialog');await expect(dialog.getByText('Dodawane funkcje: Raporty')).toBeVisible();await expect(dialog.getByText('Usuwane funkcje: Wydarzenia')).toBeVisible();await expect(dialog.getByText('Docelowy plan: Pakiet minimum')).toBeVisible();
 await page.keyboard.press('Escape');await expect(dialog).toHaveCount(0);await expect(trigger).toBeFocused();await trigger.click();await confirm(page);await expect(dialog).toHaveCount(0);await expect(page.getByRole('status').filter({hasText:'Plan obiektu został zmieniony.'})).toBeVisible();
 const write=h.calls.find(c=>c.name==='platform_change_tenant_plan_v2')!;expect(write.args).toEqual({p_tenant_id:tenantId,p_target_plan_key:'booking_only_v1',p_expected_revision:'9007199254740993',p_change_request_id:expect.stringMatching(/^[0-9a-f-]{36}$/)});
 expect(h.calls.every(c=>[...readerNames,'platform_get_tenant_plan_change_preview_v1','platform_change_tenant_plan_v2'].includes(c.name))).toBe(true);expect(h.unexpected).toEqual([]);expect(h.errors).toEqual([]);
});

for(const [role,status,label,warning]of [[null,null,'Dodaj jako administratora','Brak członkostwa'],['user','active','Awansuj do administratora','Rola: Użytkownik'],['employee','active','Awansuj do administratora','Awans zastąpi rolę pracownika'],['instructor','active','Awansuj do administratora','Po awansie konto przestanie pełnić rolę instruktora.'],['admin','suspended','Reaktywuj administratora','Status: Zawieszony']] as const){
 test(`candidate ${role}/${status}: explicit action, warning and expected state`,async({page})=>{
  const f=fixture();Object.assign(f.candidate.membership,{exists:!!role,role,status});const h=await mount(page,f);await lookup(page);await expect(section(page,'Administratorzy obiektu').getByText(warning,{exact:false})).toBeVisible();
  await page.getByRole('button',{name:label,exact:true}).click();await expect(page.getByRole('dialog').getByText(warning,{exact:false})).toBeVisible();await confirm(page);await expect(page.getByRole('dialog')).toHaveCount(0);
  const write=h.calls.find(c=>c.name===(role==='admin'?'platform_reactivate_tenant_admin_v1':'platform_add_tenant_admin_v1'))!;expect(write.args.p_expected_state).toEqual(role?{role,status}:null);expect(write.args.p_user_id).toBe(userId);expect(write.args.p_request_id).toMatch(/^[0-9a-f-]{36}$/);expect(h.errors).toEqual([]);
 });
}
for(const [role,status,text]of [['admin','active','Użytkownik jest już administratorem'],['user','suspended','Członkostwo jest zawieszone. Awans jest niedostępny.'],['user','pending','Członkostwo oczekuje na rozstrzygnięcie. Operacja jest niedostępna.'],['admin','pending','Członkostwo oczekuje na rozstrzygnięcie. Operacja jest niedostępna.']] as const){
 test(`candidate ${role}/${status} cannot be silently added`,async({page})=>{
  const f=fixture();Object.assign(f.candidate.membership,{exists:true,role,status});await mount(page,f);await lookup(page);await expect(page.getByText(text,{exact:true})).toBeVisible();await expect(page.getByRole('button',{name:/^(Dodaj jako administratora|Awansuj do administratora|Reaktywuj administratora)$/})).toHaveCount(0);
  if(status==='pending')await expect(page.getByRole('button',{name:/^(Usuń uprawnienia administratora|Zawieś administratora)$/})).toHaveCount(0);
 });
}
for(const [action,rpc,warning]of [['Usuń uprawnienia administratora','platform_demote_tenant_admin_v1','Użytkownik pozostanie członkiem obiektu, ale straci uprawnienia administratora.'],['Zawieś administratora','platform_suspend_tenant_admin_v1','Konto utraci dostęp administratora tego obiektu.']] as const){
 test(`${action}: R1 refresh from admin list and dedicated writer`,async({page})=>{
  const f=fixture();Object.assign(f.candidate.membership,{exists:true,role:'admin',status:'active'});const h=await mount(page,f);await page.getByRole('button',{name:`Zarządzaj uprawnieniami: ${email}`}).click();await page.getByRole('button',{name:action,exact:true}).click();await expect(page.getByRole('dialog').getByText(warning,{exact:false})).toBeVisible();await confirm(page);await expect(page.getByRole('dialog')).toHaveCount(0);expect(h.calls.find(c=>c.name===rpc)?.args.p_expected_state).toEqual({role:'admin',status:'active'});expect(h.calls.some(c=>c.name==='platform_lookup_tenant_admin_candidate_v1')).toBe(true);
 });
}
test('suspended admin only offers reactivation; active actions require canonical refresh and fresh lookup',async({page})=>{
 const f=fixture();Object.assign(f.candidate.membership,{exists:true,role:'admin',status:'suspended'});f.admins.admins[0].membership_status='suspended';
 let reads=0,release:()=>void=()=>{};
 const h=await mount(page,f,async call=>{if(call.name==='platform_get_tenant_admin_management_v1'&&++reads===2)await new Promise<void>(resolve=>release=resolve);});
 await lookup(page);const admins=section(page,'Administratorzy obiektu');
 await expect(admins.getByRole('button',{name:'Reaktywuj administratora',exact:true})).toBeVisible();
 await expect(admins.getByRole('button',{name:/^(Usuń uprawnienia administratora|Zawieś administratora|Dodaj jako administratora)$/})).toHaveCount(0);
 await expect(admins.getByText('Administrator jest zawieszony.',{exact:false})).toBeVisible();
 await admins.getByRole('button',{name:'Reaktywuj administratora',exact:true}).click();await confirm(page);
 await expect.poll(()=>reads).toBe(2);await expect(page.getByRole('button',{name:'Odśwież stan',exact:true})).toBeDisabled();await expect(admins.getByRole('button',{name:'Usuń uprawnienia administratora',exact:true})).toHaveCount(0);
 release();await expect(page.getByRole('button',{name:'Odśwież stan',exact:true})).toBeEnabled();await expect(admins).toContainText('Status: Aktywny');
 await expect(admins.getByRole('button',{name:'Usuń uprawnienia administratora',exact:true})).toHaveCount(0);
 await lookup(page);await expect(admins.getByRole('button',{name:'Usuń uprawnienia administratora',exact:true})).toBeVisible();await expect(admins.getByRole('button',{name:'Zawieś administratora',exact:true})).toBeVisible();
 expect(h.calls.filter(c=>c.name==='platform_reactivate_tenant_admin_v1')).toHaveLength(1);expect(h.calls.filter(c=>c.name==='platform_demote_tenant_admin_v1')).toHaveLength(0);expect(h.errors).toEqual([]);
});
test('stale demotion denial refreshes suspended state, hides demotion and never exposes raw DB errors',async({page})=>{
 const f=fixture();Object.assign(f.candidate.membership,{exists:true,role:'admin',status:'active'});
 const h=await mount(page,f,(call,model)=>{if(call.name==='platform_demote_tenant_admin_v1'){
  Object.assign(model.candidate.membership,{status:'suspended'});model.admins.admins[0].membership_status='suspended';
  // Inject the stable denial; this is a UI fallback scenario, not a DB race simulation.
  return {data:null,error:{code:'55000',message:'NOT_ACTIVE_TENANT_ADMIN',details:'PRIVATE SQL stack'}};
 }});
 await lookup(page);await page.getByRole('button',{name:'Usuń uprawnienia administratora',exact:true}).click();await confirm(page);
 await expect(page.getByRole('dialog')).toHaveCount(0);await expect(page.getByText('Ta operacja wymaga aktywnego administratora. Odśwież dane użytkownika.',{exact:true})).toBeVisible();
 await expect(page.getByRole('button',{name:'Usuń uprawnienia administratora',exact:true})).toHaveCount(0);await expect(page.getByRole('button',{name:'Reaktywuj administratora',exact:true})).toBeVisible();await expect(page.locator('body')).not.toContainText(/55000|NOT_ACTIVE_TENANT_ADMIN|PRIVATE|SQL stack/);
 expect(h.f.candidate.membership).toEqual({exists:true,role:'admin',status:'suspended'});expect(h.calls.filter(c=>c.name==='platform_demote_tenant_admin_v1')).toHaveLength(1);expect(h.calls.filter(c=>c.name==='platform_get_tenant_admin_management_v1')).toHaveLength(2);expect(h.calls.filter(c=>c.name==='platform_lookup_tenant_admin_candidate_v1')).toHaveLength(2);expect(h.errors).toEqual([]);
});
test('uncertain retry keeps request ID and payload; repeated submit sends once',async({page})=>{
 let n=0,release:()=>void=()=>{};
 const h=await mount(page,fixture(),async call=>{if(call.name==='platform_add_tenant_admin_v1'&&++n===1){await new Promise<void>(resolve=>release=resolve);return 'abort';}});
 await lookup(page);await page.getByRole('button',{name:'Dodaj jako administratora',exact:true}).click();await confirm(page);await expect(page.getByRole('button',{name:'Zapisywanie…'})).toBeDisabled();expect(n).toBe(1);release();await expect(page.getByRole('button',{name:'Ponów tę samą próbę',exact:true})).toBeEnabled();await page.getByRole('button',{name:'Zamknij potwierdzenie'}).click();await expect(page.getByRole('button',{name:'Odśwież stan',exact:true})).toBeDisabled();await expect(page.getByRole('button',{name:'Sprawdź / ponów tę samą próbę'})).toBeFocused();await page.getByRole('button',{name:'Sprawdź / ponów tę samą próbę'}).click();await page.getByRole('button',{name:'Ponów tę samą próbę',exact:true}).click();await expect(page.getByRole('dialog')).toHaveCount(0);const writes=h.calls.filter(c=>c.name==='platform_add_tenant_admin_v1');expect(writes).toHaveLength(2);expect(writes[0].args).toEqual(writes[1].args);
});
for(const [code,sqlstate,text]of [['LAST_ACTIVE_ADMIN','23514','Nie można wykonać tej operacji, ponieważ obiekt musi mieć co najmniej jednego aktywnego administratora.'],['INSTRUCTOR_HAS_OPEN_OBLIGATIONS','55000','Nie można awansować tego instruktora, ponieważ ma nierozliczone obowiązki instruktorskie.'],['STALE_MEMBERSHIP_STATE','PT409','Członkostwo zmieniło się. Dane konta zostały odświeżone. Potwierdź nową operację.']] as const){
 test(`${code} safe message and no retry`,async({page})=>{
  const h=await mount(page,fixture(),c=>c.name==='platform_add_tenant_admin_v1'?{data:null,error:{code:sqlstate,message:code,details:'PRIVATE SQL customers'}}:undefined);await lookup(page);await page.getByRole('button',{name:'Dodaj jako administratora',exact:true}).click();await confirm(page);await expect(page.getByRole('dialog')).toHaveCount(0);await expect(page.getByText(text,{exact:true})).toBeVisible();expect(h.calls.filter(c=>c.name==='platform_add_tenant_admin_v1')).toHaveLength(1);await expect(page.locator('body')).not.toContainText('PRIVATE');
 });
}
test('plan stale refresh requires fresh explicit confirmation',async({page})=>{
 const h=await mount(page,fixture(),c=>c.name==='platform_change_tenant_plan_v2'?{data:null,error:{code:'PT409',message:'PLAN_STALE'}}:undefined);await page.getByLabel('Docelowy plan').selectOption('booking_only_v1');await page.getByRole('button',{name:'Zmień plan',exact:true}).click();await confirm(page);await expect(page.getByText('Dane obiektu zmieniły się. Podgląd został odświeżony.')).toBeVisible();expect(h.calls.filter(c=>c.name==='platform_change_tenant_plan_v2')).toHaveLength(1);expect(h.calls.filter(c=>c.name==='platform_get_tenant_plan_change_preview_v1')).toHaveLength(2);
});
test('archive confirmation, stale refresh, success then dormant/private restore',async({page})=>{
 let stale=true;const h=await mount(page,fixture(),c=>c.name==='platform_archive_tenant_v1'&&stale?{data:null,error:{code:'PT409',message:'TENANT_REVISION_STALE'}}:undefined);
 await expect(page.getByRole('button',{name:'Przywróć obiekt do konfiguracji',exact:true})).toHaveCount(0);await page.getByRole('button',{name:'Archiwizuj obiekt',exact:true}).click();await expect(page.getByRole('dialog').getByText('Dane i historyczne rekordy nie zostaną usunięte.')).toBeVisible();await confirm(page);await expect(page.getByText('Status obiektu zmienił się. Dane zostały odświeżone.')).toBeVisible();stale=false;await page.getByRole('button',{name:'Archiwizuj obiekt',exact:true}).click();await confirm(page);await expect(section(page,'Status obiektu')).toContainText('Zarchiwizowany');await expect(page.getByRole('button',{name:/Aktywuj|Opublikuj/})).toHaveCount(0);
 await page.getByRole('button',{name:'Przywróć obiekt do konfiguracji',exact:true}).click();await expect(page.getByRole('dialog').getByText('Obiekt zostanie przywrócony jako nieaktywny obiekt w przygotowaniu. Nie zostanie automatycznie opublikowany.')).toBeVisible();await confirm(page);await expect(section(page,'Status obiektu')).toContainText('W przygotowaniu');await expect(section(page,'Status obiektu')).toContainText('Niepubliczny');await expect(page.getByRole('link',{name:'Ustawienia — wymagany tenant admin'})).toHaveAttribute('href','/tenant-setup/local-range');expect(h.calls.some(c=>c.name==='platform_set_tenant_state_v1')).toBe(false);
 const restores=h.calls.filter(c=>c.name==='platform_restore_archived_tenant_v1');expect(restores).toHaveLength(1);expect(restores[0].args.p_expected_revision).toBe(18);
});
test('read-only delete policy; unknown blocker safe; no customer fields or delete controls',async({page})=>{
 const f=fixture();f.eligibility.blockers.push({code:'INTERNAL_SECRET_TABLE',count:5,category:'schema',hard_blocker:true});Object.assign(f.detail,{customer_phone:'PRIVATE',customer_notes:'PRIVATE'});await mount(page,f);const card=section(page,'Możliwość trwałego usunięcia');await expect(card.getByText('Trwałe usuwanie obiektów nie jest obecnie dostępne.')).toBeVisible();await expect(card.getByText('Zależność techniczna blokuje trwałe usunięcie.',{exact:false})).toBeVisible();await expect(card.getByRole('button')).toHaveCount(0);await expect(page.locator('body')).not.toContainText(/PRIVATE|INTERNAL_SECRET_TABLE/);
});
test('section failure disables that section; authority failure closes entire page',async({page})=>{
 let deny=false;await mount(page,fixture(),c=>c.name==='platform_get_tenant_admin_management_v1'?{data:null,error:{code:deny?'42501':'XX000',message:'PRIVATE'}}:undefined);await expect(section(page,'Administratorzy obiektu').getByRole('alert')).toBeVisible();await expect(page.getByRole('button',{name:'Znajdź konto'})).toHaveCount(0);await expect(page.getByLabel('Docelowy plan')).toBeEnabled();deny=true;await page.getByRole('button',{name:'Odśwież stan',exact:true}).click();await expect(page.getByRole('heading',{name:'Brak dostępu',exact:true})).toBeVisible();await expect(page.getByRole('region')).toHaveCount(0);await expect(page.locator('body')).not.toContainText(email);
});
for(const width of [320,375,768,1440]){
 test(`responsive cards and dialog at ${width}px`,async({page})=>{
  await page.setViewportSize({width,height:900});await mount(page);await expect(page.getByRole('heading',{name:'Strzelnica testowa'})).toBeVisible();expect(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth)).toBe(true);await page.getByRole('button',{name:'Archiwizuj obiekt',exact:true}).click();expect(await page.getByRole('dialog').evaluate(el=>el.scrollWidth<=el.clientWidth)).toBe(true);const bounds=await page.getByRole('dialog').boundingBox();expect(Math.abs(bounds!.x+bounds!.width/2-width/2)).toBeLessThan(2);await page.screenshot({path:test.info().outputPath(`management-${width}.png`),fullPage:true});await page.keyboard.press('Escape');await expect(page.getByRole('button',{name:'Archiwizuj obiekt',exact:true})).toBeFocused();
 });
}
