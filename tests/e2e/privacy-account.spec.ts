import { randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { expect, test } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { getLocalSupabaseTestEnvironment } from './local-supabase';

const env = getLocalSupabaseTestEnvironment();
const db = process.env.PRIVACY_TECH_DATABASE || '';
if (!/^privacy_tech_[0-9a-f]{16}$/.test(db)) throw Error('Disposable privacy DB required');
const service = createClient(env.supabaseUrl, env.serviceRoleKey, { auth: { persistSession: false, autoRefreshToken: false } });
function sql(statement: string) {
  return execFileSync('docker', ['exec', '-i', 'supabase_db_csk-booking', 'psql', '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', db], { input: statement, encoding: 'utf8' }).trim();
}
function one(statement: string) { return JSON.parse(sql(statement).split(/\r?\n/).filter(line => line.startsWith('{')).at(-1)!); }
function row(table: string, id: string) { return one(`select to_jsonb(r) from public.${table} r where id='${id}';`); }
function profile(id: string) { return one(`select to_jsonb(r) from public.profiles r where user_id='${id}';`); }

test('real Next/Auth export and delete: multi-tenant instructor, suspended domain, failure/retry, last-admin, ordinary user', async ({ request, page }) => {
  const run = randomUUID(); const password = `Local-${run}!Aa9`;
  const users: string[] = []; const tokens: string[] = []; const emails: string[] = [];
  for (const label of ['own', 'foreign', 'last', 'ordinary', 'staff']) {
    const email = `${label}-${run}@example.invalid`; emails.push(email);
    const made = await service.auth.admin.createUser({ email, password, email_confirm: true });
    if (made.error || !made.data.user) throw Error('Synthetic local user creation failed');
    users.push(made.data.user.id);
    const client = createClient(env.supabaseUrl, env.anonKey, { auth: { persistSession: false } });
    const login = await client.auth.signInWithPassword({ email, password });
    if (login.error || !login.data.session) throw Error('Synthetic local sign-in failed');
    tokens.push(login.data.session.access_token);
  }
  const source = readFileSync('supabase/tests/20261026100000_account_export_v3_and_domain_cleanup_test.sql', 'utf8');
  const helpers = source.match(/-- BEGIN privacy fixture helpers[^\n]*\n([\s\S]*?)-- END privacy fixture helpers/)![1];
  const ids = one(`begin; ${helpers}\nselect pg_temp.privacy_fixture('${users[0]}','${users[1]}','${users[2]}','${users[3]}','${users[4]}');\ncommit;`) as Record<string, string>;
  const auth = (i: number) => ({ Authorization: `Bearer ${tokens[i]}` });
  const response = await request.get('/api/account/export', { headers: auth(0) });
  expect(response.status()).toBe(200); expect(response.headers()['cache-control']).toContain('no-store');
  expect(response.headers()['content-disposition']).toContain('csk-booking-my-data.json');
  const data = await response.json();
  expect(data.export_version).toBe(3);
  expect(data.reservations).toHaveLength(2); expect(data.event_registrations).toHaveLength(3);
  expect(data.event_registrations.find((r: { id: string }) => r.id === ids.gn).event).toBeNull();
  expect(data.platform_audit_history).toHaveLength(2);
  expect(data.platform_audit_history.find((r: { action: string }) => r.action === 'platform_admin_bootstrapped').tenant).toBeNull();
  expect(data.event_instructors).toHaveLength(2); expect(data.reminder_schedules).toHaveLength(4); expect(data.reminder_occurrences).toHaveLength(4);
  expect(data.external_settlements).toHaveLength(1); expect(data.tenant_domain_requests).toHaveLength(1);
  const text = JSON.stringify(data);
  const syntheticPasswordHash = sql(`select encrypted_password from auth.users where id='${users[0]}';`);
  expect(syntheticPasswordHash.length).toBeGreaterThan(20); expect(text).not.toContain(syntheticPasswordHash);
  for (const sentinel of [users[1], users[4], emails[1], 'foreign@example.invalid', '500999888', 'FOREIGN_PRIVATE_PERSON', 'NEVER_', ids.rf, ids.gf]) expect(text).not.toContain(sentinel);
  for (const entry of data.audit_history) { expect(entry).not.toHaveProperty('action'); expect(entry).not.toHaveProperty('details'); }
  for (const key of ['promotion_token', 'check_in_token', 'recovery_token', 'confirmation_token', 'encrypted_password', 'claim_id', 'claim_expires_at', 'provider_message_id', 'service_key', 'details']) expect(text).not.toMatch(new RegExp(`"${key}"\\s*:`));
  expect((await request.get('/api/account/export')).status()).toBe(401);
  for (const parameter of ['user_id', 'tenant_id', 'resource_id']) expect((await request.get(`/api/account/export?${parameter}=${users[1]}`, { headers: auth(0) })).status()).toBe(400);
  const normalName = profile(users[0]);
  // profiles.id equals the Auth fixture id; use a bounded synthetic text solely for capacity testing.
  sql(`update public.profiles set full_name=repeat('x',2097153) where user_id='${users[0]}';`);
  const oversized = await request.get('/api/account/export', { headers: auth(0) });
  expect(oversized.status()).toBe(413); expect((await oversized.json()).code).toBe('export_too_large');
  expect(oversized.headers()['cache-control']).toContain('no-store');
  sql(`update public.profiles set full_name='${normalName.full_name}' where user_id='${users[0]}';`);
  const domain = row('tenant_domains', ids.domain); const foreignDomain = row('tenant_domains', ids.foreign_domain);
  const foreignReservation = row('reservations', ids.rf); const attendance = row('event_registrations', ids.gf);
  const settlement = row('external_settlement_records', ids.settlement); const foreignSettlement = row('external_settlement_records', ids.foreign_settlement);
  const instructorHistory = one(`select jsonb_build_object('rows',jsonb_agg(to_jsonb(i))) from public.event_instructors i where event_id in('${ids.ea}','${ids.eb}');`).rows;
  const foreignDeliveries = one(`select jsonb_build_object('rows',jsonb_agg(to_jsonb(d) order by id)) from public.email_deliveries d where recipient_user_id='${users[1]}';`).rows;
  const lastProfile = profile(users[2]);
  const denied = await request.post('/api/account/delete', { headers: auth(2), data: { confirmation: 'USUŃ KONTO' } });
  expect(denied.status()).toBe(500); expect(profile(users[2])).toEqual(lastProfile);
  expect(sql(`select count(*) from auth.users where id='${users[2]}';`)).toBe('1');
  sql(`update public.tenants set status='suspended' where id='${ids.b}';`);
  expect((await request.post(`${env.supabaseUrl}/__privacy-test/fail-auth-delete/${users[0]}`)).status()).toBe(204);
  const pending = await request.post('/api/account/delete', { headers: auth(0), data: { confirmation: 'USUŃ KONTO' } });
  expect(pending.status()).toBe(503); expect((await pending.json()).code).toBe('auth_deletion_pending');
  expect(sql(`select count(*) from auth.users where id='${users[0]}';`)).toBe('1');
  expect(sql(`select count(*) from public.profiles where user_id='${users[0]}';`)).toBe('0');
  const auditCount = sql("select count(*) from public.audit_logs where action='account_anonymized';");
  const deleted = await request.post('/api/account/delete', { headers: auth(0), data: { confirmation: 'USUŃ KONTO' } });
  expect(deleted.status()).toBe(200); expect((await deleted.json()).code).toBe('deleted');
  expect(sql("select count(*) from public.audit_logs where action='account_anonymized';")).toBe(auditCount);
  expect((await (await request.get(`${env.supabaseUrl}/__privacy-test/status`)).json()).failedDeletes).toBe(1);
  expect(sql(`select count(*) from auth.users where id='${users[0]}';`)).toBe('0');
  for (const id of [ids.ra, ids.rb]) {
    const retained = row('reservations', id); expect(retained.user_id).toBeNull(); expect(retained.pii_anonymized_at).not.toBeNull();
    expect(retained.customer_email).toMatch(/@invalid\.local$/); expect(retained.check_in_token).toBeNull(); expect(retained.reservation_note).toBeNull();
  }
  for (const id of [ids.ga, ids.gb, ids.gn]) {
    const retained = row('event_registrations', id); expect(retained.user_id).toBeNull(); expect(retained.pii_anonymized_at).not.toBeNull();
    expect(retained.customer_email).toMatch(/@invalid\.local$/); expect(retained.promotion_token).toBeNull();
  }
  for (const prior of instructorHistory) {
    const expected = { ...prior };
    for (const key of ['instructor_user_id', 'assigned_by', 'unassigned_by']) if (expected[key] === users[0]) expected[key] = null;
    expect(row('event_instructors', prior.id)).toEqual(expected);
  }
  expect(one(`select jsonb_build_object('rows',jsonb_agg(to_jsonb(d) order by id)) from public.email_deliveries d where recipient_user_id='${users[1]}';`).rows).toEqual(foreignDeliveries);
  const afterDomain = row('tenant_domains', ids.domain); expect(afterDomain.verification_requested_by).toBeNull();
  expect({ ...afterDomain, verification_requested_by: domain.verification_requested_by }).toEqual(domain);
  expect(row('tenant_domains', ids.foreign_domain)).toEqual(foreignDomain);
  expect(row('reservations', ids.rf)).toEqual(foreignReservation);
  const afterAttendance = row('event_registrations', ids.gf); expect(afterAttendance.attendance_marked_by).toBeNull();
  expect({ ...afterAttendance, attendance_marked_by: attendance.attendance_marked_by }).toEqual(attendance);
  const afterSettlement = row('external_settlement_records', ids.settlement);
  expect(afterSettlement.actor_user_id).not.toBe(users[0]); expect(afterSettlement.external_reference).toBe('[redacted]');
  expect({ ...afterSettlement, actor_user_id: settlement.actor_user_id, external_reference: settlement.external_reference }).toEqual(settlement);
  expect(row('external_settlement_records', ids.foreign_settlement)).toEqual(foreignSettlement);
  expect(sql(`select count(*) from public.event_instructors where instructor_user_id='${users[0]}' or assigned_by='${users[0]}' or unassigned_by='${users[0]}';`)).toBe('0');
  expect(sql(`select count(*) from public.event_instructors where event_id in('${ids.ea}','${ids.eb}');`)).toBe('2');
  expect(sql(`select count(*) from public.email_deliveries where recipient_user_id='${users[0]}';`)).toBe('0');
  expect(Number(sql(`select count(*) from public.email_deliveries where recipient_user_id='${users[1]}';`))).toBeGreaterThan(0);
  expect(sql(`select count(*) from public.tenant_memberships where user_id='${users[0]}';`)).toBe('0');
  expect(sql(`select count(*) from public.audit_logs where actor_user_id='${users[0]}' or target_id='${users[0]}' or details->>'user_id'='${users[0]}';`)).toBe('0');
  expect(sql(`select count(*) from public.platform_audit_logs where actor_user_id='${users[0]}' or details->>'user_id'='${users[0]}';`)).toBe('0');
  expect(Number(sql(`select count(*) from public.reminder_occurrences where reservation_id='${ids.ra}';`))).toBe(1);
  // Exercise actual browser download for a normal account, then its real endpoint deletion.
  await page.goto('/login?redirectTo=%2Faccount'); await page.getByLabel('E-mail').fill(emails[3]); await page.getByLabel('Hasło').fill(password);
  await page.getByRole('button', { name: 'Zaloguj się' }).click(); await expect(page).toHaveURL(/\/account$/);
  const downloadPromise = page.waitForEvent('download'); await page.getByRole('button', { name: /Eksportuj|Pobierz.*dane/i }).click();
  const download = await downloadPromise; expect(download.suggestedFilename()).toBe('csk-booking-my-data.json');
  const downloaded = JSON.parse(readFileSync((await download.path())!, 'utf8')); expect(downloaded.export_version).toBe(3);
  const normalDelete = await request.post('/api/account/delete', { headers: auth(3), data: { confirmation: 'USUŃ KONTO' } });
  expect(normalDelete.status()).toBe(200); expect(sql(`select count(*) from auth.users where id='${users[3]}';`)).toBe('0');
});
