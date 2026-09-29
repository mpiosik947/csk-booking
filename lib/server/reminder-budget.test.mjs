import test from 'node:test';
import assert from 'node:assert/strict';
import { Resend } from 'resend';
import { boundedOperation, emptyReminderBody, HANDLER_BUDGET_MS, MAX_CLAIMS_PER_RUN, DELIVERY_BUDGET_MS, DB_OPERATION_TIMEOUT_MS, FINISH_MARGIN_MS } from './reminder-budget.ts';
import { runReminders } from './reminder-core.ts';

const id='11111111-1111-4111-8111-111111111111';
const claim={claim_id:id,occurrence_id:id,idempotency_key:`booking_reminder_24h/${id}`};
const payload={kind:'booking_reminder_24h',...claim,recipient:'synthetic@example.invalid',title:'Test',date:'2027-01-01',start:'10:00',end:'11:00',location:null,tenant_slug:'range-b',display_name:'Range B'};

test('empty stream accepted, JSON body rejected, hanging body bounded',async()=>{
  assert.equal(await emptyReminderBody(new Request('http://localhost',{method:'POST'})),true);
  assert.equal(await emptyReminderBody(new Request('http://localhost',{method:'POST',body:new ReadableStream({start(c){c.close();}}),duplex:'half'})),true);
  assert.equal(await emptyReminderBody(new Request('http://localhost',{method:'POST',body:'{}'})),false);
  await assert.rejects(emptyReminderBody(new Request('http://localhost',{method:'POST',body:new ReadableStream(),duplex:'half'}),20));
});

test('worst-case budget fits five deliveries, not twenty-five',()=>{
  const total=2*DB_OPERATION_TIMEOUT_MS+MAX_CLAIMS_PER_RUN*DELIVERY_BUDGET_MS;
  assert.equal(total,110000);
  assert.ok(total+FINISH_MARGIN_MS<=HANDLER_BUDGET_MS);
  assert.ok(HANDLER_BUDGET_MS<180000 && 180000<300000);
});
test('nearly exhausted discovery never claims',async()=>{
  let now=0; const calls=[];
  await runReminders({now:()=>now,rpc:async name=>{calls.push(name);now=119000;return{data:0,error:null};},send:async()=>{throw Error('must not send');}});
  assert.deepEqual(calls,['discover_reminders_v1']);
});
test('five worst-case slots finish at 110s with 10s reserve',async()=>{
  let now=0;
  const result=await runReminders({now:()=>now,rpc:async name=>{
    now+=5000;
    return{error:null,data:name==='discover_reminders_v1'?100:name==='claim_reminders_v1'?Array(5).fill(claim):name==='final_check_reminder_v1'?payload:true};
  },send:async()=>{now+=10000;return{id:'provider'};}});
  assert.equal(result.sent,5);assert.equal(now,110000);
});
test('backlog stops cleanly after unexpected scheduling delay',async()=>{
  let now=0,sends=0;
  const result=await runReminders({now:()=>now,rpc:async name=>({error:null,data:name==='discover_reminders_v1'?5:name==='claim_reminders_v1'?[claim,claim]:name==='final_check_reminder_v1'?payload:true}),send:async()=>{sends++;now=119000;return{id:'provider'};}});
  assert.equal(sends,1);assert.equal(result.sent,1);
});
test('operation timeout aborts transport without exposing details',async()=>{
  let signal;
  const start=performance.now();
  await assert.rejects(boundedOperation(s=>{signal=s;return new Promise(()=>{});},20),/Reminder operation timed out/);
  assert.equal(signal.aborted,true);assert.ok(performance.now()-start<1000);
});
test('Resend SDK forwards abort and stable idempotency to fetch',async()=>{
  const original=globalThis.fetch;
  let observed;
  try {
    globalThis.fetch=async(_url,options)=>{observed=options;return new Response(JSON.stringify({id:'fake'}),{status:200});};
    const signal=new AbortController().signal;
    await new Resend('fake-local-key').emails.send({from:'test@example.invalid',to:'test@example.invalid',subject:'fake',text:'fake'},{idempotencyKey:claim.idempotency_key,signal});
    assert.equal(observed.signal,signal);
    assert.equal(new Headers(observed.headers).get('idempotency-key'),claim.idempotency_key);
  }finally{globalThis.fetch=original;}
});
test('provider timeout never marks sent and keeps stable retry identity',async()=>{
  let completion, signal;
  const result=await runReminders({rpc:async(name,args)=>{
    if(name==='complete_reminder_v1') completion=args;
    return{error:null,data:name==='discover_reminders_v1'?1:name==='claim_reminders_v1'?[claim]:name==='final_check_reminder_v1'?payload:true};
  },send:async(_p,_c,s)=>{signal=s;return new Promise(()=>{});}});
  assert.equal(signal.aborted,true);
  assert.equal(completion.p_success,false);
  assert.equal(completion.p_provider_message_id,null);
  assert.equal(result.sent,0);assert.equal(result.failed,1);
});
