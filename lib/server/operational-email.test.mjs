import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { operationalEmailBrand, operationalEmailHistoryUrl,
  operationalEmailActionUrl, buildOperationalEmailSubject } from './operational-email-core.ts';
import { createOperationalEmailResolvers } from './operational-email.ts';
import { getOperationalEmailSenderConfiguration } from './operational-email-config.ts';
import { spawnSync } from 'node:child_process';
const wrapperNames={reservation:'resolveReservationEmailTenantContext',event:'resolveEventEmailTenantContext',event_registration:'resolveEventRegistrationEmailTenantContext'};
const resolve=(resource,read)=> { const fn=createOperationalEmailResolvers(read)[wrapperNames[resource.resourceType]]; return fn ? fn(Object.keys(resource).length===2?resource.resourceId:resource) : Promise.reject(new Error('unknown type')); };
const a='11111111-1111-4111-8111-111111111111', b='22222222-2222-4222-8222-222222222222';
const rows={ [a]:{tenant_id:a,tenant_slug:'csk',public_slug:'csk-krutla',display_name:'CSK Krutla'},
 [b]:{tenant_id:b,tenant_slug:'alfa',public_slug:'strzelnica-alfa',display_name:'Synthetic Range B'} };
const read=async(_type,id)=>rows[id]?[rows[id]]:[];
for(const type of ['reservation','event','event_registration']) for(const id of [a,b]) {
 test(`${type} ${id}: resource-bound isolated context and branding`,async()=>{
  const t=await resolve({resourceType:type,resourceId:id},read);
  assert.equal(t.tenantId,id); assert.equal(t.canonicalPublicUrl,`https://strzelajtu.pl/${rows[id].public_slug}`);
  assert.equal(operationalEmailBrand(t,'Potwierdzenie rezerwacji').subject,`StrzelajTu.pl / ${rows[id].display_name} — Potwierdzenie rezerwacji`);
  assert.equal(operationalEmailHistoryUrl(t,'events'),`https://strzelajtu.pl/t/${rows[id].tenant_slug}/my-events`);
  if(id===b) assert.doesNotMatch(JSON.stringify(t)+operationalEmailBrand(t,'Test').headerHtml+operationalEmailHistoryUrl(t,'events'),/csk|Krutla/i);
 });
}
for(const extra of [{tenant_id:b},{public_slug:'forged'},{displayName:'forged'}]) test('forged input rejected '+Object.keys(extra),async()=>{
 let called=false; await assert.rejects(resolve({resourceType:'reservation',resourceId:a,...extra},async()=>{called=true;})); assert.equal(called,false);
});
for(const resource of [{resourceType:'tenant',resourceId:a},{resourceType:'event',resourceId:'bad'},{resourceType:'event',resourceId:'33333333-3333-4333-8333-333333333333'}]) test('invalid or missing resource fails closed '+JSON.stringify(resource),async()=>assert.rejects(resolve(resource,read)));
for(const result of [[],[rows[a],rows[b]],[{...rows[a],tenant_id:null}],[{...rows[a],display_name:''}],[{...rows[a],public_slug:'../csk'}],[{...rows[a],billing:'private'}]]) test('invalid projection rejected '+JSON.stringify(result),async()=>assert.rejects(resolve({resourceType:'event',resourceId:a},async()=>result)));
test('HTML escaped and CRLF denied',async()=>{
 const t=await resolve({resourceType:'event',resourceId:b},async()=>[{...rows[b],display_name:'Alfa <img>'}]);
 assert.match(operationalEmailBrand(t,'Test').headerHtml,/&lt;img&gt;/);
 assert.throws(()=>buildOperationalEmailSubject({tenantDisplayName:'Alfa\r\nBcc:x',notificationLabel:'Test'}));
});
test('capability URL canonical and token validated',()=>{
 assert.equal(operationalEmailActionUrl('check-in',a),`https://strzelajtu.pl/check-in/${a}`);
 assert.throws(()=>operationalEmailActionUrl('events/confirm','//evil.invalid'));
});
test('sender remains exact current configuration',()=>assert.deepEqual(getOperationalEmailSenderConfiguration({RESEND_API_KEY:'test',RESERVATION_EMAIL_FROM:'Existing <test@example.invalid>'}),{resendApiKey:'test',from:'Existing <test@example.invalid>'}));
const paths=['../../app/api/send-reservation-confirmation/route.ts','../../app/api/send-reservation-cancellation/route.ts','../../app/api/send-event-registration-confirmation/route.ts','./event-reserve-promotion.ts','./event-reserve-confirmation-email.ts'];
for(const path of paths) test('runtime uses shared brand without legacy host '+path,async()=>{
 const s=await readFile(new URL(path,import.meta.url),'utf8');
 assert.doesNotMatch(s,/CSK|Krutla|krutla\.pl|NEXT_PUBLIC_SITE_URL|x-forwarded-host|\/t\/csk/);
 assert.match(s,/resolve(?:Reservation|Event|EventRegistration)EmailTenantContext/);assert.match(s,/operationalEmailBrand/);
 assert.match(s,/brand\.headerHtml/);assert.match(s,/brand\.headerText/);
});
test('service key is server-only; no browser-callable context RPC',async()=>{
 const s=await readFile(new URL('./operational-email.ts',import.meta.url),'utf8');
 assert.match(s,/import "server-only"/); assert.match(s,/SUPABASE_SERVICE_ROLE_KEY/);
 assert.doesNotMatch(s,/NEXT_PUBLIC_.*SERVICE|console\./);
});
test('owner/staff gates precede context lookup; confirmation mutation precedes receipt',async()=>{
 for(const [path,gate] of [
  ['../../app/api/send-reservation-confirmation/route.ts','.eq("user_id", user.id)'],
  ['../../app/api/send-event-registration-confirmation/route.ts','.eq("user_id", user.id)'],
  ['../../app/api/send-reservation-cancellation/route.ts','if (!isOwner && !isStaff)'],
 ]) {
  const s=await readFile(new URL(path,import.meta.url),'utf8');
  assert.ok(s.indexOf(gate)>0); assert.ok(s.indexOf(gate)<s.search(/await resolve(?:Reservation|Event|EventRegistration)EmailTenantContext/));
 }
 const receipt=await readFile(new URL('../../app/api/confirm-event-reserve-promotion/route.ts',import.meta.url),'utf8');
 assert.ok(receipt.indexOf('rpcData.code !== "confirmed"')<receipt.indexOf('await sendConfirmedPlaceEmail'));
 assert.ok(receipt.indexOf('.eq("user_id", authResult.user.id)')<receipt.indexOf('await sendConfirmedPlaceEmail'));
});
test('typed wrappers distinguish same UUID across resource types',async()=>{
 const wrappers=createOperationalEmailResolvers(async(type)=>[rows[type==='reservation'?a:b]]);
 assert.equal((await wrappers.resolveReservationEmailTenantContext(a)).tenantId,a);
 assert.equal((await wrappers.resolveEventEmailTenantContext(a)).tenantId,b);
 assert.equal((await wrappers.resolveEventRegistrationEmailTenantContext(a)).tenantId,b);
});
test('core contains no secrets, env access or clients',async()=>{
 const source=await readFile(new URL('./operational-email-core.ts',import.meta.url),'utf8');
 assert.doesNotMatch(source,/process\\.env|RESEND_|SERVICE_ROLE|createClient|new Resend/);
});
for(const file of ['operational-email.ts','operational-email-config.ts']) test('server import rejected outside server condition '+file,()=>{
 const result=spawnSync(process.execPath,['--input-type=module','-e',`await import(${JSON.stringify(new URL(file,import.meta.url).href)})`],{encoding:'utf8'});
 assert.notEqual(result.status,0); assert.match(result.stderr,/Server Component|server-only/);
});
test('endpoint schemas reject resource type inputs; production callers use literal wrappers',async()=>{
 for(const path of paths) {
  const source=await readFile(new URL(path,import.meta.url),'utf8');
  assert.doesNotMatch(source,/resourceType|resource_type|getOperationalEmailTenantContext/);
 }
 const server=await readFile(new URL('./operational-email.ts',import.meta.url),'utf8');
 assert.doesNotMatch(server,/export async function getOperationalEmailTenantContext|request\\.|searchParams/);
});
