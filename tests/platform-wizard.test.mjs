import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readAttempt, receiptId, classifyError, slugError, identityValid, readAccount, readDetail, readPlans, storageKey } from '../lib/platform-wizard.ts';

const attempt = () => ({ version: 1, requestId: randomUUID(), payload: { p_name: 'Test', p_city: 'Testowo', p_tenant_slug: 'range-local', p_public_slug: 'range-public', p_plan_key: 'booking_only_v1', p_initial_admin_user_id: randomUUID() }, adminEmail: 'admin@example.invalid', state: 'uncertain' });
test('recovery retains the exact request and payload, scoped to actor', () => {
  const a = attempt(); assert.deepEqual(readAttempt(JSON.stringify(a)), a);
  assert.notEqual(storageKey(randomUUID()), storageKey(randomUUID()));
  for (const corrupt of ['{', JSON.stringify({ ...a, requestId: '../escape' }), JSON.stringify({ ...a, state: 'confirmed' }), JSON.stringify({ ...a, payload: { ...a.payload, extra: true } })]) assert.equal(readAttempt(corrupt), null);
});
test('receipt must bind all frozen parameters and initial state', () => {
  const a = attempt(), p = a.payload, id = randomUUID();
  const r = { tenant_id: id, creation_request_id: a.requestId, name: p.p_name, city: p.p_city, tenant_slug: p.p_tenant_slug, public_slug: p.p_public_slug, plan_key: p.p_plan_key, initial_admin_user_id: p.p_initial_admin_user_id, initial_status: 'dormant', initial_is_public: false };
  assert.equal(receiptId(r, a), id);
  for (const field of Object.keys(r)) assert.equal(receiptId({ ...r, [field]: 'wrong' }, a), null, field);
});
test('canonical identity and reserved slugs reject invalid input', () => {
  assert.equal(identityValid(' '.repeat(121)), false); assert.equal(identityValid('a'.repeat(120)), true); assert.equal(identityValid('a'.repeat(121)), false);
  for (const slug of ['admin', 'platform-admin', 'tenant-setup', 'Aaa', 'a--b', 'a', '-aa', 'aa/', 'aa-']) assert.ok(slugError(slug));
  assert.equal(slugError('range-123'), '');
});
test('safe error classes distinguish uncertain outcome from semantic denial', () => {
  for (const [error, kind] of [[{code:'23505',message:'raw SQL'},'slug'],[{code:'22023',message:'Plan unavailable'},'plan'],[{code:'22023',message:'Account cannot be assigned'},'admin'],[{code:'22023',message:'Creation request payload conflict'},'conflict'],[{code:'42501',message:'raw SQL'},'denied'],[{code:'22023',message:'raw SQL'},'invalid'],[{message:'raw SQL'},'retry']]) { const mapped=classifyError(error); assert.equal(mapped.kind,kind); assert.ok(!mapped.message.includes('raw SQL')); }
});
test('reader projections discard extra PII and reject mismatched resource', () => {
  const id=randomUUID(); assert.deepEqual(readAccount({user_id:id,email:'admin@example.invalid',phone:'secret'}),{user_id:id,email:'admin@example.invalid'});
  assert.equal(readPlans([{plan_key:'x',display_name:'X',status:'inactive',features:[]}]),null);
  const d={tenant:{tenant_id:id,name:'Range',technical_slug:'range-local',status:'dormant'},public_profile:null,plan:null,admins:[{user_id:randomUUID(),email:null,phone:'secret'},{user_id:randomUUID(),email:'second@example.invalid'}],readiness:{create_ready:false,activation_ready:false,public_ready:false,booking_ready:false,booking_required:true,publication_gate_enforced:false,checks:{admin_ready:false}},customer_data:'secret'};
  assert.equal(readDetail(d,randomUUID()),null); const parsed=readDetail(d,id); assert.equal(parsed.admins.length,2); assert.ok(!JSON.stringify(parsed).includes('secret'));
});
