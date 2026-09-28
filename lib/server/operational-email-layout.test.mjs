import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { previewOperationalEmail, previewKinds, previewTenants } from '../../tests/fixtures/operational-email-previews.mjs';

for (const tenant of previewTenants) for (const kind of previewKinds) test(`${tenant.tenantSlug} ${kind}: actual renderer uses shared compatible shell`, () => {
  const mail = previewOperationalEmail(tenant, kind);
  assert.match(mail.html, /data-operational-email="strzelajtu"/);
  assert.match(mail.html, /https:\/\/strzelajtu.pl\/brand\/strzelajtu\/logo-horizontal.png/);
  assert.match(mail.html, /alt="StrzelajTu.pl"/);
  assert.match(mail.html, /System rezerwacji strzelnic/);
  assert.ok(mail.subject.startsWith(`StrzelajTu.pl / ${tenant.displayName} — `));
  assert.ok(mail.html.includes(tenant.displayName));
  assert.ok(mail.text.includes(tenant.displayName));
  assert.match(mail.html, /max-width:600px/);
  assert.match(mail.html, /table-layout:fixed/);
  assert.match(mail.html, /<!--\[if mso\]>/);
  assert.match(mail.html, /overflow-wrap:anywhere/);
  assert.match(mail.html, /bgcolor="#F5A900"/);
  assert.doesNotMatch(mail.html, /<script|<link|<style|display:(?:flex|grid)|data:image|@import|@font-face/);
  assert.doesNotMatch(mail.html + mail.text, /Poniedziałek–czwartek|pricing_rule|admin_notes|tenant_id|membership|billing|service_role|auth_token|synthetic@example.invalid/);
  const links = [...mail.html.matchAll(/href="([^"]+)"/g)].map(match => match[1]);
  assert.ok(links.length >= 1);
  for (const link of links) assert.ok(mail.text.includes(link), `unchanged CTA ${link} also in text fallback`);
  if (tenant.tenantSlug === 'synthetic-b') assert.doesNotMatch(JSON.stringify(mail), /csk|krutla/i);
  if (kind === 'booking-confirmation') assert.match(mail.html, /100.00 zł, płatność na miejscu/);
  if (kind === 'event-waitlist') assert.match(mail.html, /Lista rezerwowa/);
});

test('shared layout is pure presentation with no clients, secrets or tenant fallback', () => {
  const source = readFileSync(new URL('./operational-email-layout.ts', import.meta.url), 'utf8');
  assert.doesNotMatch(source, /process\.env|fetch\(|createClient|Resend|SUPABASE|SECRET|CSK|Krutla|recipient|tenantId|tenantSlug/);
  assert.match(source, /escapeEmailHref\(url\)/);
});
