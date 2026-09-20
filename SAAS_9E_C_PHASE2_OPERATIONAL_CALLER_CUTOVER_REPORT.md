# SAAS-9E-C Phase 2 — local operational caller cutover

## 1. Scope and boundaries

Frozen scope: 28 distinct staff operational contracts, 24 direct staff UI call sites on four screens, seven downstream cancellation-flow call sites, and two additional global Account/Dashboard call sites (26 directly affected application sites, 33 including downstream). Nineteen versioned public RPCs were added: 18 SECURITY DEFINER and one SECURITY INVOKER. Four additional closed, direct-EXECUTE-denied SECURITY INVOKER implementation helpers were added. No historical migration, RLS policy, production schema, deployment or Git index was changed. `AGENTS.md` was not modified by this phase; it remains unrelated. `supabase/drafts/` remains quarantined and non-deployable.

Four ordered, forward-only local migrations:

| Subphase | Migration | Focused rollback-only SQL | Result |
| --- | --- | --- | --- |
| C2-A Events | `20260927100000_add_tenant_scoped_staff_event_rpcs.sql` | corresponding `_test.sql` | 28/28 PASS |
| C2-B Lane Configuration | `20260927110000_add_tenant_scoped_lane_configuration_rpcs.sql` | corresponding `_test.sql` | 18/18 PASS |
| C2-C Reports | `20260927120000_add_tenant_scoped_admin_reports.sql` | corresponding `_test.sql` | 14/14 PASS |
| C2-D Users | `20260927130000_add_tenant_scoped_admin_users.sql` | corresponding `_test.sql` | 20/20 PASS |

All four migrated in order during the approved local-only reset. The 9E-C Phase 1 production baseline remains unchanged. Source-definition normalized fingerprints, missing/duplicate target gates and 76→83→86→88→94 DEFINER count gates fail closed. SQL functions retain guarded legacy caller compatibility; no existing function was replaced.

## 2. Four operational surfaces

| Selected URL | Operational calls | Selected-tenant safe | Legacy/global calls on selected URL | Gate |
| --- | ---: | ---: | ---: | --- |
| `/t/[slug]/admin/events` | 10 UI plus 7 downstream cancellation/promotion calls | 17 | 0 | PASS |
| `/t/[slug]/admin/lane-configuration` | 4 UI | 4 | 0 | PASS |
| `/t/[slug]/admin/reports` | 3 UI | 3 | 0 | PASS |
| `/t/[slug]/admin/users` | 7 UI | 7 | 0 | PASS |

Events: the bounded list, participant list, event create/update/activation, registration approval/payment and cancellation now use selected-T contracts. The event's tenant and attached lane tenants must match the route's server-resolved T. The cancellation API resolves the slug server-side, validates caller/resource T before the versioned cancellation RPC, and checks the promotion claim's event/recipient tenant before sending; old URL behavior remains a separate branch. Public participant PII is not exposed. The selected event list uses the existing table SELECT/RLS, so the one new list wrapper is INVOKER.

Lane Configuration: the selected reader, family creator and versioned family writer use T, including root/child/config/rule/pricing/duration consistency. Closed INVOKER cores are neither directly granted to browser roles nor service_role. Existing version locks, resource constraints and old `/admin/lane-configuration` work as before.

Reports: versioned KPI and export pass T to the already tenant-filtered core **before** aggregation, row counting and export selection. The authenticated caller still needs active admin membership; employee is not promoted. The existing output, pagination and PII scope remain unchanged. No client-side filtering of a global report is used.

Users: list, tenant role, tenant note, verification, identity and contact use six versioned T-first contracts. Active membership and the existing role matrix are enforced in each function, and profile PII is limited to approved operational relationships (membership, reservation or event registration in T). B-only and unrelated global users are denied from A. Tenant notes/verification are independent for A and B. Role mutation retains the tenant-local advisory lock, member target check and last-admin rule. Mutations preserve existing tenant-bound audit and no-change behavior. `profiles.role` alone does not authorize.

The selected routes are mounted only after trusted server slug resolution and staff-context checks. The browser's T parameter is a selector, not authorization. The DB independently checks active tenant/membership and stored resource ownership. Pending/suspended/missing membership denies privileged operations; instructor scope is not expanded.

## 3. Global pages, old URLs and privacy

`/account` remains a global account-wide profile/export/delete surface. It no longer calls the exact-single-active tenant verification bridge or presents one tenant's status as global. Declaration changes still show the existing re-verification guidance. `/dashboard` no longer reads global `profiles.role` as tenant staff authority or calls the tenant-verification bridge; it offers an explicit CSK location link without selecting a tenant behind the user's back. The global pages do not receive a foreign tenant slug. Tenant-specific state belongs to selected routes.

Old `/admin/*` pages remain explicit CSK compatibility branches through C3. They are not redirected from new selected operational routes. Reservation ICS is unchanged and remains C3 legacy. Other tenant staff placeholders (root, Reservations, Calendar, Check-in and Lane Blocks) are not activated in this phase. No service_role key enters browser code, no table RLS/ACL expansion is made, and no account-wide lifecycle flow is conflated with leaving a tenant.

## 4. DEFINER/INVOKER justification and inventory

| New protected DEFINER | Why INVOKER is insufficient under existing browser RLS/ACL | Tenant and audit boundary |
| --- | --- | --- |
| `admin_list_event_registrations_v2` | staff-only participant/PII join | event T, minimal DTO, read-only |
| `admin_create_event_v3` | atomic event plus lane assignment | explicit T and lane validation, existing audit |
| `admin_update_event_v3` | atomic event/lanes update | event+lanes T, existing audit |
| `admin_set_event_active_v3` | protected state change | event T, existing audit |
| `approve_event_registration_v2` | protected status mutation | registration/event T, existing audit |
| `mark_event_registration_paid_v2` | protected payment mutation | registration/event T, existing audit |
| `cancel_event_registration_v2` | owner/staff cancellation, capacity/audit | event/registration T, existing audit |
| `admin_get_lane_booking_configuration_v3` | protected staff configuration DTO | resource/family T, read-only |
| `admin_create_lane_booking_family_v2` | atomic hierarchy/config creation | all created resources T, existing audit |
| `admin_set_lane_booking_family_configuration_v3` | lock/version/config/hierarchy mutation | route/root/children T, existing audit |
| `admin_get_reservation_report_v3` | bounded admin aggregate and detail | T before aggregate, read-only |
| `admin_get_reservation_report_export_v2` | bounded admin export | T before row selection, existing PII scope |
| `admin_list_users_v2` | protected relationship/profile/notes join | active T admin and related users, read-only |
| `admin_set_user_role_v2` | member role + last-admin lock | target member T, tenant audit |
| `admin_set_user_note_v2` | protected note and audit | operational relationship T, tenant audit |
| `update_tenant_profile_verification_v2` | protected verification writer | target relationship T, tenant audit |
| `update_tenant_profile_identity_v2` | protected global identity correction | target relationship T, tenant audit |
| `update_tenant_profile_contact_details_v2` | protected contact correction | target relationship T, employee customer-only, tenant audit |

All these new client-facing DEFINER functions are postgres-owned with fixed `pg_catalog,public,pg_temp` search_path and authenticated-only EXECUTE; PUBLIC/anon/service_role have no direct EXECUTE. The one client-facing INVOKER is `admin_list_events_v2` (existing tenant-aware event SELECT/RLS and bounded DTO). Four implementation cores are INVOKER and closed to PUBLIC/anon/authenticated/service_role. No new broad table grants. DEFINER count: **76 + 18 = 94**; new INVOKER total **5**, comprising one callable list entry and four closed internal helpers. Exact function ACL/inventory regression test passes.

## 5. Bridge and 4D-2 state

Bridge definitions remain **22**; seven compatibility CSK defaults remain **7/7**. Active legacy source call sites: **20 before; 18 after**. The two Account/Dashboard implicit verification calls were removed. Twelve old staff call sites remain on explicitly retained old `/admin/*` pages, plus six C3 sites: old Booking config, Events list, BookingForm verification, My Reservations list, My Events list and reservation ICS. New selected-T branches are counted separately, not falsely subtracted from live old URL compatibility. `get_my_role()` direct app/API calls: **8 before, 8 after**, four in the old admin pages plus homepage, admin root, calendar and calendar-feed; the selected branches use `get_my_tenant_role_v1(T)`. `is_admin()`, `is_admin_or_employee()` and `is_admin_or_staff()` have no identified direct app callers, but DB dependents require the later catalog gate. **4D-2 zero-caller gate NOT MET.** C3 must remove legacy old URL/ICS callers and remaining global role authority before separate production closure review.

## 6. Local evidence, races and cleanup

- Canonical local DB target confirmed `127.0.0.1:54322`; `supabase db reset --local` replayed the entire chain through C2-D. No linked or production command.
- Focused C2-A/B/C/D SQL **28/28, 18/18, 14/14, 20/20**; rollback and cleanup PASS. Full SQL suite **50 files, 1527/1527 PASS**. Historical regression tests changed only exact function inventory, ACL and audit-writer expectations due to the 23 additions; no old migration modified.
- Node **773/773 PASS**; `npx tsc --noEmit` PASS; `npm run build` PASS (existing Next middleware deprecation warning). Focused Playwright tenant Events, Lane Configuration, Reports, Users, old URL, Account and Dashboard: **5/5 PASS**. Initial sandbox-restricted Docker access attempt was rerun with authorized local Docker access and passed.
- Local concurrent old and new tenant role demotions: one winner, last admin retained, deadlocks 0; concurrent identity/contact updates: no lost updates, tenant audit 2, cleanup 0. Existing lane-family concurrent writer/reparent A/B matrix: PASS, deadlocks 0, cross-tenant hierarchy 0, cleanup 0. Event registration concurrency regression: PASS, cleanup 0. No production stress test.
- Changed-file ESLint PASS, including `app/account/page.tsx` after scheduling its existing initial async profile load after the effect rather than synchronously setting state. `git diff --check` PASS. Local post-test synthetic marker counts: auth users **0**, tenants **0**, profiles **0**, memberships **0**.

## 7. Deployment compatibility and decisions

| App / DB | Result | Reason |
| --- | --- | --- |
| Current app + current DB | PASS | production baseline untouched |
| New app + current DB | UNSAFE | selected routes call new versioned RPCs absent from old DB |
| Current app + new DB | PASS by additive local contract | old signatures/bodies/ACL retained; production verification still required |
| New app + new DB | PASS locally | full local SQL/Node/build/Playwright; production still unverified |

Deployment must be DB-first with a separate fail-closed production preflight and approvals per phase; this task does **not** initiate it. Known C3 residual: old `/admin/*`/Booking/Events/owner lists/ICS, four global-role helper caller locations beyond the old staff pages, remaining staff route placeholders, and final 4D-2 zero-caller proof. 9D-5 and second tenant remain prohibited. SEC-004 remains OPEN.

## Final verdict

SAAS-9E-C PHASE 2 LOCAL: PASS
PHASE 2 OPERATIONAL CONTRACTS: 28
PHASE 2 CALL SITES: 26 direct app; 33 including seven cancellation downstream
EVENTS ROUTE: PASS
LANE CONFIGURATION ROUTE: PASS
REPORTS ROUTE: PASS
USERS ROUTE: PASS
ACCOUNT: PASS
DASHBOARD: PASS
GLOBAL ROLE AUTHORITY: ABSENT on selected routes; legacy old URLs remain C3
RESOURCE-TENANT CHECKS: PASS
LAST-ADMIN: PASS
CROSS-TENANT PII: PASS
AUDIT: PASS
ACTIVE LEGACY CALL SITES BEFORE: 20
ACTIVE LEGACY CALL SITES AFTER: 18
BRIDGE DEFINITIONS: 22
SECURITY DEFINER BEFORE: 76
NEW DEFINER: 18
NEW INVOKER: 5 total (one public entry + four closed cores)
SECURITY DEFINER AFTER PHASE 2: 94
4D-2 ZERO-CALLER GATE: NOT MET
4D-2: NO-GO until production proof
COMPATIBILITY DEFAULTS: 7/7
READY FOR PHASE 2 PRODUCTION PREFLIGHT: GO (separate authorization; not started)
READY FOR PHASE 3: NO-GO until review
READY FOR 9D-5: NO-GO
SECOND TENANT: NO-GO
SEC-004: OPEN

## PRODUCTION PREFLIGHT & DEPLOYMENT READINESS (read-only, 2026-09-19)

### Phase 2A isolated-deployment pre-move record (2026-09-19)

The owner separately approved a temporary, reversible CLI-input quarantine of only the later pending migration files B/C/D outside `supabase/migrations`. Exact source-file SHA-256 values, recorded **before** any move, are:

| Phase | File | Pre-move SHA-256 |
| --- | --- | --- |
| A (remains in migrations) | `20260927100000_add_tenant_scoped_staff_event_rpcs.sql` | `1247892852A57B5A9DD98777F21EF585010FAA5F16A259DB3CE03B9DC574B3CE` |
| B | `20260927110000_add_tenant_scoped_lane_configuration_rpcs.sql` | `9278A24579203A93F093CBB3E12C96F21CBEF46FF3A9CC781AF7334E9B612F1E` |
| C | `20260927120000_add_tenant_scoped_admin_reports.sql` | `4AD9932878A1DB0C5662FFFF64A9DCC4DF312DB237DFD783BFDBD79B3A39151F` |
| D | `20260927130000_add_tenant_scoped_admin_users.sql` | `19BCF96E06BD533B1A87A8BD25CBC311126C552847580CE8870D666AE03F4468` |

No application deployment, B/C/D production write, migration repair, or Git staging/commit/push is authorized in this Phase 2A step. This record is not a deploy verdict.

This section is **pre-deployment evidence**, not a production PASS for the new contracts. No `db push`, migration repair, production SQL write, application deployment, Git staging/commit/push, second-tenant activation or fixture was performed. The linked project ref read from `supabase/.temp/project-ref` and the production SQL Editor URL both equal `yuyxfodozzpzrdzkmolu`. Supabase CLI was v2.109.1; its newer-version notice is informational. All SQL Editor queries below were SELECT-only aggregates/fingerprint checks and returned no customer rows or PII.

### 1. Working tree and canonical migration set

`HEAD=8e97858107d113b170a9fd5ca957572bf19d37d1`. Raw `git status --short` has 40 tracked modifications and 12 untracked paths (the `supabase/drafts/` directory is one status path). `git diff --name-only`, `git diff --stat`, `git diff --check`, `git diff --ignore-cr-at-eol --name-only` and `git ls-files --others --exclude-standard` were inspected. The same 40 tracked paths have real, non-CRLF-only differences. `git diff --check` and `git diff --ignore-cr-at-eol --check` both exit 0; line-ending conversion warnings are environmental, not extra content. No tracked historical migration has a real diff.

| Classification | Exact scope |
| --- | --- |
| New canonical DB migrations | The four `20260927*` files below; no other new migration. |
| App runtime / selected routes | `app/admin/events/page.tsx`, `app/admin/lane-configuration/page.tsx`, `app/admin/reports/page.tsx`, `app/admin/users/page.tsx`, `app/t/[slug]/[...path]/page.tsx`, `app/account/page.tsx`, `app/dashboard/page.tsx`. |
| Server cancellation/claim boundary | `app/api/cancel-event-registration/route.ts`, `lib/server/event-reserve-promotion.ts`. |
| Focused/operational tests | `app/admin/events/tenant-cutover.test.mjs`, changed Events/Lane/Users/Account/tenant-verification tests, `tests/e2e/tenant-admin-events.spec.ts`, changed `tests/e2e/tenant-routing.spec.ts`, `scripts/saas9d4b1b-concurrency.mjs`, and four new `20260927*_test.sql` files. |
| Regression ACL/inventory tests | Existing modified `supabase/tests/*` files: exact 129→152 function inventory, 60→79 authenticated grants, 76→94 DEFINER count, trusted audit writer 18→23, approved new helper/role allow-lists and source caller assertion. Their semantic diffs are confined to these Phase 2 expectations; no test outcome or existing migration was silently changed. |
| Plan/report | `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md` (Phase 2 frozen plan) and this untracked report. |
| Excluded, not touched | `AGENTS.md` has a real but unrelated pre-existing diff and remains **excluded/unstaged**. `supabase/drafts/20260926100000_add_tenant_scoped_public_operational_readers.sql` is untracked, non-deployable and excluded. No unexpected real semantic diff was found in the remaining scope. |

| Deployment step | Canonical migration | Purpose and created function set | SHA-256 |
| --- | --- | --- | --- |
| C2-A DB 1 | `20260927100000_add_tenant_scoped_staff_event_rpcs.sql` | Seven new DEFINER Event/registration functions, one INVOKER bounded list, one closed INVOKER create core. Legacy sources retained. | `1247892852A57B5A9DD98777F21EF585010FAA5F16A259DB3CE03B9DC574B3CE` |
| C2-B DB 2 | `20260927110000_add_tenant_scoped_lane_configuration_rpcs.sql` | Three DEFINER family reader/create/writer functions and three closed INVOKER reader/create cores; requires C2-A count 83. | `9278A24579203A93F093CBB3E12C96F21CBEF46FF3A9CC781AF7334E9B612F1E` |
| C2-C DB 3 | `20260927120000_add_tenant_scoped_admin_reports.sql` | Two DEFINER tenant-first KPI/export functions; requires C2-B count 86. | `4AD9932878A1DB0C5662FFFF64A9DCC4DF312DB237DFD783BFDBD79B3A39151F` |
| C2-D DB 4 | `20260927130000_add_tenant_scoped_admin_users.sql` | Six DEFINER tenant-specific list/role/note/verification/identity/contact functions; requires C2-C count 88. | `19BCF96E06BD533B1A87A8BD25CBC311126C552847580CE8870D666AE03F4468` |

These are the only canonical pending migrations, ordered A→B→C→D. `supabase/drafts/` is outside the chain. Each migration has source fingerprint, missing/duplicate target and count gates; target count sequence is 76→83→86→88→94. The app cutover depends on **all four** DB steps. No migration file was edited during this preflight.

### 2. Migration history and production baseline

The approved local-only reset evidence was checked against the actual local `supabase_migrations.schema_migrations`: filesystem **106 versions**, local DB **106**, `db_only=0` (including no removed draft ghost), `fs_only=0`. Canonical Phase 2 versions `20260927100000`, `110000`, `120000`, `130000` are all present locally. Linked production `migration list --linked` returned equality through `20260926100000`, then precisely those four local-only rows with empty Remote; remote-only, malformed and historical mismatches **0**. The linked read-only SQL Editor showed exactly one active CSK tenant, 9 memberships and **76** public SECURITY DEFINER functions. The preflight compared all **20 normalized source function fingerprints** embedded in the four migrations: `expected=20, missing=0, drift=0`. All **23** new target names were absent. The 22 stored legacy bridge *callers/definitions* remain 22; this is not the active application caller count. Seven CSK compatibility defaults remain 7/7.

Production aggregate integrity queries returned **0** for registration↔event, event-lane↔event/lane, lane↔parent, reservation↔lane and block↔lane tenant mismatches; **0** membership duplicates/orphans/unknown roles/unknown statuses; **0** orphan rules, durations, pricing and family-version roots. The production tables had 11 events, 11 lanes, 11 reservations at this point in time, with zero event registrations lacking an event. Counts are observational, not a pre/post deployment data baseline. FK/check constraints and local rollback-only tests cover additional states not present in the single-active-tenant production dataset. No production Tenant B fixture or cross-tenant write was created.

### 3. Full operational inventory and route completeness

Notation: **T** = UUID from server-validated `/t/[slug]`, then independently checked in DB; **E/R/L/F/U** = persisted event/registration/lane/family/user relationship; **M** = active tenant membership/role; **G/B** = old global role/exact-single-active bridge. `D`/`I` below mean SECURITY DEFINER / INVOKER; `API` is a server route; `table` means SELECT under RLS; `S` means service_role server-only. PII `C` is existing bounded participant/customer DTO, `P` operational user/profile fields, `S` internal email recipient/claim; `0` none. Audit `T` is tenant-owned mutation, `S` service delivery/claim, `—` none. The source and target boundary below is *the proposed Phase 2 app*, not a claim the old deployed app already uses it.

| ID / surface | Caller operation → RPC/API; R/W | Current → target tenant/resource source | Role; PII; audit; target mode |
| --- | --- | --- | --- |
| E1 Events | page role → `get_my_tenant_role_v1(T)`; R | G → server T/M | A/E/I; 0; —; existing D |
| E2 Events | lane picker → `shooting_lanes` SELECT; R | old lane read → T=L, RLS | A/E; 0; —; table/I |
| E3 Events | list → `admin_list_events_v2(T,...)`; R | B → T before totals/page/lanes | A/E/I; 0; —; new I |
| E4 Events | participants → `admin_list_event_registrations_v2(T,E,...)`; R | E/R → T=E=R | A/E/I; C; —; new D |
| E5 Events | create/assign lanes → `admin_create_event_v3(T,...,L[])`; W | B → T=all L | A/E; 0; T; new D + closed I core |
| E6 Events | edit/assign lanes → `admin_update_event_v3(T,E,...,L[])`; W | E → T=E=all L | A/E; 0; T; new D |
| E7 Events | activate → `admin_set_event_active_v3(T,E,...)`; W | E → T=E | A/E; 0; T; new D |
| E8 Events | approve → `approve_event_registration_v2(T,R)`; W | R→E → T=R=E | A/E; C; T; new D |
| E9 Events | cancel → `/api/cancel-event-registration?tenant=slug`; W | R→E → server T=R=E | A/E; bounded C; T/S; API + D3 |
| E10 Events | mark paid → `mark_event_registration_paid_v2(T,R)`; W | R→E → T=R=E | A/E; C; T; new D |
| D1 cancellation | slug resolver → `resolve_active_tenant_by_slug_v1`; R | slug → active T, not authority | request; 0; —; existing D |
| D2 cancellation | `event_registrations.tenant_id` guard; R | R→T under RLS | owner/staff; 0; —; table/I |
| D3 cancellation | `cancel_event_registration_v2(T,R)`; W | persisted R/E=T atomically | owner/staff per old contract; C; T; new D |
| D4–D5 cancellation | prepare/complete reserve promotion; W | event/claim/registration persisted T | S only; S; S; existing I |
| D6–D7 cancellation | server event and recipient SELECT; R | validated claim IDs and event T | S only; S; —; table/service only |
| L1 Lane | page role → tenant helper(T); R | G → T/M | A; 0; —; existing D |
| L2 Lane | configuration → `admin_get_lane_booking_configuration_v3(T)`; R | B → T=F=L/rules/pricing/durations | A; 0; —; new D + 2 closed I cores |
| L3 Lane | versioned family writer → `admin_set_lane_booking_family_configuration_v3(T,F,...)`; W | persisted F/root/children=T | A; 0; T; new D |
| L4 Lane | family create → `admin_create_lane_booking_family_v2(T,jsonb)`; W | B → explicit T for all new rows | A; 0; T; new D + closed I core |
| P1 Reports | page role → tenant helper(T); R | G → T/M | A; 0; —; existing D |
| P2 Reports | KPI/filter/page → `admin_get_reservation_report_v3(T,...)`; R | B → T before aggregate/count/filter | A; approved detail C; —; new D |
| P3 Reports | export → `admin_get_reservation_report_export_v2(T,...)`; R | B → T before row selection/limit | A; approved reduced C; —; new D |
| U1 Users | page role → tenant helper(T); R | G → T/M | A; 0; —; existing D |
| U2 Users | list → `admin_list_users_v2(T,...)`; R | B → T operational relationship | A; P; —; new D |
| U3 Users | role → `admin_set_user_role_v2(T,U,role)`; W | target member T + last-admin lock | A; P; T; new D |
| U4 Users | note → `admin_set_user_note_v2(T,U,note)`; W | related U and T note | A; P; T; new D |
| U5 Users | verification → `update_tenant_profile_verification_v2(T,U,...)`; W | related U and T verification | A; P; T; new D |
| U6 Users | identity → `update_tenant_profile_identity_v2(T,U,...)`; W | related U before global identity write | A; P; T; new D |
| U7 Users | contact → `update_tenant_profile_contact_details_v2(T,U,...)`; W | related U; employee customer-only | A, E only in separate approved RPC workflow; P; T; new D |

A/E/I = active tenant admin/employee/instructor; instructor is list/participant **read-only** in Events and has no new writer access. Ordinary user cannot access selected staff pages; owner self-cancellation remains only under the established API/RPC contract. `profiles.role` is not authority. SYSTEM is server-only for D4–D7 and does not receive browser grants. The four selected route totals are Events **17/17 tenant-safe, 0 legacy/global** (10 direct UI + 7 downstream), Lane **4/4, 0**, Reports **3/3, 0**, Users **7/7, 0**. That is **31 staff operational call sites / 28 distinct staff contracts**. Two global Account/Dashboard calls are additionally removed/neutralized: **26 directly affected app call sites, 33 all-layer reviewed**. The detailed pre-change call signatures, exact source line references, role/resource matrix and current-vs-target tenant derivation are in the frozen plan section `SAAS-9E-C PHASE 2 — FINAL PLAN` and were cross-checked against the changed app/server files.

Events covers list, create, update, activation, lanes, participants, approval, paid state, cancellation and reserve-promotion side effects. No direct reject/delete or manual promote action exists on this screen. Selected cancellation validates slug and stored R/E before the new atomic wrapper; promotion verifies E/R/recipient T on the server before send. Lane reader/writer checks root, children, rule, duration, price and version resources; mixed hierarchies deny. Reports applies T in the DB before aggregate/KPI/count/group/filter/export, never global rows filtered in browser. Users uses active membership, admin/employee role limits and same-T operational relationship; B-only and unrelated U deny. Last-admin advisory/row-lock semantics and tenant-bound audit are preserved by cloned hardened sources and focused rollback/concurrency tests. These are static + local-test conclusions, **not** a fabricated production cross-tenant smoke.

Global `/account` remains account-wide; `/dashboard` remains a global landing/selector. Neither uses the exact-single-active verification bridge to present implicit CSK status after this app cutover. Old `/admin/*` stays a separate legacy CSK branch until C3; new `/t/[slug]/admin/*` executes selected-T calls and does not forward to the old global operation. Reservation ICS, Booking/owner lists and other staff placeholders remain deferred C3. This separation does not grant the browser `service_role` or a client-selected tenant authority.

### 4. DEFINER/INVOKER risk gate

The **18** new client-facing DEFINERs are exactly E4/E5/E6/E7/E8/E10/D3 (7), L2/L3/L4 (3), P2/P3 (2), U2–U7 (6). They require privileged access beyond browser table ACL/RLS: E4 needs a bounded participant/PII join; E5 atomic event plus lanes; E6 atomic edit/lane assignment; E7 status mutation; E8 registration approval; E10 payment mutation; D3 owner/staff cancellation with capacity/audit; L2 full protected config DTO; L3 locked family/hierarchy/version mutation; L4 atomic family creation; P2 DB-side aggregate/detail over protected reservations; P3 complete bounded export; U2 related-user/profile/note join; U3 last-admin role mutation; U4 tenant note/audit; U5 tenant verification/apply; U6 relationship-gated identity correction; U7 relationship-gated contact correction. Direct INVOKER under current client grants would either fail these joins/writes or require broader table privileges; existing RLS does not authorize those privileged staff workflows. Each wrapper compares server-selected T to persisted resource T and uses active membership/role; owner is postgres, search_path is fixed to `pg_catalog,public,pg_temp`, authenticated-only EXECUTE, no PUBLIC/anon/service_role direct grant. Client-visible PII and tenant audit retain the approved legacy scope. High-risk ones are D3 (capacity/notification), L3/L4 (hierarchy races) and U2–U7 (PII/last-admin).

The five new INVOKERs are E3 `admin_list_events_v2` plus four **closed** cores: Event create core, Lane v3 resource reader, Lane v3 family reader, Lane v2 creator core. E3 needs no privileged table access because existing tenant-aware Event SELECT RLS and grants plus its T predicate support the bounded non-PII DTO. The four cores are invoked only under the narrowly checked postgres-owned DEFINER wrappers and have direct EXECUTE revoked from PUBLIC/anon/authenticated/service_role; they do not enlarge the browser API. The cloned Lane reader cores independently check `auth.uid()` and active admin tenant role before returning config, even though the outer wrapper delegates. Local metadata/ACL regression tests assert the exact 23 new-function inventory. Unexpected DEFINER **0**, unknown mode/owner/ACL **0** in the local target. The production pre-state remains 76; the post-state **94 is a gated target, not yet a production observation**.

### 5. Legacy, rollout, runtime and risk

Measured active legacy bridge source sites **18**, not 22 definitions: 12 old `/admin/*` operational branches (Events list/create; Lane reader/create; Reports KPI/export; Users list/role/note/verification/identity/contact) and six C3 paths: `app/booking/page.tsx` booking config, `app/booking/BookingForm.tsx` owner verification, `app/events/page.tsx` public list, `app/my-reservations/page.tsx` owner list, `app/my-events/page.tsx` owner list, `app/api/calendar/reservations/[id]/route.ts` reservation ICS. Account/Dashboard bridge reads were removed, giving **20→18**. There are separately eight `get_my_role()` direct app/API source sites after target: old four staff pages, homepage, `/admin`, Admin Calendar and calendar-feed. `is_admin()`, `is_admin_or_employee()` and `is_admin_or_staff()` have no direct app call site in this inventory; all four named legacy role helpers still require a later catalog/dependency closure gate. **4D-2 zero-caller NOT MET; 4D-2 NO-GO**. All 22 bridge *definitions* and 7 defaults stay during Phase 2.

| Ordered production step, separately authorized | DB/app and compatibility gate |
| --- | --- |
| 0 | Recheck project ref, four SHA-256 values, history, all 20 fingerprints, 76 DEFINER, 7/7 defaults, 22 bridge definitions, integrity and runtime. Any drift: STOP. |
| 1 | DB-first C2-A; confirm 83 DEFINER and old-app compatibility before C2-B. |
| 2 | DB-first C2-B; confirm 86 and Lane metadata/ACL before C2-C. |
| 3 | DB-first C2-C; confirm 88 and tenant-first report reader/export before C2-D. |
| 4 | DB-first C2-D; confirm 94, 23-function target ACL and old-app/new-DB smoke before any app cutover. |
| 5 | **Separately approved** new app cutover; verify all four selected routes, old URL compatibility, cancellation/service email chain, PII, audit, Account/Dashboard and cleanup. On app failure, roll back app only to the previous compatible build; no DB downgrade/repair. |

| Compatibility state | Gate |
| --- | --- |
| Current app + current DB | PASS, observed production baseline. |
| New app + current DB | **UNSAFE / do not deploy**: 19 versioned RPCs absent. |
| Current app + new DB | Compatible by additive local contract; production smoke is mandatory after DB steps. |
| New app + new DB | Local PASS; production PASS only after the separate app deployment/smoke. |

The exact linked `supabase db push --linked --dry-run` returned exit 0 and **only** C2-A, C2-B, C2-C, C2-D above, in order. It explicitly stated migrations would not be pushed. No actual `db push` was executed. Local evidence is the already approved 1527/1527 full DB, 773/773 Node, 5/5 Playwright, TypeScript/build/changed-file ESLint PASS, local fixture cleanup 0, and `git diff --check` PASS; these suites were not rerun during this read-only preflight.

Read-only production HTTP gave `/` 200, global `/account` and `/dashboard` 200; anonymous old/new admin URLs redirected 307 to login, not 5xx. In the already-authenticated browser session, old Events, Lane Configuration, Reports and Users rendered their expected headings with no observed runtime error; `/t/csk/admin/{events,lane-configuration,reports,users}` rendered the **expected pre-cutover placeholder**, not the Phase 2 operational page. This is current-app baseline only, not validation of the future cutover. No mutation button was used and no customer data was exported.

Risk: Events **HIGH** (cancellation, capacity, promotion/recipient binding); Lane Configuration **HIGH** (family hierarchy and concurrency); Reports **MEDIUM** (tenant-before-aggregate/export, PII); Users **HIGH** (operational relationship, cross-tenant PII, last-admin). Overall Phase 2 **HIGH** because 18 new DEFINER entry points and four DB-first slices precede one app cutover. Mitigations are fail-closed migration source/target gates, fixed ACL/search_path, local cross-tenant/concurrency suite, ordered post-step verification and app-only rollback. Production currently has one active tenant, so a live A/B tenant smoke is intentionally unavailable; local rollback-only A/B tests and production catalog/integrity checks are the evidence. No missing preflight blocker was observed; production writes still require **separate, explicit approval and per-slice post-deploy verification**.

### Preflight verdict (not a deployment verdict)

SAAS-9E-C PHASE 2 PRODUCTION PREFLIGHT: **PASS**
WORKING TREE SCOPE: **PASS** (`AGENTS.md` unrelated/excluded; draft excluded)
LOCAL HISTORY: **PASS** (106/106, ghost 0)
PRODUCTION MIGRATION HISTORY: **PASS** (equal through `20260926100000`, four pending only)
CANONICAL MIGRATION SET: **PASS** (four files and SHA-256 values above)
PHASE 2 OPERATIONAL CONTRACTS: **28**
DIRECT CALL SITES: **26**
DOWNSTREAM CANCELLATION CALLS: **7**
EVENTS ROUTE: **PASS** (local target; production placeholder baseline)
LANE CONFIGURATION ROUTE: **PASS** (local target; production placeholder baseline)
REPORTS ROUTE: **PASS** (local target; production placeholder baseline)
USERS ROUTE: **PASS** (local target; production placeholder baseline)
ACCOUNT: **PASS** (global/account-wide preserved locally)
DASHBOARD: **PASS** (global selector preserved locally)
GLOBAL ROLE AUTHORITY: **ABSENT** on new selected routes
RESOURCE-TENANT CHECKS: **PASS** (local target + production baseline integrity)
LAST-ADMIN: **PASS** (local concurrent matrix; production not mutated)
CROSS-TENANT PII: **PASS** (local A/B tests; no production B fixture)
AUDIT: **PASS** (local tenant-bound tests; production not mutated)
ACTIVE LEGACY CALL SITES: **18**
BRIDGE DEFINITIONS: **22**
SECURITY DEFINER BEFORE: **76**
NEW DEFINER: **18**
NEW INVOKER: **5**
SECURITY DEFINER AFTER PHASE 2: **94 target, not yet production state**
4D-2 ZERO-CALLER GATE: **NOT MET**
4D-2: **NO-GO**
COMPATIBILITY DEFAULTS: **7/7**
DEPLOYMENT ORDER: **four separately gated DB-first migrations A→B→C→D, then separately approved app cutover**
DRY-RUN: **PASS** (exactly four, no push)
READY FOR PHASE 2 PRODUCTION DEPLOYMENT: **YES, subject to separate production-write authorization**
READY FOR PHASE 3: **NO-GO until Phase 2 production PASS/checkpoint/review**
READY FOR 9D-5: **NO-GO**
SECOND TENANT: **NO-GO**
SEC-004: **OPEN**

## PHASE 2 APP CUTOVER — PRODUCTION DEPLOYMENT (2026-09-20)

The approved APP-only commit `0de210599286e7711679a2833d22b1e7654559e6` was pushed by ordinary fast-forward from `8e97858107d113b170a9fd5ca957572bf19d37d1` to `origin/main`. A fresh fetch before push established `behind=0, ahead=1`; after push, local HEAD, `origin/main`, and a fresh remote `ls-remote` all matched `0de210599286e7711679a2833d22b1e7654559e6`, divergence `0/0`. `AGENTS.md` remained modified, unrelated and unstaged; Phase 2 migrations, SQL tests and drafts were not included in this app commit.

GitHub's commit-status API reported `Vercel – csk-booking-5nwh: success / Deployment has completed` for this exact commit, target deployment `8pNN3dXBz3qNoStvy5yUPMWqJwSB`. It separately reported `Vercel – csk-booking: failure` for the **non-target** project, which is not the authoritative production deployment. The target production URL served the new selected-tenant UI in an authenticated CSK admin session; the global Account page displayed location-specific verification as a separate concern, and Dashboard displayed an explicit CSK location selector. Together with the exact target-project success status, this supports **new commit active**. Direct inspection of the private Vercel dashboard was unavailable because the browser session was not signed in there.

Exact deployed runtime scope: `app/admin/events/page.tsx`, `app/admin/lane-configuration/page.tsx`, `app/admin/reports/page.tsx`, `app/admin/users/page.tsx`, `app/t/[slug]/[...path]/page.tsx`, `app/api/cancel-event-registration/route.ts`, `lib/server/event-reserve-promotion.ts`, `app/account/page.tsx`, and `app/dashboard/page.tsx`; eight focused app/E2E test files accompanied them. No application-step DB migration or production SQL write was performed. The prior A–D DB postflight baseline was 94 public SECURITY DEFINER functions, 22 bridge definitions, 7/7 compatibility defaults and zero pending Phase 2 migrations; this app-only push did not change DB code. Those catalog counts were **not independently re-queried in this post-push browser smoke**.

Authenticated read-only production smoke on `https://csk-booking-5nwh.vercel.app`:

- `/t/csk/admin/events` loaded the tenant breadcrumb, full create form, CSK lane options, filters and controlled empty list without observed runtime error. No real event was created or edited.
- `/t/csk/admin/lane-configuration` loaded six lane families, five positions, configuration summary and controls. No writer action was submitted.
- `/t/csk/admin/reports` loaded resource options and KPI summary with a controlled empty result for the current date. No customer CSV was exported.
- `/t/csk/admin/users` loaded a nine-row staff-facing list with filters, status, pagination and detail controls. This verified the authorized CSK view only; no row PII is reproduced here and no user mutation was submitted.
- `/account` loaded as a global account page and explicitly stated that verification status belongs to a selected location, not to the global profile. `/dashboard` loaded as a global landing page with an explicit CSK location link; neither view automatically presented a tenant-specific verification status.
- Legacy `/admin/events`, `/admin/lane-configuration`, `/admin/reports` and `/admin/users` each loaded their legacy CSK view in the authenticated browser session. These remain compatibility routes, **not** tenant-ready routes.

The previously completed Phase 2 local and rollback-only A/B matrices are the cross-tenant isolation evidence. Production has one active CSK tenant, so two-active-tenant UI E2E was **not performed**. This browser smoke cannot independently prove all mutation authorization, resource mismatch, cross-tenant PII or audit branches; those rely on the reviewed DB contracts and prior rollback-only tests. There was no synthetic fixture in this app smoke, and no production business-data mutation.

Post-push source recount: the Phase 2 app cutover started from **18** active legacy operational call sites and removed **0 of those 18**, because the old CSK compatibility URLs and C3 callers remain live. The earlier Phase 2 preparation removed two Account/Dashboard implicit verification reads (the broader historical count was 20→18). The 18 C3 sites are 12 old `/admin/*` branches—Events list/create; Lane Configuration reader/create; Reports KPI/export; Users list/role/note/verification/identity/contact—and six other sites: `app/booking/page.tsx` booking config, `app/booking/BookingForm.tsx` owner verification, `app/events/page.tsx` public list, `app/my-reservations/page.tsx` owner list, `app/my-events/page.tsx` owner list and `app/api/calendar/reservations/[id]/route.ts` reservation ICS. The eight direct `get_my_role()` app/API sites remain: homepage, admin root, old Events, old Lane Configuration, old Reports, old Users, Admin Calendar and admin calendar-feed. Direct app calls to `is_admin()`, `is_admin_or_employee()` and `is_admin_or_staff()` were not found in the app inventory; DB dependencies still require separate 4D-2 proof. The **4D-2 zero-caller gate is NOT MET**.

SAAS-9E-C PHASE 2 APP DEPLOY: **PASS for the approved APP-only scope**
VERCEL DEPLOY: **PASS — target project `csk-booking-5nwh`**
PRODUCTION VERSION: **NEW COMMIT ACTIVE**
EVENTS TENANT ROUTE: **PASS — read-only authenticated smoke**
LANE CONFIGURATION TENANT ROUTE: **PASS — read-only authenticated smoke**
REPORTS TENANT ROUTE: **PASS — read-only authenticated smoke**
USERS TENANT ROUTE: **PASS — read-only authenticated smoke**
ACCOUNT: **PASS — global page smoke**
DASHBOARD: **PASS — explicit selector smoke**
OLD ADMIN URL COMPATIBILITY: **PASS — read-only smoke**
GLOBAL ROLE AUTHORITY: **ABSENT in selected tenant branches per reviewed source/DB contracts; old CSK routes remain legacy**
RESOURCE-TENANT CHECKS: **PASS in prior local/rollback matrices; not re-exercised with production mutations**
CROSS-TENANT PII: **PASS in prior local/rollback matrices; two-active-tenant production UI E2E not performed**
PRODUCTION CSK AUTHENTICATED E2E: **PASS for read-only page/list smoke; mutation workflows not exercised**
TWO-ACTIVE-TENANT PROD UI E2E: **NOT PERFORMED**
ACTIVE LEGACY CALL SITES AFTER: **18**
BRIDGE DEFINITIONS: **22 — prior postflight, not freshly re-queried**
SECURITY DEFINER: **94 — prior postflight, not freshly re-queried**
COMPATIBILITY DEFAULTS: **7/7 — prior postflight, not freshly re-queried**
4D-2 ZERO-CALLER GATE: **NOT MET**
READY FOR FINAL PHASE 2 CHECKPOINT: **YES for app deployment evidence; DB catalog refresh remains for checkpoint review**
READY FOR PHASE 3 PLANNING/REVIEW: **GO after checkpoint review**
READY FOR PHASE 3 IMPLEMENTATION: **NO-GO until checkpoint/review**
READY FOR 4D-2: **NO-GO**
READY FOR 9D-5: **NO-GO**
SECOND TENANT: **NO-GO**
SEC-004: **OPEN**

## PHASE 2D PRODUCTION DB DEPLOY AND POSTFLIGHT (2026-09-19)

The authorized D-only deployment used project `yuyxfodozzpzrdzkmolu` and the authoritative `20260927130000_add_tenant_scoped_admin_users.sql`, SHA-256 `19BCF96E06BD533B1A87A8BD25CBC311126C552847580CE8870D666AE03F4468`. Its frozen domain is Admin Users: list, tenant role, tenant note, tenant verification, identity and contact. Six DEFINER wrappers and zero INVOKER functions are added in D; the approved full-chain count is 76 → A 83 → B 86 → C 88 → D **94**, with five new INVOKERs across all of Phase 2 (one Events list and four closed cores). The six normalized source fingerprints in the migration (`bf37ec48de512ea45f5d4592df5f4eac`, `9732b7d53eaa080ebc6348cd1dd68ca2`, `e8245e2156b20e6d1dfd48b4adfb747b`, `022baa5652409d2246cd5e66642e884e`, `33e0a05fb0d142cd9ba7d99cc66c6652`, `ce0146bccc9a1cc1d89c3e4d26462586`) matched production before deployment.

The fail-closed gate observed A/B/C applied once, D as the sole local-pending migration and no remote-only history row. The linked dry-run listed **D only**. The production catalog contained 88 public DEFINER functions, 22 existing bridge definitions, 7/7 CSK compatibility defaults, exactly one active CSK tenant, and zero D target functions. The checked Users-domain membership, note and verification orphan counts were zero; duplicate `(tenant_id,user_id)` counts in these three tables were zero. CSK had one active admin membership. The partial unique second-active-tenant guard index was valid and unique. The authorized `npx.cmd supabase db push --linked` applied **only D** and exited 0. No quarantine, app deployment, migration repair or Git write was performed.

Linked history after push matched all 106 local/remote entries, including D exactly once; the final `db push --linked --dry-run` returned `Remote database is up to date`. All six normalized target hashes matched the local DB target, in name order: `admin_list_users_v2` `7333cc06535c24927ceaf4bd4643b690`; `admin_set_user_note_v2` `0243a4dfe347cce1f00d54c131de45ee`; `admin_set_user_role_v2` `09235cb51757cba97e98bee6a53dc267`; `update_tenant_profile_contact_details_v2` `9a446df6a06f1f3f6ce6616c6925b3b6`; `update_tenant_profile_identity_v2` `b0136d12d54def2800dd914ea32274a9`; `update_tenant_profile_verification_v2` `30f1028aa801afc1abd0df080a4fd17f`. Six exact signatures, `SECURITY DEFINER`, owner `postgres`, fixed `pg_catalog, public, pg_temp` search_path and authenticated-only EXECUTE all passed; PUBLIC, anon and service_role have no EXECUTE. The scoped unexpected function delta is zero. Catalog totals after rollback: **94 DEFINER, 22 bridge definitions, 7/7 defaults, one active CSK**.

The existing D focused SQL was run in production SQL Editor with only its three `psql` meta-command lines omitted; its 20 numbered assertions, fail-on-any-failure assertion, `BEGIN` and terminal `ROLLBACK` remained intact. There was no SQL error and the final result was `C2-D cleanup PASS`, establishing **20/20 PASS**. It covers same-T list and note/audit, foreign and unrelated user exclusion, global-role-only/pending/suspended denial, wrong-T role/note/identity/contact/verification denial, dormant B denial and temporary A/B read isolation without leaving B active. Additional rollback-only synthetic tests exercised (a) two-admin role demotion succeeds but the remaining last-admin demotion returns `last_admin`, while CSK active status is restored before rollback, and (b) successful related-user tenant verification, identity and contact mutations with A-bound audit. Both returned cleanup PASS. Independent SELECT after all three transactions showed **zero** synthetic auth accounts, profiles, tenants, verification records and audit marker rows; prior checks also showed zero notes. No real customer record was mutated. The production concurrency race was intentionally not load-tested: approved local concurrent old/new role demotions retained one admin, zero deadlocks and zero cross-tenant effects; the target cloned source retains the tenant advisory transaction lock and row locks. This is local concurrency plus production definition evidence, not a claim of a live race test.

Read-only HTTP GET smoke (following redirects) returned 200 without 5xx for `/admin/events`, `/admin/lane-configuration`, `/admin/reports`, `/admin/users`, `/account`, `/dashboard` and `/login`. The existing authenticated `/admin/users` screen loaded its list, filters and paging without an observed runtime error; no administrative action was submitted through the real UI. This is current-app + A+B+C+D DB compatibility evidence, not the Phase 2 selected-tenant app cutover. The source inventory still counts **18 active legacy app call sites**, separately from **22 bridge definitions**. `AGENTS.md` and `supabase/drafts/` remain unrelated/excluded. `git diff --check` passed (only line-ending conversion warnings); no staging, commit or push occurred.

SAAS-9E-C PHASE 2D DB DEPLOY: **PASS**
D ONLY: **PASS**
MIGRATION HISTORY: **PASS**
NO PENDING PHASE 2 MIGRATIONS: **YES**
PHASE 2D POST-DEPLOY: **PASS**
PHASE 2D DOMAIN: **PASS for exercised Users matrix and reviewed frozen source semantics**
RESOURCE-TENANT CHECKS: **PASS**
ROLE MATRIX: **PASS**
LAST-ADMIN: **PASS (rollback-only sequential boundary; concurrency local + lock definition)**
CROSS-TENANT PII: **PASS in synthetic A/B matrix**
AUDIT: **PASS in rollback-only writer checks**
SECURITY DEFINER COUNT: **94**
BRIDGE DEFINITIONS: **22**
COMPATIBILITY DEFAULTS: **7/7**
FIXTURE CLEANUP: **PASS / 0**
CURRENT APP + FULL PHASE 2 DB: **PASS for observed runtime smoke**
READY FOR PHASE 2 APP CUTOVER: **YES — separate authorization required**
READY FOR PHASE 3: **NO-GO**
READY FOR 4D-2: **NO-GO**
READY FOR 9D-5: **NO-GO**
SECOND TENANT: **NO-GO**
SEC-004: **OPEN**

## PHASE 2B PRE-MOVE HASH RECORD (2026-09-19)

The current Phase 2B production gate identified project `yuyxfodozzpzrdzkmolu`, linked history equal through A (`20260927100000`) and precisely B/C/D local-pending. Live read-only catalog returned 83 public SECURITY DEFINER functions, 22 legacy bridge definitions, 7/7 CSK defaults, one active CSK tenant, 4/4 B source normalized fingerprints matching the B migration, and zero B target functions. Checked lane hierarchy, lane/rule/duration/pricing/version roots, and membership orphan/duplicate counts were zero.

Before temporary B-only CLI-input isolation, SHA-256 was recorded as follows:

| Phase | File | SHA-256 before move |
| --- | --- | --- |
| B | `20260927110000_add_tenant_scoped_lane_configuration_rpcs.sql` | `9278A24579203A93F093CBB3E12C96F21CBEF46FF3A9CC781AF7334E9B612F1E` |
| C | `20260927120000_add_tenant_scoped_admin_reports.sql` | `4AD9932878A1DB0C5662FFFF64A9DCC4DF312DB237DFD783BFDBD79B3A39151F` |
| D | `20260927130000_add_tenant_scoped_admin_users.sql` | `19BCF96E06BD533B1A87A8BD25CBC311126C552847580CE8870D666AE03F4468` |

This record is not a deployment result. C/D may be moved only to a named folder outside the repository and must be restored bit-for-bit after the authorized B-only gate.

## PHASE 2A ISOLATED PRODUCTION DB DEPLOY AND POSTFLIGHT (2026-09-19)

The separately approved A-only CLI-input isolation was used. B/C/D were moved, without editing, to `C:\Users\Mpios\Desktop\APP Krutla\saas9ec-phase2-hold-20260919` (outside the repository and CLI migration input); the four pre-move hashes are recorded above. The project ref was `yuyxfodozzpzrdzkmolu`. With A as the only pending local migration, linked migration history matched through Phase 1 (`20260926100000`), had zero remote-only rows, and `db push --linked --dry-run` listed **A only**. Immediately before the write, A SHA matched `1247892852A57B5A9DD98777F21EF585010FAA5F16A259DB3CE03B9DC574B3CE`; live SELECT-only checks returned 76 DEFINER, 22 bridge definitions, 7/7 defaults, eight source fingerprints with drift 0, exactly one active CSK tenant, no A target functions, and zero checked Events/membership/hierarchy mismatches. A first diagnostic query had a transcription error in one expected fingerprint; the corrected value was reread from the migration and the repeated live query returned drift 0. No migration or production object was changed for this diagnostic correction.

The authorized `npx.cmd supabase db push --linked` then reported **only** `20260927100000_add_tenant_scoped_staff_event_rpcs.sql` applied and exited 0. Linked history subsequently matched A once, with no remote-only rows. Live catalog SELECT returned 83 public SECURITY DEFINER functions, nine A target functions (seven new DEFINER plus the bounded list and closed create core INVOKER), 22 old bridge definitions, 7/7 defaults, unchanged eight source fingerprints, exactly one active CSK and zero checked Events tenant mismatches. All nine target normalized function hashes matched the local DB target by exact name; owner `postgres`, fixed `pg_catalog, public, pg_temp` path, SECURITY mode and eight authenticated-only client ACLs plus the closed core ACL matched the migration. Unexpected DEFINER delta: 0.

The existing focused A SQL matrix was run through Supabase SQL Editor with only the three `psql` meta-command lines removed and the full-chain assertion `94` changed to the isolated A-only target `83`; the 28 numbered behavioral checks, test fixture logic, `BEGIN`, final `ROLLBACK` and fail-on-any-failed-check assertion were retained. The execution returned no SQL error and final `C2-A cleanup PASS`, so **28/28 passed and the transaction rolled back**. It covered selected-T list/create, instructor read and staff writer roles, no-membership/pending/suspended/global-role negatives, A-route/B-resource denial, lane mismatch, minimal participant scope, approve, paid, cancellation, active-single-tenant switching only within the rolled-back transaction, and audit tenant mismatch denial. An independent read-only post-check returned zero synthetic auth users, profiles, tenants, memberships, lanes, events and registrations; active CSK = 1 and active tenant count = 1. No production provider email was sent.

The old app's `/admin/events` loaded the admin form and list under the existing CSK branch; `/events` loaded without a runtime error. Anonymous HTTP GET smoke returned `/admin/events` 307, `/events` 200, `/booking` 200, `/admin` 307, `/account` 200, `/dashboard` 200, `/login` 200; no 5xx. The four unchanged legacy/adjacent functions `register_for_event`, `cancel_event_registration`, `prepare_event_reserve_promotions`, `complete_event_reserve_promotion` had identical normalized local/production hashes. **Reserve/waitlist/promotion email delivery and a reject action were not newly exercised end-to-end on production**: the former is unchanged by A and was checked statically plus earlier local regression; the latter is not an active Admin Events action in this application. This is a scope/evidence limitation, not an observed defect. A-only writer/reader authorization, route/resource mismatch and PII exclusion were exercised by the rollback-only matrix.

B/C/D were restored to their exact original `supabase/migrations` paths; all three post-restore SHA-256 values equal the pre-move values above, and the temporary hold is empty. Linked migration list now shows A matched and only B, C, D local-pending, with zero remote-only rows. The final `db push --linked --dry-run` lists **B→C→D, not A**; it did not apply any migration. `AGENTS.md` remains unrelated/excluded; no app deploy, Git staging/commit/push, migration repair or second-tenant activation was performed. The previous preflight verdict block above is historical and must not be read as the post-deploy state.

PHASE 2A ISOLATED DEPLOYMENT: **PASS**
SAAS-9E-C PHASE 2A DB DEPLOY: **PASS**
A ONLY: **PASS**
B/C/D RESTORED BIT-FOR-BIT: **PASS**
MIGRATION HISTORY: **PASS**
B/C/D STILL PENDING: **YES**
PHASE 2A POST-DEPLOY: **PASS for changed A contracts; unchanged reserve/promotion flows static-only**
EVENTS DOMAIN: **PASS for Phase 2A scope; end-to-end reserve-promotion not rerun**
RESOURCE-TENANT CHECKS: **PASS**
ROLE MATRIX: **PASS**
CROSS-TENANT PII: **PASS in rollback-only A matrix**
AUDIT: **PASS in rollback-only A matrix (no tenant mismatch)**
SECURITY DEFINER COUNT: **83**
UNEXPECTED DEFINER: **0**
BRIDGE DEFINITIONS: **22**
COMPATIBILITY DEFAULTS: **7/7**
FIXTURE CLEANUP: **PASS / 0**
CURRENT APP + PHASE 2A DB: **PASS for observed no-5xx smoke and Admin Events rendering**
READY FOR PHASE 2B DB DEPLOYMENT: **NO-GO until separate review/authorization**
READY FOR APP CUTOVER: **NO-GO until all A–D DB gates complete**
READY FOR 4D-2: **NO-GO**
READY FOR 9D-5: **NO-GO**
SECOND TENANT: **NO-GO**
SEC-004: **OPEN**

## PHASE 2B ISOLATED PRODUCTION DB DEPLOY AND POSTFLIGHT (2026-09-19)

The separately approved B-only deployment targeted Supabase project `yuyxfodozzpzrdzkmolu`. The authoritative B file was `20260927110000_add_tenant_scoped_lane_configuration_rpcs.sql`, SHA-256 `9278A24579203A93F093CBB3E12C96F21CBEF46FF3A9CC781AF7334E9B612F1E`. Its domain is Lane Configuration (reader, atomic family creator, versioned family writer); the reviewed count change is 83→86 public SECURITY DEFINER functions, with three new client DEFINER wrappers and three closed INVOKER cores. The four source normalized MD5 fingerprints matched the migration exactly: v1 reader `9c6b9b10c6de8359aca5d88981b52523`, v2 reader `ff748a9030e88f8e395805d30b33ac93`, v1 creator `1fd4b47a640b52564568670d079e7659`, legacy versioned writer core `2dd7c305c6060bcb48af9adaa1c43b64`.

Before isolation, linked history equalled production through A (`20260927100000`) exactly once; only B/C/D were local-pending and remote-only count was zero. Live read-only checks returned 83 DEFINER, 22 bridge definitions, 7/7 compatibility defaults, one active CSK tenant, no B target functions, and zero checked lane-parent, orphan lane/rule/duration/pricing/version-root, membership orphan/duplicate, or self-parent anomalies. The C/D pre-move SHA values are recorded above. Only C and D were moved to `C:\Users\Mpios\Desktop\APP Krutla\saas9ec-phase2b-hold-20260919` outside the repository and CLI deploy input; B stayed in migrations. Linked history then showed B as the sole pending migration, and `db push --linked --dry-run` listed B only. The final project, B SHA and isolated-input checks were repeated before the authorized write.

The authorized `npx.cmd supabase db push --linked` applied **only B** and exited 0. With C/D still isolated, linked history showed A and B applied exactly once, no pending migration and no remote-only row. Live catalog returned 86 public DEFINER, 22 bridge definitions, 7/7 defaults and exactly one active CSK tenant. All six B target normalized hashes matched the local target byte-for-byte after CRLF/CR→LF normalization. The three client wrappers are `SECURITY DEFINER`, owner `postgres`, path `pg_catalog, public, pg_temp`, with EXECUTE for `authenticated` only. The three internal cores are `SECURITY INVOKER`, same owner/path, and direct EXECUTE denied for PUBLIC, anon, authenticated and service_role. No unexpected B function delta was observed.

The existing 18-check focused B matrix was run in production SQL Editor inside one `BEGIN`/final `ROLLBACK` transaction. Only the three `psql` meta-command lines were omitted for SQL Editor compatibility and the full-chain count assertion `94` was changed to the isolated A+B target `86`; the numbered behavioral checks, fixture and fail-on-any-failure assertion remained the same. SQL Editor returned no error and `C2-B cleanup PASS`, which establishes **18/18 PASS and rollback**. It exercised same-tenant admin read/create/no-change write, foreign/dormant exclusion, dual-membership route/resource mismatch denial, employee create denial, global-role-only and pending denial, DTO visibility, tenant-bound audit, and root/rule consistency. Suspended-member denial was not separately induced on production in this B matrix; active-membership semantics were reviewed in the unchanged authorization helper and local regression tests. Independent read-only post-check returned zero synthetic tenants, profiles, auth users, memberships, lanes and marker-bearing audit rows; active tenants=1, active CSK=1, hierarchy mismatches=0. No synthetic fixture persisted.

Current-app anonymous GET smoke returned HTTP 200 after redirects for `/admin/events`, `/admin/lane-configuration`, `/admin/reports`, `/admin/users`, `/account`, `/dashboard`, `/login`, `/booking` and `/events`, with no 5xx. The authenticated browser session additionally loaded `/admin/lane-configuration` with six families, five positions, configuration summary, reader DTO and action controls. No real admin mutation or create-family action was performed outside the rolled-back matrix. Thus the observed old-app + A+B DB compatibility is PASS within this smoke scope; it is not a production load test.

C and D were restored to their exact original migration paths. Their SHA-256 values after restore matched the pre-move values exactly: C `4AD9932878A1DB0C5662FFFF64A9DCC4DF312DB237DFD783BFDBD79B3A39151F`, D `19BCF96E06BD533B1A87A8BD25CBC311126C552847580CE8870D666AE03F4468`; the temporary hold was empty. Final linked history showed A/B matched, C/D local-pending in order, remote-only zero. The final dry-run listed **C→D only**, with no write. C was not deployed. `AGENTS.md` and `supabase/drafts/` remained unrelated/excluded; no app deployment or Git write was performed.

SAAS-9E-C PHASE 2B DB DEPLOY: **PASS**
ISOLATED B ONLY: **PASS**
C/D RESTORED BIT-FOR-BIT: **PASS**
MIGRATION HISTORY: **PASS**
C/D STILL PENDING: **YES**
PHASE 2B POST-DEPLOY: **PASS**
PHASE 2B DOMAIN: **PASS for reviewed Lane Configuration scope**
RESOURCE-TENANT CHECKS: **PASS**
ROLE MATRIX: **PASS for exercised B matrix; suspended-member production case not separately induced**
CROSS-TENANT PII: **PASS in rollback-only matrix**
AUDIT: **PASS in rollback-only matrix and cleanup post-check**
SECURITY DEFINER COUNT: **86**
BRIDGE DEFINITIONS: **22**
COMPATIBILITY DEFAULTS: **7/7**
FIXTURE CLEANUP: **PASS / 0**
CURRENT APP + A+B DB: **PASS for observed runtime smoke**
READY FOR PHASE 2C DB DEPLOYMENT: **NO-GO until separate review/authorization**
READY FOR APP CUTOVER: **NO-GO until A–D DB gates complete**
READY FOR 4D-2: **NO-GO**
READY FOR 9D-5: **NO-GO**
SECOND TENANT: **NO-GO**
SEC-004: **OPEN**

## PHASE 2C PRE-MOVE HASH RECORD (2026-09-19)

The approved C-only production gate identified project `yuyxfodozzpzrdzkmolu`; A/B were applied once and C/D were local-pending with no remote-only migrations. The authoritative C file is `20260927120000_add_tenant_scoped_admin_reports.sql`, SHA-256 `4AD9932878A1DB0C5662FFFF64A9DCC4DF312DB237DFD783BFDBD79B3A39151F`. The domain is Admin Reports KPI and export. It adds two SECURITY DEFINER RPCs, zero INVOKER functions, with expected public DEFINER count 86→88. Normalized source hashes matched: report v2 `ded8346e37b87bbf278d3b7b4673ae18`; export v1 `5a8fd638e4c7a867477781876358dcf1`. Live read-only baseline was 86 DEFINER, 22 bridge definitions, 7/7 defaults, one active CSK tenant, no C target RPCs and zero checked orphan reservation or reservation↔lane tenant mismatches.

Before any temporary D quarantine, SHA-256 of `20260927130000_add_tenant_scoped_admin_users.sql` was `19BCF96E06BD533B1A87A8BD25CBC311126C552847580CE8870D666AE03F4468`. C remains in `supabase/migrations`; D may only be moved outside the repository/deploy input and must return bit-for-bit after C verification. This record is not a deployment result.

## PHASE 2C ISOLATED PRODUCTION DB DEPLOY AND POSTFLIGHT (2026-09-19)

Only D was moved temporarily to `C:\Users\Mpios\Desktop\APP Krutla\saas9ec-phase2c-hold-20260919`, outside the repository and CLI deploy input; C remained in `supabase/migrations`. The held D SHA-256 equalled the pre-move hash above. Linked history then showed A/B applied once, C as the sole pending local migration and zero remote-only rows. The `db push --linked --dry-run` listed **C only**. The final gate reconfirmed project `yuyxfodozzpzrdzkmolu`, C SHA-256, two source normalized hashes, baseline 86 DEFINER, 22 bridge definitions, 7/7 defaults, one active CSK, no C targets, zero checked reservation↔lane tenant mismatch/orphans, and the valid unique `tenants_single_active_runtime_guard` partial index. The approved `npx.cmd supabase db push --linked` then applied **only** `20260927120000_add_tenant_scoped_admin_reports.sql` and exited 0.

With D still isolated, linked history showed C applied once and no pending/remote-only rows. Live catalog returned 88 public SECURITY DEFINER functions, 22 bridge definitions, 7/7 CSK defaults, one active CSK and one active tenant. Both target normalized hashes matched the local target: `admin_get_reservation_report_v3` = `aa8e55ede9b572492a99b270e72e6e5f`; `admin_get_reservation_report_export_v2` = `174a9eced190354ab45190dd4ef8a12a`. Both signatures, owner `postgres`, `SECURITY DEFINER`, fixed `pg_catalog, public, pg_temp` search_path and authenticated-only EXECUTE matched the migration; PUBLIC, anon and service_role lack EXECUTE. C added no INVOKER function. Unexpected function delta within this C scope was zero; the legacy report functions were not replaced.

The existing focused C SQL matrix ran in production SQL Editor in one `BEGIN`/final `ROLLBACK` transaction. Only three `psql` meta-command lines were omitted for SQL Editor compatibility and its full-chain DEFINER assertion `94` was changed to the isolated A+B+C target `88`. The 14 numbered checks, fail-on-any-failure assertion, fixture logic and rollback were retained. It returned no SQL error and `C2-C cleanup PASS`, establishing **14/14 PASS**. The matrix verified same-tenant admin access, tenant filtering before KPI/details/resource options/export row selection, no foreign price/name/email in A export, cross-tenant lane filter rejection, dual-membership tenant separation, employee/global-role-only/dormant denial and old caller presence. This is rollback-only evidence, not a permanent second tenant. Pending/suspended denial was not separately induced in this C matrix; the unchanged production `get_my_tenant_role_v1(uuid)` definition requires both membership and tenant status `active`.

Independent read-only post-check returned zero C-marked synthetic tenants, profiles, auth users, lanes, reservations, memberships and marker-bearing audit rows. The CSK tenant remained active and the active-tenant count was one. Reports is read-only: no production audit mutation was expected outside the rolled-back fixture, and no marker-bearing audit persisted. No production CSV containing real customer data was exported.

Current-app GET smoke (after redirect) returned HTTP 200, with no 5xx, for `/admin/events`, `/admin/lane-configuration`, `/admin/reports`, `/admin/users`, `/account`, `/dashboard`, `/login`, `/booking` and `/events`. The authenticated `/admin/reports` page loaded its filters, resource options, KPI summary and controlled empty state without observed runtime error. This is the old-app + A+B+C DB compatibility smoke, not a load test or full historical report reconciliation.

D was restored to its original migration path. Its post-restore SHA-256 remained `19BCF96E06BD533B1A87A8BD25CBC311126C552847580CE8870D666AE03F4468`, identical to pre-move; the temporary hold was empty. Final linked history showed A/B/C matched once, only D local-pending and zero remote-only rows. Final dry-run listed **D only**. D was not deployed. `AGENTS.md` and drafts remained unrelated/excluded; no app deployment or Git write was performed.

SAAS-9E-C PHASE 2C DB DEPLOY: **PASS**
ISOLATED C ONLY: **PASS**
D RESTORED BIT-FOR-BIT: **PASS**
MIGRATION HISTORY: **PASS**
D STILL PENDING: **YES**
PHASE 2C POST-DEPLOY: **PASS**
PHASE 2C DOMAIN: **PASS for reviewed Reports scope**
RESOURCE-TENANT CHECKS: **PASS**
ROLE MATRIX: **PASS for exercised C matrix; pending/suspended production cases verified by unchanged active-status helper definition**
CROSS-TENANT PII: **PASS in rollback-only KPI/export matrix**
AUDIT: **PASS for read-only Reports scope and fixture rollback**
SECURITY DEFINER COUNT: **88**
BRIDGE DEFINITIONS: **22**
COMPATIBILITY DEFAULTS: **7/7**
FIXTURE CLEANUP: **PASS / 0**
CURRENT APP + A+B+C DB: **PASS for observed runtime smoke**
READY FOR PHASE 2D DB DEPLOYMENT: **NO-GO until separate review/authorization**
READY FOR APP CUTOVER: **NO-GO until A–D DB gates complete**
READY FOR 4D-2: **NO-GO**
READY FOR 9D-5: **NO-GO**
SECOND TENANT: **NO-GO**
SEC-004: **OPEN**

## FINAL PHASE 2 REPRODUCIBILITY & CLOSURE AUDIT (2026-09-20)

This final section supersedes the historical intermediate A/B/C pending-state verdicts above. Phase 2 DB A–D is production PASS. The APP-only cutover commit `0de210599286e7711679a2833d22b1e7654559e6` is both local HEAD and `origin/main` (`0/0` divergence). The target `csk-booking-5nwh` Vercel deployment succeeded; authenticated non-mutating production smoke loaded all four selected CSK staff routes, global Account/Dashboard and the four old admin compatibility URLs. The distinct `csk-booking` Vercel project is not the deployment target. No production mutation E2E occurred after the app cutover.

| Phase/domain | Canonical deployed migration | SHA-256 verified against deployment record | Linked history |
|---|---|---|---|
| A — staff Events | `20260927100000_add_tenant_scoped_staff_event_rpcs.sql` | `1247892852A57B5A9DD98777F21EF585010FAA5F16A259DB3CE03B9DC574B3CE` | local=remote once |
| B — Lane Configuration | `20260927110000_add_tenant_scoped_lane_configuration_rpcs.sql` | `9278A24579203A93F093CBB3E12C96F21CBEF46FF3A9CC781AF7334E9B612F1E` | local=remote once |
| C — Admin Reports | `20260927120000_add_tenant_scoped_admin_reports.sql` | `4AD9932878A1DB0C5662FFFF64A9DCC4DF312DB237DFD783BFDBD79B3A39151F` | local=remote once |
| D — Admin Users | `20260927130000_add_tenant_scoped_admin_users.sql` | `19BCF96E06BD533B1A87A8BD25CBC311126C552847580CE8870D666AE03F4468` | local=remote once |

The linked history contained **106 rows with zero local/remote mismatches**, including A–D once each; `db push --linked --dry-run` returned **Remote database is up to date**. No ghost, pending or remote-only migration was observed. No historical migration content changed in this checkpoint scope. Production read-only SQL Editor SELECT against project `yuyxfodozzpzrdzkmolu` returned public SECURITY DEFINER **94**, stored bridge definitions **22**, CSK compatibility defaults **7/7**, active tenants **1**. This is the fresh final count evidence; full function-body fingerprints were previously checked during separate DB A–D postflights, not recomputed during this count-only SELECT.

Fail-closed local reset targeted only `127.0.0.1:54322` with `supabase db reset --local` (no `--linked`, no production write or migration repair). It replayed all **106** canonical migration files, ending in A–D, with no seed file required. The local migration table contains **106** versions; local public SECURITY DEFINER **94**, bridge definitions **22**, CSK defaults **7/7**, one active tenant. Local focused A–D SQL **80/80 PASS** (28+18+14+20), full Supabase DB suite **1527/1527 PASS** across 50 files, Node **773/773 PASS**, selected Playwright tenant/admin/account/lane/reports **17/17 PASS**, TypeScript PASS, production build PASS and changed-file ESLint PASS. The build retained only the known middleware→proxy deprecation warning. The selected-tenant concurrency script passed last-admin, identity/contact races, no deadlocks, no lost updates and cleanup **0**. Post-suite local synthetic non-CSK tenants, auth users, profiles, memberships, events and reservations all counted **0**; defaults still **7/7**. `git diff --ignore-cr-at-eol --check` passed before report staging. The ACL function inventory was exercised by the full DB suite.

Source review after app cutover confirms zero legacy/global operational calls in each selected tenant Events, Lane Configuration, Reports and Users branch; resource and active membership checks remain in the tenant RPCs. `/account` remains global/account-wide and `/dashboard` a global landing/explicit location selector. Old `/admin/*` remains legacy CSK compatibility, not tenant-ready. Reservation ICS is deliberately legacy C3 and was not included in the app cutover.

Recount from current source: **20 legacy operational sites before Phase 2, 18 after APP cutover**. The two removed sites were implicit Account/Dashboard verification bridge reads; the twelve old admin branch sites were not removed merely by adding selected-tenant alternatives. Exact remaining sites:

| File:line | Legacy RPC/helper; surface | Reason / target |
|---|---|---|
| `app/admin/events/page.tsx:484` | `admin_list_events_v1`; old Events list | Old CSK URL compatibility; C3 |
| `app/admin/events/page.tsx:648` | `admin_create_event_v2`; old Events create | Old CSK URL compatibility; C3 |
| `app/admin/lane-configuration/page.tsx:525` | `admin_get_lane_booking_configuration_v2`; old config reader | Old CSK URL compatibility; C3 |
| `app/admin/lane-configuration/page.tsx:687` | `admin_create_lane_booking_family_v1`; old family create | Old CSK URL compatibility; C3 |
| `app/admin/reports/page.tsx:146` | `admin_get_reservation_report_v2`; old KPI/details | Old CSK URL compatibility; C3 |
| `app/admin/reports/page.tsx:192` | `admin_get_reservation_report_export_v1`; old CSV | Old CSK URL compatibility; C3 |
| `app/admin/users/page.tsx:368` | `admin_list_users_v1`; old user list | Old CSK URL compatibility; C3 |
| `app/admin/users/page.tsx:519` | `admin_set_user_role_v1`; old role writer | Old CSK URL compatibility; C3 |
| `app/admin/users/page.tsx:571` | `admin_set_user_note_v1`; old note writer | Old CSK URL compatibility; C3 |
| `app/admin/users/page.tsx:621` | `update_profile_verification`; old verification writer | Old CSK URL compatibility; C3 |
| `app/admin/users/page.tsx:673` | `update_profile_identity`; old identity writer | Old CSK URL compatibility; C3 |
| `app/admin/users/page.tsx:721` | `update_profile_contact_details`; old contact writer | Old CSK URL compatibility; C3 |
| `app/booking/page.tsx:31` | `get_public_booking_configuration_v1`; global Booking | Global legacy branch; C3 |
| `app/booking/BookingForm.tsx:318` | `get_my_active_tenant_verification_v1`; global Booking | Global legacy owner verification; C3 |
| `app/events/page.tsx:89` | `get_public_event_list_v2`; global Events | Global legacy branch; C3 |
| `app/my-reservations/page.tsx:354` | `get_my_reservations_v2`; global owner list | Global legacy branch; C3 |
| `app/my-events/page.tsx:262` | `get_my_event_registrations_v1`; global owner list | Global legacy branch; C3 |
| `app/api/calendar/reservations/[id]/route.ts:23` | `get_my_reservations_v2`; reservation ICS | Server legacy/ICS, explicitly C3 |

The 4D-2 helper inventory is a distinct metric from these 18 operational sites:

| Function | Active direct app/API callers now | Files | C3 / zero-caller |
|---|---:|---|---|
| `get_my_role()` | 8 | `app/page.tsx:132`, `app/admin/page.tsx:365`, `app/admin/calendar/page.tsx:167`, `app/api/admin/calendar-feed/route.ts:82`, `app/admin/events/page.tsx:412`, `app/admin/lane-configuration/page.tsx:515`, `app/admin/reports/page.tsx:124`, `app/admin/users/page.tsx:351` | C3; NO |
| `is_admin()` | 0 direct app/API | none found | Catalog/dependency closure still required; direct source YES |
| `is_admin_or_employee()` | 0 direct app/API | none found | Catalog/dependency closure still required; direct source YES |
| `is_admin_or_staff()` | 0 direct app/API | none found | Catalog/dependency closure still required; direct source YES |

Therefore 4D-2 **zero-caller gate NOT MET**. The production CSK authenticated E2E and non-destructive staff route smoke are PASS for the observed page/list scope. Production mutation E2E after app cutover and two-active-tenant production UI E2E are **NOT PERFORMED**. Cross-tenant A/B isolation is supported by the local and previously approved production rollback-only DB matrices; the current production UI smoke cannot replace those proofs. No second tenant may be activated and SEC-004 remains OPEN.

SAAS-9E-C PHASE 2 DB: **PROD PASS**
SAAS-9E-C PHASE 2 APP: **PROD PASS — non-mutating smoke scope**
CLEAN MIGRATION REPLAY: **PASS**
FULL DB TESTS: **1527/1527 PASS**
NODE: **773/773 PASS**
PLAYWRIGHT: **17/17 PASS**
TENANT EVENTS: **PASS**
TENANT LANE CONFIGURATION: **PASS**
TENANT REPORTS: **PASS**
TENANT USERS: **PASS**
ACCOUNT: **PASS**
DASHBOARD: **PASS**
OLD ADMIN COMPATIBILITY: **PASS**
ACTIVE LEGACY CALL SITES: **18**
C3 RESIDUAL: **18 operational source sites listed above; plus eight 4D-2 direct role-helper sites (overlap with four old admin files)**
4D-2 ZERO-CALLER GATE: **NOT MET**
4D-2: **NO-GO**
SECURITY DEFINER: **94**
BRIDGE DEFINITIONS: **22**
COMPATIBILITY DEFAULTS: **7/7**
PENDING MIGRATIONS: **0**
PRODUCTION MUTATION E2E AFTER APP CUTOVER: **NOT PERFORMED**
TWO-ACTIVE-TENANT PROD UI E2E: **NOT PERFORMED**
SECOND TENANT: **NO-GO**
SEC-004: **OPEN**
FINAL PHASE 2 CHECKPOINT COMMIT: **PENDING explicit staged-scope gate**
READY TO PUSH FINAL PHASE 2 CHECKPOINT: **NO until local commit and review; no push authorized in this turn**
READY TO CLOSE PHASE 2 AFTER PUSH: **YES conditional on checkpoint match and review**
READY FOR PHASE 3 PLANNING: **GO after checkpoint review**
READY FOR PHASE 3 IMPLEMENTATION: **NO-GO until final checkpoint pushed/reviewed**
READY FOR 9D-5: **NO-GO**
