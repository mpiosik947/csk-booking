# CSK Booking — ETAP 6 Reports gap analysis

**Date:** 2026-09-05

**Reviewed HEAD:** `2705ab9 — docs: record public event availability smoke pass`

**Scope:** `/admin/reports` and directly related application, database,
authorization and test contracts

**Mode:** read-only analysis; no application, SQL, configuration or database
implementation was changed

## Executive assessment

ETAP 6 is **PARTIAL**. The module is already a useful admin-only operational
view: it loads a complete date-bounded reservation set, presents reservation
and revenue KPIs, resolves parent/position labels, and avoids the hierarchy
error in which a root plus five positions becomes six units. It is not yet a
reliable reporting product for historical or large-range analysis.

The most important confirmed correctness problem is the utilization
denominator. Reports assumes 16 opening hours per day, while Booking and the
authoritative Calendar use 08:00–20:00, or 12 hours. A resource booked for the
entire real opening window therefore reports 75% rather than 100% utilization.
There are also DST-sensitive day counts and historical-capacity/name problems.
Filters, bounded detail pagination, export and a usable mobile detail view are
missing.

## 1. Current inventory

### 1.1 Execution path and authorization

The complete client-side path is:

1. `middleware.ts` matches `/admin/:path*`, resolves the session and trusted
   profile role, and permits `/admin/reports` only for `admin`.
2. `app/admin/reports/page.tsx` independently calls `auth.getUser()` and
   `get_my_role()`, and renders report data only when the result is exactly
   `admin`.
3. The browser directly queries `public.shooting_lanes` and
   `public.reservations` through the authenticated Supabase client.
4. `lib/admin/reports.ts` validates complete pagination and calculates
   hierarchy utilization in the browser.
5. All other KPIs are calculated directly inside the React page.

There is no Reports API route and no dedicated Reports RPC. No service-role
credential is used by this module.

The relevant database boundary remains:

- `authenticated` has table `SELECT` on `reservations` and `shooting_lanes`;
- reservation RLS permits global rows to `is_admin_or_employee()` and own rows
  to their owner;
- shooting-lane RLS provides staff visibility and public visibility only for
  active resources;
- middleware/page policy narrows the Reports UI further to admin only;
- instructors and ordinary users cannot obtain a global reservation report
  through this page, although an employee continues to have the intended
  operational reservation read outside Reports.

### 1.2 Data sources

| Source | Selected data | Purpose | Loading model |
|---|---|---|---|
| `shooting_lanes` | identity, name, hierarchy, active state, whole/position modes | current hierarchy and capacity | exact count plus sequential 500-row pages |
| `lane_booking_rules` nested from lanes | `online_bookable` | current effective capacity | included in each lane page |
| `reservations` | ID, current lane relation, customer name/e-mail/phone, date/time/duration, legacy `price`, reservation/payment status | every KPI and detail row | date-bounded exact count plus sequential 500-row pages |
| nested `shooting_lanes` relation | child and explicit `parent_lane_id` relationship | `Parent — Position` display | one PostgREST relationship query, not N+1 |
| `get_my_role()` | caller role | client-side defense in depth | one RPC call |

Events, event registrations, lane blocks and payment/refund ledgers are not
part of the Reports dataset.

### 1.3 Existing reports and KPIs

| UI value | Current calculation | Assessment |
|---|---|---|
| Rezerwacje aktywne | every row except cancelled variants and `no_show` | Misnamed: completed historical reservations are included. It is closer to “not cancelled and attended/planned”. |
| Przychód planowany | sum of `price` for the same set | Operational booking value, not accounting revenue. Cancelled and no-show are excluded. |
| Przychód opłacony | above set restricted to `paid` or `paid_on_site` | Internally consistent, but no refund/reversal ledger is consulted. |
| Nieopłacone / na miejscu | above set where payment is not `paid`/`paid_on_site` | Also groups `free` and `voucher`; the label is incomplete. |
| Anulowane | all supported cancelled status variants | Correct count for current reservation status contract. |
| Nieobecności | status exactly `no_show` | Correct count for current status contract. |
| Najlepszy dzień | maximum sum of operational `price` in the non-cancelled/non-no-show set | “Best” means highest planned reservation value, not collected revenue. Tie order is not explicitly specified. |
| Najczęściej używana oś | row count grouped by current hierarchy display label | Counts bookings, not minutes, shooters or revenue; positions remain separate labels. |
| Obłożenie osi | weighted reservation duration / current effective capacity / 16 hours / days | Hierarchy weighting is sound, but the time denominator and historical model are not. |

The module uses `reservations.price`, which is currently protected by the
database constraint equating it to `total_price`. The schema explicitly marks
`price` as a legacy alias. New reporting work should use the authoritative
`total_price` snapshot before the alias is retired.

### 1.4 Date ranges

Available modes are day, ISO-like Monday–Sunday week, calendar month and
calendar year around one reference date. Database filters are inclusive:
`reservation_date >= startDate` and `reservation_date <= endDate`. Because the
column is `date`, the database comparison itself has no timezone ambiguity.

There is no arbitrary from/to range, preset navigation, “all available data”
mode, URL state, local persistence or reset action. Changing the mode or date
immediately reloads the report.

### 1.5 Pagination and request behavior

`fetchCompleteReportDataset()` prevents silent PostgREST truncation. It first
reads an exact count and then requests deterministic, sequential 500-row
ranges. It rejects empty/failed pages, duplicate IDs and count mismatches.
Stale responses are ignored through a monotonically increasing request ID.

This is source pagination, not user-facing or server-side report pagination.
Every matching reservation is retained in React state and rendered in the
DOM. A concurrent insert/delete between the exact count and offset pages can
make the operation fail closed, which is safer than a partial KPI but still
causes an avoidable report failure.

The approximate number of remote operations is:

`auth + role + lane count + ceil(lanes/500) + reservation count + ceil(reservations/500)`.

Page requests are sequential rather than parallel.

### 1.6 States and presentation

- Loading: explicit “Ładowanie raportu...”.
- Authorization failure: controlled login/access messages.
- Query, count, pagination or utilization failure: controlled generic error;
  partial KPI is not rendered.
- Empty result: dedicated explanatory empty state.
- Retry: no explicit retry button; a mode/date change or remount triggers a new
  read.
- Detail: one 1100-pixel-wide table with horizontal scrolling.
- Charts: none.
- Export: none. A previous browser CSV experiment was added in `472d974` and
  deliberately removed in `94be83c`; it is not a delivered feature.

## 2. Data correctness

### 2.1 What is correct

- A whole-lane reservation is one reservation row but is weighted across all
  effective child capacity units when position mode is active.
- A single-position reservation retains its child UUID and contributes one
  resource unit.
- A root with N effective positions contributes N units, not N+1.
- Standalone roots contribute one effective unit.
- An active but offline position does not increase current online capacity.
- Reservation counts and detail rows are not expanded across parent/children,
  so the list does not double-count a child row.
- Cancelled variants and no-show are excluded from utilization and planned
  value; cancellations and no-shows have separate counters.
- Parent relationship selection is explicit, avoiding ambiguous self-FK
  resolution.

These behaviors have direct helper tests, including whole-only, positions-only,
whole-plus-positions, inactive/offline children, mixed families and large
numbers of positions.

### 2.2 Confirmed correctness defects and risks

#### REPORTS-C01 — incorrect opening-hours denominator (confirmed)

`REPORT_OPEN_MINUTES_PER_DAY` is `16 * 60`, and the UI states “16h dziennie”.
The authoritative Booking and Calendar window is 08:00–20:00, or 720 minutes.
The report denominator is therefore 33.3% too large and the displayed
utilization is 25% lower than the correct value. Calendar tests only establish
parity by explicitly overriding the Reports helper with 720; they do not test
the default used by `/admin/reports`.

#### REPORTS-C02 — DST-sensitive number of days (confirmed)

`daysInRange` subtracts local `Date` values at noon and divides milliseconds by
86,400,000. In `Europe/Warsaw`, March 2026 evaluates to
`30.958333333333332` days and October to `31.041666666666668`. This changes the
utilization denominator around daylight-saving transitions. Calendar-date
arithmetic must count civil dates, not elapsed clock milliseconds.

The default reference date is also derived with `new Date().toISOString()`, so
during the first one or two local hours after midnight Warsaw can default to
the previous UTC date.

#### REPORTS-C03 — historical utilization uses current configuration (confirmed)

Every historical range is divided by the *current* active/online/booking-mode
capacity. There is no as-of-date capacity snapshot in the query. A position
that was bookable during the selected month but is inactive/offline now adds
zero numerator weight and zero denominator capacity. Conversely, positions
enabled later can inflate the denominator for earlier periods. The current
value is an estimate under today’s configuration, not authoritative historical
utilization.

This cannot be silently labelled historical utilization unless the business
accepts and clearly labels the “current configuration” basis or a historical
capacity model is introduced.

#### REPORTS-C04 — historical names ignore the reservation snapshot (confirmed)

Reservations contain `lane_name_snapshot`, documented as the historical name
at creation. Reports instead joins the current `shooting_lanes.name`. Inactive
resources still normally resolve and appear, but a renamed lane/position is
shown under its new name in old reports. Calendar already reads the snapshot;
Reports does not.

#### REPORTS-C05 — KPI/status semantics are not canonical (confirmed)

“Rezerwacje aktywne” includes `completed`, while excluding `no_show`. The admin
dashboard uses a different “active” definition that excludes cancellations but
still includes no-show. Thus similarly named operational KPIs can disagree.
Revenue terms are also ambiguous: planned value, paid value and unpaid/on-site
value mix booking status with payment statuses, and `free`/`voucher` fall into
the last bucket. These formulas need one documented status/payment matrix and
stable labels before they become a backend contract.

#### REPORTS-C06 — utilization sums intervals rather than their union (risk)

The helper adds weighted duration per row. Current atomic family conflict rules
normally prevent overlapping active bookings, so ordinary current data should
not double-count. Unlike Calendar, however, Reports does not union time ranges
per physical unit. Imported, corrected or legacy overlapping historical rows
could produce more than 100% utilization. A backend aggregation should reuse
Calendar’s unit/interval-union semantics or explicitly diagnose anomalous data.

#### REPORTS-C07 — date-range scans lack a dedicated date index (likely)

Repository migrations show no btree index beginning with
`reservations.reservation_date`. The date-bounded exact count and ordered row
read may therefore scan/sort a growing reservation table. This should be
confirmed with `EXPLAIN (ANALYZE, BUFFERS)` on representative non-production
data before adding an index, but it is a concrete scaling risk.

### 2.3 Events

Reports contains no event-registration count, capacity, revenue or payment
report. This is not a hidden calculation defect: Events are outside the current
dataset. Whether ETAP 6 must include event reporting is a product decision; it
should not be mixed into reservation KPIs without explicit status and revenue
semantics.

## 3. Filters

| Filter/capability | Status | Evidence / gap |
|---|---|---|
| Day/week/month/year mode | DONE | Client computes an inclusive range from a reference date. |
| Reference date | DONE | Native date input; reloads automatically. |
| Arbitrary date from/to | MISSING | No independent bounds. |
| Lane | MISSING | No resource filter. |
| Parent family | MISSING | No filter expanding a parent to root plus direct children. |
| Child position | MISSING | No exact child selector. |
| Reservation status | MISSING | Status is displayed only. |
| Payment status | MISSING | Payment status is displayed only. |
| Booking type whole/position | MISSING | Can be derived from resource kind but is not exposed. |
| Event vs reservation | MISSING / NOT IN CURRENT CONTRACT | Dataset contains reservations only. |
| Search | MISSING | No name/e-mail/phone/resource search. |
| Reset filters | MISSING | No reset control. |
| URL/query params | MISSING | State is local React state. |
| Persistence | MISSING | Reload returns to today/day. |
| User-facing pagination | MISSING | All rows are rendered after internal source paging. |

Filters should be applied by the database before summary aggregation and
detail pagination. Filtering only the already downloaded browser array would
not solve large-range payload or PII exposure.

## 4. Export

There is no current export. The removed experiment quoted CSV values but did
not neutralize spreadsheet-formula prefixes, so restoring it unchanged would
reintroduce CSV injection risk for customer-controlled fields.

A minimal safe export should:

- be generated server-side through an authenticated admin-only application
  route using the caller’s Supabase session, never a browser service-role key;
- reuse exactly the same validated filters and canonical status/payment
  semantics as the on-screen report;
- page/stream through the bounded backend detail contract rather than first
  materializing the complete year in browser memory;
- include UTF-8 BOM and stable column/timezone documentation;
- neutralize cell values beginning (after leading whitespace/control
  characters) with `=`, `+`, `-`, `@`, tab or carriage return, in addition to
  normal RFC-style quoting;
- avoid tokens, internal IDs and administrative notes;
- include customer contact data only if explicitly required for the approved
  operational export; an aggregate export should be PII-free by default;
- apply `private, no-store` response caching and a deterministic safe filename;
- return a controlled error for excessive ranges instead of timing out.

## 5. Large date ranges

| Range | Current behavior | Risk |
|---|---|---|
| 1 day | Exact count plus all matching 500-row pages; usually bounded. | Low at current scale, but still downloads contact PII and all rows. |
| 7 days | Same request pattern and client aggregation. | Low–medium. |
| 30 days | Complete rows and DOM rendering. | Medium as volume grows. |
| 90 days | Sequential paging, O(N) browser memory and O(N) rendering. | Medium–high. |
| 1 year | Full year exact count, full payload, client aggregation and all-row table. | High timeout, scan, payload, memory and UI-jank risk. |
| Entire available period | Not supported. | Correctly avoids an unbounded operation, but no controlled archival export exists. |

There is no per-row N+1 request; nested parent data is fetched by PostgREST.
The problem is breadth, not N+1. KPI aggregation, filtered counts, utilization
and grouped lane/day values should move to an admin-only database contract.
Only one bounded detail page should reach the browser. A suitable
`reservations(reservation_date, id)` index (and any filter-specific index)
should be justified with query plans after the final SQL shape is known.

## 6. Mobile UX

The code-level responsive review gives the same result at 320, 375 and 430
pixels:

- the shared shell uses safe horizontal padding;
- range controls are full-width and stack in one column;
- KPI cards stack to one column below 640 pixels;
- buttons meet a 44-pixel minimum height and focus rings are visible;
- long hierarchy names can wrap in KPI cards;
- the detail table is explicitly `min-w-[1100px]` inside a local horizontal
  scroll region, so it should not force page-level overflow but requires
  extensive two-dimensional scrolling to inspect one reservation;
- there is no mobile row/card alternative, sticky identifying column, column
  chooser or compact summary detail;
- there are no charts and no export button to assess.

At tablet widths the range controls become two columns, but the detail table
still scrolls. At desktop/max shell width the table is usable. The existing
tests assert CSS tokens only; there is no 320/375/430 browser screenshot or
interaction test. Therefore mobile is **PARTIAL**, not verified complete.

Minimal correction: retain the desktop table at large breakpoints and render
compact reservation cards below `md`, showing date/time, hierarchy label,
amount and statuses first, with customer contact behind an intentional detail
expansion.

## 7. Reports security and authorization

### Current strengths

- `/admin/reports` is fail-closed to admin in central middleware and checks the
  trusted database role again in the page.
- Data access uses the authenticated Supabase client and existing RLS; no
  service-role secret enters the browser.
- Anonymous users have no reservation-table access. Ordinary users have only
  owner-scoped rows. Instructors do not satisfy the global reservation policy.
- Raw query errors are reported through the safe client error mechanism and a
  controlled UI message is shown.
- No export endpoint currently broadens access.

### Residual module-specific risks

- All matching customer names, e-mails and phone numbers are loaded into
  browser memory even when the administrator only needs aggregate KPIs.
- A future browser-only CSV implementation would retain that broad PII payload
  and must not be restored from the removed experiment.
- `auth.getUser()` errors are not distinguished from a missing user in this
  page, producing an inaccurate login message during an Auth outage. Middleware
  remains fail-closed, so this is availability/error-semantics debt rather than
  unauthorized access.

No new broad table grant or service-role exposure is required to finish
Reports. New SECURITY DEFINER read functions must check `auth.uid()` and exact
admin role internally, have a safe `search_path`, owner/ACL preflight, and deny
`PUBLIC`, `anon` and `service_role` unless a separately justified contract says
otherwise.

## 8. Test coverage

The focused run executed 29 relevant tests across:

- `app/admin/reports/page.test.mjs`;
- `lib/admin/reports.test.mjs`;
- shared admin operational-UI tests;
- shared hierarchy-label tests.

Result: **29 passed, 0 failed**. The 17 Reports-specific tests cover exact-count
pagination/fail-closed behavior, stale requests, hierarchy inputs and capacity,
whole/position weighting, inactive/offline resources and preservation of the
existing formula locations. Most page tests are source-pattern tests rather
than behavioral rendering/data tests.

| Required area | Coverage |
|---|---|
| Complete dataset pagination | GOOD unit coverage |
| Parent/child capacity, N not N+1 | GOOD unit coverage |
| Whole-lane and child weighting | GOOD unit coverage |
| KPI numeric correctness | MISSING; tests assert source expressions, not results |
| 12-hour opening denominator | MISSING; current default is wrong |
| DST/date boundaries | MISSING |
| Canonical status/payment matrix | MISSING |
| Cancellation/no-show revenue behavior | MISSING behavioral assertions |
| Historical inactive/renamed resources | PARTIAL; current-capacity behavior is tested, historical correctness is not |
| Interval no-double-count/union | MISSING |
| Filters and reset/URL state | MISSING because feature is absent |
| Export authorization/content/CSV injection | MISSING because feature is absent |
| Large ranges/query plans/bounded payload | MISSING |
| 320/375/430 browser UX | MISSING |
| Admin allow and user/instructor deny | Route/RLS suites cover the boundary generally; no focused Reports E2E |

Required future regression fixtures should include: standalone, root whole,
single child, simultaneous non-overlapping children, inactive historical
child, renamed resource snapshot, cancelled/no-show/completed rows, every
payment status, Warsaw DST boundaries, more than 500 rows, concurrent count
change, formula-prefix customer values and role-matrix access.

## 9. Minimal implementation plan

### REPORTS-6A — canonical correctness and scalable read contract

**Scope**

- Agree and document the reservation/payment matrix for counts and the exact
  meanings of planned, paid and outstanding value.
- Make the 08:00–20:00 window and Europe/Warsaw civil-date arithmetic shared
  with Calendar instead of duplicating constants/calculations.
- Use `total_price` and `lane_name_snapshot` for historical facts.
- Decide utilization semantics explicitly: either “estimated using current
  configuration” with honest labelling, or introduce the minimal historical
  capacity source needed for an as-of-date metric. Do not claim authoritative
  historical utilization without that decision.
- Add an additive, admin-only aggregate RPC plus a separately bounded detail
  reader. Both accept validated from/to and the planned lane-family/status/
  payment/booking-type filters; summary values are computed over all filtered
  rows, never only the displayed page.
- Reuse physical-unit interval-union logic so anomalous overlaps cannot exceed
  100% silently.
- Add a date-leading index only after local query-plan evidence confirms it.

**Expected files/migrations**

- new Supabase migration and contract test;
- new shared Reports contract/parser/helper files;
- `lib/admin/reports.ts` and its tests;
- minimal call-site changes in `app/admin/reports/page.tsx` and its tests.

**Database:** YES.

**Risk:** HIGH for KPI semantics, MEDIUM technically because the readers are
additive.

**Deployment:** DB FIRST. Old app + new DB remains safe; new app + old DB must
not be deployed.

**Tests:** SQL role/ACL/PII contract, all status/payment cases, whole/child/no
double-count, 12-hour and DST boundaries, inactive/renamed history,
pagination/filter parity, malformed response and representative query plans.

**DONE:** each KPI has one documented/tested formula; Calendar/Reports capacity
parity uses the real default; historical limitations are explicit; summary is
DB-side and detail payload is bounded; no non-admin or PII expansion occurs.

### REPORTS-6B — filters, URL state and bounded detail navigation

**Scope**

- Add arbitrary from/to with safe presets and a defined maximum interactive
  span.
- Add hierarchy-aware parent, exact child, reservation status, payment status
  and whole/position filters.
- Compose every filter through the 6A backend contract.
- Add reset, URL query serialization, deterministic parsing and explicit Apply
  behavior to avoid a request on every keystroke.
- Add server-backed page/page-size navigation and total result feedback.
- Preserve stale-response and controlled loading/empty/error behavior; add a
  retry action.

**Expected files:** Reports page/components, URL/filter/parser helpers and
focused tests. No new DB change if 6A anticipated the final filters.

**Database:** NO after 6A.

**Risk:** MEDIUM.

**Deployment:** APP ONLY after 6A is deployed.

**Tests:** filter cross-product, parent expansion vs exact child, date
boundaries, reset/deep link/back-forward, page stability, stale response,
malformed data, role boundary and empty/error states.

**DONE:** all filters affect summary, detail and later export identically;
browser memory/DOM remain bounded for a one-year range.

### REPORTS-6C — safe CSV export and mobile completion

**Scope**

- Add an authenticated admin-only server route that streams/pages CSV from the
  6A contract with the exact 6B filters and no service-role browser access.
- Define minimal aggregate/detail export columns, explicitly approve any
  contact PII, neutralize spreadsheet formulas and set private/no-store headers.
- Add mobile reservation cards below `md`; keep the desktop table above it.
- Add compact filter actions and clear download progress/error feedback.
- Add 320/375/430/tablet/desktop Playwright coverage and a production smoke
  checklist.

**Expected files:** one API route and tests, Reports responsive components,
CSV helper/tests, page tests and Playwright spec.

**Database:** NO after 6A.

**Risk:** MEDIUM due to PII export; LOW–MEDIUM for layout.

**Deployment:** APP ONLY after 6B.

**Tests:** admin/user/instructor/anon route matrix, filter parity, large streamed
export, formula injection, quoting/Unicode/timezone, no tokens/internal fields,
no-store, mobile overflow/readability and desktop regression.

**DONE:** filtered CSV is safe and complete, excessive ranges fail
predictably, no full dataset is materialized in the browser, and reservation
details are usable without horizontal scrolling at 320–430 pixels.

## 10. Final decision

```text
ETAP 6 REPORTS:
PARTIAL

CURRENTLY WORKING:
Admin-only day/week/month/year reservation reporting; complete 500-row source
pagination; operational reservation/revenue/payment/cancellation/no-show KPIs;
hierarchy labels; correct N-vs-N+1 whole/position weighting; controlled
loading, empty, error and stale-response handling.

MISSING / BROKEN:
Utilization uses 16h instead of the authoritative 12h opening window; DST can
produce fractional day counts; historical capacity and names use current
configuration/names; KPI status/payment labels are not canonical; arbitrary
dates, hierarchy/status/payment/booking-type filters, user pagination, retry,
safe export and mobile detail cards are missing.

DATA CORRECTNESS RISKS:
Understated utilization, DST off-by-fractions, non-authoritative historical
capacity, renamed historical resources, inconsistent “active” definitions,
ambiguous revenue labels and possible overlap summation above 100% for anomalous
legacy data.

SECURITY RISKS:
No current access-boundary break was found. The main residual is unnecessary
browser loading of all filtered customer PII; a future export must be
admin-only, server-generated, no-store and formula-injection safe.

PERFORMANCE RISKS:
Exact counts plus sequential offset pages, likely no reservation-date btree
index, full client-side aggregation, O(N) browser memory and rendering, and a
particularly high timeout/jank risk for year-long datasets.

RECOMMENDED FIRST IMPLEMENTATION:
REPORTS-6A — canonicalize KPI/date/capacity semantics and add an additive,
admin-only, DB-aggregated summary plus bounded detail read contract.

DB CHANGE REQUIRED:
YES

DEPLOYMENT MODEL:
DB FIRST
```
