import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { Resend } from 'resend';
import { getOperationalEmailSenderConfiguration as config } from './operational-email-config.ts';

const env = { RESEND_API_KEY: 'fake-local-key', RESERVATION_EMAIL_FROM: 'StrzelajTu.pl <rezerwacje@strzelajtu.pl>', RESERVATION_EMAIL_REPLY_TO: 'strzelajTu@gmail.com', VERCEL_ENV: 'production' };
test('central target headers; optional Reply-To preserves old Production configuration', () => {
  assert.equal(config(env).replyTo, env.RESERVATION_EMAIL_REPLY_TO);
  assert.equal(config(env).from, env.RESERVATION_EMAIL_FROM);
  const old = config({ RESERVATION_EMAIL_FROM: 'StrzelajTu.pl <rezerwacje@krutla.pl>' });
  assert.equal(old.from, 'StrzelajTu.pl <rezerwacje@krutla.pl>');
  assert.equal(old.replyTo, undefined);
});
for (const value of ['', 'bad', 'a@b', 'a@example.com,b@example.com', 'Name <a@example.com>', 'a@example.com\r\nBcc:b@example.com', 'a@example.com\n', 'a@-example.com']) {
  test('invalid Reply-To disables sending: '+JSON.stringify(value), () => assert.equal(config({...env, RESERVATION_EMAIL_REPLY_TO:value}).from, undefined));
}
test('Preview cannot send even with complete provider configuration; development needs no provider', () => {
  assert.equal(config({...env, VERCEL_ENV:'preview'}).from, undefined);
  assert.equal(config({VERCEL_ENV:'development'}).from, undefined);
  assert.equal(config({VERCEL_ENV:'development'}).resendApiKey, undefined);
});
test('mock Resend serializes one central Reply-To and preserves provider identity for Tenant A/B', async () => {
  const originalFetch = globalThis.fetch;
  const requests=[];
  globalThis.fetch=async (_url, init) => {
    requests.push({body:JSON.parse(init.body), headers:new Headers(init.headers)});
    return new Response(JSON.stringify({id:'synthetic-provider-id'}), {status:200,headers:{'content-type':'application/json'}});
  };
  try {
    const {from,replyTo,resendApiKey}=config(env);
    for(const tenant of ['Range A','Synthetic Range B']) {
      await new Resend(resendApiKey).emails.send({from,replyTo,to:'test@example.invalid',subject:`StrzelajTu.pl / ${tenant} — Test`,text:tenant},{idempotencyKey:`synthetic/${tenant}`});
    }
    for(const request of requests) {
      assert.equal(request.body.from,env.RESERVATION_EMAIL_FROM);
      assert.equal(request.body.reply_to,env.RESERVATION_EMAIL_REPLY_TO);
      assert.equal(request.headers.get('idempotency-key'),`synthetic/${request.body.text}`);
      assert.doesNotMatch(JSON.stringify(request.body),/CSK|krutla/i);
    }
    assert.equal(requests.length,2);
  } finally {globalThis.fetch=originalFetch;}
});
const sources=[
  '../../app/api/send-reservation-confirmation/route.ts',
  '../../app/api/send-reservation-cancellation/route.ts',
  '../../app/api/send-event-registration-confirmation/route.ts',
  './event-cancellation-email.ts','./event-wide-cancellation.ts',
  './event-reserve-promotion.ts','./event-reserve-confirmation-email.ts',
  './instructor-email.ts','../../app/api/internal/reminders/route.ts',
];
for(const path of sources) test('sender wired to central Reply-To: '+path,()=>{
  const source=readFileSync(new URL(path,import.meta.url),'utf8');
  assert.match(source,/replyTo/);
  assert.doesNotMatch(source,/strzelajTu@gmail\.com|RESERVATION_EMAIL_REPLY_TO/);
  assert.match(source,/getOperationalEmailSenderConfiguration|getConfirmationEmailConfiguration/);
});
