# CSK Booking — EVENTS-8A implementation report

## Scope and root cause

EVENTS-8A was implemented against `main` at baseline HEAD `fdee888` without database, RPC, RLS, ACL, or migration changes.

The review found four concrete inconsistencies:

1. `/events`, `/my-events`, and `/admin/events` maintained separate Polish labels, badge styles, and action rules for the same registration statuses. In particular, `reserve` was presented both as `Rezerwowy` and `Lista rezerwowa`.
2. `/my-events` constructed the event start with `new Date("YYYY-MM-DDTHH:mm:00")`. That interpreted the wall clock in the browser timezone, while `cancel_event_registration(uuid)` evaluates `(event_date + start_time) AT TIME ZONE 'Europe/Warsaw'`. The database rejects only when the remaining time is **less than** 72 hours, so the exact 72-hour boundary is allowed.
3. The authoritative, PII-free `get_public_event_availability_v1()` response was already fetched by `/events`, but the page hid its counts from anonymous users and could still present a registration CTA after the event start.
4. `/admin/events` fetched `event_registrations` with `select('*')`, even though the participant UI uses only seven operational fields.

## Current and canonical status semantics

The current database contract was preserved:

| Status | Polish label | Occupies capacity | User cancellation | Admin approve | Admin payment | Admin cancel |
|---|---|---:|---:|---:|---:|---:|
| `registered` | Zapisany | yes | yes | yes | yes | yes |
| `approved` | Zatwierdzony | yes | yes | no | yes | yes |
| `reserve` | Lista rezerwowa | no | yes | no | yes | yes |
| `cancelled` | Anulowany | no | no | no | no | no |
| `participant` | Uczestnik | no | yes | no | no | yes |

`participant` remains an explicit transitional legacy state. Its capacity behavior was not reinterpreted: the authoritative availability and cancellation contracts count only `registered` and `approved` as occupied places. Unknown statuses fail closed, are not rendered verbatim, and expose no actions.

Payment labels in admin participant management now use the existing canonical `payment-status` mapper rather than treating every value other than `paid_on_site` as pay-on-site.

## Implementation

- Added one shared event-registration status presentation and action mapper used by public registration success, `/my-events`, and `/admin/events`.
- Added a timezone-explicit event-time helper matching PostgreSQL's Europe/Warsaw wall-clock semantics, including DST validation and the exact inclusive 72-hour cancellation boundary.
- `/my-events` now hides and rejects cancellation consistently when the status or cutoff disallows it. The backend remains authoritative.
- `/events` continues to use only `get_public_event_availability_v1()` for availability. Authoritative registered, reserve, and free-place counts are now presented consistently to anonymous and authenticated visitors. Reserve queue fairness is retained, and registration closes at the Warsaw event start.
- `/admin/events` now requests and validates exactly: `id`, `customer_name`, `customer_email`, `customer_phone`, `registration_status`, `payment_status`, and `created_at`.
- The admin DTO parser fails closed on malformed rows, duplicate registration IDs, or additional fields. It does not admit profile data, address/permit data, admin notes, user IDs, event IDs, or delivery/confirmation tokens.
- Existing Event V2 mutation RPCs, registration RPCs, reserve promotion, payment, cancellation, and confirmation flows remain unchanged.

## Availability and refresh behavior

The public page still invokes `get_public_event_availability_v1()` and does not query or count `event_registrations`. Successful registration reloads the authoritative availability. Owner cancellation updates the owner-scoped local item to the controlled `cancelled` result, and admin cancellation/promotion reloads the participant collection, so the next authoritative public read reflects the backend state. The atomic backend capacity guard remains unchanged.

## Tests

Focused Events suite:

- 137 tests passed, 0 failed.
- Covers canonical registered/approved/reserve/cancelled mappings, the legacy participant contract, payment labels, unknown-status fail-closed behavior, Warsaw winter/summer offsets, DST-invalid wall times, cancellation before/exactly at/after 72 hours, CTA alignment, public available/sold-out/reserve states, availability refresh after registration, owner cancellation state, admin refresh after reserve promotion, duplicate registration behavior, minimal participant DTO, PII rejection, authoritative RPC usage, and unchanged Event V2 mutation flows.

Full regression:

- `node --test`: 667 passed, 0 failed.
- `npx.cmd tsc --noEmit`: PASS.
- `npm.cmd run build`: PASS on Next.js 16.3.4. The pre-existing middleware-to-proxy deprecation warning remains.
- `npm.cmd audit --omit=dev`: 0 vulnerabilities.
- Changed-files ESLint: no new EVENTS-8A regressions. It reports the existing baseline within touched pages: 3 errors and 2 warnings already present in baseline HEAD (`react-hooks/static-components`, `@next/next/no-html-link-for-pages`, `@typescript-eslint/no-explicit-any`, `react-hooks/exhaustive-deps`, and the unused `getMessageClass`).
- `git diff --check`: PASS.
- DB tests were not required because no SQL, RPC, RLS, ACL, or migration changed.

## Compatibility and deployment

The change consumes existing production contracts without altering them. Old and new application builds are compatible with the current database. Deployment is application-only.

## Final status

```text
EVENTS-8A:
FULLY IMPLEMENTED

STATUS CONSISTENCY:
PASS

CANCELLATION TIME CONSISTENCY:
PASS

PUBLIC AVAILABILITY:
PASS

MINIMAL PARTICIPANT DTO:
PASS

PUBLIC EVENTS:
PASS

MY EVENTS:
PASS

ADMIN EVENTS:
PASS

PII REDUCTION:
PASS

DB CHANGE REQUIRED:
NO

DEPLOYMENT MODEL:
APP ONLY
```

## Files changed

- `app/admin/events/page.tsx`
- `app/admin/events/page.test.mjs`
- `app/events/page.tsx`
- `app/my-events/page.tsx`
- `app/my-events/page.test.mjs`
- `lib/admin/events/event-registrations.ts`
- `lib/admin/events/event-registrations.test.mjs`
- `lib/event-registration-status.ts`
- `lib/event-registration-status.test.mjs`
- `lib/event-time.ts`
- `lib/event-time.test.mjs`
- `lib/public-event-availability.test.mjs`
- `EVENTS_8A_IMPLEMENTATION_REPORT.md`
