# SAAS-9E-C Phase 1 — local operational caller cutover

Scope: local implementation and verification only. No production preflight, production SQL, Git staging/commit/push, Phase 2, Phase 3, 4D-2 or 9D-5 was performed. `AGENTS.md` was already modified independently and remains untouched/unrelated/excluded.

## Decision and inventory

The owner-list blocker recorded in the previous draft was resolved by approval of two additive, versioned tenant-scoped owner readers. The authoritative original **bridge** inventory was **15 unique direct-call RPC names at 17 UI call sites**. Standalone public availability was an additional planned DB contract without a direct app caller. The approved target is **18 versioned 9E-C contracts**: six in C1, twelve in C2, zero in C3. The two old owner-list UI calls were outside that original 17-row bridge table and remain legacy too. Five selected-tenant branches were added in C1, yielding **24 reviewed physical UI direct call sites = 17 original bridge + 2 old owner-list + 5 selected-tenant**. A further server-side ICS caller of the old reservation owner list is tracked separately. `app/account/page.tsx` and `app/dashboard/page.tsx` are among the 19 remaining active legacy UI sites, have no tenant slug, and are not mounted in `/t/[slug]` routes. The standalone availability v2 RPC has no direct app caller. The per-site phase mapping is in `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md`.

## Local DB contract

Canonical additive migration: `supabase/migrations/20260926100000_add_tenant_scoped_operational_readers.sql`. The quarantined `supabase/drafts/20260926100000_add_tenant_scoped_public_operational_readers.sql` remains a non-deployable historical draft and was not copied verbatim. Six new `postgres`-owned, SP1 `SECURITY DEFINER` RPCs preserve all legacy signatures and the 22 bridge definitions:

| Contract | Caller / result | Gate |
|---|---|---|
| `get_public_booking_configuration_v2(uuid)` | tenant booking configuration; existing PII-free DTO | active tenant; anon/authenticated only |
| `get_public_event_list_v3(uuid,text,text,integer,integer)` | bounded tenant event page; existing PII-free DTO | active tenant; tenant filter before count/page; anon/authenticated only |
| `get_public_event_availability_v2(uuid)` | standalone PII-free availability DTO | active tenant; anon/authenticated only |
| `get_my_tenant_verification_v2(uuid)` | caller's own tenant verification | active tenant plus `auth.uid()`; authenticated only |
| `get_my_reservations_v3(uuid,integer,integer)` | owner reservation JSON page, established item fields | active tenant plus `auth.uid()` and row tenant **before** count/order/limit; authenticated only |
| `get_my_event_registrations_v2(uuid,text,text,integer,integer)` | owner event JSON page, existing status/scope DTO | active tenant plus `auth.uid()` and row tenant **before** filters/count/order/limit; authenticated only |

The two owner readers remain `SECURITY DEFINER` because current reservation RLS and historical lane/event joins do not preserve the established owner DTO under `SECURITY INVOKER`. They explicitly enforce identity and tenant equality in the body. A supplied tenant UUID selects an active scope; it never authorizes foreign-owner rows. No `profiles.role` authority or browser service role was introduced. Function-count target is **70 + 6 = 76** after C1 and **76 + 12 = 88** after C2; 22 old bridge definitions and seven compatibility defaults remain. Old global/multi-membership owner-list RPCs remain available to the old URLs until a reviewed later cutover.

Local reset was authorized and gated against `127.0.0.1:54322`; `supabase db reset --local` rebuilt the full canonical migration chain including `20260926100000`. No `--linked`, migration repair or remote DB operation was used. The focused rollback-only SQL matrix uses a single synthetic owner with eight A and eight B reservations and event registrations. For tenant A, page 1/limit 5 yields five A rows and total 8, not 16; page 2 yields three rows. The symmetric B checks pass after a transaction-local active-tenant swap. Foreign owner, dormant tenant and cross-tenant row checks deny/return zero as appropriate. Final `ROLLBACK` removes the fixture.

## Application cutover and route boundary

`/t/[slug]/booking`, `/t/[slug]/events`, `/t/[slug]/my-reservations` and `/t/[slug]/my-events` mount the existing UI with a server-resolved active tenant UUID. Their data calls use the five selected-tenant RPC branches listed above; no app-side filtering of a global owner list exists. `/booking`, `/events`, `/my-reservations` and `/my-events` retain their explicit legacy branches for current CSK compatibility. Account and Dashboard remain global legacy callers, receive no foreign slug/context and cannot grant tenant staff authority. Their bridge dependency means the zero-old-caller gate is **not met**.

Tenant-route create-reservation, event registration and event cancellation requests carry a slug selector. Server handlers compare the selected active tenant to the persisted lane/event/registration tenant using the authenticated client before invoking existing resource-bound mutation RPCs. The tenant-route reservation cancellation endpoint performs the same comparison before the canonical `cancel_reservation` RPC. The slug cannot override the resource tenant. Existing email/claim flows and old URL mutation paths are unchanged. Tenant staff pages remain fail-closed placeholders outside C1. The active-single-tenant production guard remains; local A/B fixture tests do not authorize a second active production tenant.

## Verification and limitations

| Check | Local result |
|---|---|
| Focused C1 SQL | **20/20 PASS**, transaction ends `ROLLBACK` |
| Full Supabase DB suite | **46 files / 1447 tests PASS**; historical exact inventory assertions updated for six reviewed functions |
| Resource/slug guard Node tests | **4/4 PASS** |
| Full Node suite | **771/771 PASS** |
| TypeScript | `npx tsc --noEmit` **PASS** |
| Production build | `npm run build` **PASS**; existing middleware/proxy warning only |
| Focused Playwright | tenant routing, booking configuration, events responsive suite **12/12 PASS**; tenant-route assertions refreshed after placeholder removal |
| Changed-files ESLint | No new findings. `app/events/page.tsx` retains two baseline errors and one warning, verified in `HEAD` source |
| `npm audit --omit=dev` | **One moderate existing dependency advisory** for `baseline-browser-mapping`; no dependency change in C1, not auto-fixed |
| `git diff --check` | **PASS** |
| Independent local fixture post-check | local `supabase_db_csk-booking` read-only COUNT across tenant/lane/event/reservation/registration marker fields: **0** |

No browser end-to-end session with two simultaneously active production tenants was attempted or claimed. The rollback-only local DB matrix proves the A/B owner-list data boundary under the present exact-one-active-tenant guard. Runtime tenant routes were exercised for public rendering and unauthenticated owner/staff denial; authenticated owner UI behavior is supported by SQL/Node contract tests, not a complete browser A/B fixture. Production preflight is a separate, not-yet-authorized phase. The `supabase/drafts` file must not enter a deployment checkpoint; `AGENTS.md` remains unrelated.

SAAS-9E-C PHASE 1 LOCAL: **PASS**

TENANT-SCOPED MY RESERVATIONS: **PASS**

TENANT-SCOPED MY EVENTS: **PASS**

DB-LEVEL PAGINATION: **PASS**

APP-SIDE TENANT FILTERING: **ABSENT**

CROSS-TENANT OWNER ISOLATION: **PASS (local rollback-only DB matrix)**

UNIQUE RPC CONTRACTS: **18 planned (15 original direct-call contracts + standalone availability + 2 owner readers)**

DIRECT CALL SITES: **24 reviewed UI sites after C1 (19 legacy + 5 selected-tenant); one additional server ICS legacy site**

ACTIVE LEGACY CALL SITES AFTER PHASE 1: **19 UI; 20 including the server ICS caller**

SECURITY DEFINER COUNT AFTER PHASE 1: **76 locally**

FULL 9E-C TARGET SECURITY DEFINER: **88**

BRIDGE DEFINITIONS: **22**

4D-2 ZERO-CALLER GATE: **NOT MET**

4D-2: **NO-GO**

READY FOR PHASE 1 PRODUCTION PREFLIGHT: **GO — separate authorization required**

READY FOR PHASE 2: **NO-GO until review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## PHASE 1 DB PRODUCTION DEPLOY & POST-DEPLOY (DB-FIRST CHECKPOINT)

The approved report order was **DB FIRST, APP only after this checkpoint**. Immediately before the write, the linked project ref and dashboard were both `yuyxfodozzpzrdzkmolu`; the canonical migration SHA-256 was `AD94B30D5F7B825409E544F996F364C8843C581B45FBB46CBBB674DA679EC926`. Linked history had 101 matched versions through `20260925100000`, no remote-only row and one pending local version, `20260926100000`. The final CLI dry-run listed only `20260926100000_add_tenant_scoped_operational_readers.sql`. The draft under `supabase/drafts` was not in the migration directory. `AGENTS.md` remained unrelated and unstaged. Read-only production SQL immediately before push returned one active tenant (CSK), 70 public SECURITY DEFINER functions, 22 active-single-tenant bridge definitions and 7/7 compatibility defaults.

With the separate user authorization, `npx.cmd --no-install supabase db push --linked` applied **only** that migration and exited 0. No app deployment, additional persistent production write, migration repair or Git write was performed. Post-deploy linked history shows `20260926100000` LOCAL=REMOTE, and the final dry-run says `Remote database is up to date.` Production catalog SELECT returned one active tenant, 76 public SECURITY DEFINER functions, 22 bridge definitions, 7/7 defaults and exactly one migration-history row for this version. The delta of six matches the six additive target functions; no other function was replaced by the migration.

All six new RPCs were inspected in the production catalog: the intended signatures are present, each is `postgres`-owned, `STABLE SECURITY DEFINER` with `search_path=pg_catalog, public, pg_temp`; the three public readers allow `anon` and `authenticated`, while the three owner/user readers allow `authenticated` only. None has effective `PUBLIC` or `service_role` EXECUTE. The additive migration did not change legacy owner-reader signatures or the 22 bridge definitions. SQL body review and the production owner matrix establish `auth.uid()` plus selected active tenant filtering inside the database, before count, ordering and LIMIT/OFFSET; no browser-side tenant post-filter is used for the new tenant-route lists.

The production rollback-only owner matrix used synthetic `example.invalid` actors and future-dated A/B records in `BEGIN` with terminal `ROLLBACK`. The SQL Editor initially rejected a test-harness GUC (`saas9ec1_checks`); **no security assertion was counted from that attempt**, and an immediate independent check found zero residue. The corrected matrix preserved the same 20 authorization/pagination predicates, made each predicate fail-closed in a transaction-local `pg_temp.ok` helper and completed without an exception, returning `20 checks reached`. A further independent SELECT after `ROLLBACK` found **zero** synthetic tenants, Auth users, profiles, memberships, lanes, reservations, events, registrations and matching audit fixtures; CSK remained active. It proved A page size 5/total 8 with eight B records present, A page 2 size 3, the same result for events, foreign owner total 0, dormant B denial, then B-only page/total after the transaction-local active-tenant switch and A denial while B was active. No synthetic row persisted.

Current deployed app + new DB: anonymous HTTP GET smoke returned 200 after redirects, without 5xx, for `/booking`, `/events`, `/my-reservations`, `/my-events`, `/account`, `/dashboard`, `/admin` and `/login`. This is an availability/compatibility smoke, **not** an authenticated end-to-end UI proof. The existing reservation ICS route is unchanged in the working tree, still calls `get_my_reservations_v2()` under the owner session and is explicitly deferred (one of 20 active legacy call sites: 19 UI, one server ICS). An anonymous request with a nonexistent valid reservation UUID returned 401; a live authenticated owner ICS download was **not** performed. Its old-RPC signature and preflight normalized fingerprint were unchanged, and the new migration is additive. Thus the legacy ICS server path has contract and denial evidence, not a new authenticated production delivery claim. The 20 legacy app sites and 22 definitions remain separate metrics.

`git diff --check` exited 0 (Git reported only advisory working-copy LF/CRLF conversion warnings). `AGENTS.md` and the nondeployable draft were neither staged nor modified by this deployment. The app cutover still needs separate authorization and subsequent authenticated UI/ICS smoke; no second tenant can be activated, and SEC-004 remains open.

SAAS-9E-C PHASE 1 DB PRODUCTION DEPLOY: **PASS**

DB POST-DEPLOY: **PASS**

TENANT-SCOPED MY RESERVATIONS: **PASS — production rollback-only matrix**

TENANT-SCOPED MY EVENTS: **PASS — production rollback-only matrix**

DB-LEVEL PAGINATION: **PASS**

APP-SIDE TENANT FILTERING: **ABSENT in new tenant-route callers**

CROSS-TENANT OWNER ISOLATION: **PASS**

CROSS-TENANT PII: **PASS in tested DB owner DTO scope; no second tenant activated**

CURRENT APP + NEW DB: **PASS — additive compatibility and unauthenticated HTTP smoke; authenticated UI not exercised**

ACTIVE LEGACY CALL SITES: **20 (19 UI + 1 ICS)**

BRIDGE DEFINITIONS: **22**

SECURITY DEFINER COUNT: **76; unexpected delta 0**

COMPATIBILITY DEFAULTS: **7/7**

FIXTURE CLEANUP: **PASS — zero persisted synthetic rows**

READY FOR PHASE 1 APP CUTOVER: **YES — separate approval and post-app authenticated smoke required**

READY FOR PHASE 2: **NO-GO**

READY FOR 4D-2: **NO-GO**

SECOND TENANT: **NO-GO**

## APP CUTOVER PRODUCTION DEPLOYMENT (separately approved)

The DB-first checkpoint above remained intact. The approved app-only commit is
`07bfd63aa4bc8237a85c9d3de351e17e8f246118` (`SAAS-9E-C Phase 1 cut over
tenant operational callers`). The exact staged/committed scope was **19 files**:

| Deployed runtime file(s) | Call site / old → selected-tenant contract | Tenant/resource authority | Legacy after cutover |
|---|---|---|---|
| `app/t/[slug]/[...path]/page.tsx` | Passes trusted server-resolved tenant to four C1 screens | Active slug resolved server-side; no client tenant authority | Old CSK URLs remain separate |
| `app/booking/page.tsx` | Public config `get_public_booking_configuration_v1` → `v2` on tenant route | Server tenant ID; no resource argument | v1 on global `/booking` |
| `app/booking/BookingForm.tsx` | Owner verification `get_my_active_tenant_verification_v1` → `get_my_tenant_verification_v2` on tenant route | Server tenant ID plus DB `auth.uid()` | v1 on global booking |
| `app/events/page.tsx` | Public list `get_public_event_list_v2` → `v3` on tenant route | Server tenant ID; registration request carries slug, not authority | v2 on global `/events` |
| `app/my-reservations/page.tsx` | Owner list `get_my_reservations_v2` → `v3` on tenant route | Server tenant ID plus DB owner; DB pages/counts before rendering | v2 on global page |
| `app/my-events/page.tsx` | Owner list `get_my_event_registrations_v1` → `v2` on tenant route | Server tenant ID plus DB owner; DB page/count before rendering | v1 on global page |
| `app/api/create-reservation/route.ts`, `app/api/register-event/route.ts`, `app/api/cancel-event-registration/route.ts` | Existing resource-bound writers, no new RPC; route slug checked against persisted resource tenant | Persisted reservation/event tenant wins; mismatch denied | Existing no-slug callers retain contract |
| `app/api/tenant-cancel-reservation/route.ts` | New tenant URL to the existing controlled cancellation RPC | Server checks authenticated owner and persisted reservation tenant | Existing cancellation endpoint retained |
| `lib/server/tenant-resource-scope-core.ts`, `lib/server/tenant-resource-scope.ts` | Server helper for the four API paths above, not an RPC | Resolved active slug compared with persisted resource `tenant_id` | Not a client authority |
| `lib/event-read-contracts.ts` | Parses v1/v2 owner DTO shape, no direct RPC | DTO compatibility only | v1 remains supported |

The six committed test files are `lib/booking-day-group.test.mjs`,
`lib/booking-time-range.test.mjs`, `lib/public-booking-configuration.test.mjs`,
`lib/public-event-availability.test.mjs`,
`lib/server/tenant-resource-scope.test.mjs`, and
`tests/e2e/tenant-routing.spec.ts`. The last one now tests an authenticated
local user against the two tenant owner readers and BookingForm verification;
only its public booking-configuration DTO is mocked because the local database
has no active bookable lane. It also tests Account/Dashboard legacy continuity.
The local synthetic Auth user is deleted in `finally`. No app-step DB/schema
change or production fixture was created. No app-side filtering of a global
owner list was introduced; the selected-tenant owner reader receives a bounded
page and returns its count from the DB.

Predeploy rerun: focused Node **80/80**, full Node **771/771**, TypeScript
**PASS**, production build **PASS**, focused Playwright **15/15**, staged and
unstaged `git diff --check` **PASS**. Changed test ESLint **PASS**; changed-file
ESLint still reports the existing two errors/one warning in
`app/events/page.tsx`, already present in HEAD before C1 (no new finding).
The build also repeats the pre-existing Next.js middleware deprecation warning.
Staging was exactly the 19 files above and `git diff --cached --check` passed;
`AGENTS.md`, migration, SQL tests, plan, this report and draft were excluded.

After `git fetch origin`, divergence was **behind 0 / ahead 1**, and a plain
`git push origin main` advanced `6c3b961` to `07bfd63` without force, reset or
rebase. Local HEAD and `origin/main` now both equal the full commit above,
divergence **0/0**. GitHub's Vercel status for the *requested target*
`csk-booking-5nwh` says **success — Deployment has completed**, deployment
`GX8UrcbHET6Twuiy7k1doZsBzGkb`. A distinct GitHub status for a different
Vercel project named `csk-booking` (without `-5nwh`) reports a failed deployment
`Hci271ddLZhQ3V1nBo4vQkdbGb2A`; this is not the requested production target
and should be investigated separately before treating that second project as
healthy. The target's live `/t/csk/my-*` pages render the new (previously
placeholder) owner UI, corroborating the new commit is active.

Authenticated, read-only browser smoke in the existing production session:
`/t/csk/my-reservations` rendered its controlled empty state without a raw
error; `/t/csk/my-events` rendered one owner registration with page **1/1,
total 1** and disabled previous/next controls; `/t/csk/booking` rendered the
lane selection and BookingForm; `/account` loaded the legacy profile form; and
`/dashboard` loaded the legacy panel. No booking, cancellation, account write
or email was triggered. The browser console reported no error/warning on the
tenant booking view. This smoke proves the signed-in CSK flows, not a live
two-active-tenant UI test: that remains forbidden by the exact-one-active
guard. Cross-tenant owner count/PII isolation was established instead by the
prior **20/20 production rollback-only DB matrix** with A/B fixtures and
independent zero-residue check. There was no new production fixture in this
app deployment. Public `/` rendered successfully and the new route pages did
not show 5xx.

The existing global `/account` and `/dashboard` source files were unchanged;
the server-side reservation ICS caller remains unchanged on
`get_my_reservations_v2()`. Repo-wide C1 inventory still has **19 active
legacy UI call sites + 1 ICS server site = 20**, distinct from the **22**
stored bridge definitions. The five new selected-tenant UI branches do not
erase the old global CSK branches; subtracting five from the already
post-C1-counted 20 would double-count the cutover. The DB-only post-deploy
catalog measured **76** SECURITY DEFINER functions, **22** bridge definitions,
**7/7** compatibility defaults and exactly one active CSK tenant; the app-only
commit made no DB change. No second tenant was activated. `AGENTS.md` remains
unrelated, modified in the working tree but **unstaged/uncommitted**.

SAAS-9E-C PHASE 1 APP DEPLOY: **PASS**

VERCEL DEPLOY: **PASS — requested `csk-booking-5nwh`; separate `csk-booking` status failed**

PRODUCTION VERSION: **NEW COMMIT ACTIVE**

TENANT-SCOPED MY RESERVATIONS: **PASS — authenticated empty state + DB matrix**

TENANT-SCOPED MY EVENTS: **PASS — authenticated page/count + DB matrix**

DB-LEVEL PAGINATION: **PASS — DB matrix; 1/1 live UI**

APP-SIDE TENANT FILTERING: **ABSENT**

BOOKINGFORM CUTOVER: **PASS**

ACCOUNT LEGACY COMPATIBILITY: **PASS**

DASHBOARD LEGACY COMPATIBILITY: **PASS**

AUTHENTICATED PRODUCTION E2E: **PASS for current CSK; live A/B UI not claimed**

CROSS-TENANT OWNER ISOLATION: **PASS — rollback-only DB matrix, not two-active-tenant browser test**

CROSS-TENANT PII: **PASS — tested DB owner DTO scope; no live Tenant B activation**

ACTIVE LEGACY CALL SITES AFTER APP CUTOVER: **20 (19 UI + 1 ICS)**

BRIDGE DEFINITIONS: **22**

SECURITY DEFINER COUNT: **76**

COMPATIBILITY DEFAULTS: **7/7**

ICS: **LEGACY, unchanged**

READY FOR FINAL PHASE 1 CHECKPOINT: **YES — separate Git/report scope review**

READY FOR PHASE 2 PLANNING/REVIEW: **GO**

READY FOR PHASE 2 IMPLEMENTATION: **NO-GO until Phase 1 checkpoint/review**

READY FOR 4D-2: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

SEC-004: **OPEN**

## HISTORICAL PRODUCTION PREFLIGHT & DEPLOYMENT READINESS (BEFORE DB PUSH)

This section preserves the **pre-deployment snapshot** of read-only production checks and CLI dry-run. The completed DB deployment and current production state are documented immediately above. Production project identity was checked against linked `supabase/.temp/project-ref` and the Supabase dashboard URL: `yuyxfodozzpzrdzkmolu`. At preflight time no production data-changing SQL, migration repair, Git write, app deployment or second-tenant activation was performed.

### 1. Working tree and canonical migration

Raw `git status --short`, `git diff --name-only`, `git diff --stat`, `git diff --check` and `git ls-files --others --exclude-standard` were reviewed. There are **36 tracked real-content diffs and 8 untracked files**. `git diff --ignore-cr-at-eol --name-only` lists the same 36 tracked paths: **zero CRLF/LF-only paths**. Exact classification of all 44 paths:

| Category | Count | Exact scope |
|---|---:|---|
| Phase 1 migration | 1 | `supabase/migrations/20260926100000_add_tenant_scoped_operational_readers.sql` |
| Phase 1 app cutover / server resource guard | 13 | `app/api/{cancel-event-registration,create-reservation,register-event,tenant-cancel-reservation}/route.ts`; `app/booking/{BookingForm,page}.tsx`; `app/events/page.tsx`; `app/my-{events,reservations}/page.tsx`; `app/t/[slug]/[...path]/page.tsx`; `lib/event-read-contracts.ts`; `lib/server/tenant-resource-scope-{core,server}.ts` (actual server facade is `tenant-resource-scope.ts`) |
| Phase 1 focused tests | 2 | `supabase/tests/20260926100000_add_tenant_scoped_operational_readers_test.sql`; `lib/server/tenant-resource-scope.test.mjs` |
| Regression / ACL / inventory tests | 24 | 19 historical `supabase/tests/*.sql` inventory updates; four `lib/{booking-day-group,booking-time-range,public-booking-configuration,public-event-availability}.test.mjs`; `tests/e2e/tenant-routing.spec.ts` |
| Plan and report | 2 | `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md`; this report |
| Unrelated real diff, excluded | 1 | `AGENTS.md`, Next.js-generated instruction-block change; not staged, modified or reverted by this task |
| Temporary support, excluded | 1 | `supabase/drafts/20260926100000_add_tenant_scoped_public_operational_readers.sql` |
| Unexpected / CRLF-only | **0 / 0** | No other semantic path |

The tracked app changes were inspected with `git diff --ignore-cr-at-eol`; they are conditional tenant branches, resource comparisons and matching test updates. The 19 historical SQL changes only update the exact 70→76 definer count, six ACL/inventory rows, and one allow-list. The draft is outside `supabase/migrations` and **must not** be deployment input. Canonical migration SHA-256: **`AD94B30D5F7B825409E544F996F364C8843C581B45FBB46CBBB674DA679EC926`**. `git diff --check` exited 0.

### 2. Local and production migration history

Local confirmed database is the local `supabase_db_csk-booking` container, not a linked production target. Its `supabase_migrations.schema_migrations` has **102** versions, exactly matching **102** canonical filesystem filenames; latest `20260926100000`, no local-only ghost version or filesystem-only version. The local prefix through `20260925100000` has 101 versions, min `20260716082130`, normalized ordered-version MD5 `78af8003b7a0ec8ae20c25464afde489`.

Production read-only SQL returned **101** versions, the same min/max and MD5; the latest is `20260925100000`, and target `20260926100000` is absent. Linked CLI `migration list` parsed **102** rows: 101 identical local/remote, zero malformed, zero mismatch, zero remote-only, and exactly one local-only version `20260926100000`. `npx.cmd --no-install supabase db push --linked --dry-run` exited 0 and displayed **only** `20260926100000_add_tenant_scoped_operational_readers.sql`. It explicitly said migrations would not be pushed. CLI v2.109.1's v2.117.0 update notice is informational; no update was attempted.

### 3. Exact Phase 1 RPC scope and SECURITY DEFINER delta

All six new functions are local `postgres`-owned, `STABLE SECURITY DEFINER`, fixed `search_path=pg_catalog, public, pg_temp`, with no effective `PUBLIC` or `service_role` EXECUTE. Existing versions are preserved. The six are the entire **C1** slice of the **18-contract** 9E-C plan (C2=12, C3=0). `T` below is the UUID obtained by the server from the active slug; the RPC independently checks active tenant. Browser-supplied UUID is a scope selector, never authorization.

| Function/signature | Direct tenant-route caller | Class / resource / page | ACL | Why DEFINER; PII/audit/risk |
|---|---|---|---|---|
| `get_public_booking_configuration_v2(uuid)` | `app/booking/page.tsx` | PUBLIC; lane config for T; no pagination | anon, authenticated | Calls closed tenant-parameterized INVOKER core that clients cannot execute; public 14-field PII-free DTO, read-only/no audit; LOW |
| `get_public_event_list_v3(uuid,text,text,integer,integer)` | `app/events/page.tsx` | PUBLIC; event page scoped to T before count/page | anon, authenticated | Closed core cannot be granted directly; no participant PII, read-only/no audit; LOW |
| `get_public_event_availability_v2(uuid)` | none (standalone DB contract) | PUBLIC; event availability for T | anon, authenticated | Closed core cannot be granted directly; PII-free aggregate, read-only/no audit; LOW |
| `get_my_tenant_verification_v2(uuid)` | `app/booking/BookingForm.tsx` | AUTH USER; `auth.uid()` and T; no page | authenticated | Direct tenant verification table ACL/RLS is closed; returns only caller status/flags/timestamps, no staff role or audit write; MEDIUM |
| `get_my_reservations_v3(uuid,integer,integer)` | `app/my-reservations/page.tsx` | OWNER; reservation rows and historical lane labels; DB page/total | authenticated | INVOKER would not preserve historical owner rows/label joins under current RLS; exact owner+tenant predicate precedes ordering/count/limit; owner operational token in DTO, no foreign PII or audit write; MEDIUM |
| `get_my_event_registrations_v2(uuid,text,text,integer,integer)` | `app/my-events/page.tsx` | OWNER; event registration/status/scope; DB filter/page/total | authenticated | INVOKER would not preserve historical event joins under current RLS; exact owner+tenant predicate precedes status/date filters/count/limit; owner event DTO only, no audit write; MEDIUM |

Production baseline read-only: **70** public SECURITY DEFINER, **22** bridge-containing definitions, **7/7** temporary CSK defaults, exactly one active CSK tenant. Local target is **76**, attributable to exactly six additive functions; no pre-existing target function was replaced. Full C1+C2 projection is **88**, not a present production count. The seven normalized `pg_get_functiondef` MD5s for the three existing public cores, old verification, both old owner lists, and slug resolver matched local against production exactly. This also confirms the current closed cores and legacy inputs used by the new wrappers have no observed definition drift. Unexpected DEFINER delta and unidentified target functions: **0**.

### 4. Production integrity and owner-list semantics

Aggregate, PII-free production SELECTs returned **0** for orphan reservation lanes, reservation/lane tenant mismatch, null or orphan event IDs, event-registration/event tenant mismatch, orphan or mixed-tenant event-lane links, duplicate `(tenant_id,user_id)` memberships, and unknown reservation, registration, membership-role or membership-status values. No customer row or identifier was exported.

The new SQL bodies validate active T and `auth.uid()` and require `reservation.user_id=actor AND reservation.tenant_id=T`, or `registration.user_id=actor AND registration.tenant_id=T` with an event join on T. These `owned` sets are materialized **before** owner-list count, status/scope filtering, ordering and `LIMIT/OFFSET`. The focused rollback-only local matrix created eight A and eight B records of each kind: A page 1/size 5 returned five A items and total 8, page 2 three; switching the sole active tenant yielded B total 8 and no A IDs. Foreign user totals were zero; dormant/invalid tenant was denied. No app-side tenant post-filter exists. Post-rollback independent local marker count was **0**.

Owner reservation DTO fields: `id` (record ID), `reservation_date`, `start_time`, `end_time`, `price`, `reservation_status`, `payment_status`, `attendance_status`, `checked_in_at`, `lane_display_name` (operational UI), and `check_in_token` (sensitive owner-only check-in action). Every field originates in tenant-owned `reservations` or same-tenant `shooting_lanes`; no profile, customer email/phone/address or admin note is fetched. The owner check-in token remains a sensitive established owner DTO field and must never enter public output or logs. Owner event DTO fields: registration `id`, `registration_status`, `payment_status`, `created_at`, plus nested same-tenant event `id`, `title`, `description`, `event_date`, `start_time`, `end_time`, `location`, `price`. It contains no participant contact data or other user's registration. Both contracts are DB-paginated and owner-only.

### 5. All 25 runtime call sites and deferrals

The 17 baseline bridge UI sites are listed individually with file/source/authority in the plan's `9E-C direct-call-site allocation correction` table. Their exact allocation after C1 is below. A conditional C1 branch does **not** erase the old global URL branch; all old sites remain active until URL cutover.

| Phase | Sites | Exact callers / why safe or deferred |
|---|---:|---|
| C1 selected-tenant | **5** | `app/booking/page.tsx` config v2; `app/events/page.tsx` list v3; `app/booking/BookingForm.tsx` verification v2; `app/my-reservations/page.tsx` owner list v3; `app/my-events/page.tsx` owner list v2. Each receives server-resolved T only under `/t/[slug]`; owner lists filter by actor+T in DB. |
| C2 legacy pending | **14** | Account and Dashboard verification (2, global, no slug), plus Admin Events list/create (2), Lane Configuration reader/create (2), Reports KPI/export (2), Users list/role/note/verification/identity/contact (6). Staff tenant routes are still placeholders, so these global CSK callers cannot render B under an A route. Exact-single-active bridge remains functional. |
| C3 legacy URL/caller retirement | **6** | Old `/booking` config, `/events` list, BookingForm verification (3 conditional legacy branches); old `/my-reservations` and `/my-events` owner-list branches (2); `app/api/calendar/reservations/[id]/route.ts` server ICS owner-list caller (1). Each is global/CSK compatibility rather than a foreign tenant-route read. Remove or make route-bound only after separate old-URL/ICS review. |
| **Total** | **25** | **24 UI + 1 server ICS**, no unassigned caller. |

Thus active legacy after C1 is **20 = 19 UI + 1 ICS**, while stored bridge definitions remain **22 before and after target**. The original 17 bridge UI callers alone are not the entire active legacy inventory. Account/Dashboard do not receive a slug, do not grant client tenant authority and cannot be mounted under `/t/[slug]`. Existing admin callers also remain global, behind current server/DB authorization and the exact-single-active bridge; no tenant B data is presented under route A. This is transition safety, **not** multi-tenant readiness.

ICS specifically uses `app/api/calendar/reservations/[id]/route.ts` → `get_my_reservations_v2().eq('id',id).maybeSingle()` under the authenticated owner's credentials. It has no tenant slug or browser-supplied foreign-owner authority, returns a synthesized calendar file with no email/phone/check-in token, and old RPC membership/active-tenant checks remain. Its global endpoint is not a tenant-route data source; the new tenant page's CTA receives only IDs from its T-scoped owner list. A caller could request their **own** other-tenant ID on the global endpoint after future activation, but the current bridge fails closed unless exactly one tenant is active; second tenant remains blocked. This caller therefore needs explicit C3 route-context/ICS cutover before second-tenant readiness; it is not silently declared retired.

### 6. Trusted context, resource mismatches, 4D-2 and compatibility

`/t/[slug]` resolves an active tenant on the server. The public UUID passed to a new RPC is validated again in DB; owner authority is `auth.uid()`, not `profiles.role`. The three tenant-route mutation handlers and tenant reservation cancellation endpoint compare the persisted `resource.tenant_id` to server-resolved slug tenant before the canonical resource-bound RPC. A route A/resource B or route B/resource A mismatch fails closed, with no CSK fallback or resource rebinding. The local guard tests passed 4/4. Staff routes require active membership and allowed role before showing even their transitional placeholder; C1 does not expand instructor scope. Legacy mutation paths remain unchanged and are not used as foreign tenant-route authority.

4D-2 remains blocked. `get_my_role()` still has eight app/API callers: homepage, Admin root, Calendar, Reports, Users, Events, Lane Configuration and calendar-feed; C3 must remove them and direct `profiles.role` authority before zero-call proof. `is_admin()`, `is_admin_or_employee()` and `is_admin_or_staff()` are closed legacy helpers with no intended active app caller, but their ACL retirement also requires catalog/caller proof. For each of these four, the zero-caller gate is **NOT MET as a whole** after C1 and expected still NOT MET after C2; only full C3 production cutover plus separate review can change that. No 4D-2 ACL was changed here.

| Compatibility state | Result / gate |
|---|---|
| CURRENT APP + CURRENT DB | PASS, present production single-CSK runtime |
| NEW APP + CURRENT DB | **UNSAFE**: tenant routes call six missing RPCs; old URLs remain but this is not a usable rollout |
| CURRENT APP + NEW DB | PASS contractually: six additive functions, old signatures/22 bridges/7 defaults untouched |
| NEW APP + NEW DB | Local PASS; production PASS still requires a separately approved DB-first migration then app deployment and runtime smoke |

Recommended order is **DB FIRST, then APP**, with a verification gate between them. On app rollback, the previous app remains compatible with the additive DB. A failed transactional DB migration rolls back; after production use, any corrective change requires a separately reviewed migration, never repair or destructive downgrade. DB RPC risk **MEDIUM** because six privileged readers include owner DTOs, though authorization is scoped and no data backfill occurs. App cutover risk **MEDIUM** because stale legacy branches, ICS, route/resource mismatch and partial deployment require explicit gates. The draft must remain excluded, and the canonical SHA must be rechecked immediately before any future push.

### 7. Local evidence and current production runtime

The accepted local run remains **focused SQL 20/20; full DB 1447/1447; Node 771/771; Playwright 12/12; TypeScript/build/diff check PASS; fixture residue 0**. Since that run, the working tree's application/migration/test semantics have not been changed in this preflight; this section adds read-only evidence and report text only. Changed-file ESLint has no new findings; the two errors and one warning in Events are present in `HEAD`. `npm audit --omit=dev` reports one pre-existing moderate `baseline-browser-mapping` advisory; `package*.json` and dependencies were not changed. Neither residual is remediated in this scope.

Unauthenticated production GET smoke returned HTTP 200 without 5xx for `/booking`, `/events`, `/my-reservations`, `/my-events`, `/account`, `/dashboard`, `/login`, `/t/csk/booking` and `/t/csk/events`; `/admin`, `/t/csk/my-reservations` and `/t/csk/my-events` redirected to `/login` and ended at 200. `/t/not-real/booking` returned 404. This tests baseline availability and anonymous authorization only, **not** authenticated staff/owner workflow or a Phase 1 deployment (which has not occurred).

### 8. Final production preflight verdict

No blocker was found in migration history, input fingerprints, production tenant integrity, working-tree scope or dry-run. The dry-run is **not** production write authorization. The next step requires a separate explicit decision for DB push and, only after DB post-deploy PASS, app deployment approval.

SAAS-9E-C PHASE 1 PRODUCTION PREFLIGHT: **PASS**

WORKING TREE SCOPE: **PASS — 42 Phase 1 paths, AGENTS.md and draft excluded**

MIGRATION SHA: **PASS — AD94B30D5F7B825409E544F996F364C8843C581B45FBB46CBBB674DA679EC926**

LOCAL HISTORY RECONCILED: **PASS — 102/102, no ghost migration**

MIGRATION HISTORY: **PASS — 101 matched, one pending, zero remote-only/malformed**

UNIQUE RPC CONTRACTS: **18**

DIRECT UI CALL SITES: **24**

SERVER LEGACY CALLERS: **1**

TOTAL RUNTIME CALL SITES: **25**

TENANT-SCOPED MY RESERVATIONS: **PASS**

TENANT-SCOPED MY EVENTS: **PASS**

DB-LEVEL PAGINATION: **PASS**

APP-SIDE TENANT FILTERING: **ABSENT**

TRUSTED TENANT CONTEXT: **PASS**

RESOURCE-BOUND TENANT CHECK: **PASS**

CROSS-TENANT OWNER ISOLATION: **PASS — local rollback-only matrix**

CROSS-TENANT PII: **PASS — local owner DTO/matrix; no production second tenant**

ACTIVE LEGACY CALL SITES AFTER PHASE 1: **20**

BRIDGE DEFINITIONS: **22**

SECURITY DEFINER COUNT AFTER PHASE 1: **76 local target; production currently 70**

FULL 9E-C TARGET SECURITY DEFINER: **88**

COMPATIBILITY DEFAULTS: **7/7**

4D-2 ZERO-CALLER GATE: **NOT MET**

4D-2: **NO-GO**

DEPLOYMENT ORDER: **DB FIRST, then APP after post-DB gate**

DRY-RUN: **PASS — only 20260926100000, no push**

READY FOR PHASE 1 PRODUCTION DEPLOYMENT: **YES — separate explicit approval required**

READY FOR PHASE 2: **NO-GO until Phase 1 production PASS/checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**
