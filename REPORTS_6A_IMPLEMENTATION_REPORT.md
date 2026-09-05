# CSK Booking — REPORTS-6A implementation report

**Date:** 2026-09-05

**Scope:** canonical correctness and scalable read contract for `/admin/reports`

**Deployment performed:** no

## Root cause and previous model

The previous page downloaded all matching reservation rows and all lane
configuration rows into the browser, then calculated every KPI in React. Its
utilization denominator used `16 * 60` minutes despite the canonical opening
window being 08:00–20:00 (720 minutes). Date ranges were based on elapsed local
milliseconds, so DST transitions could produce fractional 23/25-hour report
days. Historical labels came from current lane relations rather than the
existing reservation snapshot.

This also meant that a yearly report transferred every matching customer's
name, e-mail and phone to the browser before any aggregate could be shown.

## Implemented read contract

Migration `20260905150000_add_admin_reservation_reports_v1.sql` adds:

- `public.admin_get_reservation_report_v1(date,date,integer,integer) returns jsonb`;
- a bounded inclusive date range of at most 366 civil days;
- a detail page limited to 1–100 rows (default 50), with a bounded offset;
- DB-side status, revenue, hierarchy and interval-union aggregation;
- index `reservations_reporting_date_time_idx` on
  `(reservation_date, start_time, id)` for range filtering and deterministic
  detail ordering.

The browser now performs one report RPC request per selected range/page. It no
longer directly selects `reservations` or `shooting_lanes`, and no longer holds
the complete matching dataset in React state. Aggregate output contains no
customer PII. The bounded detail page keeps only the customer name, e-mail and
phone already required by the existing admin detail table; it does not expose
`user_id`, addresses, permit data, admin notes, check-in/confirmation tokens or
other internal fields.

## Canonical KPI semantics

| KPI | Implemented definition |
|---|---|
| Active reservations | `reservation_status = confirmed` |
| Completed reservations | `reservation_status = completed`, kept separate from active |
| Cancelled | `cancelled`, `canceled`, `cancelled_by_admin`, `cancelled_by_user` |
| No-show | `reservation_status = no_show`, separate from active/revenue |
| Planned revenue | authoritative `total_price` for confirmed + completed |
| Paid revenue | planned set with payment `paid` or `paid_on_site` |
| Outstanding/on-site | planned set with payment `unpaid` or `pay_on_site` |
| Free/voucher | not misclassified as outstanding revenue |
| Best day | highest planned revenue, stable date tie-break |
| Top resource | most confirmed/completed reservations, stable UUID tie-break |
| Occupancy | union of `[start,end)` ranges per effective physical unit, clipped to 08:00–20:00 |

## Date, time and hierarchy correctness

- One date always contributes one 720-minute report day.
- Client ranges use UTC calendar arithmetic and database input/output remains
  `date`, independent from elapsed DST hours.
- The default date is calculated in `Europe/Warsaw`.
- Month, year and cross-year week boundaries are calendar-based.
- A root in position mode maps to its usable child units and is not an extra
  capacity unit.
- A whole-lane reservation maps once to every effective unit in its family.
- A child reservation maps only to that child, never to siblings.
- Overlapping root/child legacy ranges are merged per unit before minutes are
  summed, preventing double counting and percentages above 100.
- Inactive/offline children do not increase current effective position
  capacity, consistent with the existing Calendar capacity model.

## Authorization and security

The RPC is `STABLE`, `SECURITY DEFINER`, owned by `postgres`, returns `jsonb`
and has the explicit search path `pg_catalog, public, pg_temp`.

- `authenticated`: `EXECUTE`, followed by an internal exact `admin` role check;
- ordinary user: controlled `not_allowed`;
- instructor: controlled `not_allowed`;
- employee (`pracownik`): controlled `not_allowed`;
- `anon`: no `EXECUTE`;
- `PUBLIC`: no `EXECUTE`;
- `service_role`: no explicit `EXECUTE`;
- no table ACL or RLS policy was widened;
- no service-role client is used by the browser.

The global SEC-002 function inventory test was updated from 67 to 68 functions
and from 42 to 43 authenticated grants, with the new signature explicitly
classified as an internally authorized admin RPC.

## Historical data

Existing `reservations.lane_name_snapshot` is now authoritative for the booked
resource name and inactive historical reservations remain visible in details.

**REPORTS-HISTORY-SNAPSHOT residual:** there is no historical capacity/config
snapshot, so the denominator necessarily uses current resource configuration.
For position reservations there is also no parent-name snapshot; the displayed
prefix is the current parent name while the position name is the reservation
snapshot. Both limitations are explicit in the RPC metadata and UI. A fully
historical utilization model requires a separate configuration snapshot design
and was intentionally not added to REPORTS-6A.

## Tests

- Focused Reports/operational Node tests: **33/33 PASS**.
- All Node tests: **629/629 PASS**.
- Focused transactional SQL contract: **25/25 PASS**, final rollback.
- Full local Supabase DB suite: **16 files, 316 tests, PASS**.
- Local DB post-check: RPC absent, index absent and fixture absent after cleanup.
- TypeScript `tsc --noEmit`: **PASS**.
- Next.js 16.3.4 production build: **PASS** (37 routes generated).
- `npm audit --omit=dev`: **0 vulnerabilities**.
- ESLint changed files: **0 errors, 0 warnings**.
- Full ESLint: existing baseline **13 errors, 6 warnings**; new REPORTS-6A
  regressions: **0**. This is not an increase over the documented 14/6 baseline.
- `git diff --check`: **PASS** (line-ending conversion warnings only).

No production or remote Supabase operation was executed. Local schema objects
used for the full suite were removed after testing.

## Compatibility and rollout

| Application | Database | Result |
|---|---|---|
| Old | Old | SAFE — current behavior remains available |
| Old | New | SAFE — migration is additive; old page ignores the new RPC/index |
| New | Old | UNSAFE operationally — report request fails closed because the RPC is absent |
| New | New | SAFE — intended contract |

**Recommended deployment model: DB FIRST.** Apply only the new migration,
verify function properties/ACL and a read-only admin call, then deploy the
application. Rolling the application back after the migration is safe because
the database change is additive. Deploying the application first causes only a
controlled Reports error, but is not the recommended order.

Full CSV export and the mobile detail-card redesign remain REPORTS-6B/6C and
were not implemented.

## Final status

```text
REPORTS-6A:
FULLY IMPLEMENTED

OCCUPANCY CORRECTNESS:
PASS

DST / DATE CORRECTNESS:
PASS

HIERARCHY:
PASS

LARGE RANGE READ CONTRACT:
PASS

PII REDUCTION:
PASS

HISTORICAL SNAPSHOT:
RESIDUAL

DB CHANGE REQUIRED:
YES

DEPLOYMENT MODEL:
DB FIRST
```

## Files changed

- `app/admin/reports/page.tsx`
- `app/admin/reports/page.test.mjs`
- `app/admin/admin-operational-ui.test.mjs`
- `app/admin/admin-hierarchy-labels.test.mjs`
- `lib/admin/reports.ts`
- `lib/admin/reports.test.mjs`
- `supabase/migrations/20260905150000_add_admin_reservation_reports_v1.sql`
- `supabase/tests/20260905150000_add_admin_reservation_reports_v1_test.sql`
- `supabase/tests/20260816143000_harden_public_function_execute_acl_test.sql`
- `REPORTS_6A_IMPLEMENTATION_REPORT.md`
