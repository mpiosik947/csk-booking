import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { deliverEventAcceptance } from './event-acceptance-delivery-core.ts';
import { eventInvitationKey } from './event-invitation-key.ts';
import { operationalEmailBrand,operationalEmailHistoryUrl,operationalEmailActionUrl } from './operational-email-core.ts';
import { escapeHtml,escapeEmailHref } from './email-html.ts';
const id='11111111-1111-4111-8111-111111111111',tenant='22222222-2222-4222-8222-222222222222';
const lease='33333333-3333-4333-8333-333333333333';
const claim={code:'ready',registration_id:id,tenant_id:tenant,recipient_user_id:id,claim_id:lease,idempotency_key:`event-reserve-acceptance/${tenant}/${id}`};
function harness({providerError=false,markerError=false,sendThrows=false,claimCode='ready',providerId='provider-1'}={}){
 const calls=[];return {calls,deps:{claim:async resource=>{calls.push(['claim',resource]);return {data:claimCode==='ready'?claim:{code:claimCode},error:null};},
 send:async c=>{calls.push(['send',c.idempotency_key]);if(sendThrows)throw Error('secret provider details');return {data:providerId?{id:providerId}:null,error:providerError?Error('secret'):null};},
 complete:async(c,success,message)=>{calls.push(['complete',c,success,message]);return {data:{code:success?'sent':'failed'},error:markerError?Error('marker'):null};}}};
}
test('provider accepted plus committed sent marker is sent',async()=>{const h=harness();assert.equal(await deliverEventAcceptance(id,h.deps),'sent');assert.deepEqual(h.calls[2],['complete',lease,true,'provider-1']);});
for(const options of [{providerError:true},{sendThrows:true},{providerId:null}])test('failed or ambiguous provider is not declared sent '+JSON.stringify(options),async()=>{const h=harness(options);assert.equal(await deliverEventAcceptance(id,h.deps),'failed');assert.deepEqual(h.calls[2],['complete',lease,false,null]);});
test('provider success marker failure is uncertain, never exactly-once',async()=>{const h=harness({markerError:true});assert.equal(await deliverEventAcceptance(id,h.deps),'uncertain');assert.equal(h.calls.filter(x=>x[0]==='send').length,1);});
for(const state of ['already_sent','in_progress','retry_exhausted','not_found','unavailable'])test('claim '+state+' never calls provider',async()=>{const h=harness({claimCode:state});assert.equal(await deliverEventAcceptance(id,h.deps),state==='already_sent'||state==='retry_exhausted'?state:'pending');assert.equal(h.calls.length,1);});
test('invalid and forged claim context fails closed',async()=>{
 for(const field of ['registration_id','tenant_id','recipient_user_id','idempotency_key']){
  const h=harness();h.deps.claim=async()=>({data:{...claim,[field]:'forged'},error:null});
  assert.equal(await deliverEventAcceptance(id,h.deps),'uncertain');assert.equal(h.calls.length,0);
 }
 const h=harness();assert.equal(await deliverEventAcceptance('invalid',h.deps),'failed');assert.equal(h.calls.length,0);
});
test('retry uses stable logical key despite new claim',async()=>{const h=harness();await deliverEventAcceptance(id,h.deps);h.deps.claim=async()=>({data:{...claim,claim_id:tenant},error:null});await deliverEventAcceptance(id,h.deps);assert.deepEqual(h.calls.filter(x=>x[0]==='send').map(x=>x[1]),[claim.idempotency_key,claim.idempotency_key]);});
test('invitation key stable across retries, tenant/registration/version separated, no raw token',()=>{
 const key=eventInvitationKey(tenant,id,lease);assert.equal(key,eventInvitationKey(tenant,id,lease));
 assert.notEqual(key,eventInvitationKey(id,id,lease));assert.notEqual(key,eventInvitationKey(tenant,tenant,lease));assert.notEqual(key,eventInvitationKey(tenant,id,id));
 assert.ok(!key.includes(lease));assert.ok(key.length<=256);assert.throws(()=>eventInvitationKey(tenant,id,'bad'));
});
const read=p=>readFileSync(new URL(p,import.meta.url),'utf8');
test('server-only retry derives recipient from claim-bound resource, no client authority',()=>{
 const s=read('./event-acceptance-delivery.ts');assert.match(s,/import "server-only"/);assert.match(s,/\.eq\("tenant_id", claim.tenant_id\)/);assert.match(s,/\.eq\("user_id", claim.recipient_user_id\)/);
 assert.doesNotMatch(s,/console\.|NEXT_PUBLIC_.*SERVICE|profiles\.role|body\./);
 const route=read('../../app/api/confirm-event-reserve-promotion/route.ts');assert.ok(route.indexOf('rpcData.code !== "confirmed"')<route.indexOf('await retryEventAcceptanceEmail'));
 assert.match(route,/notification,/);assert.doesNotMatch(route,/catch\(\(\) => null\)/);
});
test('invitation marker validated and actual expiry displayed; provider key wired',()=>{
 const s=read('./event-reserve-promotion.ts');assert.match(s,/success && !data.email_sent_recorded/);assert.match(s,/idempotencyKey: eventInvitationKey/);
 assert.match(s,/promotion.promotion_token_expires_at/);assert.doesNotMatch(s,/Link jest ważny przez 24 godziny/);
});

// Render real production HTML/text template literals with synthetic allowlisted data.
export function previewEventEmail(t,kind){
 const invitation=kind==='invitation',acceptance=kind==='acceptance';
 const src=read(invitation?'./event-reserve-promotion.ts':acceptance?'./event-reserve-confirmation-email.ts':'../../app/api/send-event-registration-confirmation/route.ts');
 const label=src.match(/operationalEmailBrand\(tenant, "([^"]+)"\)/)?.[1];assert.ok(label);
 const brand=operationalEmailBrand(t,label),url=invitation?operationalEmailActionUrl('events/confirm',id):operationalEmailHistoryUrl(t,'events');
 const values={tenant:t,brand,displayName:'Osobo testowa',formattedDate:'15 października 2026',formattedStartTime:'10:00',formattedEndTime:'11:00',formattedPrice:'100.00 zł',eventTitle:'Synthetic event',startTime:'10:00',endTime:'11:00',location:'Obiekt testowy',formattedStatus:kind==='waitlist'?'Lista rezerwowa':'Potwierdzony',myEventsUrl:url,eventsUrl:url,confirmUrl:url,expiresAt:'16.10.2026, 10:00',escapeHtml,
 event:{title:'Synthetic event',location:'Obiekt testowy'},eventItem:{title:'Synthetic event',location:'Obiekt testowy'}};
 for(const [key,value] of Object.entries({...values}))if(typeof value==='string')values['safe'+key[0].toUpperCase()+key.slice(1)]=escapeHtml(value);
 values.safeEventTitle=escapeHtml(values.eventTitle);values.safeLocation=escapeHtml(values.location);values.safeMyEventsUrl=escapeEmailHref(url);values.safeConfirmUrl=escapeEmailHref(url);
 const render=n=>{const m=src.match(new RegExp('const '+n+' = `([\\s\\S]*?)`;'));assert.ok(m);return Function(...Object.keys(values),'return `'+m[1]+'`;')(...Object.values(values));};
 return {subject:brand.subject,html:render('html'),text:render('text'),cta:url};
}
for(const t of [{tenantId:id,tenantSlug:'csk',publicSlug:'csk-krutla',displayName:'CSK — Centrum Szkolenia Krutla'},
 {tenantId:tenant,tenantSlug:'synthetic-b',publicSlug:'synthetic-range-b',displayName:'Synthetic Range B'}])for(const kind of ['registration','waitlist','invitation','acceptance'])test('real template '+t.tenantSlug+' '+kind,()=>{
 const mail=previewEventEmail(t,kind);assert.match(mail.subject,/^StrzelajTu.pl \/ /);assert.ok(mail.text.includes(t.displayName));assert.ok(mail.html.includes(t.displayName));assert.ok(mail.html.includes(mail.cta));
 assert.match(mail.text,/Synthetic event/);assert.match(mail.text,/10:00/);
 if(t.tenantSlug==='synthetic-b')assert.doesNotMatch(JSON.stringify(mail),/CSK|csk|Krutla/);
 assert.doesNotMatch(JSON.stringify(mail),/admin_notes|membership|billing|service_role|auth_token/);
});
