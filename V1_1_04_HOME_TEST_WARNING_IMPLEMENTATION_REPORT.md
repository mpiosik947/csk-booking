# V1.1-04 — Home page test-mode warning

## Outcome

The existing small `WERSJA TESTOWA` card at the bottom of the home page was
replaced with one prominent warning directly between the brand hero and the
primary booking/event calls to action. There is no competing duplicate
message.

The warning states that CSK has not officially opened, the application is
currently used for testing, current reservations and event registrations are
not binding, and the official launch will be announced separately.

## Presentation and accessibility

- The panel follows the existing graphite, olive and amber CSK palette.
- A stronger amber border, warning icon and visible `TEST` badge distinguish it
  from ordinary informational cards without using an aggressive red alert.
- The content uses a labelled semantic `section` and an `h2` heading.
- The meaning is expressed in text and does not rely on color or the icon.
- Flexible, bounded containers and wrapping typography avoid fixed-width
  overflow while keeping the primary CTA immediately below the notice.

## Scope and regression safety

Only the home page presentation and its focused tests changed. The `/booking`
and `/events` CTA labels and destinations remain unchanged. Authentication,
navigation, reservation/event logic, backend contracts, database objects and
all other pages are untouched.

## Tests

| Check | Result |
|---|---|
| Focused homepage Node tests | PASS — 5/5 |
| Homepage Playwright | PASS — 6/6 |
| Responsive widths | PASS — 320, 375, 430, 768 and 1440 px |
| Primary CTA href regression | PASS — `/booking` and `/events` |
| All Node tests | PASS — 727/727 |
| TypeScript `tsc --noEmit` | PASS |
| Production build | PASS |
| `npm audit --omit=dev` | PASS — 0 vulnerabilities |
| Changed-files ESLint | PASS — 0 errors, 0 warnings |
| `git diff --check` | PASS |

The Playwright environment was explicitly verified before execution as local
Supabase at `http://127.0.0.1:54321`. No database operation or fixture was
needed. The existing Next.js middleware deprecation warning remains unchanged
and is outside this task.

## Final result

```text
V1.1-04 HOME TEST WARNING:
FULLY IMPLEMENTED

HOME WARNING:
PASS

MESSAGE CLARITY:
PASS

MOBILE:
PASS

HOME CTA REGRESSION:
PASS

DB CHANGE REQUIRED:
NO

DEPLOYMENT MODEL:
APP ONLY

FILES CHANGED:
app/page.tsx
app/page.test.mjs
tests/e2e/home-test-warning.spec.ts
V1_1_04_HOME_TEST_WARNING_IMPLEMENTATION_REPORT.md

TESTS:
focused 5/5; Playwright 6/6; Node 727/727; TypeScript, build, audit,
changed-files ESLint and git diff --check PASS
```
