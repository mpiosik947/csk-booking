# CSK Booking — project roadmap rebase 2026-09

## Scope and evidence

This is a read-only comparison of the functional roadmap with repository HEAD
`43b1262 — docs: record calendar position smoke pass`. The review covered the
current App Router pages, API handlers, shared frontend/server helpers,
Supabase migrations and tests, recent Git history, security closeout reports
and production smoke evidence.

No application code, SQL, configuration, database, deployment or Git history
was changed. This report is the only file created by the review.

The current single-tenant security baseline remains closed with zero new
Critical, High or Medium P1 findings. This document is a product/engineering
roadmap review, not a new security audit.

## 1. Current product inventory

### Public and customer-facing modules

| Route | Current behavior | Completeness | Test evidence | Production evidence |
|---|---|---|---|---|
| `/` | Auth-aware landing page with navigation to booking, trainings, account/customer areas and role-aware admin entry. | Complete for the current product shell. | Covered indirectly by build, security-header tests and route smoke. | Public-page and header smoke passed. |
| `/booking` | Loads public booking configuration, supports standalone/root/position booking modes, hierarchy-aware V3 availability, duration and pricing selection, confirmation, atomic `create_reservation_v2` and confirmation e-mail. It fails closed on malformed availability and stale requests. | Functionally complete for current lane products. | Strong helper/contract coverage (63 focused booking/config tests), database RPC suites and five-scenario Playwright lane-family coverage. | Public configuration and booking-related security/e-mail flows were smoke-tested in production. |
| `/events` | Lists active events, shows details, accepts authenticated registrations, supports direct participant or reserve-list intent, confirmation and confirmation e-mail. | Partial: the event writer safely decides participant vs reserve atomically, but the displayed participant/free-place count is not authoritative for ordinary users. Active past events can remain visible until staff deactivates them. | Public page is checked by the admin Events suite and API/security suites; no dedicated browser E2E for the complete public event journey. | Registration, reserve promotion, confirmation and e-mail contracts have production smoke evidence. No current full UX smoke for availability/count presentation. |
| `/account` | Reads and edits the owner profile through `update_my_profile_v1`, handles declarations/qualifications, password change, data export and self-delete/anonymization. | Complete for the approved single-tenant account lifecycle. | Focused account/password/lifecycle tests and database security tests. | Password policy, export/delete/anonymization and profile hardening passed production smoke. |
| `/my-reservations` | Owner-scoped `get_my_reservations_v2` list, active/history separation, hierarchy labels, cancellation through controlled RPC, cancellation e-mail and check-in link. | Complete for current self-service. | Focused reservation helpers plus RPC/database tests. | Cancellation delivery, check-in and account-lifecycle compatibility passed production smoke. |
| `/my-events` | Owner-scoped training registrations, active/history grouping, status/payment details and controlled cancellation with reserve promotion. | Functionally complete at current scale; lacks dedicated browser E2E and list pagination/filtering for long histories. | Shared Event/API/security tests; primarily source/contract tests rather than end-to-end browser behavior. | Cancellation, reserve promotion and confirmation flows have production smoke evidence. |
| `/check-in/[token]` | Minimal public token lookup inside the approved validity window; no contact PII; mutation remains staff-only and idempotent. | Complete under SEC-005 contract. | Focused public check-in and DB tests. | Full SEC-005 production smoke passed. |
| `/events/confirm/[token]` | GET is read-only; authenticated owner confirmation is POST-only, owner-scoped and idempotent. | Complete under SEC-003 contract. | Focused server/API and DB tests. | Full owner/cross-user/repeat production smoke passed. |

### Administrative modules

| Route | Current behavior | Completeness | Test evidence | Production evidence |
|---|---|---|---|---|
| `/admin` | Role-aware operational dashboard with daily/monthly reservation metrics, arrival/check-in worklist, unpaid/no-show indicators, user-verification signals and upcoming event reserve-list signals. | Complete as current operational home. | Route-protection, status and shared UI tests. | Admin-route fail-closed smoke passed for all roles. |
| `/admin/calendar` | Day/week/month views, date/lane/type/history filters, entry previews, hierarchy-aware parent/child scope, events and lane blocks, effective-capacity occupancy and historical inactive resources. | Complete for current scope. | Strong calendar suite (current lineage records 152 focused checks after the position fix). | Single-position production smoke passed on `e60482a`, including Day/Week/Month, filters, inactive history, no sibling projection and zero residue. |
| `/admin/reservations` | Search, date/status filters, sorting, hierarchy labels, operational state actions, controlled cancellation/e-mail and responsive cards/table. | Complete for ordinary current volume; partial for scale because the list has no explicit bounded UI/server pagination. | Reservation state/action helper and DB suites; no dedicated browser E2E. | Controlled cancellation and hard-delete prevention passed production smoke. |
| `/admin/reports` | Day/week/month/year ranges, complete multi-page source loading, reservation/revenue/payment/cancellation/no-show KPIs, best day/top lane, hierarchy-aware utilization, detailed table and fail-closed empty/error handling. | Partial. It is a useful operational report, but not a finished reporting product. | 17 focused page/helper tests, including complete-dataset pagination and hierarchy utilization. | Admin route access is production-verified; there is no dedicated current production smoke of all KPI semantics and large datasets. |
| `/admin/users` | Admin-only server-side list RPC with search, role/verification filters, sorting, 25-row pagination, desktop table/mobile cards, accessible details modal, identity/contact edits, role, verification, admin note and all declarations/qualifications. | Done for ETAP 7 scope. | 16 directly associated page/route tests plus database RPC/RLS suites. | Route protection and controlled profile/admin RPCs passed production smoke. |
| `/admin/check-in` | Employee/admin operational worklist, date/search, profile verification, payment/attendance transitions, cancellation and QR/token lookup. | Complete for current roles and workflow. | Profile-read, reservation operational-state, check-in and database tests. | Check-in token, audit integrity and role restrictions passed production smoke. |
| `/admin/events` | Hierarchy-aware create/edit/activate/deactivate V2 RPCs, global or lane assignment, date/status sorting/filtering, participant/reserve/cancelled sections, approval, cancellation/promotion and mark-paid action. | Partial: core management is strong, but the list has no search or bounded pagination; public availability presentation is not authoritative; full cross-surface mobile/browser regression is missing. | 97 focused admin/helper checks plus API/e-mail/DB tests. Much UI coverage is source-contract based. | Event write, payment, registration, promotion, confirmation and e-mail paths have production evidence; not every consolidated admin/public UX path has one current E2E smoke. |
| `/admin/lane-blocks` | Hierarchy-aware list, active/inactive filter, create, edit and activate/deactivate through controlled RPCs with conflict handling. | Complete for current operational scale; long-list pagination/search is not implemented. | Lane-block helper and DB/concurrency suites. | Writer/ACL/hierarchy changes were deployed and postflight-tested during the feature series. |
| `/admin/lane-configuration` | Admin-only Read V2/family writer V2, standalone and parent/position creation, rename, limits, pricing, durations, booking modes, readiness, bulk position preparation, before/after confirmation, optimistic locking and audit. | Complete for current lane-family configuration scope. | 76 focused helper/page checks plus five local Playwright scenarios and extensive DB/concurrency coverage. | The hierarchy and configuration rollout was production-verified during its staged deployment; no change is required for this roadmap rebase. |

### API and RPC backbone

The repository contains controlled server/API paths for reservation creation,
reservation/event cancellation, account export/delete, registration,
reserve-promotion confirmation and five e-mail flows. The current database
model includes hierarchy-aware availability V3, reservation V2, Event V2,
family-locking, lane-block writers, lane-family configuration/creation,
owner-scoped reads, audit logging and hardened direct-DML/ACL boundaries.

The latest recorded full baseline before the calendar-only change was 614 Node
tests and 269 database checks. The calendar bugfix lineage then recorded 618
Node tests and 152 focused calendar checks. No SQL changed after the 269-test DB
baseline. This review did not rerun those suites because the task is inventory
and roadmap analysis only.

## 2. Rebased roadmap status

| Stage | Status | Current assessment |
|---|---|---|
| ETAP 1–5D — booking/reservations/hierarchy/blocks/events/calendar/check-in/e-mails/conflicts | **DONE** | The complete single-tenant operational backbone exists, is tested and has substantial production smoke evidence. Later hierarchy and security work replaced several original implementations without removing their business capability. |
| ETAP 6 — Reports | **PARTIAL** | Core KPI/revenue/utilization report exists and hierarchy correctness is tested, but filtering, export, flexible ranges and mobile/large-data operation are incomplete. |
| ETAP 7 — Users | **DONE** | All requested list/search/filter/sort/page/details/role/verification/note/declaration/mobile capabilities exist behind hardened RPCs and admin authorization. |
| ETAP 8 — Events / Trainings UX | **PARTIAL** | Core public/admin/customer flows exist, including reserve promotion and payment status, but public availability presentation is not authoritative and operational list/browser UX needs completion. |
| ETAP 9 — SaaS / multi-tenant | **TODO / DEFERRED** | It has not been implemented and must not be inferred from current single-tenant security. A second tenant is not ready. |

No old stage is wholly obsolete. Individual V1 writers/readers were replaced by
hierarchy-aware V2/V3 contracts; those implementation tasks are best marked
**OBSOLETE / REPLACED**, while the business stages they served remain done.

## 3. ETAP 6 — Reports

### What is implemented

- KPI cards for active reservations, planned/paid/unpaid revenue, cancellations,
  no-shows, top lane and best day.
- Hierarchy-aware effective-capacity utilization; a parent plus positions is
  not counted as independent duplicate capacity.
- Day, week, month and year ranges selected from a reference date.
- Exact-count, deterministic, 500-row batched loading for lanes and
  reservations, with duplicate/incomplete page fail-closed behavior.
- Detailed reservation table with hierarchy display name, customer/contact,
  price, reservation status and payment status.
- Admin-only authorization, stale-request protection and explicit
  loading/empty/error states.

### What is missing

- No arbitrary `from`/`to` date range.
- No lane/family/position filter.
- No reservation-status or payment-status filter.
- No search within the report.
- No export. A CSV experiment existed and was deliberately removed in commit
  `94be83c`; export therefore cannot be counted as delivered.
- No user-facing pagination, aggregation endpoint or virtualization for the
  detail table. Source pagination prevents silent truncation but still loads
  the full selected range into the browser.
- Mobile falls back to a horizontally scrollable table with `min-width: 1100px`;
  there is no compact mobile report/card layout.
- Revenue is operational reservation value, not a reconciled accounting model
  with refunds or an external payment ledger. Labels should remain explicit
  unless such a model is added.
- No dedicated production functional smoke for KPI parity on a representative
  hierarchy and large range.

**ETAP 6 verdict: PARTIAL.**

## 4. ETAP 7 — Users

### Delivered scope

- Admin-only `admin_list_users_v1` read contract.
- Server-side search by name/e-mail/phone.
- Role and verification filters.
- Newest, oldest, name and role sorting.
- Bounded 25-row pagination with count/range feedback.
- Responsive desktop table and mobile cards.
- Accessible details dialog with focus containment/return and Escape close.
- Basic identity, address/contact, exact role, verification, admin note,
  declarations and qualifications.
- Explicit save/confirmation for privileged actions, last-admin protection,
  stable errors and database audit.

There is no functional gap in the defined ETAP 7 checklist. Bulk actions and
user export are possible future conveniences, not evidence that this stage is
unfinished.

**ETAP 7 verdict: DONE.**

## 5. ETAP 8 — Events / Trainings

### Delivered scope

- Public event list/detail and authenticated registration.
- Atomic capacity enforcement and reserve-list placement in
  `register_for_event`.
- Customer confirmation UI and confirmation e-mail.
- Owner cancellation with 72-hour rule and automatic reserve promotion.
- Secure reserve-promotion link: read-only GET plus authenticated owner POST.
- `my-events` active/history views with payment and cancellation status.
- Admin V2 create/edit/activate/deactivate with hierarchy-aware lane assignment
  and conflict locking.
- Admin participant, reserve and cancelled sections; approval, controlled
  cancellation and `mark_event_registration_paid`.
- Idempotency, audit, e-mail escaping/delivery and direct-DML hardening.

### Confirmed product gap: public availability is not authoritative

`app/events/page.tsx` calculates participant and reserve counts from nested
`event_registrations`. An ordinary authenticated user can read only their own
registration through the current owner-scoped RLS policy, while an anonymous
request does not request registration rows at all. Consequently, the UI can
show `0 / limit`, `Wolne miejsca` or a normal registration action even when
other users already fill the event or a reserve queue exists.

This does **not** permit overbooking: `register_for_event` locks the event,
counts all active registrations inside its SECURITY DEFINER transaction and
returns `registered` or `reserve` correctly. The gap is inaccurate public UX,
not a write-integrity failure. The correct fix is a minimal aggregate public
availability contract with counts only and no participant PII; widening table
SELECT is not appropriate.

### Other missing maturity

- Public listing does not itself exclude past-but-still-active events; the RPC
  rejects a registration after start, but the stale event can remain visible.
- Admin Events has active/hidden filtering and date sorting, but no search,
  server pagination or bounded loading.
- Participant/reserve tables are not paginated.
- No consolidated Playwright flow covers public registration, reserve
  transition, owner confirmation, `my-events` and admin participant handling.
- Responsive classes and prior mobile polish exist, but there is no current
  390 px end-to-end regression for the complete Events workflow.
- Payment handling is the approved on-site status operation, not an online
  payment/refund product.

Instructor-event assignment is intentionally excluded. SEC-008 remains
deferred and is not a reason to expand this stage now.

**ETAP 8 verdict: PARTIAL.**

## 6. General product gaps

### Immediate correctness and completion gaps

1. Public Events needs an authoritative, PII-free availability summary.
2. Reports needs product-level filters, export and mobile/large-range behavior.
3. Events administration and participant lists need search/pagination for
   predictable operation as data grows.
4. Reservations, check-in and lane-block lists are rich but mostly unbounded;
   their query/load strategy should be reviewed before materially larger data
   volume.

### UX and coverage gaps

- Only lane-family creation currently has a real Playwright suite. Booking,
  reservations, Events, Calendar, Reports, Users and check-in rely heavily on
  Node source/contract tests, DB tests and manual production smoke.
- Several large client pages combine loading, validation, mutation and modal
  UI in one file (`account`, `admin/events`, `admin/check-in`). This raises
  regression cost even though current behavior works.
- `README.md` is still the generic create-next-app document and does not
  describe the product, local Supabase safety rules, test matrix or deployment
  workflow.
- No user-facing notification center or delivery history exists; e-mail failure
  is generally shown only in the initiating flow. This is enhancement scope,
  not a current blocker.

No placeholder screen was found among the requested product routes. Missing
items are depth/scalability/UX gaps in implemented modules rather than empty
route placeholders.

## 7. Technical debt

| Debt | Current evidence | Recommended handling |
|---|---|---|
| ESLint baseline | Last full confirmation: exactly 14 errors and 6 warnings, with zero new security-remediation regressions. | Pay down separately; add a no-new-errors gate before broad feature work. |
| Middleware convention | Next.js 16 warns that `middleware.ts` is deprecated in favor of the proxy convention. Current SEC-011 behavior is tested and production-safe. | Migrate mechanically with the full role/path matrix preserved. |
| Next package alignment | Runtime `next` is 16.3.4 while `eslint-config-next` remains 16.2.6. | Align versions during maintenance and rerun lint/build. |
| Test shape | Many UI tests inspect source text rather than exercising rendered behavior. | Add component/browser behavior tests; do not delete useful contract tests. |
| E2E breadth | One Playwright file covers five lane-family scenarios only. | Add a small critical-path E2E suite for booking, Events, Calendar and account/admin operations. |
| Large client components | Several pages exceed a comfortable single-component responsibility boundary. | Refactor only alongside focused tests; avoid a broad rewrite. |
| Database test split | Historical tests live under `tests_legacy_20260816`, while the active suite uses a consolidated baseline plus current deltas. | Document which suite is authoritative and retain explicit cross-writer coverage. |
| Project documentation | Generic README does not match the actual product or operational safeguards. | Replace with project-specific setup/test/deployment documentation. |

These are engineering-maintenance items, not functional or security blockers
for the current single-tenant installation.

## 8. Deferred — do not touch yet

The following remain consciously deferred:

- SaaS and `tenant_id` propagation.
- A second tenant.
- Authoritative instructor-to-event assignment and SEC-008 remediation.
- SEC-009 10B time-based retention, pending approved periods.
- Final privacy/terms owner identity, legal form, address and privacy contact.

They do not block ordinary feature development for the current single-tenant
CSK instance. They become mandatory at their already documented boundaries:
SaaS/tenant two, instructor participant access, retention automation or formal
commercial/legal completion respectively.

## 9. New priority order

### NEXT 1 — authoritative public Event availability

- **Goal:** return correct participant/free-place/reserve-state aggregates to
  `/events` without exposing registration PII, and hide/label elapsed events.
- **Why now:** this is the only concrete current customer-facing correctness
  mismatch found in the roadmap review. The writer is safe, but the UI can set
  the wrong expectation immediately before registration.
- **Scope:** new minimal read RPC/view or extension of a safe public Event DTO,
  `/events` parser/presentation, focused DB/Node tests and public browser smoke.
- **Risk:** medium-high because the aggregate must match the writer's status
  semantics and remain safe under RLS/concurrency.
- **Database:** yes, most likely an additive SECURITY DEFINER aggregate reader
  with strict ACL and no PII.
- **Model:** Codex Sol recommended for RPC/RLS/status-parity review; Terra can
  handle the UI after the contract is fixed.
- **DONE:** anonymous and authenticated users see the same authoritative
  counts/status; full events show reserve action; elapsed events are handled;
  `register_for_event` parity tests pass; no PII or broader table SELECT.

### NEXT 2 — finish Reports as an operational product

- **Goal:** complete ETAP 6 with arbitrary dates, lane/family/status/payment
  filters, safe export and a usable mobile detail view.
- **Why now:** Reports is the clearest unfinished historical stage and already
  has a correct hierarchy-aware calculation foundation.
- **Scope:** report contract/semantics, filters, export hardening (including CSV
  formula injection), mobile cards or responsive detail view, and bounded
  large-range loading/aggregation.
- **Risk:** medium; high if revenue semantics or a new aggregate RPC is added.
- **Database:** optional for a small UI iteration, recommended for scalable
  aggregation/export.
- **Model:** Terra for UI-only work; Sol if adding DB aggregation/financial
  semantics.
- **DONE:** all filters compose correctly, export is safe and complete, mobile
  needs no 1100 px table, large ranges are bounded, empty/error/stale states and
  hierarchy parity are tested and production-smoked.

### NEXT 3 — finish Events/Trainings operational UX

- **Goal:** close the remaining ETAP 8 admin/customer usability gaps after the
  availability contract is authoritative.
- **Why now:** the backend workflow is mature; search/pagination and consolidated
  UX tests provide more value than another new module.
- **Scope:** admin search/server pagination, paginated participant/reserve lists,
  public/my-events filtering/history polish and 390 px browser coverage.
- **Risk:** medium.
- **Database:** possibly, for bounded list/read RPCs; no change to Event V2
  writers should be needed.
- **Model:** Terra for frontend pagination/mobile; Sol if list RPC/RLS changes
  are required.
- **DONE:** bounded deterministic lists, preserved action state, accurate counts,
  mobile/browser flows and no regression in promotion/payment/e-mails.

### NEXT 4 — scale the remaining operational lists

- **Goal:** add bounded loading/pagination where needed in admin reservations,
  check-in and lane blocks.
- **Why now:** these modules work, but their client-side list strategy will
  become the next operational bottleneck after Reports/Events.
- **Scope:** inventory row counts/query limits, server filters/cursors,
  pagination UX and stale-response tests.
- **Risk:** medium.
- **Database:** only if safe list RPCs are needed.
- **Model:** Terra for existing-query UI work; Sol for new scoped readers.
- **DONE:** deterministic bounded loads, URL-stable filters, responsive UI and
  role/PII parity.

### NEXT 5 — quality and maintenance checkpoint

- **Goal:** reduce regression cost before another large feature tranche.
- **Why now:** only one feature has Playwright coverage and the lint/deprecation
  baseline is known but unresolved.
- **Scope:** critical-path E2E, component behavior tests, middleware-to-proxy
  migration, ESLint baseline, version alignment and product README.
- **Risk:** low-medium; route-protection migration requires careful regression.
- **Database:** no, except local fixture setup already used by E2E.
- **Model:** Terra; Sol review only for authorization-boundary changes.
- **DONE:** no lint baseline, aligned Next tooling, supported proxy convention,
  documented test/deployment workflow and stable E2E for the major journeys.

## 10. Final roadmap decision

```text
CURRENT PRODUCT STATUS:
Production-capable, security-hardened single-tenant booking and operations
system. Core booking, hierarchy, reservations, check-in, lane administration,
calendar and controlled event workflows are live. Reports and Events UX remain
the two meaningful partial functional areas.

ETAP 1–5D:
DONE

ETAP 6 REPORTS:
PARTIAL

ETAP 7 USERS:
DONE

ETAP 8 EVENTS/TRAININGS:
PARTIAL

ETAP 9 SAAS:
DEFERRED / NOT READY

IMMEDIATE NEXT TASK:
Add an authoritative, PII-free public Event availability/count contract and
align /events presentation with register_for_event semantics.

NEXT 3 PRIORITIES:

1. Correct public Event availability and elapsed-event UX.
2. Complete Reports filters, safe export, mobile and large-range behavior.
3. Complete Events/Trainings search, pagination and cross-surface browser UX.

BLOCKERS BEFORE CURRENT SINGLE-TENANT FEATURE DEVELOPMENT:
NONE at the platform/security level. The public Event availability mismatch
should be fixed before promoting the training/reserve-list experience, but it
does not block unrelated single-tenant feature work.

BLOCKERS BEFORE SAAS:
End-to-end tenant/membership ownership and tenant_id isolation; tenant-scoped
RLS/RPC/API/audit/background jobs; authoritative instructor-event assignment;
tenant-safe lane-block visibility; approved retention rules; final legal
controller/contact data before the relevant commercial boundary.
```
