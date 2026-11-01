import {test,expect} from '@playwright/test';import fs from 'node:fs';import assert from 'node:assert/strict';import {randomUUID} from 'node:crypto';import {createServerClient} from '@supabase/ssr';import sharp from 'sharp';
const fixture=JSON.parse(fs.readFileSync(process.env.PUBLIC_TEST_MODE_FIXTURE_FILE,'utf8'));
for(const v of [fixture.app,fixture.origin])assert.equal(new URL(v).hostname,'127.0.0.1');assert.match(fixture.scratchDatabase,/^sbr3_[a-f0-9]{16}$/);
const emails={admin:'ptm2-0@example.invalid',employee:'ptm2-1@example.invalid',instructor:'ptm2-2@example.invalid',suspended:'ptm2-3@example.invalid',pending:'ptm2-4@example.invalid',foreign:'ptm2-5@example.invalid',pa:'ptm2-6@example.invalid',removed:'ptm2-7@example.invalid',customer:'ptm1-customer@example.invalid'};
const A='ptm1-synthetic-a',B='ptm2-b';let image,Arow,Brow;
async function login(context,actor){const cookies=[];const c=createServerClient(fixture.origin,fixture.anonKey,{cookieOptions:{secure:true},cookies:{getAll:()=>[],setAll:v=>cookies.push(...v)}});const{data,error}=await c.auth.signInWithPassword({email:emails[actor],password:fixture.password});expect(error).toBeNull();await context.addCookies(cookies.map(({name,value})=>({name,value,domain:'127.0.0.1',path:'/',secure:true,sameSite:'Lax'})));return data.session.access_token;}
async function rpc(name,args,token=fixture.anonKey){const r=await fetch(fixture.origin+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:fixture.anonKey,authorization:'Bearer '+token,'content-type':'application/json'},body:JSON.stringify(args)});return{status:r.status,body:await r.json()};}
const values=(name,extra={})=>({name,kind:'partner',display_format:'logo',is_active:true,display_order:0,target_url:null,short_description:null,starts_at:null,ends_at:null,...extra});
async function save(context,slug,props,record=null,upload=image){return context.request.post(fixture.app+'/api/tenant-partners/'+slug,{headers:{origin:fixture.app},multipart:{payload:JSON.stringify({id:record?.id??randomUUID(),revision:record?.revision??null,media_id:record?.media_id??null,archive:false,values:props}),...(upload?{image:{name:'synthetic.png',mimeType:'image/png',buffer:upload}}:{})}});}
test.beforeAll(async({browser})=>{
 image=await sharp({create:{width:600,height:200,channels:4,background:'#71834c'}}).png().toBuffer();
 for(const[actor,slug]of[['admin',A],['foreign',B]]){const context=await browser.newContext({ignoreHTTPSErrors:true});const token=await login(context,actor);const current=await rpc('admin_get_tenant_partners_v1',{p_tenant_slug:slug},token);const name=slug===A?'A logo':'B logo';let row=current.body.items.find(p=>p.name===name);
 if(!row){const r=await save(context,slug,values(name));expect(r.status(),await r.text()).toBe(200);row=(await r.json()).items.find(p=>p.name===name);}if(slug===A)Arow=row;else Brow=row;
 if(slug===B){for(const[name,patch]of[['B banner',{kind:'commercial_partner',display_format:'banner',target_url:'https://example.invalid/path?q=1#info',display_order:3}],['B inactive',{is_active:false}],['B future',{starts_at:'2099-01-01T00:00:00.000Z'}],['B expired',{ends_at:'2001-01-01T00:00:00.000Z'}]]){if(current.body.items.some(p=>p.name===name))continue;const result=await save(context,B,values(name,patch));expect(result.status(),await result.text()).toBe(200);}}
 await context.close();}
});
test.beforeEach(async({context})=>{await context.route('**/*',route=>new URL(route.request().url()).hostname==='127.0.0.1'?route.continue():route.abort());});

test('patched Next image optimizer accepts local raster and denies SVG and unapproved remote sources',async({context})=>{
 const optimize=url=>fixture.app+'/_next/image?url='+encodeURIComponent(url)+'&w=640&q=75';
 const raster=await context.request.get(optimize('/brand/strzelajtu/logo-symbol.png'));
 expect(raster.status()).toBe(200);expect(raster.headers()['content-type']).toMatch(/^image\//);
 const meta=await sharp(await raster.body()).metadata();expect(meta.width).toBeLessThanOrEqual(640);
 expect((await context.request.get(optimize('/file.svg'))).status()).toBe(400);
 expect((await context.request.get(optimize('https://example.invalid/image.png'))).status()).toBe(400);
});

test('own admin creates via UI, edits order, disables, activates and archives with real upload',async({page,context})=>{
 const name='UI Partner '+randomUUID().slice(0,8);
 await login(context,'admin');await page.goto('/t/'+A+'/admin/settings');await page.getByRole('link',{name:'Partnerzy i sponsorzy'}).click();
 await expect(page.getByRole('heading',{name:'Partnerzy i sponsorzy',exact:true})).toBeVisible();await page.getByRole('button',{name:'Dodaj partnera'}).click();
 await page.getByLabel('Nazwa partnera',{exact:true}).fill(name);await page.getByLabel('Grafika',{exact:false}).setInputFiles({name:'synthetic.png',mimeType:'image/png',buffer:image});
 await page.getByLabel('Aktywny',{exact:true}).check();await page.getByRole('button',{name:'Zapisz partnera'}).click();await expect(page.getByRole('status')).toHaveText('Zapisano zmiany.');
 const item=page.locator('li').filter({has:page.getByRole('heading',{name,exact:true})});await expect(item.getByRole('img')).toBeVisible();
 await item.getByRole('button',{name:'Edytuj',exact:true}).click();await page.getByLabel('Kolejność',{exact:true}).fill('12');await page.getByRole('button',{name:'Zapisz partnera'}).click();await expect(item).toContainText('Kolejność: 12');
 await item.getByRole('button',{name:'Wyłącz',exact:true}).click();await expect(item).toContainText('Wyłączony');await item.getByRole('button',{name:'Aktywuj',exact:true}).click();await expect(item).toContainText('Opublikowany');
 page.once('dialog',d=>d.accept());await item.getByRole('button',{name:'Archiwizuj'}).click();await expect(item).toContainText('Archiwum');await expect(item.getByRole('button',{name:'Edytuj'})).toHaveCount(0);
});

test('live B filters dates and state, exact position, labels, links, no A or external image request',async({page})=>{
 await page.goto('/ptm2-public-b');const section=page.getByTestId('tenant-partners');await expect(section.getByRole('heading',{name:'Partnerzy [TEST] B',exact:true})).toBeVisible();
 await expect(section.getByText('B logo',{exact:true})).toBeVisible();await expect(section.getByText('B banner',{exact:true})).toBeVisible();await expect(section.getByText('Materiał reklamowy')).toBeVisible();
 for(const name of ['A logo','B inactive','B future','B expired'])await expect(page.getByText(name,{exact:true})).toHaveCount(0);
 const link=section.getByRole('link');await expect(link).toHaveAttribute('href','https://example.invalid/path?q=1#info');await expect(link).toHaveAttribute('rel','noopener noreferrer sponsored');await expect(link).toHaveAttribute('target','_blank');
 expect(await page.evaluate(()=>{const info=document.querySelector('[data-testid="information-rows"]'),partners=document.querySelector('[data-testid="tenant-partners"]'),footer=document.querySelector('[data-testid="tenant-landing-panel"] footer');return !!(info.compareDocumentPosition(partners)&Node.DOCUMENT_POSITION_FOLLOWING)&&!!(partners.compareDocumentPosition(footer)&Node.DOCUMENT_POSITION_FOLLOWING);})).toBe(true);
 await section.scrollIntoViewIfNeeded();await expect.poll(()=>section.locator('img').evaluateAll(images=>images.every(i=>i.complete&&i.naturalWidth>0))).toBe(true);
 await link.focus();await expect(link).toBeFocused();await expect(section.locator('button')).toHaveCount(0);
});
for(const width of [320,375,768,1440])test('mobile layout '+width,async({page},info)=>{
 await page.setViewportSize({width,height:1100});await page.goto('/ptm2-public-b');const partners=page.getByTestId('tenant-partners');await partners.scrollIntoViewIfNeeded();
 expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
 const columns=await page.getByTestId('partner-logo-grid').evaluate(e=>getComputedStyle(e).gridTemplateColumns.split(' ').length);expect(columns).toBe(width<768?2:width<1280?4:5);
 await page.screenshot({path:info.outputPath('partners-'+width+'.png'),fullPage:true});
});

for(const actor of ['anon','customer','employee','instructor','suspended','pending','foreign','removed','pa','admin'])test(actor+' availability, media and admin matrix',async({context,page})=>{
 const token=actor==='anon'?fixture.anonKey:await login(context,actor),allowed=['admin','employee','instructor','pa'].includes(actor);
 await page.goto('/ptm1-public-a');await expect(page.getByTestId('tenant-partners')).toHaveCount(allowed?1:0);
 const r=await rpc('get_public_tenant_partners_v1',{p_public_slug:'ptm1-public-a'},token);expect(r.status).toBe(allowed?200:423);
 const media=await context.request.get(fixture.app+'/api/tenant-partners/media/'+Arow.media_id);expect(media.status()).toBe(allowed?200:404);expect(media.headers()['cache-control']).toContain('no-store');
 const list=await rpc('admin_get_tenant_partners_v1',{p_tenant_slug:A},token);expect(list.status).toBe(actor==='admin'?200:actor==='anon'?401:403);
 if(actor!=='admin'){const response=await save(context,A,values('Forbidden'));expect([401,403]).toContain(response.status());}
});

test('direct storage denies raw downloads, listing, signed URLs and forged uploads even for own admin',async({context})=>{
 const token=await login(context,'admin'),path='e7310000-0000-4000-8000-000000000001/partners/'+Arow.media_id+'.webp';
 for(const auth of [fixture.anonKey,token]){
  for(const route of ['/object/public/tenant-partners/'+path,'/object/authenticated/tenant-partners/'+path]){const r=await fetch(fixture.origin+'/storage/v1'+route,{headers:{apikey:fixture.anonKey,authorization:'Bearer '+auth}});expect(r.ok).toBe(false);}
  const signed=await fetch(fixture.origin+'/storage/v1/object/sign/tenant-partners/'+path,{method:'POST',headers:{apikey:fixture.anonKey,authorization:'Bearer '+auth,'content-type':'application/json'},body:JSON.stringify({expiresIn:60})});expect(signed.ok).toBe(false);
  const list=await fetch(fixture.origin+'/storage/v1/object/list/tenant-partners',{method:'POST',headers:{apikey:fixture.anonKey,authorization:'Bearer '+auth,'content-type':'application/json'},body:JSON.stringify({prefix:'',limit:100})});if(list.ok)expect(await list.json()).toEqual([]);
  const put=await fetch(fixture.origin+'/storage/v1/object/tenant-partners/'+path,{method:'POST',headers:{apikey:fixture.anonKey,authorization:'Bearer '+auth,'content-type':'image/webp'},body:Buffer.from('RIFFFAKEWEBP')});expect(put.ok).toBe(false);
 }
});

test('server rejects SVG and spoofed MIME, and CSRF; stale version preserves existing data',async({context})=>{
 await login(context,'admin');const invalid=await save(context,A,values('Unsafe'),null,Buffer.from('<svg onload="alert(1)"></svg>'));expect(invalid.status()).toBe(400);
 const csrf=await context.request.post(fixture.app+'/api/tenant-partners/'+A,{headers:{origin:'https://foreign.invalid'},data:'bad'});expect(csrf.status()).toBe(403);
 const stale=await save(context,A,values('stale'),{...Arow,revision:randomUUID()},null);expect(stale.status()).toBe(409);
 const read=await rpc('get_public_tenant_partners_v1',{p_public_slug:'ptm2-public-b'});expect(read.body[0].id).toBe(Brow.id);
});

test('admin to anon logout invalidates cached media and landing, anon to admin restores',async({page,context})=>{
 await context.route('https://strzelajtu.pl/**',route=>route.fulfill({status:302,headers:{location:fixture.app+'/'}}));
 await login(context,'admin');await page.goto('/ptm1-public-a');await expect(page.getByTestId('tenant-partners')).toBeVisible();
 const url=fixture.app+'/api/tenant-partners/media/'+Arow.media_id;expect((await context.request.get(url)).status()).toBe(200);
 await page.getByRole('button',{name:'Wyloguj',exact:true}).click();await expect(page).toHaveURL(fixture.app+'/');await expect(page.getByRole('link',{name:'Zaloguj się',exact:true}).first()).toBeVisible();await page.goto('/ptm1-public-a');await expect(page.getByTestId('tenant-partners')).toHaveCount(0);expect((await context.request.get(url)).status()).toBe(404);
 await login(context,'admin');await page.reload();await expect(page.getByTestId('tenant-partners')).toBeVisible();expect((await context.request.get(url)).status()).toBe(200);
});

test('concurrent own-admin writes accept one revision and reject the stale competitor',async({context})=>{
 const token=await login(context,'admin');const before=await rpc('admin_get_tenant_partners_v1',{p_tenant_slug:A},token);const row=before.body.items.find(p=>p.id===Arow.id);
 const unchangedB=await rpc('get_public_tenant_partners_v1',{p_public_slug:'ptm2-public-b'});
 const results=await Promise.all([save(context,A,values('A logo',{display_order:20}),row,null),save(context,A,values('A logo',{display_order:30}),row,null)]);
 expect(results.map(r=>r.status()).sort()).toEqual([200,409]);
 const after=await rpc('admin_get_tenant_partners_v1',{p_tenant_slug:A},token);const next=after.body.items.find(p=>p.id===row.id);
 expect([20,30]).toContain(next.display_order);expect(next.revision).not.toBe(row.revision);
 const restore=await save(context,A,values('A logo'),next,null);expect(restore.status()).toBe(200);
 expect((await rpc('get_public_tenant_partners_v1',{p_public_slug:'ptm2-public-b'})).body).toEqual(unchangedB.body);
});

test('admin editor stays within mobile viewport with labelled controls',async({page,context},info)=>{
 await login(context,'admin');await page.setViewportSize({width:320,height:1000});await page.goto('/t/'+A+'/admin/partners');await page.getByRole('button',{name:'Dodaj partnera'}).click();
 for(const name of ['Nazwa partnera','Kolejność','Adres strony','Krótki opis','Publikuj od','Publikuj do','Aktywny'])await expect(page.getByLabel(name,{exact:true})).toBeVisible();
 for(const name of ['Rodzaj','Format'])await expect(page.getByRole('combobox',{name,exact:true})).toBeVisible();
 expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
 await page.screenshot({path:info.outputPath('partner-admin-mobile.png'),fullPage:true});
});

test('failed replacement upload rolls back only its newly uploaded asset',async({context})=>{
 await login(context,'admin');const stale=await save(context,A,values('A logo'),{...Arow,revision:randomUUID()},image);expect(stale.status()).toBe(409);
 expect((await context.request.get(fixture.app+'/api/tenant-partners/media/'+Arow.media_id)).status()).toBe(200);
});

test('custom domains serve only their own live public media and discard session authority',async({context})=>{
 const token=await login(context,'admin');const cookie=(await context.cookies(fixture.app)).map(c=>c.name+'='+c.value).join('; ');
 const request=(host,id)=>context.request.get('http://127.0.0.1:3107/api/tenant-partners/media/'+id,{headers:{host,authorization:'Bearer '+token,cookie},maxRedirects:0});
 const live=await request('partners-b.example.invalid',Brow.media_id);expect(live.status()).toBe(200);expect(live.headers()['content-type']).toContain('image/webp');
 expect((await request('partners-a.example.invalid',Arow.media_id)).status()).toBe(404);
 expect((await request('partners-a.example.invalid',Brow.media_id)).status()).toBe(404);
 expect((await request('partners-b.example.invalid',Arow.media_id)).status()).toBe(404);
 expect((await request('unknown-partners.example.invalid',Brow.media_id)).status()).toBe(404);
 const mutation=await context.request.post('http://127.0.0.1:3107/api/tenant-partners/'+B,{headers:{host:'partners-b.example.invalid',origin:'https://partners-b.example.invalid'},data:'{}'});expect(mutation.status()).toBe(404);
});

test('two tenant admins racing the same new UUID cannot overwrite the winning tenant',async({browser})=>{
 const a=await browser.newContext({ignoreHTTPSErrors:true}),b=await browser.newContext({ignoreHTTPSErrors:true});
 try {
  const ta=await login(a,'admin'),tb=await login(b,'foreign');
  const id=randomUUID(),pa=values('A collision',{is_active:false}),pb=values('B collision',{is_active:false});
  const results=await Promise.all([
   save(a,A,pa,{id,revision:null,media_id:Arow.media_id},null),
   save(b,B,pb,{id,revision:null,media_id:Brow.media_id},null),
  ]);
  const statuses=results.map(r=>r.status());expect(statuses.filter(s=>s===200)).toHaveLength(1);
  expect(statuses.filter(s=>s===403||s===409)).toHaveLength(1);
  const ar=(await rpc('admin_get_tenant_partners_v1',{p_tenant_slug:A},ta)).body.items.filter(p=>p.id===id);
  const br=(await rpc('admin_get_tenant_partners_v1',{p_tenant_slug:B},tb)).body.items.filter(p=>p.id===id);
  expect(ar.length+br.length).toBe(1);
  if(statuses[0]===200){expect(ar[0]).toMatchObject({name:pa.name,media_id:Arow.media_id});expect(br).toEqual([]);}
  else {expect(br[0]).toMatchObject({name:pb.name,media_id:Brow.media_id});expect(ar).toEqual([]);}
 } finally {await a.close();await b.close();}
});
