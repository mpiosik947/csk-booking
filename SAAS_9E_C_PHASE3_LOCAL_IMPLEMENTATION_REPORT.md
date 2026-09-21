# SAAS-9E-C Phase 3 / C3 — local implementation report

Date: 2026-09-20. Base `main` HEAD: `634ca40c8684292681e83855b87f4a09a3fc3dce`. Scope: **local C3-A/B/C only**. No production preflight, production SQL, deployment, Git staging, commit, or push was performed. `AGENTS.md` and `supabase/drafts/*` remain unrelated and excluded.

## C3-A — forward-only DB contracts

Canonical migration: `supabase/migrations/20260928100000_add_c3_owner_calendar_and_global_profile_contracts.sql`; SHA-256 `012A0472EA74CF17FD912C37B78A63B3BA68DF50144A46B35A0EAD5C2CAD6D0D`. Historical migrations were not modified. The migration adds exactly two functions:

| Function/signature | Security | Owner / search_path | EXECUTE | Normalized local definition MD5 | Contract |
|---|---|---|---|---|---|
| `get_my_reservation_calendar_v1(uuid)` | `SECURITY DEFINER`, `STABLE` | `postgres`; `pg_catalog, public, pg_temp` | `authenticated` only (plus owner) | `daafbde3d6a6edef3678e3aeb746e652` | `auth.uid()` owner and active membership; tenant from persisted reservation; eight-field minimal ICS DTO; no arbitrary tenant/user parameter or bridge |
| `update_my_profile_v2(text×6, boolean×10)` | `SECURITY DEFINER`, `VOLATILE` | `postgres`; `pg_catalog, public, pg_temp` | `authenticated` only (plus owner) | `6b740226c6de401754dfb9da2fd543f7` | target strictly `auth.uid()`; exactly 16 allowed global contact/self-declaration inputs; tenant verification invalidated per related tenant when declarations change; tenant-bound audit; five-field global result |

`PUBLIC`, `anon` and `service_role` have no direct EXECUTE grant on either function. The ICS contract does not expose customer name, email, phone, token, admin note, or another user's reservation. The profile contract accepts no target `user_id`/`tenant_id` or privilege-bearing fields; owner-writable privilege fields remain **0**. Neither function calls the active-single-tenant bridge. Existing DB grants, RLS, legacy function signatures and seven CSK compatibility defaults were not changed. Local catalog: **94 → 96** public SECURITY DEFINER functions, **2 expected new**, **0 unexpected**, **22** stored bridge definitions and **7/7** defaults.

## C3-B — app caller and route cutover

The frozen L01–L18 matrix in `SAAS_9E_C_PHASE3_LEGACY_CALLER_RETIREMENT_PLAN.md` is the per-call-site inventory. Its categories now close as follows:

| Category | Before → after | Target |
|---|---:|---|
| L01–L12 staff old RPC arms | 12 → 0 | Tenant-scoped Events, Lane Configuration, Reports and Users RPCs; old supported `/admin/*` URLs hand off to same `/t/csk/admin/*` suffix only after Auth, active CSK lookup and membership role check |
| L13–L15 public bridge calls | 3 → 0 | `/booking` and `/events` explicit `/t/csk/*` compatibility redirects; tenant-scoped public booking/event readers and verification |
| L16–L17 owner readers | 2 → 0 | Tenant-specific `/my-reservations` and `/my-events` aliases; v3/v2 owner contracts with explicit server-validated tenant context |
| L18 reservation ICS | 1 → 0 | `get_my_reservation_calendar_v1(reservation_id)`; resource-derived tenant and owner check |
| Supplemental `get_my_role()` app/API call sites | 8 → 0 | Global home removes role grant; staff pages/API use active tenant membership; calendar preview retains instructor-safe role mapping |
| `is_admin()`, `is_admin_or_employee()`, `is_admin_or_staff()` direct app/API call sites | 0 → 0 each | Definitions untouched for separate 4D-2 catalog review |

Repo-wide runtime source scan of `app`, `lib` and `middleware.ts` (`*.ts`, `*.tsx`, `*.js`) found no active `get_my_role`, old bridge/owner RPC call, `active_single_tenant_id_v1`, or direct global `profiles.role` authority. The mechanical C3 test also asserts absence from the former call sites. This is an **app/API caller** count, not a stored-function definition count; the latter stays **22**.

The five previously placeholder tenant-admin destinations now render their existing operational modules under validated slug, Auth and membership. Their reads and actions are:

| Canonical route | Feature parity / reads / writes | PII and authorization | Legacy calls / ready |
|---|---|---|---|
| `/t/[slug]/admin` | Dashboard, queues, current and monthly reservations, event indicators; direct operational reads filter persisted `tenant_id` | T+M role; instructor cannot read customer operations | 0 / YES |
| `/t/[slug]/admin/reservations` | Existing filters, export, payment, attendance and cancellation; reservation/lane reads filter tenant | T+M and existing controlled RPCs; no foreign reservation list | 0 / YES |
| `/t/[slug]/admin/calendar` | Day/week/month, preview, filters; server calendar feed requires validated slug and filters lanes/reservations/blocks/events to tenant | Separate API Auth+membership; instructor preview keeps restricted fields; no service role | 0 / YES |
| `/t/[slug]/admin/check-in` | Day queue, token lookup, payment, attendance, verification and cancellation | T+M; token lookup additionally verifies persisted reservation tenant before display | 0 / YES |
| `/t/[slug]/admin/lane-blocks` | List/create/activate/deactivate with lane/block reads filtered to tenant | T+M; writes use existing resource-bound controlled RPCs | 0 / YES |

Legacy `/admin/*` mapping is explicitly fixed to slug `csk`, not inferred from the active-tenant count. Unknown admin paths return 404. Safe known query fields are preserved; tokens and arbitrary query keys are not copied. Canonical `/t/[slug]` routes revalidate active tenant and membership server-side. `/account` remains global/account-wide and now calls `update_my_profile_v2`; `/dashboard` is a global location landing with explicit CSK links, not a role grant. `/api/send-reservation-cancellation` derives staff role from the reservation's persisted tenant. The event-registration ICS response checks registration/event tenant consistency and no longer hardcodes a CSK location label.

## C3-C — local evidence and limitations

- Clean local Supabase replay on **127.0.0.1:54322**: complete canonical chain, including C3 migration, PASS. No `--linked` or production access.
- Focused C3 SQL: **16/16 PASS** (owner/foreign/anonymous/missing reservation, minimal DTO, profile owner-only allow-list, verification invalidation/audit, ACL, fingerprints, function/default inventory). Full DB: **51 files, 1543/1543 PASS**. The broader DB suite supplies tenant RLS/IDOR, membership-status and resource-integrity regression coverage.
- Node: **777/777 PASS**. Focused C3 source tests: **4/4 PASS**. TypeScript: PASS. Production build: PASS (existing Next middleware→proxy deprecation warning). Changed-file ESLint: **0 errors, 3 existing hook dependency warnings**. `git diff --check`: PASS.
- Full local Playwright after clean DB replay: **38/38 PASS**, including five tenant-admin modules, explicit public/owner routes, legacy CSK handoff, admin queues, event/report mobile screens, booking, account and invalid/inactive tenant slugs. No production browser test was run.
- Final local DB replay after E2E removed test-created lane families. Follow-up full DB suite PASS. Read-only final counts: `auth_test_users=0`, `test_profiles=0`, `test_lanes=0`, `test_events=0`. Fixture cleanup: PASS.
- `npm audit --omit=dev` reported **one moderate** advisory in transitive `baseline-browser-mapping@2.10.30` via `next@16.3.4` ([GHSA-w5vr-8v7q-w6rv](https://github.com/advisories/GHSA-w5vr-8v7q-w6rv)). It was not modified because dependency remediation is outside C3. This is not a C3-introduced package change.
- Production catalog, real deployment, production second-tenant behavior and production cross-tenant UI were **not** tested. The second active tenant remains technically blocked. Production preflight requires a separate authorization and fresh project/migration/fingerprint/integrity gates.

Compatibility/rollout: CURRENT APP + CURRENT DB = existing Phase 2 production baseline; CURRENT APP + NEW C3 DB = additive-contract compatible (legacy functions untouched; no separate old-app local runtime run); NEW C3 APP + CURRENT DB = **UNSAFE** (two required RPCs absent); NEW C3 APP + NEW C3 DB = local PASS. Therefore deployment recommendation is **DB FIRST**, subject to separate production preflight, DB deploy verification and app deployment approval. A DB rollback after use would require a separately reviewed forward corrective migration, not migration repair.

Working-tree classification: C3 migration; C3 SQL regression inventory tests; app/API caller retirement; five tenant-admin surfaces; routing compatibility; ICS; global Account; Node/Playwright tests; this plan/report. The pre-existing `AGENTS.md` and `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md` modifications are unrelated and untouched by C3. `supabase/drafts/*` is non-deployable and excluded. No unexpected C3 semantic diff was identified; CR-at-EOL warnings are environmental and `git diff --check` passed. No Git write was performed.

## Final local verdicts

| Gate | Result |
|---|---|
| SAAS-9E-C PHASE 3 LOCAL | **PASS** (with separate moderate dependency advisory noted above) |
| C3 DB CONTRACTS / ICS CONTRACT / GLOBAL PROFILE CONTRACT | **PASS / PASS / PASS** |
| SECURITY DEFINER BEFORE / NEW / AFTER / UNEXPECTED | **94 / 2 / 96 / 0** |
| LEGACY OPERATIONAL CALLERS BEFORE / AFTER | **18 / 0** |
| GET_MY_ROLE BEFORE / AFTER | **8 / 0** |
| FIVE TENANT-ADMIN SCREENS | **PASS** |
| OLD ADMIN COMPATIBILITY / PUBLIC ROUTES / OWNER ROUTES | **PASS / PASS / PASS** |
| ACCOUNT / DASHBOARD / ICS | **PASS / PASS / PASS** |
| CROSS-TENANT PII / GLOBAL ROLE AUTHORITY | **PASS in local DB/security matrix / ABSENT in active app authority** |
| BRIDGE DEFINITIONS / COMPATIBILITY DEFAULTS | **22 / 7/7** |
| CLEAN MIGRATION REPLAY / FULL DB / NODE / PLAYWRIGHT | **PASS / 1543/1543 PASS / 777/777 PASS / 38/38 PASS** |
| FIXTURE CLEANUP | **PASS** |
| 4D-2 ELIGIBLE FOR REVIEW | **YES, only as a separate review; no automatic implementation authority** |
| 4D-2 / 9D-5 / SECOND TENANT | **NO-GO / NO-GO / NO-GO** |
| SEC-004 | **OPEN** |
| READY FOR C3 PRODUCTION PREFLIGHT | **GO**, subject to separate approval and fresh live gates |
| PRODUCTION WRITE / GIT WRITE | **NO / NO** |

Stop after local verification. Do not begin production preflight automatically.

## PRODUCTION PREFLIGHT & DEPLOYMENT READINESS (read-only, 2026-09-20)

This section records the separately authorized production preflight. It does **not** authorize or record a production `db push`, application deployment, or Git write. The project link is `yuyxfodozzpzrdzkmolu`; the Supabase SQL Editor visibly identified the project as `csk-booking`. Production SQL used only `SELECT`. The first aggregate query failed parsing before execution; subsequent corrected queries were read-only. No production data was modified.

### Migration and catalog gates

| Gate | Evidence / result |
|---|---|
| Canonical file | `supabase/migrations/20260928100000_add_c3_owner_calendar_and_global_profile_contracts.sql`; SHA-256 `012A0472EA74CF17FD912C37B78A63B3BA68DF50144A46B35A0EAD5C2CAD6D0D` |
| Function scope | Exactly two `CREATE FUNCTION` statements, no private/internal helper, no `CREATE OR REPLACE`, no historical migration edit |
| Local history | `supabase migration list --local`: 107/107 filesystem/local versions through `20260928100000`; ghost 0; filesystem-only 0 |
| Linked production history | 106/106 earlier local/remote matches through `20260927130000`; only local-only version `20260928100000`; remote-only 0; mismatch 0 |
| Linked dry-run | `supabase db push --linked --dry-run` exited 0 and listed **only** `20260928100000_add_c3_owner_calendar_and_global_profile_contracts.sql` |
| Production baseline | public SECURITY DEFINER **94**; stored bridge definitions **22**; temporary CSK defaults **7/7**; active tenants **1**, active CSK **1**; both C3 functions absent before deployment |
| Projected catalog | exactly +2 expected SECURITY DEFINER, projected **96**; unexpected/unknown additions **0** |

The two target signatures are `get_my_reservation_calendar_v1(uuid)` (`STABLE`) and `update_my_profile_v2(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)` (`VOLATILE`). Both are `SECURITY DEFINER`, owner `postgres`, fixed `search_path = pg_catalog, public, pg_temp`, with explicit `REVOKE ALL` from `PUBLIC`, `anon`, `authenticated`, and `service_role`, then `GRANT EXECUTE` to `authenticated` only. No dynamic SQL or caller-selected tenant/user authority occurs. Local normalized definition MD5s are respectively `daafbde3d6a6edef3678e3aeb746e652` and `6b740226c6de401754dfb9da2fd543f7`. These are **local target fingerprints**, not claims that target functions exist in production yet.

Three pre-existing input dependencies were compared by the same `pg_get_functiondef` → CRLF/CR-to-LF → MD5 algorithm in local and production catalogs: `get_my_reservations_v2()` = `f94e8447a935cf184ce3b242598f01a5`, `is_tenant_member_v1(uuid)` = `d6874f126835fb83fe452d1ff7bfba89`, and `update_my_profile_v1(text×6,boolean×10)` = `eed0787e7c5a67e537b5703289abf536`; **3/3 match**. Production metadata for each is SECURITY DEFINER, owner `postgres`, `search_path=pg_catalog, public, pg_temp`, and `postgres`/`authenticated` EXECUTE only. The initial fingerprint query used an incorrectly typed v1 signature and failed without mutation; the corrected name-based query returned the three actual signatures. This establishes no drift in these C3 input contracts, not a claim that every unrelated production function was fingerprinted.

The ICS DEFINER is justified by the owner-checked, resource-derived exact-ID read joining tenant identity and historical lane/parent labels: production `authenticated` has reservation/lane SELECT subject to RLS but **no direct `tenants` SELECT**. An INVOKER cannot preserve this frozen minimal DTO and public tenant name through current grants. The function itself checks `auth.uid()`, `r.user_id`, active tenant membership, and the persisted reservation's `tenant_id`, returning eight fields only. It does not use the active-single-tenant bridge or `get_my_role()`. Risk is privileged read under a DEFINER, bounded by exact resource ownership, active membership, same-tenant joins, minimal ACL/DTO, and the tested foreign/not-found behavior.

The global profile DEFINER is justified by production `authenticated` having **no direct `profiles` UPDATE grant** and by the required controlled owner update plus per-tenant verification invalidation/audit. The only target is `auth.uid()`; it accepts six contact text fields and ten declaration booleans, no `user_id` or `tenant_id`. It cannot accept or write `role`, membership role/status, admin note, tenant verification authority/status, privilege flags or system-managed fields. Response is only `ok`, `changed`, stable code, `declarations_changed`, and `updated_at`; it has no tenant-specific data. The function may invalidate each *existing related* tenant verification as an account-wide declaration side effect, but its response and authority do not depend on CSK, active tenant, role bridge, or verification result. Owner-writable privilege fields: **0**. Production `profiles` schema includes the expected global contact/declaration columns and keeps legacy/system/verification columns separate. Risk is controlled global profile write under a DEFINER, bounded by `auth.uid()`, fixed allow-list, row/advisory locks, tenant-bound audit, and authenticated-only ACL.

### Production integrity and current runtime

Read-only production aggregate checks returned: reservations 11; `reservation_null_tenant=0`, `reservation_missing_owner=0`, `reservation_missing_or_cross_tenant_lane=0`, `reservation_missing_tenant=0`, `reservation_owner_profile_missing=0`; duplicate profile users 0; profile-to-Auth orphans 0; membership-to-profile orphans 0; unknown membership role/status 0; lane-parent, lane-block, event-lane, and event-registration tenant mismatches **0**. `reservations`, `profiles`, and `tenant_memberships` have RLS enabled. Production `authenticated` has no direct `tenants` SELECT or `profiles` UPDATE. These are the relevant C3 input checks, not a full production security audit.

Unauthenticated, non-mutating HTTP smoke of the **current Phase 2 app**: `/`, `/booking`, `/events`, `/my-reservations`, `/my-events`, `/account`, `/dashboard` each returned HTTP 200; `/admin`, `/admin/reservations`, `/admin/calendar`, `/admin/check-in`, `/admin/lane-blocks` and the five `/t/csk/admin...` counterparts each returned controlled HTTP 307. **No 5xx**. This does not prove authenticated feature parity or C3 app behavior in production; neither new C3 app nor DB is deployed.

### Source cutover, URLs and working tree

Fresh runtime scan of `app`, `lib`, and `middleware.ts`, excluding tests, found **0** direct old operational RPC sites (frozen L01–L18 categories: 12 staff + 3 public + 2 owner + 1 ICS, all removed), **0** active `get_my_role()` sites (former eight: home, admin dashboard, admin calendar, calendar feed API, admin Events, lane configuration, Reports, Users), and **0** direct app/API callers each of `is_admin()`, `is_admin_or_employee()`, `is_admin_or_staff()`. Stored definitions are intentionally unchanged; the latter helpers and DB dependencies still require separate 4D-2 review. No `profiles.role` is used as an active app/API staff authority. The five canonical tenant-admin screens—root, Reservations, Calendar, Check-in, Lane Blocks—are locally functional, server-validated by slug and active membership, with resource-tenant guards and no old bridge calls; see the C3-B table above for read/write/PII scope. Their **production** behavior remains untested until app cutover.

Old supported `/admin/*` paths are explicit CSK compatibility aliases, not an active-tenant-count resolver; unknown paths fail closed. `/booking` and `/events` explicitly hand off to `/t/csk/...`; `/my-reservations` and `/my-events` are tenant-scoped via validated slug and v3/v2 owner readers, not global mixed lists. `/account` is global and uses `update_my_profile_v2`; `/dashboard` remains a global landing with explicit location navigation. Reservation ICS uses authenticated request → reservation ID → new exact-ID RPC → persisted reservation/tenant and owner check → minimal DTO → no-store ICS. It passes no caller tenant authority. Event ICS additionally compares registration/event tenant. Local route and role tests passed; current production aliases are Phase 2 baseline only.

Working-tree reconciliation used raw `git status --short`, `git diff --name-only`, `git diff --stat`, untracked listing, and a semantic `git diff --ignore-cr-at-eol --check` (PASS). **88 real changed/untracked paths** were classified: A canonical C3 migration 1; B C3-focused and affected SQL inventory/regression tests 25; C runtime caller retirement 4 (admin lane configuration/Reports/Users and cancellation API); D five admin surfaces/calendar feed 7; E routing compatibility 4; F ICS 2; G Account/Dashboard/home 3; H public/owner routes plus admin Events cutover 6; I Node/Playwright/source tests 31; J C3 plan/report 2; K unrelated existing SAAS-9D plan 1; L existing `AGENTS.md` 1; M non-deployable draft 1; N unexpected 0. This accounts for all 88 paths. The raw diff includes CRLF warnings, but no non-CRLF unexpected path. `AGENTS.md`, the unrelated SAAS-9D plan, and `supabase/drafts/*` remain excluded and unmodified by this preflight. No staging occurred.

### Compatibility, rollout and future rollback-only test matrix

| Combination | Decision | Basis |
|---|---|---|
| Current Phase 2 app + current production DB | PASS | Existing production baseline and read-only smoke |
| Current Phase 2 app + new C3 DB | PASS by additive contract; live run pending | Migration only adds two versioned functions, preserves legacy callers/signatures/grants/defaults; verify again immediately after any future DB push |
| New C3 app + current DB | **UNSAFE** | Account and reservation ICS call absent v2/ICS RPCs |
| New C3 app + new C3 DB | Local PASS; production pending | Clean replay, 1543/1543 DB, 777/777 Node, 38/38 Playwright |

Deployment order is **DB FIRST**: (1) separately authorized C3 migration push, (2) post-DB catalog/ACL/rollback-only checks and old-app compatibility smoke, (3) separately authorized C3 app cutover, (4) production caller recount and authenticated route smoke, (5) separately approved reproducible Git checkpoint. Execute none of these steps in this preflight. If a later DB deployment must be reversed after use, use a reviewed forward corrective migration rather than history repair. The additive DB permits reverting an app release to the previous compatible app, subject to its security review.

Future **post-DB** rollback-only matrix, not executed here: wrap `BEGIN ... ROLLBACK`; create only named synthetic owner/foreign identities and tenant-bound resources inside the transaction. ICS: owner allow, foreign/anonymous deny, nonexistent ID empty/deny, tenant from stored reservation, minimal fields, no cross-tenant PII. Profile: owner allowed-field mutation, foreign mutation impossible, role/verification/admin-note/membership mutation impossible, tenant-free response, declaration-change per-tenant invalidation/audit. After rollback, count each synthetic fixture by run marker and require zero persisted rows. Never use real customer records for mutation.

Local evidence reconfirmed from the completed C3 run: focused SQL **16/16**, full DB **1543/1543**, Node **777/777**, Playwright **38/38**, TypeScript/build PASS, changed-file ESLint **0 errors** (3 hook warnings), clean replay PASS, fixture cleanup 0, diff check PASS. Tests were not rerun against production. The unrelated moderate `npm audit --omit=dev` advisory remains as described above; no package changes were made.

### Preflight verdicts

| Required verdict | Result |
|---|---|
| SAAS-9E-C PHASE 3 PRODUCTION PREFLIGHT | **PASS**, limited to read-only gates above |
| WORKING TREE SCOPE / LOCAL MIGRATION HISTORY / PRODUCTION MIGRATION HISTORY | **PASS / PASS / PASS** |
| C3 DRY-RUN / C3 PENDING MIGRATIONS / DRY-RUN EXACTLY ONE C3 | **PASS / 1 / YES** |
| ICS CONTRACT / GLOBAL PROFILE CONTRACT / OWNER-WRITABLE PRIVILEGE FIELDS | **PASS / PASS / 0** |
| SECURITY DEFINER BEFORE / NEW / PROJECTED / UNEXPECTED | **94 / 2 / 96 / 0** |
| LEGACY OPERATIONAL CALLERS / GET_MY_ROLE ACTIVE CALLERS | **0 / 0** |
| FIVE TENANT-ADMIN SCREENS / OLD ADMIN COMPATIBILITY | **PASS locally / PASS locally** |
| PUBLIC ROUTES / OWNER ROUTES / ACCOUNT / DASHBOARD / ICS APP FLOW | **PASS locally** |
| CROSS-TENANT PII DESIGN / GLOBAL ROLE AUTHORITY | **PASS locally / ABSENT in active app authority** |
| BRIDGE DEFINITIONS / COMPATIBILITY DEFAULTS | **22 / 7/7** |
| DEPLOYMENT ORDER | **DB FIRST → DB verification → app cutover → caller recount → checkpoint** |
| CURRENT APP + NEW C3 DB / NEW C3 APP + CURRENT DB | **PASS by additive compatibility / UNSAFE** |
| READY FOR C3 DB PRODUCTION DEPLOYMENT | **YES, pending separate explicit authorization and repeat final gate at deployment time** |
| READY FOR C3 APP DEPLOYMENT | **NO-GO until DB production PASS** |
| 4D-2 / 9D-5 / SECOND TENANT / SEC-004 | **NO-GO / NO-GO / NO-GO / OPEN** |
| PRODUCTION WRITE / GIT WRITE | **NO / NO** |

STOP before production push, app deployment, staging, commit, or Git push.

## C3 DB PRODUCTION DEPLOYMENT (2026-09-20)

This section supersedes the *pre-deployment state* above; the preflight remains as historical evidence. The user authorized **only** the C3 database migration and rollback-only verification. No C3 application deployment, Git write, migration repair, bridge/default removal, 4D-2, or 9D-5 was performed. Production project: `csk-booking`, ref `yuyxfodozzpzrdzkmolu`.

### Final gate and deployment

Immediately before the push, the linked project identity was verified; local and remote migration history matched for all 106 previous versions through `20260927130000`, with no remote-only or mismatched version. The only pending file was `supabase/migrations/20260928100000_add_c3_owner_calendar_and_global_profile_contracts.sql`. Its SHA-256 was `012A0472EA74CF17FD912C37B78A63B3BA68DF50144A46B35A0EAD5C2CAD6D0D`, and the linked dry-run listed exactly that file. Production baseline was 94 SECURITY DEFINER functions, 22 bridge definitions, seven compatibility defaults, one active tenant (CSK), no C3 functions, and no C3 input-integrity anomaly. The three normalized dependency fingerprints listed in the preflight matched production 3/3. `AGENTS.md` remained unrelated and excluded.

The authorized `supabase db push --linked` exited 0 and reported application of **only** `20260928100000_add_c3_owner_calendar_and_global_profile_contracts.sql`. Post-deploy migration history matched **107/107** including C3, with pending 0, remote-only 0 and mismatch 0. Final linked `db push --dry-run` returned `Remote database is up to date`. No migration repair was used.

### Function, ACL and inventory verification

Normalized definition fingerprint algorithm: `pg_get_functiondef` with CRLF→LF and CR→LF, then MD5. Production target definitions matched the local preflight values **2/2**:

| Contract / exact signature | Mode and volatility | Owner / search_path | EXECUTE ACL | Normalized MD5 |
|---|---|---|---|---|
| `get_my_reservation_calendar_v1(uuid)` | SECURITY DEFINER / STABLE | `postgres` / `pg_catalog, public, pg_temp` | `postgres`, `authenticated`; no `PUBLIC`, `anon`, or direct `service_role` grant | `daafbde3d6a6edef3678e3aeb746e652` |
| `update_my_profile_v2(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)` | SECURITY DEFINER / VOLATILE | `postgres` / `pg_catalog, public, pg_temp` | `postgres`, `authenticated`; no `PUBLIC`, `anon`, or direct `service_role` grant | `6b740226c6de401754dfb9da2fd543f7` |

Production public SECURITY DEFINER count is **96** (94+2); unexpected C3 function/definer drift **0**. Bridge definitions remain **22** and temporary compatibility defaults **7/7**. The functions have no caller-selected tenant or user authority, no dynamic SQL, and use `auth.uid()`/persisted resource ownership as defined in the migration. The profile function exposes no privilege-field parameters or write path; owner-writable privilege fields **0**.

### Rollback-only production matrix

The focused C3 SQL matrix ran in the production SQL Editor with `BEGIN` and final `ROLLBACK`, using only synthetic `example.invalid` identities and `[TEST][C3A]`-marked resources. SQL Editor-only adaptation omitted psql `\\set`/`\\pset` directives. An initial attempt had a mistyped test-side v2 ACL signature and stopped on check 3 **before fixture insertion**; an explicit `ROLLBACK` followed and read-only residue counts were 0. The corrected editor text matched the actual 10-boolean signature; no migration or stored test file was changed. The final run returned **16/16 `ok` rows**, and its assertion required exactly 16 passing checks before the ending `ROLLBACK`.

- ICS checks: exact owner/resource-derived reservation and tenant, historical inactive-lane label, foreign and anonymous no-row, nonexistent ID same no-row, and precisely eight approved DTO fields with no customer/contact/token/admin-note fields. This establishes the current single-active-tenant owner boundary; it does **not** claim a production test with a second active tenant.
- Global profile checks: owner can change only permitted contact/declarations; response has five global fields and no tenant/role/verification/member/user identifier; role/email/admin note and the foreign profile remain unchanged; declaration change invalidates the related tenant verification with tenant-bound audit; repeat no-change adds no audit; the RPC has no arbitrary user/privilege arguments. This does not test an intentionally forbidden direct profile update or claim account-wide UI cutover is live.

Read-only post-rollback counts: synthetic Auth users **0**, profiles **0**, lanes **0**, pricing rules **0**, reservations **0**, audit fixtures **0**; active tenants remained **1** and SECURITY DEFINER count **96**. Thus fixture cleanup and persisted test data are **0**. Neither the active CSK tenant nor real customer records were mutated by a committed transaction.

### Production integrity and current-app compatibility

Post-deploy read-only counts: reservation null tenant **0**, missing owner **0**, lane/tenant mismatch **0**, membership/profile orphan **0**, profile/Auth orphan **0**, duplicate profile user **0**; active tenants **1** and active CSK **1**. The migration added functions only; it changed no business table schema/data. The rollback matrix found no cross-user PII in the ICS DTO or global profile response; broader cross-tenant production runtime cannot be demonstrated while the second active tenant is blocked.

Unauthenticated HTTP smoke of the **current Phase 2 application against the new C3 DB** returned 200 for `/`, `/booking`, `/events`, `/login`, `/account`, `/dashboard`, `/my-reservations`, `/my-events`, and `/t/csk/booking`. `/admin`, `/admin/reservations`, `/admin/calendar`, `/admin/reports`, `/admin/events`, `/admin/check-in`, plus `/t/csk/admin` and its Reservations/Calendar/Check-in/Lane-Blocks/Events/Users routes returned controlled 307 rather than 5xx. This verifies availability and unauthenticated protection, **not** authenticated workflow parity or the future C3 application. Current production app remains Phase 2; local C3 target source has old operational callers **18→0** and active `get_my_role()` sites **8→0**, but that source has **not** been deployed.

No app deployment or Git write occurred. `git diff --check`: PASS. Existing `AGENTS.md`, unrelated SAAS-9D plan changes, and `supabase/drafts/*` remain excluded. C3 app cutover requires a **separate approval and deployment verification**; NEW C3 APP + OLD DB is unsafe.

### C3 DB deployment verdicts

| Required verdict | Result |
|---|---|
| SAAS-9E-C C3 DB DEPLOY / C3 MIGRATION ONLY | **PASS / PASS** |
| MIGRATION HISTORY / PENDING MIGRATIONS | **PASS / 0** |
| ICS DB CONTRACT / GLOBAL PROFILE DB CONTRACT | **PASS / PASS** |
| ROLLBACK-ONLY ICS / ROLLBACK-ONLY PROFILE | **PASS / PASS** (focused matrix 16/16, transaction rolled back) |
| CROSS-TENANT PII | **PASS for tested owner/foreign-user and minimal-DTO boundary**; no second-active-tenant production scenario |
| OWNER-WRITABLE PRIVILEGE FIELDS | **0** |
| SECURITY DEFINER / UNEXPECTED DEFINER | **96 / 0** |
| BRIDGE DEFINITIONS / COMPATIBILITY DEFAULTS | **22 / 7/7** |
| FIXTURE CLEANUP | **PASS, 0 persisted synthetic fixture** |
| CURRENT APP + NEW C3 DB | **PASS for observed non-mutating route smoke; authenticated flows not exercised** |
| READY FOR C3 APP CUTOVER | **YES for separately authorized deployment, subject to app deployment and authenticated production verification** |
| READY FOR 4D-2 / READY FOR 9D-5 / SECOND TENANT | **NO-GO / NO-GO / NO-GO** |
| SEC-004 | **OPEN** |

STOP before C3 app deployment, staging, commit, or Git push.

## C3 APPLICATION PRODUCTION CUTOVER (2026-09-21)

The local deployment gate was repeated immediately before staging: clean migration replay PASS; full DB **1543/1543**; Node **777/777**; TypeScript PASS; production build PASS; changed-file ESLint **0 errors / 3 existing hook warnings**; full Playwright **38/38**; `git diff --cached --check` PASS; post-E2E local reset/replay PASS; final DB suite **1543/1543**; local fixture counts 0. Runtime source inventory returned legacy operational RPC callers **0**, `get_my_role()` callers **0**, and direct `is_admin*` runtime helper callers **0**.

An explicit 56-file runtime/application/test scope was staged. The C3 migration, SQL tests, plans/reports, `AGENTS.md`, unrelated SAAS-9D plan and `supabase/drafts/*` were excluded. Commit `b3a85bba9797f4ea056fbd41d6b3e990af59b2cc` (`SAAS-9E-C Phase 3 retire legacy application callers`) was pushed by ordinary fast-forward from `634ca40` to `origin/main`. Post-push local and remote HEAD matched exactly and divergence was `0/0`.

Authenticated production evidence after the Vercel main-branch deployment:

- `/dashboard` rendered the global account landing and the explicit CSK location selector.
- `/t/csk/admin`, Reservations, Calendar, Check-in and Lane Blocks rendered their tenant-scoped operational headings for the authenticated admin. Tenant Events, Reports, Users and Lane Configuration were also reached successfully.
- Every tested legacy route (`/admin`, Reservations, Calendar, Check-in, Lane Blocks, Events, Reports, Users, Lane Configuration) redirected deterministically to its `/t/csk/admin...` counterpart and rendered the expected module.
- `/booking` → `/t/csk/booking`; `/events` → `/t/csk/events`; `/my-reservations` → `/t/csk/my-reservations`; `/my-events` → `/t/csk/my-events`. `/account` remained global.
- No tested screen exposed an application error or 5xx. The account had no active reservation, therefore an owner ICS download was **not performed**; the DB contract, local route suite and production C3 rollback matrix remain the evidence for that path. No production mutating E2E or second-active-tenant UI test was performed.

The production-visible route shape and dashboard selector are unique to the C3 target and establish that the new application is live against the already deployed C3 DB. Production source at the matching Git commit has legacy operational callers **0** and `get_my_role()` runtime callers **0**. This closes the application cutover portion; final DB/report/test reproducibility artifacts are committed separately in the C3 final checkpoint.

### Application cutover verdict

| Gate | Result |
|---|---|
| C3 APP DEPLOY | **PASS** (`b3a85bba9797f4ea056fbd41d6b3e990af59b2cc`) |
| NEW C3 APP + NEW C3 DB | **PASS** |
| AUTHENTICATED NON-DESTRUCTIVE E2E | **PASS for listed customer/admin screens** |
| PRODUCTION MUTATING E2E | **NOT PERFORMED** |
| PRODUCTION OWNER ICS DOWNLOAD | **NOT PERFORMED — no active reservation fixture** |
| LEGACY OPERATIONAL / GET_MY_ROLE CALLERS | **0 / 0 at deployed source** |
| TWO ACTIVE PRODUCTION TENANT UI | **NOT PERFORMED / NO-GO** |
| READY FOR FINAL C3 CHECKPOINT | **YES** |
