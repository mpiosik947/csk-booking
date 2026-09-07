# V1.1-03 — Admin action queues / deep links

## Inventory before implementation

- `/admin` already exposed operational cards and loaded today's reservations, monthly reservations and four upcoming events.
- The existing cards linked to unfiltered modules, so their count and the destination list were not the same operational view.
- `/admin/reservations` restored `search`, reservation `status`, `date` and `sort` from the URL, but had no payment filter and did not react to browser back/forward.
- `/admin/check-in` defaulted to today's date, but computed it as UTC and did not expose an expected/not-yet-checked-in URL preset.
- `/admin/events` used the bounded EVENTS-8B event and participant RPCs. Participant filters were local state only and became available only after selecting an event.
- There is no global PII-free event-reserve aggregate/list contract. A correct global reserve count cannot be guaranteed without backend work.

## Implementation

### Dashboard

The existing `Wymaga uwagi` section now contains four whole-card links:

1. `Oczekiwani dzisiaj` — confirmed visits for today whose attendance is `planned` or null.
2. `Nieopłacone` — today's confirmed reservations whose canonical payment status is `unpaid`.
3. `Lista rezerwowa eventów` — opens Events with the existing participant `reserve` preset prepared.
4. `Dzisiejsze rezerwacje` — every reservation with today's Warsaw date.

Counts are shown only where the dashboard data and destination filters have identical semantics. The event-reserve card intentionally has no count because the current bounded event list cannot provide a correct global reserve aggregate.

### Deep-link contracts

```text
/admin/check-in?date=YYYY-MM-DD&attendance=expected&page=1
/admin/reservations?date=YYYY-MM-DD&status=confirmed&payment=unpaid&page=1
/admin/events?participantStatus=reserve&participantPage=1&page=1
/admin/reservations?date=YYYY-MM-DD&page=1
```

Dates are derived explicitly in `Europe/Warsaw`. Parameters contain no PII, tokens or user IDs. Invalid dates/statuses/payment values fail safe to existing defaults. Reservation and participant filter changes reset `page` to 1, and URL state is reapplied on browser history navigation.

### Queue behavior

- Check-in exposes `Wszystkie` and `Oczekiwani`; checked-in, completed and cancelled rows do not enter the expected queue.
- Reservations exposes a URL-backed canonical payment-status filter and combines it with the existing date and reservation-status filters.
- Events restores the `reserve` participant preset, then applies it through `admin_list_event_registrations_v1` after an operator opens one event. The browser still receives one bounded participant page (maximum 50), not every participant list.
- The event queue is therefore intentionally **PARTIAL**: it is a safe deep-link preset, not a global list of events with reserve counts.

## Authorization and security

- The queue section remains restricted to `admin` and `pracownik`, matching existing module access.
- Ordinary users remain denied by the existing admin route policy.
- No table policy, RLS, ACL, RPC, SQL or migration was changed.
- No service-role code or browser-side privileged access was added.
- No PII is rendered on the queue cards or encoded in the links.

## Mobile UX

The queue grid is one column at narrow widths and two columns from the existing medium breakpoint. Cards retain full clickable areas, minimum touch height and keyboard focus styling. Local Playwright passed without document-level horizontal overflow at 320, 375 and 430 px.

## Tests

- Focused action queues plus Reservations/Check-in/Events: **55/55 PASS**.
- All Node tests: **722/722 PASS**.
- Playwright `admin-action-queues.spec.ts`: **4/4 PASS** against `http://127.0.0.1:54321` only.
- TypeScript `tsc --noEmit`: **PASS**.
- Production build (Next.js 16.3.4): **PASS**.
- `npm audit --omit=dev`: **PASS — 0 vulnerabilities**.
- Changed-files ESLint: **0 errors**; two unchanged hook warnings remain in the pre-existing dashboard/check-in effects.
- `git diff --check`: **PASS**.
- Database tests: not required; no SQL/RPC/RLS/ACL changes.

## Files changed

- `app/admin/page.tsx`
- `app/admin/reservations/page.tsx`
- `app/admin/check-in/page.tsx`
- `app/admin/events/page.tsx`
- `app/admin/admin-operational-ui.test.mjs`
- `app/admin/admin-action-queues.test.mjs`
- `lib/admin/action-queues.js`
- `lib/admin/action-queues.d.ts`
- `lib/admin/action-queues.test.mjs`
- `tests/e2e/admin-action-queues.spec.ts`
- `V1_1_03_ADMIN_ACTION_QUEUES_IMPLEMENTATION_REPORT.md`

## Final result

```text
V1.1-03 ADMIN ACTION QUEUES:
PARTIAL

EXPECTED TODAY:
PASS

UNPAID:
PASS

EVENT RESERVE QUEUE:
PARTIAL

TODAY RESERVATIONS:
PASS

DEEPLINK / URL STATE:
PASS

COUNT CONSISTENCY:
PASS

MOBILE UX:
PASS

AUTHORIZATION:
PASS

RESERVATIONS REGRESSION:
PASS

CHECK-IN REGRESSION:
PASS

EVENTS REGRESSION:
PASS

DB CHANGE REQUIRED:
NO

DEPLOYMENT MODEL:
APP ONLY
```
