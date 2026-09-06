# EVENTS-8C — Mobile UX, final polish and Playwright

Date: 2026-09-06

## Scope and result

The work was limited to the application UX and browser tests for /events,
/my-events, and /admin/events. No SQL, migration, RPC, RLS, ACL, event status,
availability, cancellation cutoff, or mutation contract was changed.

## UX changes

### Public events

- The existing responsive event cards retain title, date/time, location,
  authoritative availability, sold-out and reserve-list states.
- A failed bounded read now exposes a controlled “Spróbuj ponownie” action.
- An empty search has filter-aware copy.
- Pagination uses two full-width 48 px controls on narrow screens and keeps the
  current page visible without horizontal overflow.

### My events

- The scope selector now exposes all three scopes already supported by
  get_my_event_registrations_v1: upcoming, history, and all.
- Upcoming and historical sections have scope-aware empty states.
- A failed owner-scoped read has a controlled retry action.
- Status and payment presentation remains canonical.
- Cancellation visibility still uses the canonical Europe/Warsaw 72-hour
  helper; its semantics were not changed.
- Mobile pagination uses full-width 48 px controls.

### Admin events and participants

- The event filter bar remains stacked through tablet width and no longer
  overflows around 768 px.
- Participant, reserve-list, and cancelled tables become labelled stacked cards
  below the desktop breakpoint; desktop retains the semantic table layout.
- Cards expose only the existing minimal participant DTO and preserve status,
  payment, approval, payment marking, cancellation, queue order, filters, and
  pagination.
- Participant and event read failures offer controlled retry actions.
- Pagination actions have 48 px touch targets on mobile.
- Existing cancellation-triggered reserve promotion behavior remains unchanged;
  no new mutation action or RPC was introduced.

## Accessibility

- Existing label/input associations and focus rings were retained.
- Retry actions have explicit accessible names.
- Participant cards include visible mobile field labels.
- Pagination remains a labelled nav, with clear disabled states and 48 px
  touch targets.
- Browser checks covered page-level horizontal overflow at 320, 375, 430, 768,
  and 1440 px.

## Playwright coverage

tests/e2e/events-responsive.spec.ts uses the existing local-only Supabase
guard. The environment was confirmed as
NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54321; requests to
*.supabase.co are explicitly aborted. The suite creates one synthetic local
admin and removes it in teardown.

The eight browser tests cover the required public viewports, search,
pagination, sold-out/reserve presentation, controlled error/retry, upcoming,
history, all and status views, cancellation eligibility, admin search/scope,
participant filters, participant pagination, mobile participant cards, and
horizontal overflow.

Result: **8/8 PASS**.

## Regression

- Focused Events tests: **61/61 PASS**.
- All Node tests: **677/677 PASS**.
- TypeScript (npx.cmd tsc --noEmit): **PASS**.
- Next.js production build: **PASS**.
- Production dependency audit (npm.cmd audit --omit=dev): **PASS, 0 vulnerabilities**.
- Changed-files ESLint: all changed files except app/events/page.tsx are clean.
  That file reports the same pre-existing baseline as HEAD (2 errors, 1
  warning: nested EventDetails, internal anchor, unused helper);
  **new EVENTS-8C ESLint regressions: 0**.
- git diff --check: **PASS**.
- DB tests: not run because there are no SQL/RPC/RLS/ACL changes.

## Compatibility and deployment

- EVENTS-8A status, availability, registration, reserve, promotion,
  cancellation, payment, and 72-hour rules: unchanged and regression tests
  pass.
- EVENTS-8B bounded reads, URL-backed filters, stable pagination, owner scope,
  participant DTO, page-size bounds, and no-fetch-all contracts: unchanged and
  regression tests pass.
- DB change required: **NO**.
- Deployment model: **APP ONLY**.

## Files changed

- app/events/page.tsx
- app/my-events/page.tsx
- app/admin/events/page.tsx
- lib/event-read-contracts.ts
- app/events/events-ux.test.mjs
- tests/e2e/events-responsive.spec.ts
- package.json
- EVENTS_8C_IMPLEMENTATION_REPORT.md

## Final status

EVENTS-8C: **FULLY IMPLEMENTED**

PUBLIC MOBILE: **PASS**

MY EVENTS MOBILE: **PASS**

ADMIN EVENTS MOBILE: **PASS**

PARTICIPANT MOBILE: **PASS**

SEARCH / FILTER UX: **PASS**

PAGINATION UX: **PASS**

LOADING / EMPTY / ERROR: **PASS**

ACCESSIBILITY: **PASS**

PLAYWRIGHT: **PASS**

EVENTS-8A REGRESSION: **PASS**

EVENTS-8B REGRESSION: **PASS**

DB CHANGE REQUIRED: **NO**

DEPLOYMENT MODEL: **APP ONLY**
