import test from 'node:test';
import assert from 'node:assert/strict';
import {reminderContent,validReminderSecret,runReminders} from './reminder-core.ts';
const id='11111111-1111-4111-8111-111111111111';
const payload=(kind,brand='Synthetic Range B',slug='range-b')=>({kind,occurrence_id:id,idempotency_key:`${kind}/${id}`,recipient:'synthetic@example.invalid',title:'Test',date:'2027-03-28',start:'10:00:00',end:'11:00:00',location:'Tor 1',tenant_slug:slug,display_name:brand});
for(const kind of ['booking_reminder_24h','event_reminder_24h'])for(const [brand,slug] of [['CSK — Centrum Szkolenia Krutla','csk'],['Synthetic Range B','range-b']])
test(`${kind} ${slug} branding`,()=>{const p=payload(kind,brand,slug),c=reminderContent(p);assert.match(c.subject,new RegExp(`StrzelajTu.pl / ${brand}`));assert.ok(c.text.includes(`/t/${slug}/my-`));if(slug==='range-b')assert.doesNotMatch(JSON.stringify(c),/csk|krutla/i);});
test('dedicated secret fails closed',()=>{for(const header of [null,'','Bearer short','Bearer wrong'])assert.equal(validReminderSecret(header,'x'.repeat(32)),false);assert.equal(validReminderSecret('Bearer '+'x'.repeat(32),'x'.repeat(32)),true);assert.equal(validReminderSecret('Bearer short','short'),false);});
for(const scenario of ['sent','cancelled','provider-failed','marker-failed','rescheduled'])test(scenario,async()=>{
const p=payload('booking_reminder_24h');let sends=0;const keys=[];
const result=await runReminders({rpc:async(name)=>({error:null,data:name==='discover_reminders_v1'?1:name==='claim_reminders_v1'?[{claim_id:id,occurrence_id:id,idempotency_key:p.idempotency_key}]:name==='final_check_reminder_v1'?(['cancelled','rescheduled'].includes(scenario)?null:p):scenario!=='marker-failed'}),send:async(p)=>{sends++;keys.push(p.idempotency_key);if(scenario==='provider-failed')throw Error('redacted');return{id:'provider-1'};}});
if(['cancelled','rescheduled'].includes(scenario)){assert.equal(sends,0);assert.equal(result.skipped,1);}else{assert.deepEqual(keys,[p.idempotency_key]);assert.equal(result[scenario==='sent'?'sent':scenario==='marker-failed'?'uncertain':'failed'],1);}
});
test('untrusted claim identity cannot send',async()=>{let sends=0;const p=payload('event_reminder_24h');const r=await runReminders({rpc:async(name)=>({error:null,data:name==='discover_reminders_v1'?0:name==='claim_reminders_v1'?[{claim_id:id,occurrence_id:id,idempotency_key:'forged'}]:name==='final_check_reminder_v1'?p:true}),send:async()=>{sends++;return{id:'x'};}});assert.equal(sends,0);assert.equal(r.failed,1);});
