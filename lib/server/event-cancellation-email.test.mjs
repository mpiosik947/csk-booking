import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {cancellationEmailContent,deliverEventCancellation,attemptCancellationReceipt} from './event-cancellation-email-core.ts';
const id='a0000000-0000-4000-8000-000000000001',tenantId='b0000000-0000-4000-8000-000000000002';
const claim={code:'ready',claim_id:id,registration_id:id,tenant_id:tenantId,recipient_user_id:id,idempotency_key:`event-registration-cancellation/${tenantId}/${id}`};
const response=code=>({data:{code},error:null});
const deps=()=>({prepare:async()=>({data:claim,error:null}),send:async()=>({data:{id:'provider-test'},error:null}),complete:async(_id,success)=>response(success?'sent':'failed')});
for(const [slug,name] of [['csk','CSK — Centrum Szkolenia Krutla'],['synthetic-range-b','Synthetic Range B']]){
 test(`${slug} subject body CTA isolated and allowlisted`,()=>{
  const result=cancellationEmailContent({tenantId,tenantSlug:slug,publicSlug:'public-other',displayName:name,canonicalPublicUrl:'https://example.invalid'},
   {title:'Synthetic <event>',event_date:'2026-11-30',start_time:'10:00',end_time:'11:00',admin_notes:'SECRET',promotion_token:'SECRET'});
  assert.equal(result.subject,`StrzelajTu.pl / ${name} — Zapis na wydarzenie anulowany`);
  assert.ok(result.text.includes(`https://strzelajtu.pl/t/${slug}/my-events`));
  assert.ok(result.html.includes('&lt;event&gt;')); assert.ok(!JSON.stringify(result).includes('SECRET'));
  if(slug!=='csk')assert.doesNotMatch(JSON.stringify(result),/csk|krutla/i);
 });
}
test('successful receipt marked sent',async()=>assert.equal(await deliverEventCancellation(id,deps()),'sent'));
test('provider failure recorded without business rollback',async()=>{
 const d=deps();d.send=async()=>{throw Error('private provider error')};let marked=false;
 d.complete=async(_id,success)=>{assert.equal(success,false);marked=true;return response('failed')};
 assert.equal(await deliverEventCancellation(id,d),'failed');assert.equal(marked,true);
});
test('provider success marker failure is uncertain, never exactly once',async()=>{
 const d=deps();d.complete=async()=>{throw Error('marker failed')};assert.equal(await deliverEventCancellation(id,d),'uncertain');
});
for(const code of ['retired','retry_exhausted','already_sent','in_progress'])test(`${code} never sends`,async()=>{
 const d=deps();d.prepare=async()=>response(code);d.send=async()=>assert.fail('must not send');
 assert.equal(await deliverEventCancellation(id,d),code==='in_progress'?'pending':code);
});
test('forged resource or provider key fails closed',async()=>{
 for(const field of ['registration_id','tenant_id','recipient_user_id','idempotency_key']){
  const d=deps();d.prepare=async()=>({data:{...claim,[field]:'forged'},error:null});d.send=async()=>assert.fail('must not send');
  assert.equal(await deliverEventCancellation(id,d),'uncertain');
 }
});
test('receipt exception never prevents subsequent promotion',async()=>{
 const order=['cancelled'];await attemptCancellationReceipt(async()=>{order.push('email');throw Error('failure')});order.push('promotion');
 assert.deepEqual(order,['cancelled','email','promotion']);
});
test('real cancellation route calls receipt before promotion inside safe boundary',()=>{
 const source=readFileSync(new URL('../../app/api/cancel-event-registration/route.ts',import.meta.url),'utf8');
 assert.ok(source.indexOf('await attemptCancellationReceipt')>source.indexOf('if (!isCancellationRpcResult'));
 assert.ok(source.indexOf('await attemptCancellationReceipt')<source.indexOf('await promoteEventReserve'));
});
test('continuity uses separate receipt route without new promotion',()=>{
 const s=readFileSync(new URL('../../app/continuity/ContinuityPanel.tsx',import.meta.url),'utf8');
 assert.ok(s.includes('/api/send-event-cancellation'));assert.ok(!s.includes('promoteEventReserve'));
});
test('server adapter authorizes before privileged resource read',()=>{
 const s=readFileSync(new URL('./event-cancellation-email.ts',import.meta.url),'utf8');
 assert.match(s,/import "server-only"/);assert.ok(s.indexOf('prepare:')<s.indexOf('db.from('));
 for(const binding of ['.eq("tenant_id", claim.tenant_id)','.eq("user_id", claim.recipient_user_id)','.eq("registration_status", "cancelled")','.is("pii_anonymized_at", null)'])assert.ok(s.includes(binding));
});
