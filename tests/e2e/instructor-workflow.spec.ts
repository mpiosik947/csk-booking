import { test, expect } from '@playwright/test';
import { readFileSync, readdirSync } from 'node:fs';
import { resolve } from 'node:path';
const bundle=readFileSync('test-results/instructor-browser/fixture.js','utf8');
const css=readdirSync('.next/static/css',{recursive:true}).filter(n=>String(n).endsWith('.css')).map(n=>readFileSync(resolve('.next/static/css',String(n)),'utf8')).join('\n');
const id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const event={id,title:'Szkolenie syntetycznego Tenant B',description:'Opis szkolenia',event_date:'2026-12-01',start_time:'10:00:00',end_time:'11:00:00',location:'Miejsce testowe',status:'upcoming',participants_available:true};
for(const width of [375,430,1440])test(`scoped instructor reader ${width}: sections, revocation, no cached PII`,async({page},info)=>{
  await page.setViewportSize({width,height:1000});
  let denied=false;
  await page.route('http://instructor.test/**',async route=>{
    const url=new URL(route.request().url());
    if(url.pathname.startsWith('/api/instructor/')){
      expect(url.pathname).toBe('/api/instructor/synthetic-b/events');
      await route.fulfill({status:denied?403:200,contentType:'application/json',body:JSON.stringify(denied?{error:'denied'}:{event,participants:{total:1,items:[{registration_id:'fixture',display_name:url.searchParams.get('section')==='reserve'?'Osoba rezerwowa':'Uczestnik testowy',registration_status:url.searchParams.get('section')==='reserve'?'reserve':'registered'}]}})});return;
    }
    await route.fulfill({contentType:'text/html; charset=utf-8',body:`<html><head><style>${css}</style></head><body style="background:#090d09;color:#eee;padding:16px"><main id="root"></main><script>${bundle}</script></body></html>`});
  });
  await page.goto(`http://instructor.test/?eventId=${id}`);
  await expect(page.getByRole('listitem').filter({hasText:'Uczestnik testowy'})).toBeVisible();
  await page.getByRole('button',{name:'Lista rezerwowa',exact:true}).click();
  await expect(page.getByRole('listitem').filter({hasText:'Osoba rezerwowa'})).toBeVisible();
  await expect(page.getByRole('listitem').filter({hasText:'Uczestnik testowy'})).toHaveCount(0);
  expect(await page.evaluate(()=>document.documentElement.scrollWidth)).toBeLessThanOrEqual(width);
  await page.screenshot({path:info.outputPath(`instructor-detail-${width}.png`),fullPage:true});
  denied=true;
  await page.getByRole('button',{name:'Odśwież',exact:true}).click();
  await expect(page.getByRole('alert')).toBeVisible();
  await expect(page.getByRole('listitem').filter({hasText:'Osoba rezerwowa'})).toHaveCount(0);
  await page.goBack();
});
test('0, 1, N selected instructors; keyboard and removal',async({page})=>{
  await page.route('http://instructor.test/**',route=>route.fulfill({contentType:'text/html; charset=utf-8',body:`<html><body><div id="root"></div><script>${bundle}</script></body></html>`}));
  await page.goto('http://instructor.test/?selector=1');
  const output=page.getByLabel('Selected IDs');await expect(output).toHaveText('');
  await page.getByLabel('Instruktor Alfa',{exact:true}).check();await expect(output).toHaveText('a');
  await page.getByLabel('Instruktor Beta',{exact:true}).focus();await page.keyboard.press('Space');await expect(output).toHaveText('a,b');
  await page.getByLabel('Instruktor Alfa',{exact:true}).uncheck();await expect(output).toHaveText('b');
});
test('cancelled/expired metadata remains but PII unavailable; logout clears DOM',async({page})=>{
  await page.route('http://instructor.test/**',route=>route.request().url().includes('/api/')?
    route.fulfill({json:{event:{...event,status:'cancelled',participants_available:false},participants:null}}):
    route.fulfill({contentType:'text/html; charset=utf-8',body:`<html><body><div id="root"></div><script>${bundle}</script></body></html>`}));
  await page.goto(`http://instructor.test/?eventId=${id}`);
  await expect(page.getByText(/Dane uczestników są niedostępne/)).toBeVisible();
  await page.evaluate(()=>window.dispatchEvent(new CustomEvent('fixture-auth',{detail:'SIGNED_OUT'})));
  await expect(page.getByRole('alert')).toBeVisible();await expect(page.getByText(event.title,{exact:true})).toHaveCount(0);
});
