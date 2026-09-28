import { readFileSync } from 'node:fs';
import { operationalEmailBrand, operationalEmailHistoryUrl, operationalEmailActionUrl } from '../../lib/server/operational-email-core.ts';
import { reminderContent } from '../../lib/server/reminder-core.ts';
import { cancellationEmailContent } from '../../lib/server/event-cancellation-email-core.ts';
import { renderEmailExpression } from './operational-email-render.mjs';

export const previewTenants = [
  { tenantId: '11111111-1111-4111-8111-111111111111', tenantSlug: 'csk', publicSlug: 'csk-krutla', displayName: 'CSK — Centrum Szkolenia Krutla', canonicalPublicUrl: 'https://strzelajtu.pl/csk-krutla' },
  { tenantId: '22222222-2222-4222-8222-222222222222', tenantSlug: 'synthetic-b', publicSlug: 'synthetic-range-b', displayName: 'Synthetic Range B', canonicalPublicUrl: 'https://strzelajtu.pl/synthetic-range-b' },
];
export const previewKinds = ['booking-confirmation', 'booking-cancellation', 'event-registration', 'event-waitlist', 'event-cancellation', 'reserve-promotion', 'reserve-acceptance', 'booking-reminder', 'event-reminder'];

export function previewOperationalEmail(tenant, kind) {
  const id = '33333333-3333-4333-8333-333333333333';
  if (kind.endsWith('-reminder')) {
    const type = kind === 'booking-reminder' ? 'booking_reminder_24h' : 'event_reminder_24h';
    return reminderContent({ kind: type, occurrence_id: id, idempotency_key: `${type}/${id}`,
      recipient: 'synthetic@example.invalid', title: type === 'booking_reminder_24h' ? 'Rezerwacja stanowiska' : 'Szkolenie strzeleckie — poziom podstawowy',
      date: '2026-11-30', start: '10:00', end: '11:00', location: 'Oś 25 m', tenant_slug: tenant.tenantSlug, display_name: tenant.displayName });
  }
  if (kind === 'event-cancellation') return cancellationEmailContent(tenant, { title: 'Szkolenie strzeleckie — poziom podstawowy', event_date: '2026-11-30', start_time: '10:00', end_time: '11:00' });
  const files = {
    'booking-confirmation': 'app/api/send-reservation-confirmation/route.ts',
    'booking-cancellation': 'app/api/send-reservation-cancellation/route.ts',
    'event-registration': 'app/api/send-event-registration-confirmation/route.ts',
    'event-waitlist': 'app/api/send-event-registration-confirmation/route.ts',
    'reserve-promotion': 'lib/server/event-reserve-promotion.ts',
    'reserve-acceptance': 'lib/server/event-reserve-confirmation-email.ts',
  };
  if (!files[kind]) throw Error('Unknown preview kind');
  const source = readFileSync(new URL(`../../${files[kind]}`, import.meta.url), 'utf8');
  const label = source.match(/operationalEmailBrand\(tenant, "([^"]+)"\)/)?.[1];
  if (!label) throw Error('Missing production subject');
  const brand = operationalEmailBrand(tenant, label);
  const values = { tenant, brand, displayName: 'Osobo testowa', formattedDate: '30 listopada 2026',
    startTime: '10:00', endTime: '11:00', formattedStartTime: '10:00', formattedEndTime: '11:00',
    laneName: 'Oś 25 m', location: 'Sala szkoleniowa', formattedPrice: '100.00 zł',
    eventTitle: 'Szkolenie strzeleckie — poziom podstawowy',
    formattedStatus: kind === 'event-waitlist' ? 'Lista rezerwowa' : 'Potwierdzony',
    event: { title: 'Szkolenie strzeleckie — poziom podstawowy', location: 'Sala szkoleniowa' },
    eventItem: { title: 'Szkolenie strzeleckie — poziom podstawowy', location: 'Sala szkoleniowa' },
    cancelledByText: 'Twoja rezerwacja została anulowana.', expiresAt: '29.11.2026, 18:00',
    reservationsUrl: operationalEmailHistoryUrl(tenant, 'reservations'),
    myEventsUrl: operationalEmailHistoryUrl(tenant, 'events'),
    checkInUrl: operationalEmailActionUrl('check-in', id),
    confirmUrl: operationalEmailActionUrl('events/confirm', id),
  };
  return { subject: brand.subject, html: renderEmailExpression(source, 'html', values), text: renderEmailExpression(source, 'text', values) };
}
