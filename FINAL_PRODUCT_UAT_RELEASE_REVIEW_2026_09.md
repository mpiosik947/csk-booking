# CSK Booking — Final Product UAT / Release Review

**Review date:** 2026-09-06

**Scope:** single-tenant V1

**Reviewed HEAD:** `2b925d6`

**Branch:** `main`

## Executive decision

The current single-tenant product passed the final functional release review.
No P0, P1 or P2 product regression was found. Two known, non-runtime technical
debt items remain at P3: the existing ESLint baseline and Next.js' deprecated
`middleware` convention. Neither prevented compilation, the production build,
the automated browser suite, or the production read-only smoke.

Production mutation flows were not repeated against real customer data. Their
release evidence is the current local DB/Node/browser regression suite plus the
already completed production smoke sections in
`PRODUCTION_SECURITY_SMOKE_TEST.md`. This review itself performed only
read-only production navigation and response inspection.

## Environment and evidence

- Git working tree was clean before the report was created.
- Production public routes were checked directly on Vercel.
- A real authenticated production admin session was used for read-only module
  loading; no create/edit/cancel/pay/promote/check-in action was submitted.
- The public responsive matrix covered 320, 375, 430, 768 and 1440 CSS px.
- Local browser tests used the current production build on
  `127.0.0.1:3000` and local Supabase only.
- DB tests were run explicitly with `--local` after verifying
  `127.0.0.1:54322` was listening.
- No production fixture, email, database mutation, migration or deployment was
  created by this review.

## UAT results

| UAT | Result | Evidence |
|---|---|---|
| 1. Public home / navigation | PASS | Production `/`, `/login`, `/register`, `/booking`, `/events`, `/privacy` and `/terms` returned HTTP 200 without 5xx or horizontal overflow. Home CTA links resolve to Booking, Events, Login, Register and Terms; Terms links to Privacy. The final controller/contact data remains the explicitly deferred legal residual. |
| 2. Auth | PASS | Login/register/forgot/reset pages loaded in production. Anonymous direct `/admin/*` navigation redirected to `/login`; the authenticated administrator retained access. Invalid/missing-session, 401/403/503 classification, logout and password-policy behavior remain covered by the current Node suite and the SEC-010/SEC-011 production smokes. |
| 3. Booking — single position | PASS | Current contracts preserve the selected child UUID through Availability V3, `create_reservation_v2`, My Reservations, Admin Reservations and Calendar. Calendar tests confirm the child appears once with `Parent — Position`, no sibling projection and no double count. |
| 4. Booking — whole lane | PASS | The public configuration, Availability V3 and atomic reservation writer retain the whole-family scope. Whole-lane reservations are displayed once and conflict with child occupancy through the family lock. |
| 5. Booking conflicts | PASS | DB and Node contracts cover same-child denial, sibling independence, child-versus-whole, whole-versus-child and whole-versus-whole conflicts. The writer remains atomic and fail-closed. |
| 6. Cancellation | PASS | Controlled cancellation updates status without hard-deleting history, releases availability, updates Calendar/Admin views and uses the hardened idempotent cancellation-email delivery contract. CLEAN-004 and SEC-015 production smokes remain PASS. |
| 7. My Reservations | PASS | Active/history/cancelled presentation, details, ownership, cancellation actions and controlled loading/empty/error behavior remain covered. The live production route loaded without 5xx or overflow; no foreign data was exposed. |
| 8. Admin Reservations | PASS | Production `/admin/reservations` loaded in the authenticated admin session without overflow or runtime failure. List, operational actions, hierarchy labels and mobile presentation remain covered by the current contract tests. |
| 9. Admin Calendar | PASS | Production `/admin/calendar` loaded successfully. Day/week/month, parent/child filtering, inactive child history, single-position visibility and no-double-count behavior remain covered by the current test suite and the dedicated production calendar smoke. |
| 10. Lane Blocks | PASS | Production `/admin/lane-blocks` loaded successfully. Controlled writer, family conflict behavior, Calendar impact, activation/deactivation and hierarchy semantics remain protected by current tests and deployed contracts. |
| 11. Check-in | PASS | Production `/admin/check-in` and an invalid public token route loaded without 5xx. Valid/invalid/too-early/expired/cancelled token behavior, staff lookup, idempotency and the minimal public DTO remain covered by DB/Node tests and the SEC-005 production smoke. |
| 12. Users | PASS | Production `/admin/users` loaded without overflow or runtime error. Bounded list/search/details, role, verification, admin note, declarations, controlled self/admin RPCs and ordinary-user denial remain covered. CLEAN-005 and users production evidence remain valid. |
| 13. Reports | PASS | Production `/admin/reports` loaded successfully. KPI, 720-minute operating day, hierarchy aggregation, filters, pagination 50, safe CSV, empty/error states and 320/375/430/desktop UX are covered by REPORTS-6A/B/C production smokes and the passing responsive E2E suite. The known historical snapshot residual was not reopened. |
| 14. Public Events | PASS | Production `/events` returned HTTP 200 at every required viewport without overflow or 5xx. Search and controlled empty/error/retry states work. Availability comes from the bounded authoritative PII-free contract; registration, duplicate, sold-out and reserve behavior remain covered by EVENTS-8A/B/C evidence. |
| 15. My Events | PASS | The live authenticated route supported upcoming/history/all and canonical registered/approved/reserve/cancelled filters with URL restoration and mobile-safe pagination. Payment, `>=72h` cancellation and promotion confirmation remain aligned with the backend contract. |
| 16. Admin Events | PASS | The live production module loaded in an admin session. Search, scope and sort worked; participant cards and status/payment filters were bounded and mobile-safe. Edit/activation, pagination, promotion and payment actions remain on controlled RPCs and are covered by EVENTS-8A/B/C. |
| 17. Email flows | PASS | Booking confirmation/cancellation, event registration/reserve/promotion and related delivery paths retain escaped HTML, trusted recipients, claim/idempotency and safe provider-failure handling. No email was sent during this review; SEC-006 and SEC-015 production smoke results plus current tests provide the release evidence. |
| 18. Mobile | PASS | Production `/`, Login, Register, Booking and Events showed no horizontal overflow at 320/375/430/768/1440. Authenticated admin modules showed no overflow in the live phone-sized session. Full local Playwright coverage passed for Events, Reports and lane-family workflows. |
| 19. Browser / runtime | PASS | No console warning/error was recorded during the authenticated admin traversal. No checked route produced a 5xx or application-error page. URL filters, back/forward, malformed values and controlled retry behavior are covered by live checks and tests. |
| 20. Test suite | PASS | Node 677/677, DB 378/378, Playwright 18/18, TypeScript and production build all passed. Production dependency audit reported zero vulnerabilities. `git diff --check` is reported in the final verification below. |

## Functional release matrix

| Area | Status | Release evidence |
|---|---|---|
| Public navigation and legal links | PASS | Live production route/link checks and responsive matrix |
| Authentication and protected routes | PASS | Live anonymous/admin checks, SEC-010/SEC-011 smokes, Node tests |
| Booking and availability | PASS | Atomic DB contracts, hierarchy/availability Node tests, production smokes |
| Reservations and cancellation | PASS | CLEAN-004, SEC-015, Calendar smoke and current tests |
| Calendar | PASS | Dedicated production position smoke and current hierarchy tests |
| Lane configuration and blocks | PASS | Local Playwright lane-family scenarios and controlled writer contracts |
| Check-in | PASS | SEC-005 production smoke and current minimal-DTO/idempotency tests |
| Users | PASS | Users contracts, CLEAN-005 production smoke and current tests |
| Reports | PASS | REPORTS-6A/B/C production smokes and passing E2E |
| Events / trainings | PASS | EVENTS-8A/B/C production smokes and passing E2E |
| Email delivery | PASS | SEC-006/SEC-015 production smokes and delivery tests |
| Current single-tenant security | PASS | Final clean confirmation plus no regression observed in this UAT |

## Automated verification

| Check | Result |
|---|---|
| All Node tests | PASS — 677 tests, 0 failed |
| All Supabase DB tests | PASS — 18 files, 378 tests, 0 failed; local `127.0.0.1:54322` only |
| Playwright | PASS — 18 tests, 0 failed |
| TypeScript | PASS — `npx.cmd tsc --noEmit` |
| Production build | PASS — Next.js 16.3.4, 37 static pages generated |
| Production dependency audit | PASS — 0 vulnerabilities |
| Full ESLint | KNOWN BASELINE — 12 errors, 5 warnings; new UAT regressions: 0 |

The first Playwright attempt selected an already-running stale development
server on port 3013 and could not authenticate the newly created local fixture.
That was an environment-selection failure, not a product failure. The suite was
rerun against a fresh current-HEAD production build on `127.0.0.1:3000` and
passed 18/18. The temporary test server and configuration were removed.

## Findings

### UAT-001 — Existing ESLint baseline

- **Priority:** P3
- **Evidence:** full ESLint reports 12 errors and 5 warnings in existing files.
- **Impact:** code-quality/maintainability debt; TypeScript, build and runtime
  tests pass.
- **Decision:** non-blocking for single-tenant V1; schedule a dedicated lint
  cleanup without mixing it into functional work.

### UAT-002 — Deprecated Next.js middleware convention

- **Priority:** P3
- **Evidence:** Next.js 16.3.4 build warns that `middleware` should migrate to
  the `proxy` convention.
- **Impact:** no current runtime failure; future-framework compatibility debt.
- **Decision:** non-blocking for V1; migrate in an isolated, fully regression-
  tested task.

No new P0, P1 or P2 finding was confirmed.

## Known deferred / accepted residuals

- SaaS / `tenant_id` and a second tenant: deferred; multi-tenant release is not
  ready.
- Instructor-to-event assignment model (SEC-008): deferred.
- REPORTS-HISTORY-SNAPSHOT: accepted report-history limitation.
- SEC-009 10B time-based retention: deferred pending retention-period decision.
- Final legal controller identity/address/contact fields: deferred pending the
  final business entity decision.
- Supabase leaked-password protection: accepted plan limitation/future
  hardening.
- Managed Supabase ACL residual: accepted platform-managed residual under the
  existing guard.

These items do not block the current single-tenant V1 under the approved scope.

## Release recommendation

The product is ready to be marked **CSK Booking Single-Tenant V1 — Feature
Complete / Production Ready**, with the documented non-blocking residuals.
Before any SaaS or second-tenant work, tenant isolation and the explicitly
deferred data/access decisions must be completed and independently verified.

## Final result

```text
FINAL PRODUCT UAT:
PASS

P0:
0

P1:
0

P2:
0

P3:
2

BOOKING:
PASS

ADMIN:
PASS

CALENDAR:
PASS

CHECK-IN:
PASS

USERS:
PASS

REPORTS:
PASS

EVENTS:
PASS

EMAILS:
PASS

MOBILE:
PASS

SECURITY REGRESSION:
NONE CONFIRMED

CURRENT SINGLE-TENANT RELEASE:
READY WITH NON-BLOCKING RESIDUALS

BLOCKERS BEFORE V1:
NONE

KNOWN DEFERRED / ACCEPTED RESIDUALS:
SaaS/tenant_id; instructor-event assignment; REPORTS-HISTORY-SNAPSHOT;
time-based retention 10B; final legal controller/contact data;
leaked-password protection plan limitation; managed Supabase ACL residual.

RECOMMENDED NEXT ACTION:
Review and checkpoint this UAT report, then mark the current single-tenant
release as V1. Keep SaaS work blocked until tenant isolation is implemented.
```
