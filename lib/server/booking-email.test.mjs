import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { operationalEmailBrand, operationalEmailHistoryUrl } from './operational-email-core.ts';
import { escapeHtml, escapeEmailHref } from './email-html.ts';
import { renderEmailExpression } from '../../tests/fixtures/operational-email-render.mjs';

const tenants = [
  { displayName: 'CSK — Centrum Szkolenia Krutla', tenantSlug: 'csk', publicSlug: 'csk-krutla' },
  { displayName: 'Synthetic Range B', tenantSlug: 'synthetic-b', publicSlug: 'synthetic-range-b' },
];
const source = kind => readFileSync(new URL(`../../app/api/send-reservation-${kind}/route.ts`, import.meta.url), 'utf8');

// Render the actual endpoint templates, not a second copy of their HTML.
export function previewBookingEmail(tenant, kind, staff = false) {
  const brand = operationalEmailBrand(tenant, kind === 'confirmation' ? 'Potwierdzenie rezerwacji' : 'Rezerwacja anulowana');
  const reservationsUrl = operationalEmailHistoryUrl(tenant, 'reservations');
  const values = {
    tenant, brand, reservationsUrl,
    reservation: { pricing_rule_label: 'Poniedziałek–czwartek', price: 100 },
    displayName: 'Osobo testowa', formattedDate: '15 października 2026',
    startTime: '10:00', endTime: '11:00', laneName: 'Oś testowa', formattedPrice: '100.00 zł',
    checkInUrl: 'https://strzelajtu.pl/check-in/11111111-1111-4111-8111-111111111111',
    cancelledByText: staff ? 'Rezerwacja została anulowana przez obsługę obiektu.' : 'Twoja rezerwacja została anulowana.',
    safeTenantName: escapeHtml(tenant.displayName), safeReservationsUrl: escapeEmailHref(reservationsUrl),
  };
  for (const key of ['displayName', 'formattedDate', 'startTime', 'endTime', 'laneName', 'formattedPrice']) {
    values[`safe${key[0].toUpperCase()}${key.slice(1)}`] = escapeHtml(values[key]);
  }
  values.safeCheckInUrl = escapeEmailHref(values.checkInUrl);
  const render = name => renderEmailExpression(source(kind), name, values);
  return { subject: brand.subject, html: render('html'), text: render('text'), cta: reservationsUrl };
}

for (const [index, tenant] of tenants.entries()) for (const [kind, staff] of [['confirmation', false], ['cancellation', false], ['cancellation', true]]) {
  test(`actual booking template tenant ${index + 1}, ${kind}, staff=${staff}`, () => {
    const mail = previewBookingEmail(tenant, kind, staff);
    const label = kind === 'confirmation' ? 'Potwierdzenie rezerwacji' : 'Rezerwacja anulowana';
    assert.equal(mail.subject, `StrzelajTu.pl / ${tenant.displayName} — ${label}`);
    assert.ok(mail.text.includes(`StrzelajTu.pl\n${tenant.displayName}`));
    assert.ok(mail.html.includes(escapeHtml(tenant.displayName)));
    assert.ok(mail.text.includes(`Obiekt: ${tenant.displayName}`));
    assert.match(mail.text, /Status: (Potwierdzona|Anulowana)/);
    assert.equal(mail.cta, `https://strzelajtu.pl/t/${tenant.tenantSlug}/my-reservations`);
    assert.ok(mail.html.includes(`href="${mail.cta}"`));
    assert.match(mail.text, /10:00 - 11:00/);
    assert.match(mail.text, /Oś testowa/);
    if (kind === 'confirmation') assert.match(mail.text, /100.00 zł, płatność na miejscu/);
    if (staff) assert.match(mail.text, /przez obsługę obiektu/);
    if (index === 1) assert.doesNotMatch(JSON.stringify(mail), /CSK|csk-krutla|\/t\/csk|Centrum Szkolenia Krutla/);
    else assert.doesNotMatch(JSON.stringify(mail), /Synthetic Range B|synthetic-b/);
    assert.doesNotMatch(JSON.stringify(mail), /tenant_id|admin_notes|billing|membership/);
    assert.doesNotMatch(JSON.stringify(mail), /Poniedziałek–czwartek|pricing_rule_label/);
  });
}

test('tenant HTML is escaped; unsafe header and route values fail closed', () => {
  const mail = previewBookingEmail({ ...tenants[1], displayName: 'Range <img src=x>' }, 'cancellation');
  assert.doesNotMatch(mail.html, /<img src=x>/);
  assert.match(mail.html, /&lt;img src=x&gt;/);
  assert.throws(() => previewBookingEmail({ ...tenants[1], displayName: 'X\r\nBcc: victim' }, 'confirmation'));
  assert.throws(() => previewBookingEmail({ ...tenants[1], tenantSlug: '../evil' }, 'confirmation'));
});

for (const kind of ['confirmation', 'cancellation']) test(`${kind}: strict payload, authorized resource before resolver, shared delivery`, () => {
  const code = source(kind);
  assert.match(code, /(?:bodyKeys|Object\.keys\(parsedBody\))\.length !== 1/);
  if (kind === 'confirmation') assert.match(code, /\.eq\("id", reservationId\)/);
  else assert.match(code, /"get_reservation_cancellation_email_v1", \{ p_reservation_id: reservationId \}/);
  const gate = kind === 'confirmation' ? '.eq("user_id", user.id)' : 'if (reservationError)';
  assert.ok(code.indexOf(gate) < code.indexOf('await resolveReservationEmailTenantContext(reservationId)'));
  assert.match(code, /if \(!reservationData\)/);
  assert.match(code, /operationalEmailHistoryUrl\(tenant, "reservations"\)/);
  assert.match(code, /deliverConfirmationEmail\(\{/);
  assert.match(code, /\{ idempotencyKey \}/);
  assert.doesNotMatch(code, /\.update\(|\.insert\(|\.delete\(|CSK|Krutla|window\.location|x-forwarded-host/);
});
