# SAAS-9E-C Phase 3 / C3 — legacy caller retirement freeze

Status: C3 local implementation and verification completed, 2026-09-20; production preflight has **not** started. Source checkpoint `634ca40c8684292681e83855b87f4a09a3fc3dce` (`main` = `origin/main` at review start). Phase 2 is CLOSED / PROD PASS. No production query or write was performed for this C3 work: 94 public SECURITY DEFINER functions, 22 bridge definitions, 7/7 defaults and zero pending migrations are the latest recorded production baseline evidence, **not a fresh live catalog check**. `AGENTS.md` and `supabase/drafts/*` are unrelated/excluded.

## Method and exact source-site metric

Recounted across `app`, `lib`, and `middleware.ts` using RPC-name search, `.rpc(`, direct `.from(`, role-helper references and route entry points. A *site* means a reachable source expression that can invoke an old operational contract, not a function definition, SQL test occurrence, or number of runtime requests. The conditional old arm is counted once; selected-tenant arms are not old sites. The 18 below match the Phase 2 report after fresh source confirmation. They do **not** include eight distinct `get_my_role()` sites, direct `profiles.role` decisions, or the active global `update_my_profile_v1` call; those are tracked separately because merging metrics would conceal the 4D-2/9D-5 gates.

Legend for tenant/authority: `bridge` = old exact-single-active-CSK contract; `T(path)` = server-validated `/t/[slug]` tenant; `R` = persisted resource tenant; `M` = active tenant membership; `U` = `auth.uid()` owner. `DB?` is target change, not current requirement. Every row has exactly one residual category.

| ID/category | File:line; surface / URL | Old RPC; R/W | Current tenant / authority | Why legacy; C3 target | DB? / app? / 4D-2? / 9D-5? |
|---|---|---|---|---|---|
| L01 A | `app/admin/events/page.tsx:484`; `/admin/events` list | `admin_list_events_v1` R | bridge / legacy CSK staff wrapper | old branch; redirect to `/t/csk/admin/events`, remove old branch | N/Y/Y/Y |
| L02 A | `app/admin/events/page.tsx:648`; `/admin/events` create | `admin_create_event_v2` W | bridge / legacy staff wrapper | old branch; canonical v3 with T+M and lane/resource checks | N/Y/Y/Y |
| L03 A | `app/admin/lane-configuration/page.tsx:525`; `/admin/lane-configuration` | `admin_get_lane_booking_configuration_v2` R | bridge / legacy staff wrapper | old branch; canonical v3 | N/Y/Y/Y |
| L04 A | `app/admin/lane-configuration/page.tsx:687`; same URL | `admin_create_lane_booking_family_v1` W | bridge / legacy staff wrapper | old branch; canonical v2 T+M | N/Y/Y/Y |
| L05 A | `app/admin/reports/page.tsx:146`; `/admin/reports` | `admin_get_reservation_report_v2` R | bridge / legacy staff wrapper | old branch; canonical v3 | N/Y/Y/Y |
| L06 A | `app/admin/reports/page.tsx:192`; same URL/export | `admin_get_reservation_report_export_v1` R | bridge / legacy staff wrapper | old branch; canonical v2 | N/Y/Y/Y |
| L07 A | `app/admin/users/page.tsx:368`; `/admin/users` | `admin_list_users_v1` R | bridge / legacy staff wrapper | old branch; canonical v2 | N/Y/Y/Y |
| L08 A | `app/admin/users/page.tsx:519`; same URL | `admin_set_user_role_v1` W | bridge / legacy staff wrapper | old branch; canonical v2 | N/Y/Y/Y |
| L09 A | `app/admin/users/page.tsx:571`; same URL | `admin_set_user_note_v1` W | bridge / legacy staff wrapper | old branch; canonical v2 | N/Y/Y/Y |
| L10 A | `app/admin/users/page.tsx:621`; same URL | `update_profile_verification` W | bridge / legacy staff wrapper | old branch; canonical `update_tenant_profile_verification_v2` | N/Y/Y/Y |
| L11 A | `app/admin/users/page.tsx:673`; same URL | `update_profile_identity` W | bridge / legacy staff wrapper | old branch; canonical `update_tenant_profile_identity_v2` | N/Y/Y/Y |
| L12 A | `app/admin/users/page.tsx:721`; same URL | `update_profile_contact_details` W | bridge / legacy staff wrapper | old branch; canonical `update_tenant_profile_contact_details_v2` | N/Y/Y/Y |
| L13 B | `app/booking/page.tsx:31`; `/booking` | `get_public_booking_configuration_v1` R | bridge / public active CSK | no explicit location; explicit CSK compatibility redirect to `/t/csk/booking` | N/Y/N/Y |
| L14 B | `app/booking/BookingForm.tsx:318`; `/booking` verification | `get_my_active_tenant_verification_v1` R | bridge / U + selected active CSK | old prop-less branch; canonical `get_my_tenant_verification_v2(T)` | N/Y/N/Y |
| L15 B | `app/events/page.tsx:89`; `/events` | `get_public_event_list_v2` R | bridge / public active CSK | no explicit location; redirect to `/t/csk/events`, v3(T) | N/Y/N/Y |
| L16 C | `app/my-reservations/page.tsx:354`; `/my-reservations` | `get_my_reservations_v2` R | legacy global owner/active membership + U | list is tenant-specific; redirect to `/t/csk/my-reservations`, v3(T) | N/Y/N/Y |
| L17 C | `app/my-events/page.tsx:262`; `/my-events` | `get_my_event_registrations_v1` R | legacy global owner/U | list is tenant-specific; redirect to `/t/csk/my-events`, v2(T) | N/Y/N/Y |
| L18 E | `app/api/calendar/reservations/[id]/route.ts:23`; reservation ICS | `get_my_reservations_v2` R | legacy global owner list/U | resource-by-ID export must derive tenant from reservation; versioned minimal owner ICS RPC | **Y**/Y/N/Y |

**Recounted active legacy operational call sites: 18.** A=12, B=3, C=2, E=1; D/F/G/H=0 within this narrowly defined metric. There are **additional** D/F/G dependencies described below; they are not silently counted as part of 18. The old admin Events page also has conditional old arms for participant/read and update/action RPCs; those are resource-bound and outside the 18 bridge/legacy-owner metric, but their old-route reachability must disappear in the same redirect. Old admin dashboard, Reservations, Calendar, Check-in and Lane Blocks do direct table reads/writes: they are C3 operational surface work even though they do not increase the 18 RPC-site count.

Every supplemental residual also has one category: **D** = `/account` active `update_my_profile_v1` call and `/dashboard` old-navigation links (dashboard has no current bridge read); **F** = eight `get_my_role()` call sites plus direct global-role decisions in middleware, Check-in and cancellation email; **G** = the 22 stored bridge function definitions (catalog objects, not extra app sites); **H** = five canonical staff placeholders, tenant-home back-links and the old unscoped calendar-feed/direct-table surfaces. These categories are disjoint from A/B/C/E source-site counting; a function definition is never counted as an app call.

## URL transition and old staff architecture

An old URL is a **documented CSK-only compatibility alias**, never an authority source. Validate exact supported path and trusted active `csk` tenant; for staff, authenticate and check `M` against that URL's existing role matrix before handoff. Preserve safe query filters, drop malformed/PII/token query fields, reset unsafe pagination. Redirect to a fully functioning canonical route only **after** parity. Unknown `/admin/*` remains deny/404, not a wildcard tenant handoff. No client-supplied tenant ID or hidden active-tenant fallback. Existing `middleware.ts` currently authorizes old `/admin/*` through `profiles.role`; that must be replaced or made non-authoritative before any redirect is considered secure. Canonical route's server check and DB/RLS remain authoritative independently of middleware.

| Old URL/current | Canonical target and C3 disposition | Auth / tenant source | Future removal? |
|---|---|---|---|
| `/admin` — legacy dashboard, global-role read and unscoped reservation/event queries | `/t/csk/admin`; implement tenant dashboard first, then redirect; old component stops loading | active admin/employee/instructor per existing page matrix, T(path)+M; RLS plus T filters | yes, after published-link review |
| `/admin/events` — dual old/new branches | `/t/csk/admin/events`; redirect after existing selected branch parity | existing admin/employee/instructor restrictions, T+M | yes |
| `/admin/lane-configuration` — dual branches | `/t/csk/admin/lane-configuration`; redirect | admin, T+M | yes |
| `/admin/reports` — dual branches | `/t/csk/admin/reports`; redirect | admin, T+M | yes |
| `/admin/users` — dual branches | `/t/csk/admin/users`; redirect | admin, T+M | yes |
| `/admin/reservations` — unscoped direct list | `/t/csk/admin/reservations`; implement selected-tenant page, then redirect | admin/employee, T+M, RLS+T query filter; writes resource-bound | yes |
| `/admin/calendar` — global role + legacy feed | `/t/csk/admin/calendar`; implement selected page and tenant-bound feed, then redirect | admin/employee/instructor (no scope widening), T+M, RLS+T | yes |
| `/admin/check-in` — profile global role + direct list | `/t/csk/admin/check-in`; implement selected page and resource-token/T match, then redirect | admin/employee, T+M; resource tenant wins | yes |
| `/admin/lane-blocks` — unscoped lane/block lists | `/t/csk/admin/lane-blocks`; implement selected page, then redirect | admin/employee, T+M, RLS+T; block writers derive R | yes |
| `/api/admin/calendar-feed` — old server role and unscoped data | tenant-qualified feed contract (`/api/admin/calendar-feed?tenant=csk` as temporary API compatibility only, or `/api/t/[slug]/admin/calendar-feed`); old no-selector request denied after cutover | authenticated T+M on server, RLS+T, role-specific PII | yes |
| `/booking`, `/events` — global public branches | explicit CSK alias redirects to `/t/csk/booking`, `/t/csk/events`; page links use canonical URL | validated active CSK via server resolver, no public role | yes |
| `/my-reservations`, `/my-events` — global owner lists | explicit CSK alias redirects to corresponding `/t/csk/...`; no global mixed list under these names | login + T(path); U and RLS/RPC per tenant | yes |
| `/account` — global account management | **keep `/account`**, no tenant redirect; global profile writer response must cease consulting CSK bridge | auth.uid(); no implicit T | no |
| `/dashboard` — global landing/location choice | **keep `/dashboard`**, explicit CSK location link while only CSK active; no tenant verification/role from bridge | auth.uid(); selection is navigation, not grant | no |
| `/` — home, global `get_my_role()` for admin link | keep home global; link to location/dashboard without global-role grant | public/auth session only; role checked at tenant route | no |
| `/api/calendar/reservations/[id]` — owner ICS via old list | keep global resource-ID URL only if new resource-derived owner contract passes; optional tenant-qualified alias must compare slug to R | U+R from DB, not caller tenant_id | no |
| `/api/calendar/event-registrations/[id]` — direct owner-scoped join, no bridge | keep resource-derived global ICS; verify `event_registrations.tenant_id = events.tenant_id`, remove hard-coded CSK labels before second tenant | U+R from DB; optional route selector must match R | no |
| `/check-in/[token]`, `/events/confirm/[token]` — token/resource routes | keep resource-bound, review token tenant consistency; never infer tenant from old URL | token and persisted resource, not supplied slug | no |

The `app/t/[slug]/[...path]/page.tsx` shell currently renders a **placeholder** for Admin root, Reservations, Calendar, Check-in and Lane Blocks, with a CSK-only link back to the old page. Redirecting old URLs to these placeholders now would regress operations and form a navigation loop. Implement the five selected-tenant modules and remove placeholder back-links first. The canonical Events, Lane Configuration, Reports and Users branches already render in production. The tenant home (`app/t/[slug]/page.tsx`) likewise still links CSK users back to global Booking/Events; update its navigation to canonical URLs. Preserve old query/deep-link state only after explicit validation.

## Public, owner, global Account/Dashboard and ICS contracts

- Public Booking: v2 configuration already accepts resolved T. BookingForm verification v2 accepts T; lane availability and create-reservation are resource-bound and server API verifies route slug against persisted lane via `tenantResourceMatches`. C3 removes prop-less old branches; a user must enter through a validated tenant URL. Public Events: v3 list(T) is live; availability remains database-authoritative. Registration API must compare route selector and persisted event tenant, never trust the selector as authorization.
- Owner reservation/event lists are **tenant-specific**, not global cross-tenant aggregates. `get_my_reservations_v3(T,page,size)` and `get_my_event_registrations_v2(T,...)` exist. Old owner URLs become explicit CSK aliases. Cancellation/payment/promotion/ICS links must preserve resource-tenant checks; do not mix a user’s records across tenants under a chosen URL.
- `/account` stays account-wide. `app/account/page.tsx:438` actively calls `update_my_profile_v1`, whose current body calls `active_single_tenant_id_v1()` only to return a CSK verification status after updating global profile/declarations. Target: versioned **`update_my_profile_v2`** with same owner-scoped global mutation and per-tenant verification invalidation/audit semantics, but **no selected-tenant verification fields or single-active bridge in its response**. Account UI uses only global result fields; tenant status is read separately within tenant routes. No leave-tenant behavior is introduced. This is a second active bridge caller beyond the 18 operational-site metric.
- `/dashboard` is already global and currently reads only own global profile plus an explicit `/t/csk` location link; it has no active tenant-verification RPC. It must not gain an implicit CSK role/status check. Its current customer links to old Booking/Events/owner URLs should become explicit-location links or location selection. `/` currently uses `get_my_role()` only to expose an admin shortcut; remove that authority/visibility assumption and navigate through explicit location with server membership gate.
- Reservation ICS today authenticates bearer via `getCalendarRequestContext` (anon key, no service_role), calls `get_my_reservations_v2()` and filters `.eq(id)` afterward, rejects cancelled status, then emits a no-store ICS. That RPC is a **list** across active memberships, not an exact resource-T contract; `get_my_reservations_v3` is paged JSON and cannot safely be `.eq(id)`-filtered. Target new **`get_my_reservation_calendar_v1(p_reservation_id uuid)`**: derive tenant from persisted reservation; require `reservation.user_id=auth.uid()`, active resource tenant, valid active status, join same-tenant lane/parent (including inactive historical labels); return only ID, date/times, safe lane label and public location/name if approved. No caller-supplied tenant authority, no check-in token, no customer PII. The server returns uniform 404 for foreign/nonexistent, 409 for own cancelled, retains safe escaped ICS fields and private/no-store. If a tenant-qualified ICS URL is added, its trusted slug must equal the RPC-returned resource tenant before export. The old URL may stay as a resource-derived endpoint; this is **not** a legacy bridge after cutover.
- Event-registration ICS already uses `event_registrations` owner query and joined event data, with no legacy RPC or service_role. Verify tenant FK/equality and use resource tenant for branding; owner/foreign/invalid/reserve/cancelled tests. Do not add a client tenant_id parameter as authority. Both downloads must exclude email, phone, address, user_id, auth/check-in/confirmation tokens, admin note and ATTENDEE.

## Global-role and 4D-2 exact source inventory

| Function | Active direct app/API sites now | Files/routes | C3 action; expected direct sites after C3 |
|---|---:|---|---|
| `get_my_role()` | **8** | `app/page.tsx:132` `/`; `app/admin/page.tsx:365` `/admin`; `app/admin/calendar/page.tsx:167` `/admin/calendar`; `app/api/admin/calendar-feed/route.ts:82`; `app/admin/events/page.tsx:412`; `app/admin/lane-configuration/page.tsx:515`; `app/admin/reports/page.tsx:124`; `app/admin/users/page.tsx:351` | remove old pages/branches, use T+M for canonical staff and location navigation for `/`; **0** |
| `is_admin()` | **0** | no direct app/API caller; closed DB helper still catalog-dependent | preserve function in C3; separate 4D-2 catalog/dependency review; **0** |
| `is_admin_or_employee()` | **0** | no direct app/API caller | same; **0** |
| `is_admin_or_staff()` | **0** | no direct app/API caller | same; **0** |

Additional direct global-role authorities outside the helper count: `middleware.ts:102–139` reads `profiles.role` for old `/admin/*`; `app/admin/check-in/page.tsx:616–627` uses `profiles.role`; `app/api/send-reservation-cancellation/route.ts:207–251` treats global admin/pracownik as staff. C3 must replace them with T+M and resource tenant (for email recipient/operation) or fail closed; DB RPC remains independently authoritative. `app/api/admin/calendar-feed/route.ts` is server-side but still uses `get_my_role` and unscoped direct table queries. These are **not** additions to the 18 RPC-site metric. No instructor permission may be expanded. A source zero-count is necessary but not sufficient: 4D-2 separately proves DB callers/ACL, profile trigger and runtime behavior.

## Bridge definitions and defaults

The 22 is **stored definition count**, not active caller count. All 22 definitions remain during C3; removal is 9D-5 after separate approval. The 16 old public contracts are listed below with direct app source sites now → C3. The number is zero for public availability because the current `/events` calls the list contract, not the availability RPC directly.

| Bridge definition | Active caller now → expected after C3 | Removal phase |
|---|---|---|
| `get_public_booking_configuration_v1` | 1 app site L13 → 0 | 9D-5 |
| `get_public_event_list_v2` | 1 app site L15 → 0 | 9D-5 |
| `get_public_event_availability_v1` | 0 direct app sites; retained public contract → 0 | 9D-5 |
| `get_my_active_tenant_verification_v1` | 1 app site L14 → 0 | 9D-5 |
| `admin_create_event_v2` | 1 app site L02 → 0 | 9D-5 |
| `admin_list_events_v1` | 1 app site L01 → 0 | 9D-5 |
| `admin_create_lane_booking_family_v1` | 1 app site L04 → 0 | 9D-5 |
| `admin_get_lane_booking_configuration_v2` | 1 app site L03 → 0 | 9D-5 |
| `admin_get_reservation_report_v2` | 1 app site L05 → 0 | 9D-5 |
| `admin_get_reservation_report_export_v1` | 1 app site L06 → 0 | 9D-5 |
| `admin_list_users_v1` | 1 app site L07 → 0 | 9D-5 |
| `admin_set_user_note_v1` | 1 app site L09 → 0 | 9D-5 |
| `admin_set_user_role_v1` | 1 app site L08 → 0 | 9D-5 |
| `update_profile_verification` | 1 app site L10 → 0 | 9D-5 |
| `update_profile_identity` | 1 app site L11 → 0 | 9D-5 |
| `update_profile_contact_details` | 1 app site L12 → 0 | 9D-5 |
| `admin_create_event_v2__saas9d2b1_core` | indirect old-wrapper caller → 0 live calls after L02 retires | 9D-5 |
| `admin_list_events_v1__saas9d2b1_core` | indirect old-wrapper caller → 0 live calls after L01 retires | 9D-5 |
| `admin_get_lane_booking_configuration_v1` | indirect old-v2 reader caller → 0 live calls after L03 retires | 9D-5 |
| `_backfill_csk_tenant_user_verifications_v1` | 0 runtime callers; historical migration only → 0 | 9D-5 |
| `prevent_non_admin_profile_privilege_changes` | active profile trigger → retained active trigger after C3 | 9D-5 after 4D-2 review |
| `update_my_profile_v1` | 1 `/account` app site → 0 after global v2 cutover | 9D-5 |

Thus active direct app call sites to the **16 bridge public wrappers** are 15 now and target 0; the separate account writer adds 1 direct bridge-dependent site now and targets 0. The two owner lists and reservation ICS make the 18 legacy operational-source metric. No definition is dropped in C3. Compatibility defaults remain **7/7**; current legacy INSERT/RPC writers may still need them. Prove every writer supplies T explicitly before their 9D-5 removal, including reservations, lanes, lane blocks, events, event lanes, event registrations and email deliveries.

## Exact C3 target and implementation slices

| Surface | Current legacy calls | Target calls / route | DB / app / tests | Done when |
|---|---|---|---|---|
| Four selected staff screens + old aliases | L01–L12, five old role lookups | existing selected v2/v3 contracts; old URLs redirect only after parity | no DB / app / route+role E2E | no old conditional branches or role RPC |
| Admin root, Reservations, Calendar/feed, Check-in, Lane Blocks | unscoped direct reads and role sources | fully functional `/t/[slug]/admin/...`, T+M, RLS+T; R for actions | no new DB assumed / app / cross-tenant & PII tests | placeholders removed; old URLs safely hand off; no unscoped query |
| Public Booking/Events | L13–L15 | existing v2/v3(T); old aliases to explicit `/t/csk/...` | no DB / app / public contract tests | no old RPC arm; resource/route match |
| Owner lists | L16–L17 | existing v3/v2(T); old aliases explicit CSK | no DB / app / owner+multi-tenant tests | no global mixed list |
| Reservation ICS | L18 | new exact-ID owner/R-derived calendar RPC | **new DB** / app / ICS tests | no old list RPC; no PII/token/foreign export |
| Global Account | one separate bridge-dependent writer | new global `update_my_profile_v2`; no tenant-specific response | **new DB** / app / lifecycle tests | account still global; old writer has zero app sites |
| Global home/dashboard | one separate role helper; old navigation | no role grant on `/`; explicit location navigation on both | no DB / app / navigation tests | no implicit CSK authority |
| Middleware, cancellation email, staff API | direct global role sources | trusted T+M and resource-bound checks | no DB assumed / app / auth+IDOR tests | global role alone cannot authorize |

**Phase 3 legacy operational sites before 18; removed 18; after 0** (target, not implemented). Separately: `get_my_role` 8→0, `update_my_profile_v1` direct 1→0, direct `profiles.role` authority 3 areas→0. Old bridge definitions 22→22. The six newly selected-tenant wrappers introduced in Phase 1 and twelve staff wrappers in Phase 2 are preserved.

**APP-only possible: NO.** Required DB contract list is exactly two *proposed versioned RPCs*: `get_my_reservation_calendar_v1(uuid)` and `update_my_profile_v2` (same 16 input types as v1, tenant-free response). Both require owner-scoped `SECURITY DEFINER` to retain historic inactive-lane labels and account-wide invalidation; **new SECURITY DEFINER delta +2, projected public count 94→96** if neither contract is safely implementable as INVOKER under current RLS. This is a planning target, not a live catalog fact. No other new RPC is currently required by reviewed staff modules; if parity testing disproves that, stop and revise the frozen scope before coding. No existing signature/bridge/default is changed in this phase.

Recommended slices: **C3-DB** additive two RPCs and focused local SQL/ACL/PII/concurrency tests; production DB-first with old app compatibility. **C3-APP-A** reservation ICS/account cutover and public/owner aliases. **C3-APP-B** missing selected staff modules and calendar-feed/check-in/cancellation authority; parity first, then old-admin redirects. **C3-APP-C** eliminate home/old role helper branches, hardcoded back-links, complete source recount. Each slice needs its own local verification and deployment gate. Database rollback after use is a reviewed forward corrective migration, not migration repair/destructive rollback. App rollback can use previous compatible commit while additive DB contracts remain, but must not re-enable a known cross-tenant authorization bug.

## Security, tests and release gates

Test logged-out, ordinary user, employee, admin and instructor against old/new staff routes; pending/suspended/no membership deny; valid/invalid/inactive slug; staff A/resource B, dual-membership route A/resource B, parent-child/lane-block/event mismatch, no foreign PII. Public old aliases preserve intended CSK UX but never read foreign tenant by implicit authority. Owner old/new routes test same user in A and B, cancellation and events/reserve flows. ICS tests: owner, foreign user, foreign tenant resource, invalid ID, unauthenticated, cancelled, inactive historical lane, CR/LF injection, no PII/token, no-store; event ICS status and tenant consistency. Global Account/Dashboard tests confirm no selected tenant, account-wide export/anonymization untouched, declaration change invalidates each related tenant independently. Calendar/feed/check-in and cancellation email test authorization before data exposure. Test 320/375/430 mobile navigation, query/deep links, back/forward and no redirect loops.

Run focused C3 SQL, full DB suite after migration, Node, TypeScript, build, Playwright tenant/old-route/API/ICS/role matrices, `npm audit --omit=dev`, changed-files ESLint and `git diff --check`. Cross-tenant proof uses local or rollback-only fixtures only; no second active production tenant. Security authority stays `tenant_memberships.role/status`, resource tenant wins, route selector is not authority, RLS/DB must enforce independently of UI filters. Zero old-source inventory must be mechanically asserted, not inferred from a hidden link.

After C3 production PASS: 4D-2 is only **eligible for separate review** if `get_my_role`, `is_admin`, `is_admin_or_employee`, `is_admin_or_staff` direct caller counts are all zero **and** DB catalog, trigger and direct global-role authorization decisions are closed. Not automatic GO. 9D-5 entry: C3 PROD PASS, complete final caller recount, separately resolved 4D-2, zero active bridge callers where required, proven zero writer dependence on all seven defaults, no hidden CSK fallback, and still no active second tenant. SEC-004 remains OPEN until SAAS-9H.

## Planning decision and open verification gates

The target architecture is specified without an unresolved *business* choice. Before implementation, however, two technical gates require local proof: (1) the exact-ID ICS RPC and global account v2 preserve historical/caller semantics under current RLS; (2) all five placeholder staff modules and role-dependent API paths can reach feature parity without another DB contract. If either fails, stop, revise RPC count and request scope review. These are explicit implementation gates, not authorization to improvise new contracts. No production write or Git staging/commit/push is authorized by this document.

```text
SAAS-9E-C PHASE 2: CLOSED / PROD PASS
PHASE 3 LEGACY CALL SITES BEFORE: 18
FULL C3 INVENTORY: PASS for current source; live catalog recheck pending production preflight
OLD STAFF URL PLAN: PASS, parity-gated
PUBLIC ROUTE PLAN: PASS
OWNER ROUTE PLAN: PASS
ACCOUNT: GLOBAL
DASHBOARD: GLOBAL
ICS PLAN: PASS, DB-first
APP-ONLY PHASE 3: NO
DB CONTRACTS REQUIRED: 2 proposed
NEW SECURITY DEFINER REQUIRED: 2 proposed (+2; target 96)
GET_MY_ROLE CALLERS NOW: 8
IS_ADMIN CALLERS NOW: 0 direct app/API
IS_ADMIN_OR_EMPLOYEE CALLERS NOW: 0 direct app/API
IS_ADMIN_OR_STAFF CALLERS NOW: 0 direct app/API
EXPECTED LEGACY CALLERS AFTER C3: 0 operational sites; 0 direct 4D-2 helper sites; 22 retained definitions
4D-2 AFTER C3: ELIGIBLE FOR REVIEW, conditional on separate production/catalog proof
BRIDGE DEFINITIONS DURING C3: 22
COMPATIBILITY DEFAULTS DURING C3: 7/7
SECOND TENANT: NO-GO
SEC-004: OPEN
UNRESOLVED ARCHITECTURAL BLOCKERS: 0; two fail-closed technical proof gates above
READY FOR PHASE 3 LOCAL IMPLEMENTATION: GO, phased and subject to the two proof gates and separate authorization
PRODUCTION WRITE: NO
GIT WRITE: NO
```

## C3 PRE-IMPLEMENTATION CONTRACT FREEZE (2026-09-20)

This freeze is planning only and supersedes the provisional security-mode/count assumptions above. Source evidence: baseline `profiles` schema, `20260905100000_harden_profile_direct_updates.sql`, tenant-aware reservation/lane RLS, `20260911140000_harden_reservation_checkin_rpcs.sql`, `20260922100000_harden_account_lifecycle_rpcs.sql`, and current app/route shell. Production catalog counts remain previously recorded evidence, not a fresh live query.

### Contract 1 — reservation ICS exact reader

| Item | Frozen contract |
|---|---|
| FUNCTION / VERSION / SIGNATURE | `public.get_my_reservation_calendar_v1(p_reservation_id uuid)`; exact ID, 0–1 row; no caller tenant ID |
| SECURITY / OWNER / PATH / VOLATILITY | `SECURITY DEFINER`; `postgres`; fixed `pg_catalog,public,pg_temp`; `STABLE`; fully qualified objects, no dynamic SQL |
| ACL | Revoke EXECUTE from PUBLIC, anon, authenticated, service_role, then grant only authenticated; no new table grants |
| INPUT / OUTPUT DTO | Input UUID selector only. Return `reservation_id uuid, tenant_id uuid, reservation_date date, start_time time, end_time time, reservation_status text, lane_display_name text, tenant_public_name text`. `tenant_id` is server-internal, never written to ICS. |
| AUTH / OWNER / RESOURCE | `auth.uid()` non-null; persisted `reservation.user_id = auth.uid()`; preserve active tenant membership required by old v2 and require active resource tenant; staff role alone cannot export another user's ICS. |
| TENANT | Derive only from persisted `reservation.tenant_id`; lane and parent join on same tenant, including inactive historical lane for display. No active-CSK bridge, caller tenant authority or broad list read. |
| ERROR / NOT FOUND | HTTP invalid UUID 400; missing/invalid auth 401; foreign/nonexistent/no-membership/inactive tenant indistinguishable zero row → 404; own cancelled controlled 409; unexpected DB error generic 500. No row metadata in denial. |
| PII | No user_id, name, email, phone, address, permit, admin note, JWT, check-in/confirmation/cancellation token or ATTENDEE in DTO/ICS. No PII expansion. |

**Invoker versus definer.** `reservations` owner SELECT RLS requires `auth.uid()` **and active tenant membership** (`20260910120000...:128–135`). Public `shooting_lanes` SELECT excludes inactive historic resources; staff SELECT has a role requirement. An INVOKER join would not reliably preserve the existing inactive-lane label. `get_my_reservations_v3(T,page,size)` returns paged JSON, so PostgREST `.eq(id)` cannot safely constrain that RPC. INVOKER is **insufficient** for this exact historic-label contract without widening table grants/RLS. A narrow DEFINER is justified only with the explicit owner/member/resource checks above. Existing `app/api/calendar/reservations/[id]/route.ts` bearer validation stays; its flow becomes request → validated auth user → reservation ID → exact-ID RPC → persisted reservation tenant → owner check → minimal DTO → escaped, private/no-store ICS. An optional URL slug must be compared with the returned resource tenant, never used to grant. The old `get_my_reservations_v2()` call is removed.

### Contract 2 — global account profile writer

| Item | Frozen contract |
|---|---|
| FUNCTION / VERSION / SIGNATURE | `public.update_my_profile_v2(p_phone text,p_postal_code text,p_city text,p_street text,p_house_number text,p_apartment_number text,p_permission_sport boolean,p_permission_collector boolean,p_permission_hunting boolean,p_permission_training boolean,p_permission_personal_protection boolean,p_permission_other boolean,p_qualification_instructor boolean,p_qualification_range_officer boolean,p_qualification_pzss_license boolean,p_qualification_hunter boolean) RETURNS jsonb`; same 16 input types as v1 |
| SECURITY / OWNER / ACL / PATH | `VOLATILE SECURITY DEFINER`, owner `postgres`, fixed `pg_catalog,public,pg_temp`; revoke all EXECUTE then grant authenticated only; no direct UPDATE grant/policy restored |
| AUTH / WRITE | `auth.uid()` is the sole target ID. Lock and update only `profiles.user_id=auth.uid()`. Preserve v1 validation, idempotent `no_change`, changed declarations invalidating **each** related tenant verification row and tenant-bound audit per actual invalidation. |
| RETURN DTO | `ok`, `changed`, stable `code`, `declarations_changed`, `updated_at` only. No tenant ID, membership, role, verification status, active-CSK, exact-single-active bridge or `get_my_role` result. |
| FORBIDDEN | No caller target user_id/tenant_id; no changes to role, membership, membership status, admin_note, verified privilege, tenant verification authority, email/name identity, audit/system fields or permit numbers. |

**Invoker versus definer.** `20260905100000...:213–215` explicitly removed both profile UPDATE policies and authenticated table UPDATE. The current writer also changes protected tenant verification rows and writes audit. Regranting direct UPDATE to make INVOKER work would reopen CLEAN-005's blocked privilege path. INVOKER is **insufficient**; DEFINER is necessary with an exact `auth.uid()` row predicate and column allow-list. `/account` remains global/account-wide; export, anonymization, Auth deletion and future leave-tenant contracts are unchanged. Old v1 remains for additive old-app/new-DB compatibility until app cutover, then its active caller becomes zero.

### Full relevant `profiles` schema and owner whitelist

The baseline table (`20260816090000_remote_baseline.sql:9953–9996`) has **43** columns; no later profile ADD COLUMN was found in the migration chain. OWNER-WRITABLE means only through this allow-listed RPC, not direct DML. These ten `permission_*`/`qualification_*` inputs are self-declarations, **not verified privilege flags**.

| Classification | Exact fields | Count |
|---|---|---:|
| OWNER-WRITABLE | `phone`, `postal_code`, `city`, `street`, `house_number`, `apartment_number`, `permission_sport`, `permission_collector`, `permission_hunting`, `permission_training`, `permission_personal_protection`, `permission_other`, `qualification_instructor`, `qualification_range_officer`, `qualification_pzss_license`, `qualification_hunter` | 16 |
| IMMUTABLE in owner contract | `id`, `user_id`, `created_at` | 3 |
| SYSTEM-ONLY or separate controlled identity/admin flow | `full_name`, `first_name`, `last_name`, `email`, `role`, `weapon_permit_number`, `weapon_permit_type`, `weapon_permit_issuer`, `has_range_officer`, `range_officer_number`, `has_instructor`, `instructor_number`, `admin_note`, `updated_at` | 14 |
| TENANT-SCOPED ELSEWHERE / frozen legacy projection | `verification_status`, `verified_at`, `verified_by`, `verification_note`, `unverified_at`, `unverified_by`, `permissions_verified`, `permissions_verified_at`, `permissions_verified_by`, `permissions_verification_note` | 10 |

**Privilege-related owner-writable fields: 0.** `profiles.role` is legacy, not tenant authority; `profiles.admin_note` is frozen legacy, not the tenant note source. The global response contains no tenant-specific field.

### DB count and forward-only migration target

ICS mode **DEFINER** (+1); profile mode **DEFINER** (+1); new INVOKER **0**. Recorded baseline 94 → **projected 96**. The count follows actual RLS/ACL and audit needs, not the prior target. A single future minimal forward-only C3 migration creates these two versioned functions, sets owner/path/volatility/ACL, asserts old fingerprints and target metadata/count, and changes **no** historical migration, old signature, bridge definition or compatibility default. If implementation needs another function or grant, STOP and re-review the scope; no migration is created now.

### Five exact tenant-admin placeholders

All five are **A — MUST CUT OVER IN C3**. `app/t/[slug]/[...path]/page.tsx` rechecks active slug and `getStaffRouteContext(slug,roles)` (Auth + active tenant membership), but renders an operational component only for the four already selected Events/Lane Configuration/Reports/Users routes. Each of the five below renders the same generic placeholder and, only for `slug=csk`, a link back to the old global URL. Thus the tenant URL currently renders **no old component**, executes **no legacy RPC directly**, but **can link** to an old global action; following that link **loses the slug** and may reach bridge or `profiles.role` authority. A non-CSK placeholder has no old link but is not operational or tenant-ready.

| # / tenant URL | Source / current render / old target | RPC/API, tenant/authority, mutation, PII | C3 target and fail-closed rule |
|---|---|---|---|
| 1 `/t/[slug]/admin` | catch-all shell placeholder → `/admin` (`app/admin/page.tsx`) | Placeholder: resolver+M only, no mutation/PII. Old dashboard: `get_my_role`, unscoped reservations/events reads and customer PII. | Build T+M tenant dashboard with RLS+T and scoped links; then remove old component reachability and hand off old URL. Current old link/slug loss/role path **YES**. |
| 2 `/t/[slug]/admin/reservations` | shell placeholder → `/admin/reservations` (`app/admin/reservations/page.tsx`) | Old direct lane/reservation reads, customer PII, resource-bound operational writes; placeholder no calls. | Build selected T+M list; RLS+T, resource-bound writes, same role matrix; then redirect old URL. Old link/slug loss **YES**. |
| 3 `/t/[slug]/admin/calendar` | shell placeholder → `/admin/calendar` (`app/admin/calendar/page.tsx`) | Old `get_my_role`, `/api/admin/calendar-feed` and unscoped lane/reservation/block/event reads; instructor PII restrictions; placeholder no calls. | Build tenant calendar + tenant-qualified server feed with T+M, RLS+T and unchanged instructor scope; then redirect. Old link/slug loss/role path **YES**. |
| 4 `/t/[slug]/admin/check-in` | shell placeholder → `/admin/check-in` (`app/admin/check-in/page.tsx`) | Old `profiles.role`, direct reservations and resource-token check-in RPC; customer PII and attendance writes; placeholder no calls. | Build T+M list; token/resource tenant must match T, writes remain resource-bound; then redirect. Old link/slug loss/global role **YES**. |
| 5 `/t/[slug]/admin/lane-blocks` | shell placeholder → `/admin/lane-blocks` (`app/admin/lane-blocks/page.tsx`) | Old direct lane/block reads, resource-bound create/toggle; operational reason field, no customer PII; placeholder no calls. | Build T+M lane/block list, RLS+T and resource consistency; then redirect. Old link/slug loss **YES**. |

For **each** row: current `/t/...` directly renders old `/admin` component **NO**; links to global action **YES for CSK**; executes legacy RPC directly **NO**; loses slug after clicking old link **YES**; bridge/global-role exposure via old destination **YES where listed**. Every YES has the C3 target above. No B safe read-only compatibility or C deferral is accepted: redirecting now would regress live operations or loop through placeholder back-links. Until parity, the tenant URL remains **BLOCKED as an operational module** and the old URL keeps existing behavior; it is never called tenant-ready.

### Reverified 18→0 and role-helper 8→0 accounting

At HEAD `634ca40...`, L01–L18 in the source matrix above remain reachable. They are reclassified in user-facing terms as L01–L12 **OLD STAFF URL**, L13–L15 **PUBLIC**, L16–L17 **OWNER**, L18 **ICS**. Each has a frozen target and expected post-C3 source count **0**. ACCOUNT/DASHBOARD/ROLE HELPER/BRIDGE/OTHER are separate dependencies and do not secretly enlarge the 18-site metric. The old Events resource-bound RPC arms and five direct-table admin modules must also be retired/refactored, but do not inflate this specifically bridge/owner legacy metric.

| Mutually exclusive removal mechanism | IDs | Count |
|---|---|---:|
| Old staff URL handoff after canonical operational parity | L01–L12 | 12 |
| Remove old public/owner arms and use existing tenant RPC under explicit route | L13–L17 | 5 |
| Exact resource ICS contract replaces list RPC | L18 | 1 |
| Profile contract (separate `/account` site, not an L item) | — | 0 |
| Other route refactor (role/direct table work, not an L item) | — | 0 |
| **Total** | **L01–L18** | **18** |

The eight `get_my_role()` direct callers are independently accounted for: `app/page.tsx:132` `/` uses it to display a staff shortcut → global location navigation without a role grant; `app/admin/page.tsx:365` `/admin` → T+M dashboard; `app/admin/calendar/page.tsx:167` `/admin/calendar` preview role → T+M with unchanged instructor PII; `app/api/admin/calendar-feed/route.ts:82` → server T+M and RLS+T; `app/admin/events/page.tsx:412`, `app/admin/lane-configuration/page.tsx:515`, `app/admin/reports/page.tsx:124`, `app/admin/users/page.tsx:351` → delete old role branches and retain `get_my_tenant_role_v1(T)` in canonical screens. Thus **1+3+4=8 → 0**. `is_admin()`, `is_admin_or_employee()` and `is_admin_or_staff()` have **0 direct app/API callers now and target 0**; their DB dependencies/ACL require separate 4D-2 catalog proof and are untouched in C3. Direct `profiles.role` authorities in middleware, Check-in and cancellation-email server logic must also be removed, independent of this helper count.

### Frozen route, rollout and evidence limits

Known old `/admin/*` URLs hand off **only** to their same suffix under `/t/csk/admin/*`, after explicit legacy-CSK mapping, active-CSK verification, Auth and unchanged role matrix. There is no `if missing tenant use active tenant`, no exact-single-active lookup, no wildcard unknown-admin redirect. `/booking` and `/events` explicitly redirect to `/t/csk/booking` and `/t/csk/events`; `/my-reservations` and `/my-events` are tenant-specific, not global aggregates, and explicitly redirect to `/t/csk/...` after login. `/account` stays GLOBAL with no bridge-derived response; `/dashboard` stays GLOBAL location landing with no verification/role bridge. Reservation ICS is resource-ID-derived without caller tenant authority. Keep 22 old bridge **definitions** and 7/7 defaults for later 9D-5 review, not active use.

Rollout: **C3-A DB-first** additive two contracts → focused/local DB+ACL+PII tests → separate production preflight/deploy/postflight authorization; **C3-B APP** ICS/account caller cutover, all five canonical admin modules, role/direct-global cleanup, public/owner aliases and old staff redirects only after parity; **C3-C** production caller recount and checkpoint. Old app + new DB must PASS. DB rollback after use requires a separately reviewed forward corrective migration, never repair/destructive downgrade; app rollback may use a compatible prior commit but must not re-enable known authorization defects. C3 does not implement 4D-2/9D-5 or activate a second tenant.

Frozen tests: ICS owner/non-owner/anonymous/invalid/foreign-tenant/no-membership/cancelled/inactive-historical-resource, no PII/secret/injection and no-store; profile owner allow-list, other-user/role/admin_note/verification/membership mutation denial, no bridge-derived response, account-wide declaration invalidation/audit; all five placeholders converted or remain blocked, old→canonical no loop/slug loss, invalid/inactive slug, admin/employee/instructor/user and pending/suspended/no-membership role matrix, resource/route mismatch, public and owner aliases, global Account/Dashboard, L01–L18 zero, `get_my_role` zero and is_admin* unchanged. Cross-tenant local or rollback-only DB proof may PASS; single-CSK production runtime may PASS; **two-active-tenant production UI = NOT PERFORMED**, never marked PASS while second tenant is NO-GO.

Freeze verdict: FIVE PLACEHOLDERS IDENTIFIED **YES**; FIVE PLACEHOLDERS HAVE FINAL TARGET **YES**; ICS/PROFILE CONTRACT **FROZEN**; owner-writable privilege fields **0**; ICS/PROFILE SECURITY MODE **DEFINER/DEFINER**; NEW DB CONTRACTS **2**; NEW DEFINER **2**; PROJECTED COUNT **96**; unresolved architectural choices **0**. Local implementation is **GO only after separate authorization** and must stop/review if real RLS, DTO parity or a new caller contradicts this freeze. PRODUCTION WRITE **NO**; GIT WRITE **NO**.

## C3 local implementation checkpoint (2026-09-20)

The separately authorized local implementation is recorded in `SAAS_9E_C_PHASE3_LOCAL_IMPLEMENTATION_REPORT.md`. The frozen L01–L18 matrix above remains the authoritative before→after accounting: runtime source scan now finds **0/18** old operational call sites and **0/8** `get_my_role()` call sites. The three other direct role helpers have **0** app/API callers. All five tenant-admin placeholders render operational modules under the validated slug; old supported `/admin/*` URLs are explicit CSK-only compatibility redirects, and unknown admin paths return 404. No stored bridge definition or compatibility default was removed.

The single additive migration is `20260928100000_add_c3_owner_calendar_and_global_profile_contracts.sql` (SHA-256 `012A0472EA74CF17FD912C37B78A63B3BA68DF50144A46B35A0EAD5C2CAD6D0D`): two new authenticated-only definers, **94→96** total, bridge **22**, defaults **7/7**. Clean local migration replay passed; focused SQL **16/16**, full DB **1543/1543**, Node **777/777**, and Playwright **38/38** passed. TypeScript, production build, changed-file ESLint (0 errors, 3 existing hook warnings), and `git diff --check` passed. Final local reset removed E2E fixtures; read-only local counts for test users/profiles/lanes/events were all zero. The separate `npm audit --omit=dev` check reported one moderate transitive `baseline-browser-mapping` advisory; no dependency remediation is included in C3.

This is a **local-only** checkpoint. The two-active-tenant production UI matrix, live production catalog, deployment, and post-deploy verification have not been run. Production write, Git write, 4D-2, 9D-5, and second-tenant activation remain **NO**.
