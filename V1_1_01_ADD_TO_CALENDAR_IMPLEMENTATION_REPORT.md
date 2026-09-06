# V1.1-01 — Add to calendar implementation report

## Result

The application now provides a safe **Dodaj do kalendarza** download for an
authenticated user's active reservation and for their `registered` or
`approved` event registration. The feature generates a standalone `.ics` file;
it neither requests calendar permissions nor connects to Google, Apple, or
Microsoft calendar APIs.

## Current-flow analysis

- `/my-reservations` reads only the caller's records through
  `get_my_reservations_v2()`. The calendar route reuses that owner-scoped RPC
  and applies the requested reservation ID as a result filter.
- `/my-events` reads the caller's registrations through
  `get_my_event_registrations_v1()`. The calendar route performs an exact
  authenticated table read constrained by both registration ID and
  `auth.uid()` (`user_id = verified caller`); existing RLS remains in force.
- Neither route uses a service-role client. Both use the public anon key plus
  the caller's verified Bearer JWT.
- Missing and foreign records are indistinguishable (`404`). Missing/invalid
  sessions are `401`; Auth availability failures preserve the shared
  `503`/`500` classification; disallowed statuses return controlled `409`.
- Both routes are GET-only and contain no insert, update, delete, cancellation,
  or other mutation.

## Availability of the CTA

- Reservation: shown only in the existing active-reservations collection. It
  is therefore absent for cancelled and historical records.
- Event registration: shown only for canonical `registered` and `approved`
  statuses. It is absent for `reserve` and `cancelled` and appears after a
  reserve-list promotion changes the canonical status.
- The CTA was intentionally not duplicated into booking/registration success
  flows in this iteration.

## ICS contract

Each response contains a single RFC 5545-shaped `VEVENT` within:

- `BEGIN:VCALENDAR`
- `VERSION:2.0`
- a fixed CSK `PRODID`
- `CALSCALE:GREGORIAN`
- `METHOD:PUBLISH`

The event contains only an opaque UID, DTSTAMP, DTSTART, DTEND, SUMMARY,
DESCRIPTION, and an optional public LOCATION. It never emits ATTENDEE,
ORGANIZER, URL, user contact data, profile data, notes, tokens, or credentials.

Reservation content uses the existing owner read model's hierarchy display
name, retaining standalone/whole-lane and parent-position labels. Event content
uses the event's public title, description, location, and scheduled times.

## UID and injection protection

- UID is a deterministic SHA-256 digest of the record type and internal record
  ID. The source ID is not exposed in the generated UID.
- Dynamic text escapes backslashes, commas, semicolons, CR, LF, and CRLF in the
  iCalendar text format.
- Tests cover attempted fake `ATTENDEE`, `URL`, `ORGANIZER`, `BEGIN:VEVENT`, and
  `END:VEVENT` injection.
- Lines are folded without splitting Unicode code points and remain at or below
  75 UTF-8 octets, including continuation whitespace.

## Timezone

Source wall-clock values are interpreted in `Europe/Warsaw` through the
existing canonical Warsaw conversion helper and emitted as UTC timestamps.
This avoids fixed UTC+1/UTC+2 assumptions. Tests cover winter, summer, the
non-existent spring-forward hour (fail-closed), a valid post-transition time,
and the autumn overlap (deterministic Warsaw mapping).

## HTTP response

- `Content-Type: text/calendar; charset=utf-8`
- `Content-Disposition: attachment` with a fixed, non-PII filename
- `Cache-Control: private, no-store`
- `X-Content-Type-Options: nosniff`

Filenames are `csk-rezerwacja.ics` and `csk-szkolenie.ics`.

## Mobile and browser behavior

The shared button uses the current CSK visual system, a minimum 44 px touch
height, wrapping action groups, and bounded error text. The browser downloads a
Blob returned by the authenticated route; it never opens a calendar API or asks
for device permissions.

Focused Playwright verification used a fresh local application server and
confirmed:

- the event calendar request carries the signed-in user's Bearer token;
- the response downloads as `csk-szkolenie.ics`;
- the CTA is present for `approved` and absent for `reserve`;
- no horizontal overflow at 320, 375, 430, 768, and 1440 px.

## Files changed

- `app/_components/AddToCalendarButton.tsx`
- `app/api/calendar/reservations/[id]/route.ts`
- `app/api/calendar/event-registrations/[id]/route.ts`
- `app/api/calendar/calendar-routes.test.mjs`
- `app/my-reservations/page.tsx`
- `app/my-events/page.tsx`
- `lib/server/calendar-export-route.ts`
- `lib/server/icalendar.ts`
- `lib/server/icalendar.test.mjs`
- `tests/e2e/events-responsive.spec.ts`
- `V1_1_01_ADD_TO_CALENDAR_IMPLEMENTATION_REPORT.md`

No SQL, migration, RPC, RLS, ACL, or database file changed.

## Verification

- Focused ICS/routes/booking/events tests: **29/29 PASS**
- All Node tests: **695/695 PASS**
- Relevant Playwright: **PASS**
- TypeScript (`npx.cmd tsc --noEmit`): **PASS**
- Production build (`npm.cmd run build`): **PASS**
- Changed-files ESLint: **PASS**
- `npm.cmd audit --omit=dev`: **PASS — 0 vulnerabilities**
- Supabase DB tests: **not required; no DB/SQL contract changed**

## Final status

V1.1-01 ADD TO CALENDAR:
FULLY IMPLEMENTED

RESERVATION ICS:
PASS

EVENT REGISTRATION ICS:
PASS

OWNERSHIP:
PASS

NO CALENDAR PERMISSIONS:
PASS

PII MINIMIZATION:
PASS

TOKEN / SECRET EXCLUSION:
PASS

ICS INJECTION PROTECTION:
PASS

TIMEZONE / DST:
PASS

HTTP NO-STORE:
PASS

MOBILE UX:
PASS

BOOKING REGRESSION:
PASS

EVENTS REGRESSION:
PASS

DB CHANGE REQUIRED:
NO

DEPLOYMENT MODEL:
APP ONLY
