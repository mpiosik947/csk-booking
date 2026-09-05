# REPORTS-6B — filters and safe CSV export

Date: 5 September 2026  
Baseline: `0f212de`  
Scope: local implementation and local Supabase verification only

## Filter inventory

| Filter | Before REPORTS-6B | After REPORTS-6B |
|---|---|---|
| Date from | PARTIAL — derived from day/week/month/year UI | DONE — explicit inclusive date | 
| Date to | PARTIAL — derived from day/week/month/year UI | DONE — explicit inclusive date |
| Parent lane | MISSING | DONE — parent plus its direct positions |
| Child position | MISSING | DONE — exact position only |
| Reservation status | MISSING | DONE — canonical confirmed/completed/cancelled/no-show semantics |
| Payment status | MISSING | DONE — values from the existing payment model |
| Booking type | MISSING | DONE — whole lane or single position |

Events remain outside the reservation report contract.

## Implementation

The additive database migration keeps `admin_get_reservation_report_v1(...)` unchanged and adds:

- `admin_get_reservation_report_v2(date,date,uuid,text,text,text,integer,integer)` for filtered KPI and 50-row details;
- `admin_get_reservation_report_export_v1(date,date,uuid,text,text,text)` for a complete, bounded, PII-minimal export dataset;
- a private `_admin_reservation_report_rows_v2(...)` helper shared by both public contracts.

All filtering is performed in PostgreSQL. KPI values use the entire filtered set and are independent of detail pagination. Details retain a stable `reservation_date, start_time, id` ordering. Changing or resetting a filter returns the UI to page one.

The report URL stores only `from`, `to`, `lane`, `status`, `payment`, and `type`. Values are allowlisted, dates are validated, ranges are limited to 366 calendar days, and no PII is written to the URL. History navigation is handled through browser history and `popstate`.

## CSV contract

CSV includes only:

- reservation date;
- start and end time;
- hierarchy-aware resource label;
- booking type;
- reservation status;
- payment status;
- total amount.

It excludes reservation/user identifiers, customer name, email, phone, address, permits, tokens, admin notes, and profile data. Customer display name was intentionally not exported because it is unnecessary for the stated operational report.

The format is deterministic UTF-8 with BOM, semicolon separator, CRLF rows, and quoted fields for compatibility with Polish Excel. Text beginning with optional whitespace/control characters followed by `=`, `+`, `-`, or `@` is prefixed with an apostrophe before CSV quoting. Quotes, commas, semicolons, CR/LF, Unicode, and Polish characters are covered by tests.

Export is intentionally bounded at 5,000 rows. Up to and including 5,000 rows is returned in one PII-minimal JSON payload and generated in the browser. A larger filtered result returns `export_too_large` without rows; the UI asks the administrator to narrow the filters. This avoids an unbounded browser payload without introducing a background-job subsystem.

## Authorization and security

- Admin: allowed after `auth.uid()` and exact database role verification.
- Employee, instructor, ordinary user, and anon: denied.
- `authenticated` receives EXECUTE only on the two externally callable contracts.
- `PUBLIC`, `anon`, and `service_role` receive no EXECUTE on the new RPCs.
- The shared helper has no client-role EXECUTE.
- SECURITY DEFINER RPCs are owned by `postgres`, are STABLE, and use `search_path = pg_catalog, public, pg_temp`.
- No table RLS policy or table grant was widened, and no service-role client was added.

## REPORTS-6A regression

The v1 definition is fingerprinted unchanged. REPORTS-6B preserves the canonical 08:00–20:00 / 720-minute day, calendar-date/DST behavior, hierarchy-aware effective capacity, interval-union occupancy without double counting, revenue/status rules, admin-only access, bounded detail pagination, and the documented PII scope of the existing screen.

`REPORTS-HISTORY-SNAPSHOT` remains unchanged: capacity can use current configuration, and a child snapshot does not contain a historical parent name.

## Compatibility and rollout

| Application | Database | Result |
|---|---|---|
| Old | Old | SAFE |
| Old | New | SAFE — migration is additive and v1 is unchanged |
| New | Old | UNSAFE — the v2 and export RPCs are absent; UI fails closed |
| New | New | SAFE |

Deployment model: **DB FIRST**. Apply only `20260905170000_add_admin_reservation_report_filters_export.sql`, verify its ACL/signatures, then deploy the application. No production deployment was performed in this task.

## Verification results

- Focused Reports/filter/CSV Node tests: 29/29 PASS.
- REPORTS-6B database contract: 34/34 PASS.
- Full Supabase DB suite on local `127.0.0.1:54322`: 17 files, 350 tests, PASS.
- All Node tests: 637/637 PASS.
- TypeScript `tsc --noEmit`: PASS.
- Next.js 16.3.4 production build: PASS (existing middleware-to-proxy deprecation warning only).
- `npm audit --omit=dev`: 0 vulnerabilities.
- ESLint on changed application/test files: PASS.
- Full ESLint: known baseline only — 13 errors and 6 warnings; new REPORTS-6B regressions: 0.
- `git diff --check`: PASS.

## Final status

```text
REPORTS-6B:
FULLY IMPLEMENTED

FILTERS:
PASS

FILTERED KPI:
PASS

PAGINATION:
PASS

CSV EXPORT:
PASS

CSV INJECTION PROTECTION:
PASS

PII MINIMIZATION:
PASS

AUTHORIZATION:
PASS

REPORTS-6A REGRESSION:
PASS

DB CHANGE REQUIRED:
YES

DEPLOYMENT MODEL:
DB FIRST

HISTORICAL SNAPSHOT RESIDUAL:
UNCHANGED
```

Files changed:

- `app/admin/reports/page.tsx`
- `app/admin/reports/page.test.mjs`
- `app/admin/admin-hierarchy-labels.test.mjs`
- `app/admin/admin-operational-ui.test.mjs`
- `lib/admin/reports.ts`
- `lib/admin/reports.test.mjs`
- `supabase/migrations/20260905170000_add_admin_reservation_report_filters_export.sql`
- `supabase/tests/20260905170000_add_admin_reservation_report_filters_export_test.sql`
- `supabase/tests/20260816143000_harden_public_function_execute_acl_test.sql`
- `REPORTS_6B_IMPLEMENTATION_REPORT.md`
