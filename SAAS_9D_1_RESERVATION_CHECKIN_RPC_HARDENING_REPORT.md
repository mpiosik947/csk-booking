# SAAS-9D-1 — Reservation / Check-in RPC Tenant Hardening

Local implementation report. Date: 2026-09-11 (Europe/Warsaw). Repository baseline: `02af6857a88e37d30b6e4b1159496cecff91bac1` on `main`.

## 1. Executive summary

SAAS-9D-1 is implemented and verified locally. Reservation creation, cancellation, staff operations, check-in, owner reservation reads, reservation-scoped profile reads and lane busy-range readers now authorize against the tenant derived from the trusted resource. A global `profiles.role` is no longer sufficient for these active definer paths.

No application caller, API signature, UI, production database or remote environment was changed. No commit, push or staging operation was performed.

## 2. Functions in scope

| Function | Current caller | Tenant source | Target authorization |
|---|---|---|---|
| `create_reservation_v2(uuid,date,time,integer,integer,uuid,text)` | booking API | `shooting_lanes.tenant_id` | active tenant `user` membership |
| `cancel_reservation(uuid)` | owner/admin reservation flows | `reservations.tenant_id` | owner with active membership, or tenant admin/employee |
| `update_reservation_admin_note(uuid,text)` | admin reservations | reservation | tenant admin/employee |
| `update_reservation_attendance(uuid,text)` | admin reservations/check-in | reservation | tenant admin/employee |
| `update_reservation_payment(uuid,text)` | admin reservations | reservation | tenant admin/employee |
| `get_check_in_reservation_v1(uuid)` | admin check-in | token → reservation | tenant admin/employee |
| `get_public_check_in_status_v1(uuid)` | public check-in | token → reservation | only active-tenant neutral DTO |
| `get_my_reservations_v2()` | my reservations | caller-owned rows | active membership and active tenant per row |
| `get_reservation_customer_profiles_v1(uuid[])` | admin reservations/check-in | exact reservation batch | one tenant, tenant admin/employee |
| busy ranges V1/V2/V3 | booking/legacy callers | lane | active tenant membership |

The legacy `create_reservation(...)` definition was not rewritten; all PUBLIC/anon/authenticated/service_role EXECUTE access was removed.

## 3. Pre-change fingerprints

| Signature | MD5 |
|---|---|
| `cancel_reservation(uuid)` | `c968aee936a8ccca3db268c3eac7b342` |
| `create_reservation_v2(...)` | `3f201f96dc413736d564089536b98d7d` |
| `get_check_in_reservation_v1(uuid)` | `d0c3aa17b9104dd7d7ad70c5abdcb214` |
| busy V1 | `2bab8b9ba5086ed74931d2f434a3819a` |
| busy V2 | `40f0914451c01c4d1f34bf61b72d1afe` |
| busy V3 | `3ac61a3195e4f40393c9d38a86367a91` |
| `get_my_reservations_v2()` | `0492a134c20ade26a55b08f28fcb4364` |
| `get_public_check_in_status_v1(uuid)` | `ea4a14a4e8e7d3c6d36d4c9b92da15c5` |
| `get_reservation_customer_profiles_v1(uuid[])` | `54a0765ed09b671a3a930bca9030d553` |
| admin note | `45fa1f94af33276a149cce88172ccadd` |
| attendance | `f0c8467a9481d65b658cfd77dc0d6f6b` |
| payment | `3be211e74ee56baf64daa3815289c3a7` |

Migration preflight rejects any missing signature or fingerprint drift. It also snapshots every unrelated public definer and the postflight requires exact definition, owner, path and ACL equality.

## 4. Tenant derivation

No new tenant argument is accepted from the client. Existing resource IDs are resolved under the definer boundary. Batch profile lookup requires every supplied reservation ID to exist and belong to exactly one tenant. Public check-in returns only `unavailable` for missing, foreign dormant or otherwise unusable tokens.

## 5. Membership authorization

Privileged wrappers require an active `tenant_memberships` record through `get_my_tenant_role_v1`. Allowed staff roles are exactly `admin` and `employee`. Null, pending and suspended membership states fail closed. The implementation explicitly checks `role IS NULL OR role NOT IN (...)`; local focused tests caught and eliminated the unsafe SQL three-valued-logic form.

## 6. Owner authorization

Cancellation derives the reservation tenant and owner. It allows the authenticated owner only when an active membership exists in that tenant, or tenant-local admin/employee staff. Foreign owner IDs and cross-tenant resources return controlled denial.

## 7. Reservation creation

The wrapper derives the tenant from `lane_id` and requires the caller's active `user` membership in that tenant. The preserved core retains pricing, durations, operating hours, hierarchy locks, idempotency, capacity, block/event conflicts and audit semantics.

The core INSERT was narrowly patched under an exact preflight fingerprint to write `v_lane.tenant_id` explicitly. The temporary CSK default is not used as the security mechanism. Existing composite `(tenant_id,lane_id)` integrity remains fail-closed and rejects mismatched rows.

## 8. Reservation cancellation

Owner and staff paths are separated before calling the preserved business core. The canonical 12-hour owner cutoff, operational status validation, audit action and resulting status remain unchanged.

## 9. Attendance/check-in

Admin/employee check-in lookup and attendance mutation derive tenant from token/reservation. Tenant A staff cannot use a Tenant B token. Ordinary users and instructors receive no new staff permission. Public status remains anonymous, neutral and active-tenant-only.

## 10. Instructor behavior

Instructor permission was not expanded. Instructor membership does not satisfy reservation staff mutation, operational profile lookup or staff check-in requirements.

## 11. service_role paths

No browser service role was introduced. `service_role` EXECUTE was removed from the hardened create, cancel, attendance and busy-range contracts and from legacy `create_reservation`. No new service-role grant was added.

## 12. Grants/search_path

The 12 client wrappers remain postgres-owned `SECURITY DEFINER` functions with `search_path=pg_catalog, public, pg_temp`. Their 12 preserved cores are postgres-owned `SECURITY INVOKER` and have no EXECUTE for PUBLIC, anon, authenticated or service_role. PUBLIC has no EXECUTE on any public function; the existing explicit anon/authenticated surface is preserved or narrowed.

## 13. Temporary CSK defaults

All seven approved compatibility defaults remain. The reservation default remains for later legacy compatibility but `create_reservation_v2` now stores the lane-derived tenant explicitly. Global default removal stays deferred to a later approved 9D gate before second-tenant activation.

## 14. Cross-tenant tests

The 32-test focused suite covers Admin A and Employee A allow on Tenant A and deny on Tenant B; instructor/no-membership/pending denial; tenant-scoped busy ranges; active-tenant owner reads; mixed-tenant profile batch denial; public dormant-token denial; and tenant-derived creation.

## 15. IDOR tests

Foreign cancellation, cross-tenant staff mutation, cross-tenant token lookup, cross-tenant lane availability and mixed reservation arrays all fail closed. Existing composite FKs continue to reject tenant/resource mismatch.

## 16. Global role negative test

Admin and employee profile roles are insufficient without an active membership in the resource tenant. Tenant B operations were denied despite the CSK global profile role. Result: global-role bypass removed for this phase.

## 17. Concurrency regression

The updated current-schema harness passed:

- deterministic scenarios: 52/52;
- stress: 50/50;
- deadlock `40P01`: 0;
- lock timeout `55P03`: 0;
- serialization failure `40001`: 0;
- unexpected SQLSTATE: 0;
- final invariant violations: 0;
- protected fingerprints unchanged: true;
- cleanup complete: true.

The harness itself required two test-only maintenance corrections: include the already-required resource `name` in family payloads and accept the current TAP output from the invariant suite. Its Windows/Docker timing tolerance remains material (at least 400 ms) but allows scheduler jitter.

## 18. Runtime regression

- local DB reset: PASS;
- focused SQL: 32/32 PASS;
- full DB: 27 files / 784 tests PASS;
- Node: 734/734 PASS;
- TypeScript: PASS;
- Next.js 16.3.4 production build: PASS;
- focused Playwright: 11/11 PASS across My Reservations, admin queues/routes and lane-family configuration;
- npm audit: one existing moderate `baseline-browser-mapping` advisory; not introduced or changed here.

## 19. SECURITY DEFINER inventory after

Public `SECURITY DEFINER` count remains 73. Twelve new protected core names are `SECURITY INVOKER`; each corresponding original signature remains a definer wrapper. Final definer catalog fingerprint is `6432cac00f27c1b11d23fe82a2a04c21`. Representative wrapper fingerprints: cancel `c5423189dcfab4aa1be39e93e42a6aca`, create V2 `ff1c273379e9ee3af3a1a60d131af81b`, check-in `80f207247b98956a7f649dbf3f725638`.

## 20. Deferred 9D functions

Events/email/promotion (9D-2), lane configuration/block writers (9D-3), reports/profiles/account/global role/public context (9D-4) and final retirement/default removal (9D-5) are unchanged and require separate review and authorization.

## 21. Production deployment plan

Production remains blocked pending a separate read-only preflight. That preflight must confirm exact source fingerprints, migration history, migration SHA-256, only this migration pending, current membership reconciliation, no tenant/resource orphan, ACL baseline and dry-run. Deployment should be DB-only, followed by focused production-safe tenant/ACL verification and current CSK runtime smoke. No app deployment is required because signatures are unchanged.

## 22. Git status

The working tree is intentionally modified and uncommitted. No `git add`, commit or push was performed. Files are listed in the final command output and task handoff.

## 23. Final verdict

SAAS-9D-1 LOCAL: **PASS**

RESERVATION RPC TENANT ISOLATION: **PASS**

CHECK-IN TENANT ISOLATION: **PASS**

GLOBAL ROLE BYPASS: **REMOVED**

OWNER OPERATIONS: **PASS**

CONCURRENCY: **PASS**

LEGACY CSK RUNTIME: **PASS**

READY FOR SAAS-9D-1 PRODUCTION PREFLIGHT: **GO**

READY FOR SAAS-9D-2: **NO-GO until review**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 29. PRODUCTION DEPLOYMENT & POST-DEPLOY VERIFICATION

Production deployment and verification were completed on 2026-09-12 under explicit authorization. The only deployed migration was `20260911140000_harden_reservation_checkin_rpcs.sql`. No application change, dependency update, migration repair, manual replacement SQL, Git staging, commit or push was performed.

### 29.1 Exact migration and SHA

- production project: linked project `yuyxfodozzpzrdzkmolu` (`csk-booking`, `ACTIVE_HEALTHY`);
- deployed migration: `20260911140000_harden_reservation_checkin_rpcs.sql` only;
- SHA-256 immediately before push: `EDC4EBFC05ED258D23A6665335B57A3A077ABA1412EAD43D0EEB1DCAE86ECD42`;
- pre-push normalized fingerprints: 12/12 exact matches;
- pre-push data gate: 0 duplicate memberships, 0 orphan memberships, 0 unknown roles/statuses, 0 null/mismatched reservation or lane tenant ownership;
- legacy active repository callers: 0.

`supabase db push --linked` applied exactly that one migration and completed successfully.

### 29.2 Migration history and final dry-run

Post-deploy `supabase migration list --linked` reports `20260911140000` as LOCAL=REMOTE, with no divergence. The first post-deploy dry-run encountered a transient temporary-login SASL authentication failure and made no change. A clean retry passed and returned exactly `Remote database is up to date.`

### 29.3 Deployed 12-RPC fingerprints

Production was compared to the fully migrated local target using the same normalized definition fingerprint, owner, security mode, search path and ACL query. All values matched exactly:

| RPC | Production/target fingerprint | Owner | Search path | Client EXECUTE |
|---|---|---|---|---|
| `cancel_reservation(uuid)` | `c5423189dcfab4aa1be39e93e42a6aca` | postgres | `pg_catalog, public, pg_temp` | authenticated |
| `create_reservation_v2(uuid,date,time,integer,integer,uuid,text)` | `ff1c273379e9ee3af3a1a60d131af81b` | postgres | safe | authenticated |
| `get_check_in_reservation_v1(uuid)` | `80f207247b98956a7f649dbf3f725638` | postgres | safe | authenticated |
| `get_lane_booking_busy_ranges(uuid,date)` | `b06fa07313e2549d7dead7ba62d9b89d` | postgres | safe | authenticated |
| `get_lane_booking_busy_ranges_v2(uuid,date)` | `dedf2493e3fb428a6a915146004449bd` | postgres | safe | authenticated |
| `get_lane_booking_busy_ranges_v3(uuid,date)` | `249ede970e180faa38d80fd89835e177` | postgres | safe | authenticated |
| `get_my_reservations_v2()` | `f94e8447a935cf184ce3b242598f01a5` | postgres | safe | authenticated |
| `get_public_check_in_status_v1(uuid)` | `94cab3b6cd055d5f14d96b6db5a30842` | postgres | safe | anon |
| `get_reservation_customer_profiles_v1(uuid[])` | `5902d87f82e5dd15a71ad6d4842bf5cf` | postgres | safe | authenticated |
| `update_reservation_admin_note(uuid,text)` | `ee1e857d879499e7f438cb89ef0ffaf0` | postgres | safe | authenticated |
| `update_reservation_attendance(uuid,text)` | `f2c3d06b2af0ae07d5cc5f0fa961c6fc` | postgres | safe | authenticated |
| `update_reservation_payment(uuid,text)` | `4d0ea7ed4ef012d13ccea01597d8b28b` | postgres | safe | authenticated |

All 12 are `SECURITY DEFINER`, owner `postgres`, have the exact safe search path, no PUBLIC grant and no service-role grant. The public check-in status contract remains anon-only; the other 11 active client RPCs remain authenticated-only.

### 29.4 Legacy ACL-only result

Legacy `create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)` retains normalized body fingerprint `3212b32f37ebc8e665a9a94e94260976`, its original signature, owner `postgres`, `SECURITY DEFINER` mode and `search_path=pg_catalog, public, pg_temp`. PUBLIC, anon, authenticated and service_role now all have no EXECUTE. The approved change was ACL-only and active callers remain 0.

### 29.5 Tenant derivation and authorization proof

A 36-check production smoke used unique synthetic identifiers inside one transaction and deliberately ended with `P0001: SAAS9D1_PROD_ALL_36_PASS_ROLLBACK`. The success marker was reached only after every assertion passed. A separate read-only post-check confirmed zero synthetic Auth users, profiles, tenants, lanes, reservations and audit rows.

The checks proved:

- reservation operations derive tenant from `reservations.tenant_id`;
- availability/creation derives tenant from `shooting_lanes.tenant_id`;
- check-in derives tenant from token → reservation → `reservations.tenant_id`;
- admin and employee can perform allowed operations only in their active membership tenant;
- the same global legacy admin role without active membership in Tenant B cannot operate on Tenant B resources;
- instructor, no-membership, pending and suspended actors are denied privileged reservation operations;
- an owner can cancel their own active-tenant reservation under the canonical contract;
- foreign-owner and cross-tenant IDOR cancellation are denied;
- admin/employee own-tenant check-in lookup succeeds;
- cross-tenant check-in, ordinary-user staff lookup and dormant-tenant public token paths fail closed;
- reservation creation succeeds only in the actor's active membership tenant and writes the lane-derived tenant ID without a caller tenant argument;
- cross-tenant/dormant-tenant creation is denied;
- the composite tenant/lane integrity constraint continues to reject mismatched rows.

Result: the global `profiles.role` bypass is **REMOVED for the SAAS-9D-1 scope**.

### 29.6 Concurrency and reservation semantics

The deployed 12 definitions are fingerprint-identical to the locally tested target. The hardened wrapper does not alter the preserved creation core's lock order, exclusion constraint behavior, advisory/multi-family locking, hierarchy conflict logic, event-conflict logic, or whole-axis/single-position semantics. Completed evidence therefore remains applicable after deployment: deterministic concurrency 52/52 PASS, randomized stress 50/50 PASS, zero deadlocks, zero double booking and zero invariant violations. The production rollback smoke additionally executed tenant-aware creation successfully and verified explicit lane-derived ownership. No disruptive live production load test was run.

### 29.7 Temporary defaults and SECURITY DEFINER inventory

All 7/7 approved temporary CSK compatibility defaults remain present; SAAS-9D-1 removed none. The post-deploy production SECURITY DEFINER inventory exactly matches the fully migrated local target:

- count: 73 on production and local;
- canonical definition/ACL aggregate fingerprint: `9f079c0c0411f41b74e481257785a6d5` on both;
- unexpected drift: 0.

Only the approved 12 definitions/security wrappers and legacy ACL changed relative to the pre-deploy baseline.

### 29.8 Runtime smoke

Post-deploy production browser smoke passed for Booking, My Reservations, Admin Reservations, Check-in, Admin, Calendar, lane configuration and login/account. Booking configuration, reservation reads, admin reservation controls, check-in filters, calendar hierarchy, lane configuration and account/session data all loaded without a new 5xx or runtime error. No browser mutation was performed; controlled creation, cancellation and staff mutation behavior was exercised in the rollback-only production SQL smoke.

### 29.9 Remaining SAAS-9D blockers

SAAS-9D-1 is deployed and verified, but SEC-004 remains open because additional SECURITY DEFINER/RPC groups are reserved for SAAS-9D-2 and later phases. SAAS-9D-2 implementation remains blocked until this change receives a reviewed Git checkpoint. Second-tenant activation remains prohibited.

### 29.10 Git checkpoint proposal

Branch remains `main` at `02af6857a88e37d30b6e4b1159496cecff91bac1`. `git diff --check` passes. The CRLF-insensitive tracked diff contains only the seven expected regression-test/harness updates. The exact proposed checkpoint set is:

1. `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md`
2. `SAAS_9D_1_RESERVATION_CHECKIN_RPC_HARDENING_REPORT.md`
3. `supabase/migrations/20260911140000_harden_reservation_checkin_rpcs.sql`
4. `supabase/tests/20260911140000_harden_reservation_checkin_rpcs_test.sql`
5. `supabase/tests/20260816143000_harden_public_function_execute_acl_test.sql`
6. `supabase/tests/20260903100000_harden_audit_log_integrity_test.sql`
7. `supabase/tests/20260909110000_backfill_csk_tenant_ownership_test.sql`
8. `supabase/tests/20260909130000_tenant_relationship_integrity_test.sql`
9. `supabase/tests/20260910120000_tenant_aware_booking_rls_test.sql`
10. `supabase/tests/20260911120000_remaining_tenant_aware_rls_test.sql`
11. `supabase/tests/final_cross_writer_regression.ps1`

No temporary smoke-test file remains. Nothing is staged. Checkpoint creation requires separate approval.

### 29.11 Final production verdict

SAAS-9D-1 PRODUCTION DEPLOY: **PASS**

SAAS-9D-1 POST-DEPLOY: **PASS**

12 RPC TENANT ISOLATION: **PASS**

GLOBAL ROLE BYPASS: **REMOVED for SAAS-9D-1 scope**

CHECK-IN TENANT ISOLATION: **PASS**

OWNER AUTHORIZATION: **PASS**

CONCURRENCY: **PASS**

LEGACY `create_reservation` ACL: **PASS**

READY FOR GIT CHECKPOINT: **YES**

READY FOR SAAS-9D-2 PLANNING: **GO**

READY FOR SAAS-9D-2 IMPLEMENTATION: **NO-GO until checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 28. SAAS-9D-1R — PRODUCTION PREFLIGHT RETRY

This section records the final read-only production retry performed on 2026-09-12 after the approved local reconciliation. No production SQL write, migration deployment, migration repair, writer RPC, Git staging, commit or push was executed. The only deployment command was `supabase db push --linked --dry-run`.

### 28.1 New SHA verification

The SHA-256 recalculated directly from `supabase/migrations/20260911140000_harden_reservation_checkin_rpcs.sql` is:

`EDC4EBFC05ED258D23A6665335B57A3A077ABA1412EAD43D0EEB1DCAE86ECD42`

It exactly matches the approved value. Static scope inspection found 12 controlled function renames/replacements and one separately approved legacy ACL-only cleanup.

### 28.2 Normalized fingerprint results

The approved guard converts CRLF and bare CR line endings to LF and performs no other semantic normalization. A fresh production catalog read produced the following results:

| Function | Signature | Normalized production fingerprint | Expected normalized baseline | Match |
|---|---|---|---|---|
| `cancel_reservation` | `(uuid)` | `8a8e46f00dcbb9e0eba45d8b5b86b6da` | `8a8e46f00dcbb9e0eba45d8b5b86b6da` | YES |
| `create_reservation_v2` | `(uuid,date,time without time zone,integer,integer,uuid,text)` | `601664ae4957ed0eef29f85ded57a191` | `601664ae4957ed0eef29f85ded57a191` | YES |
| `get_check_in_reservation_v1` | `(uuid)` | `d0c3aa17b9104dd7d7ad70c5abdcb214` | `d0c3aa17b9104dd7d7ad70c5abdcb214` | YES |
| `get_lane_booking_busy_ranges` | `(uuid,date)` | `95accb3363de7fb5e8b2f03bde18555c` | `95accb3363de7fb5e8b2f03bde18555c` | YES |
| `get_lane_booking_busy_ranges_v2` | `(uuid,date)` | `573f69aa8ab31a8f26c5734cebf9a785` | `573f69aa8ab31a8f26c5734cebf9a785` | YES |
| `get_lane_booking_busy_ranges_v3` | `(uuid,date)` | `119f24a2b9226fdd4a85b9bec8013e4e` | `119f24a2b9226fdd4a85b9bec8013e4e` | YES |
| `get_my_reservations_v2` | `()` | `37fc831189c125fd3ba94149813010d3` | `37fc831189c125fd3ba94149813010d3` | YES |
| `get_public_check_in_status_v1` | `(uuid)` | `ea4a14a4e8e7d3c6d36d4c9b92da15c5` | `ea4a14a4e8e7d3c6d36d4c9b92da15c5` | YES |
| `get_reservation_customer_profiles_v1` | `(uuid[])` | `34ca36a24032d4606cec1a3327e1bdaf` | `34ca36a24032d4606cec1a3327e1bdaf` | YES |
| `update_reservation_admin_note` | `(uuid,text)` | `89830fb63e81252389d5ce30c43fe0da` | `89830fb63e81252389d5ce30c43fe0da` | YES |
| `update_reservation_attendance` | `(uuid,text)` | `a8b1ac70f0ba227ad53ebed39b2c4c10` | `a8b1ac70f0ba227ad53ebed39b2c4c10` | YES |
| `update_reservation_payment` | `(uuid,text)` | `24b46f6834d825020392ee18ba5c11ba` | `24b46f6834d825020392ee18ba5c11ba` | YES |

Result: **12/12 MATCH**. The previous raw line-ending mismatch is resolved without weakening semantic drift detection.

### 28.3 Exact final scope

The migration changes the bodies/security logic of exactly the approved 12 RPC signatures. Public signatures, return contracts and caller-visible arguments remain unchanged. It separately revokes non-owner EXECUTE from legacy `create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)`.

For that legacy function, the production normalized body fingerprint is `3212b32f37ebc8e665a9a94e94260976`; owner is `postgres`; it is `SECURITY DEFINER`; and `search_path` is `pg_catalog, public, pg_temp`. Its production ACL is owner plus `service_role`; PUBLIC, anon and authenticated have no EXECUTE. The target changes only the ACL by revoking `service_role`, leaving the definition, signature, owner and search path byte/metadata-equivalent. Repository caller scan found **0 active callers** of legacy `create_reservation(...)`.

No other function body, signature, owner, security mode or ACL is in the migration scope.

### 28.4 Caller proof

Current runtime callers use the unchanged contracts for `create_reservation_v2`, busy ranges v3, cancellation, My Reservations v2, public/admin check-in, customer-profile batching, attendance, payment and admin-note operations. Retained busy-range v1/v2 contracts have no active application caller but remain signature-compatible. No caller passes or must begin passing `tenant_id`; no Next.js or API change is required.

### 28.5 Fresh production state

The fresh aggregate-only production read confirmed:

- tenants: 1 total, 1 active, exactly 1 active `csk`;
- memberships: 9 total; roles `admin=1`, `user=8`; statuses `active=9`;
- unknown roles/statuses: 0/0;
- duplicate memberships: 0;
- orphan tenant memberships: 0;
- orphan Auth-user memberships: 0;
- lane resources: 11, null tenant IDs: 0;
- reservations: 11, null tenant IDs: 0, orphan lanes: 0, tenant mismatches: 0;
- reservations with check-in tokens: 11 (count only; no token value was read or reported).

There is no unexplained mismatch requiring STOP.

### 28.6 Tenant derivation and membership authorization

The target derives authorization context from trusted resources:

- `reservation_id` → `reservations.tenant_id`;
- `lane_id` → `shooting_lanes.tenant_id`;
- check-in token/attendance → reservation → `reservations.tenant_id`.

No caller-supplied tenant ID is the authorization source. Staff operations require `auth.uid()` + active membership + allowed tenant membership role (`admin`/`employee`) + resource-tenant equality. A global `profiles.role=admin` without active membership in the resource tenant is denied. Global legacy role alone no longer authorizes any of the 12 target RPCs.

### 28.7 Owner authorization and check-in isolation

Owner cancellation derives both owner and tenant from the reservation: the owner with active membership is allowed according to the existing cancellation contract; a foreign reservation and cross-tenant IDOR are denied. For check-in, tenant admin/employee on the reservation tenant is allowed, while a foreign tenant, pending membership, suspended membership, missing membership and invalid token/resource all fail closed.

These paths were covered by the completed local SQL suite; production preflight remained read-only and did not invoke mutating RPCs.

### 28.8 Grants, owner and search path

All 12 production functions are currently owned by `postgres`, are `SECURITY DEFINER`, have `search_path=pg_catalog, public, pg_temp`, and have no PUBLIC EXECUTE. Current and target grants are:

| Function group | Current client grants | Current service_role | Target grants | Target owner/path/security mode |
|---|---|---|---|---|
| `get_public_check_in_status_v1` | anon | none | anon only | unchanged: postgres / safe path / definer |
| remaining 11 active RPCs | authenticated | present only on cancellation, creation v2, busy v1-v3 and attendance | authenticated only | unchanged: postgres / safe path / definer |
| legacy `create_reservation` | no client grant | EXECUTE | owner only | unchanged: postgres / safe path / definer |

The migration only narrows EXECUTE. It introduces no new PUBLIC, anon, authenticated or service-role exposure.

### 28.9 Temporary CSK defaults

All approved 7/7 compatibility defaults remain present on `shooting_lanes`, `reservations`, `lane_blocks`, `events`, `event_lanes`, `event_registrations` and `email_deliveries`. SAAS-9D-1 removes none of them.

`create_reservation_v2` explicitly derives the lane tenant and writes that tenant ID. Cancellation, attendance, payment and admin-note writers derive authorization from the already tenant-owned reservation and update that row; they do not rely on a default for authorization. The owner-only legacy `create_reservation` still technically relies on the CSK reservation default because its preserved body does not supply `tenant_id`, but it has no active caller and loses `service_role` EXECUTE. Defaults for writers outside this phase remain compatibility bridges for later controlled SAAS-9D work.

### 28.10 SECURITY DEFINER inventory drift

A canonical full production inventory was compared with a clean local database stopped at the production migration boundary (`20260911120000`). The results matched exactly:

- all public SECURITY DEFINER functions: count 73, aggregate fingerprint `5516bc0e8aea5e2c6d5ae144fc251c77`;
- 12 target definitions plus legacy ACL surface: count 13, aggregate fingerprint `cd4fe82bd7f73bc92d93cbe7135eede1`;
- all unrelated SECURITY DEFINER functions: count 60, aggregate fingerprint `1a4f9b9ecb032c36912f8275aaaf9eae`.

Production and clean-local counts and all three aggregate fingerprints are identical. Unexpected drift: **0**.

### 28.11 Migration history and dry-run

`supabase migration list --linked` confirms LOCAL=REMOTE through `20260911120000`. There is no remote-only migration and the only local pending migration is `20260911140000_harden_reservation_checkin_rpcs.sql`.

After all prior gates passed, `supabase db push --linked --dry-run` completed successfully and reported exactly:

`20260911140000_harden_reservation_checkin_rpcs.sql`

No migration was pushed. The CLI version notice (`2.109.1`, newer `2.117.0` available) is informational and is not a deployment blocker.

### 28.12 Runtime baseline

Read-only production browser smoke passed for the authenticated session/account, public Booking, My Reservations, Admin Reservations, Check-in, Calendar, Reports, Events and lane configuration. Pages rendered their expected controls/data or controlled empty states without a 5xx/runtime failure. No form submission, writer action or production mutation was performed.

### 28.13 Concurrency invariants

The migration preserves the existing lock order, exclusion constraints, advisory/multi-family locking, hierarchy conflict logic, event conflict logic and whole-axis/single-position semantics. It changes tenant derivation/authorization and explicitly persists lane-derived tenant ownership in creation without changing the concurrency core. Completed local evidence remains: deterministic concurrency 52/52 PASS, stress 50/50 PASS, zero deadlocks, zero double booking and zero invariant violations. No migration content changed after that evidence, so a duplicate rerun was not required for this preflight retry.

### 28.14 Deployment risk

| Area | Risk | Assessment |
|---|---|---|
| CREATE/rename/replace function DDL | MEDIUM | Transactional and guarded; short catalog/function locks remain possible. |
| legacy ACL revoke | LOW | Zero active callers; grant is narrowed to owner-only. |
| check-in regression | MEDIUM | Operationally important, but tenant/role matrices and runtime baseline pass. |
| reservation creation | MEDIUM | Critical write path; public signature and concurrency core are preserved and fully tested locally. |
| concurrency | LOW | Lock order and constraints are unchanged; deterministic and stress evidence pass. |
| caller compatibility | LOW | Signatures unchanged and all active callers remain compatible. |

A low-traffic deployment period is sufficient. Deployment should STOP on fingerprint/preflight failure, lock timeout, unexpected migration scope, or immediate Booking/Check-in smoke regression; no maintenance window is required by current evidence.

### 28.15 Remaining blockers

There is no preflight blocker to the separately authorized production push of the single migration. The required next gate is explicit user authorization for the actual `db push`. SAAS-9D-2 remains blocked until SAAS-9D-1 production deployment, post-deploy verification and checkpoint/review are complete.

### 28.16 Final production-preflight retry verdict

SAAS-9D-1 PRODUCTION PREFLIGHT RETRY: **PASS**

NORMALIZED FINGERPRINTS: **12/12 PASS**

FINAL SCOPE: **12 RPC + 1 ACL-ONLY PASS**

LEGACY `create_reservation` ACL: **PASS**

TENANT DERIVATION: **PASS**

GLOBAL ROLE BYPASS: **REMOVED in target / production deployment pending**

CHECK-IN TENANT ISOLATION: **PASS**

OWNER AUTHORIZATION: **PASS**

CALLER COMPATIBILITY: **PASS**

READY FOR PRODUCTION PUSH: **YES**

READY FOR SAAS-9D-2: **NO-GO until 9D-1 production PASS and checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 26. SAAS-9D-1R — MIGRATION REVISION & LOCAL REVALIDATION

### 26.1 CRLF/LF root cause and normalized guard

The 10/12 production preflight mismatches were caused only by catalog-rendered line endings: production used LF and the clean Windows reconstruction used CRLF. All twelve full `pg_get_functiondef` values and inspected metadata were semantically identical after line-ending normalization.

The revised preflight hashes this exact expression:

```sql
md5(replace(replace(pg_get_functiondef(oid), E'\r\n', E'\n'), E'\r', E'\n'))
```

Only CRLF and lone CR are canonicalized to LF. No other whitespace, SQL text, arguments or metadata are removed. Because the input remains the full `pg_get_functiondef`, the guard still covers the signature and defaults, return declaration, language, volatility/strictness, SECURITY mode, `SET`/`search_path` clauses and function body. Owner and ACL remain separately asserted. A focused negative test proves that changing `select 1` to `select 2` changes the canonical fingerprint.

### 26.2 Revised final scope

The final scope is explicitly **12 RPC HARDENING + 1 LEGACY ACL-ONLY CLEANUP**.

| Active signature | Clean pre-change canonical fingerprint | Post-migration canonical fingerprint |
|---|---:|---:|
| `cancel_reservation(uuid)` | `8a8e46f00dcbb9e0eba45d8b5b86b6da` | `c5423189dcfab4aa1be39e93e42a6aca` |
| `create_reservation_v2(uuid,date,time,integer,integer,uuid,text)` | `601664ae4957ed0eef29f85ded57a191` | `ff1c273379e9ee3af3a1a60d131af81b` |
| `get_check_in_reservation_v1(uuid)` | `d0c3aa17b9104dd7d7ad70c5abdcb214` | `80f207247b98956a7f649dbf3f725638` |
| `get_lane_booking_busy_ranges(uuid,date)` | `95accb3363de7fb5e8b2f03bde18555c` | `b06fa07313e2549d7dead7ba62d9b89d` |
| `get_lane_booking_busy_ranges_v2(uuid,date)` | `573f69aa8ab31a8f26c5734cebf9a785` | `dedf2493e3fb428a6a915146004449bd` |
| `get_lane_booking_busy_ranges_v3(uuid,date)` | `119f24a2b9226fdd4a85b9bec8013e4e` | `249ede970e180faa38d80fd89835e177` |
| `get_my_reservations_v2()` | `37fc831189c125fd3ba94149813010d3` | `f94e8447a935cf184ce3b242598f01a5` |
| `get_public_check_in_status_v1(uuid)` | `ea4a14a4e8e7d3c6d36d4c9b92da15c5` | `94cab3b6cd055d5f14d96b6db5a30842` |
| `get_reservation_customer_profiles_v1(uuid[])` | `34ca36a24032d4606cec1a3327e1bdaf` | `5902d87f82e5dd15a71ad6d4842bf5cf` |
| `update_reservation_admin_note(uuid,text)` | `89830fb63e81252389d5ce30c43fe0da` | `ee1e857d879499e7f438cb89ef0ffaf0` |
| `update_reservation_attendance(uuid,text)` | `a8b1ac70f0ba227ad53ebed39b2c4c10` | `f2c3d06b2af0ae07d5cc5f0fa961c6fc` |
| `update_reservation_payment(uuid,text)` | `24b46f6834d825020392ee18ba5c11ba` | `4d0ea7ed4ef012d13ccea01597d8b28b` |

Exactly twelve active signatures receive tenant-aware wrapper/security changes. The migration snapshots every unrelated public SECURITY DEFINER function and fails if its normalized definition, owner, `proconfig` or ACL changes. No Events, lane/config, reports, profile or application code was changed.

### 26.3 Legacy `create_reservation(...)` ACL-only cleanup

Repository and catalog caller review remains `ACTIVE CALLERS = 0`. The migration now has a separate fail-closed legacy preflight requiring the reviewed baseline:

- canonical definition fingerprint `3212b32f37ebc8e665a9a94e94260976`;
- owner `postgres`;
- SECURITY DEFINER unchanged;
- `search_path=pg_catalog, public, pg_temp`;
- no PUBLIC/anon/authenticated EXECUTE and exactly the existing owner + service-role grantees.

After migration the canonical fingerprint remains `3212b32f37ebc8e665a9a94e94260976`, owner and `search_path` remain unchanged, and ACL is exactly owner-only (`{postgres=X/postgres}`). The function body, signature and business logic are not modified. Only the approved `service_role EXECUTE` removal occurs.

### 26.4 Migration identity

The previous SHA-256 `A5968B9EE3B290B03D95FE0751CE57E92CEE30547E1FEBA891AC15E4ED69BF46` is superseded.

Revised migration SHA-256:

`EDC4EBFC05ED258D23A6665335B57A3A077ABA1412EAD43D0EEB1DCAE86ECD42`

The migration was not edited after the successful reset and validation summarized below.

### 26.5 Clean baseline and local validation

A clean local reset to `20260911120000` passed before applying 9D-1. It confirmed all twelve canonical pre-change fingerprints and the legacy production-equivalent ACL baseline. A subsequent full clean reset applied the revised `20260911140000` migration successfully. After all test fixtures, another full reset restored a clean current local database.

Results:

- focused SAAS-9D-1 SQL: **36/36 PASS**;
- LF versus CRLF canonical equivalence: **PASS**;
- semantic body-change detection: **PASS**;
- twelve wrapper/core security and tenant checks: **PASS**;
- legacy definition/owner/path unchanged and exact ACL cleanup: **PASS**;
- cross-tenant, IDOR, tenant-spoof, no-membership, pending and suspended cases: **PASS**;
- owner operations and check-in isolation: **PASS**;
- full Supabase DB suite: **788/788 PASS** across 27 files;
- Node: **734/734 PASS**;
- TypeScript `tsc --noEmit`: **PASS**;
- production build: **PASS** (known middleware-to-proxy deprecation warning only);
- focused operational Playwright: **11/11 PASS**;
- deterministic cross-writer/concurrency requirements: **52/52 PASS**;
- randomized stress: **50/50 PASS**;
- deadlocks, lock timeouts, serialization failures and unexpected SQLSTATEs: **0**;
- final cross-writer invariant violations: **0**;
- protected unrelated function fingerprints unchanged: **true**;
- concurrency cleanup and temporary logs removed: **true**.

All deferred 9D functions remain outside the migration and are protected by the unrelated-definer snapshot. SAAS-9D-2 remains deferred.

### 26.6 Production preflight retry requirements

No production preflight, dry-run or write was performed during this revision. A separately authorized retry must re-check migration history, the revised SHA-256, canonical production fingerprints for all twelve functions, the exact legacy baseline, current tenant/membership/resource invariants, ACLs, only this migration pending, and then `db push --linked --dry-run`. Production push remains separately gated.

### 26.7 Revision verdict

MIGRATION REVISION: **PASS**

NORMALIZED FINGERPRINT GUARD: **PASS**

12 RPC HARDENING: **PASS**

LEGACY `create_reservation` ACL-ONLY: **PASS**

LOCAL FULL REGRESSION: **PASS**

READY FOR PRODUCTION PREFLIGHT RETRY: **GO**

READY FOR PRODUCTION PUSH: **NO**

READY FOR SAAS-9D-2: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 25. SAAS-9D-1R — PRODUCTION FINGERPRINT & SCOPE RECONCILIATION

This section supersedes the preliminary root-cause uncertainty in section 24. The reconciliation was read-only for production. A clean local database was explicitly reset to `20260911120000`; migration `20260911140000` was not applied during the baseline comparison and was not edited.

### 25.1 Twelve-function fingerprint matrix

| Function | Production raw MD5 | Clean local pre-9D-1 MD5 | Migration expected MD5 | PROD=LOCAL | PROD=EXPECTED | LOCAL=EXPECTED |
|---|---|---|---|---:|---:|---:|
| `cancel_reservation(uuid)` | `8a8e46f00dcbb9e0eba45d8b5b86b6da` | `c968aee936a8ccca3db268c3eac7b342` | `c968aee936a8ccca3db268c3eac7b342` | no | no | yes |
| `create_reservation_v2(uuid,date,time,integer,integer,uuid,text)` | `601664ae4957ed0eef29f85ded57a191` | `3f201f96dc413736d564089536b98d7d` | `3f201f96dc413736d564089536b98d7d` | no | no | yes |
| `get_check_in_reservation_v1(uuid)` | `d0c3aa17b9104dd7d7ad70c5abdcb214` | same | same | yes | yes | yes |
| `get_lane_booking_busy_ranges(uuid,date)` | `95accb3363de7fb5e8b2f03bde18555c` | `2bab8b9ba5086ed74931d2f434a3819a` | `2bab8b9ba5086ed74931d2f434a3819a` | no | no | yes |
| `get_lane_booking_busy_ranges_v2(uuid,date)` | `573f69aa8ab31a8f26c5734cebf9a785` | `40f0914451c01c4d1f34bf61b72d1afe` | `40f0914451c01c4d1f34bf61b72d1afe` | no | no | yes |
| `get_lane_booking_busy_ranges_v3(uuid,date)` | `119f24a2b9226fdd4a85b9bec8013e4e` | `3ac61a3195e4f40393c9d38a86367a91` | `3ac61a3195e4f40393c9d38a86367a91` | no | no | yes |
| `get_my_reservations_v2()` | `37fc831189c125fd3ba94149813010d3` | `0492a134c20ade26a55b08f28fcb4364` | `0492a134c20ade26a55b08f28fcb4364` | no | no | yes |
| `get_public_check_in_status_v1(uuid)` | `ea4a14a4e8e7d3c6d36d4c9b92da15c5` | same | same | yes | yes | yes |
| `get_reservation_customer_profiles_v1(uuid[])` | `34ca36a24032d4606cec1a3327e1bdaf` | `54a0765ed09b671a3a930bca9030d553` | `54a0765ed09b671a3a930bca9030d553` | no | no | yes |
| `update_reservation_admin_note(uuid,text)` | `89830fb63e81252389d5ce30c43fe0da` | `45fa1f94af33276a149cce88172ccadd` | `45fa1f94af33276a149cce88172ccadd` | no | no | yes |
| `update_reservation_attendance(uuid,text)` | `a8b1ac70f0ba227ad53ebed39b2c4c10` | `f0c8467a9481d65b658cfd77dc0d6f6b` | `f0c8467a9481d65b658cfd77dc0d6f6b` | no | no | yes |
| `update_reservation_payment(uuid,text)` | `24b46f6834d825020392ee18ba5c11ba` | `3be211e74ee56baf64daa3815289c3a7` | `3be211e74ee56baf64daa3815289c3a7` | no | no | yes |

### 25.2 Definition diffs and root cause

For every mismatched function, the production `prosrc` uses LF while the clean-local `prosrc` uses CRLF. Example first bytes: production `"\ndeclare\n..."`; local `"\r\ndeclare\r\n..."`. The raw length delta equals the number of line endings. After replacing CRLF and lone CR with LF, every body and every full `pg_get_functiondef` is identical.

All compared metadata is also identical for all 12 functions:

- signature and argument defaults;
- return type;
- language and volatility;
- `STRICT` state;
- `SECURITY DEFINER` state;
- parallel state;
- owner `postgres`;
- `search_path=pg_catalog, public, pg_temp`;
- PUBLIC/anon/authenticated/service_role grants.

Classification for each of the ten mismatches: **A — formatting-only (CRLF versus LF)**. There is no production-only body change, missing hotfix or authorization difference. The two raw matches were recreated by later migration sources whose stored line endings already match production.

### 25.3 Canonical fingerprint proof

The canonical expression tested read-only was:

```sql
md5(replace(replace(pg_get_functiondef(oid), E'\r\n', E'\n'), E'\r', E'\n'))
```

It produced 12/12 production-to-clean-local matches. Canonical values are the production raw values in the matrix because production already stores LF.

### 25.4 Fingerprint-method analysis

The current migration hashes raw `pg_get_functiondef(regprocedure)`. This includes function signature, argument names/defaults, result declaration, language, volatility/strict/definer clauses, SET/search-path clauses and the body, including verbatim whitespace and line endings. It does not include owner or ACL. The migration checks owner/ACL separately when setting the target wrappers, while its unrelated-definer snapshot stores owner, `proconfig` and `proacl` in additional columns.

The current target guard is therefore semantically strong but non-portable across LF/CRLF reconstruction. The stable replacement should normalize **only** line endings before hashing. It must not collapse general whitespace or normalize string contents broadly, because those transformations could hide a semantic change. Tests must prove CRLF/LF equivalence and rejection after any non-line-ending body or metadata change.

### 25.5 Source of truth and reproducibility

Production current definitions and the current repository migration chain are both authoritative for semantics: they reconstruct identical bodies and metadata. Production is authoritative for the deployed raw LF representation; clean local is authoritative for the repository's current CRLF reconstruction. There is no unrepresented production hotfix in the 12-function set.

`PROD == CLEAN LOCAL BASELINE` is **NO for raw bytes/fingerprints**, but **YES for normalized definitions and all inspected metadata**. The reproducibility defect is limited to line-ending-sensitive fingerprinting.

### 25.6 Legacy `create_reservation(...)` inventory

- signature: `create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)`;
- owner: `postgres`;
- mode: `SECURITY DEFINER`;
- search path: `pg_catalog, public, pg_temp`;
- production grants: PUBLIC no, anon no, authenticated no, service_role yes;
- production fingerprint: `3212b32f37ebc8e665a9a94e94260976`;
- replacement: active `create_reservation_v2(...)` used by the application;
- repository application/API/server-action callers: 0;
- production SQL-function callers found by scanning `pg_proc.prosrc`: 0;
- PostgREST references in active repository code: 0;
- only remaining direct references are archived legacy SQL tests and negative tests asserting the application does not call v1.

The function is operationally deprecated. Its remaining service-role EXECUTE is not reachable by anon or authenticated clients and a standard service-role JWT has no owner `auth.uid()`. Therefore no active exploit path was demonstrated. It nevertheless remains a tenant-unaware privileged surface that could become dangerous if a future service path supplies user context incorrectly; removing the unused grant is appropriate least-privilege hardening.

### 25.7 Caller-safety conclusion

`ACTIVE APPLICATION CALLERS = 0`. Removing service-role EXECUTE does not affect the current booking API, load harness or browser flow because each uses `create_reservation_v2`. No SQL function delegates to v1. The archived compatibility tests are not runtime callers.

### 25.8 Scope options

**Option A — remove legacy ACL change from 9D-1.** Keeps the literal 12-RPC scope and minimizes this migration, but leaves an unnecessary tenant-unaware service-role surface until later cleanup.

**Option B — explicitly define 9D-1 as 12 hardened RPCs plus 1 legacy ACL-only surface.** Preserves the already tested revoke, closes the dormant surface in the same security boundary, and has no active-caller regression based on current evidence. It requires explicit scope approval and tests that the legacy function body remains unchanged while only EXECUTE is revoked. **Recommended.**

**Option C — separate legacy ACL cleanup migration.** Provides the clearest deployment separation and keeps 9D-1 literally limited to 12, but adds another migration and sequencing/checkpoint burden. It is appropriate if change-control policy requires one concern per migration.

### 25.9 Recommended solution

Use Option B only after explicit approval: rename the phase description to “12 hardened RPCs + 1 legacy ACL-only surface.” Keep the legacy function definition fingerprinted and unchanged, retain the zero-caller proof, revoke only its service-role EXECUTE, and test the exact before/after ACL matrix. This closes the dormant surface without introducing a second deployment unit.

### 25.10 Exact migration revision plan

No edit was made in this task. The approved follow-up should:

1. add a small immutable line-ending-canonical fingerprint expression/helper scoped to the migration;
2. replace the 12 raw preflight comparisons with canonical `pg_get_functiondef` comparisons;
3. set the 12 expected canonical values to the production values listed in section 25.1;
4. keep exact metadata, owner, path and ACL assertions; do not weaken unrelated-definer snapshot/postflight equality inside the same transaction;
5. explicitly inventory the legacy v1 function as an ACL-only thirteenth surface if Option B is approved;
6. preflight its definition, owner, path, current service-role-only grant and zero-client grants;
7. postflight that its body/metadata are unchanged and all non-owner EXECUTE is absent;
8. add CRLF/LF equivalence tests plus negative tests for body, signature/default, return, volatility, security mode, search path, owner and grant drift;
9. run clean reset, focused SQL, full DB, concurrency, Node, TypeScript, build and diff checks;
10. repeat production baseline, history, SHA-256 and dry-run before any write.

### 25.11 Remaining blockers

- explicit owner decision between Option B and Option C/A;
- separate authorization to revise migration `20260911140000`;
- full local retest of the revised migration;
- repeated production preflight and dry-run showing only the revised migration.

### 25.12 SAAS-9D-1R verdict

FINGERPRINT ROOT CAUSE: **RESOLVED**

PRODUCTION == CLEAN LOCAL BASELINE: **NO raw / YES semantically**

12-RPC SCOPE: **REQUIRES REVISION**

LEGACY `create_reservation` ACL: **INCLUDE AS ACL-ONLY — recommended, pending explicit approval**

MIGRATION REVISION PLAN: **READY**

READY TO MODIFY 9D-1 MIGRATION: **GO — only after separate explicit authorization**

READY FOR PRODUCTION PREFLIGHT RETRY: **NO-GO until revised migration is locally re-tested**

READY FOR PRODUCTION PUSH: **NO**

SAAS-9D-2: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 24. PRODUCTION PREFLIGHT & DEPLOYMENT READINESS — 2026-09-12

### 24.1 Fresh production state

The production inspection was executed through `supabase db query --linked` inside a transaction declared `READ ONLY`. No production DML, schema change, migration, writer RPC or deployment was executed.

- tenants: 1 total, 1 active, exactly 1 active `csk`;
- memberships: 9 total; roles: admin 1, user 8; statuses: active 9;
- duplicate memberships: 0;
- orphan tenant memberships: 0;
- orphan Auth-user memberships: 0;
- unknown roles: 0;
- unknown membership statuses: 0;
- lanes/resources: 11 total, all under CSK (6 lanes, including 5 active/online and 1 inactive/offline; 5 active/online positions);
- reservations: 11 total, all under CSK; 7 confirmed/planned and 4 no-show; all 11 have a check-in token;
- the seven approved CSK compatibility defaults remain present and every corresponding `tenant_id` column remains `NOT NULL`.

The broader row-to-resource mismatch analysis was not continued after the mandatory function-fingerprint STOP condition was reached.

### 24.2 Exact 12-function scope and fingerprint comparison

The migration rewrites exactly the approved 12 active signatures. It additionally changes the ACL of legacy `create_reservation(uuid,date,time,integer,integer,uuid,text)` by revoking EXECUTE from PUBLIC, anon, authenticated and service_role. Although the legacy definition is not rewritten and no repository caller was found, this is still a thirteenth function-level change under the literal preflight requirement; therefore exact 12-function scope is **FAIL** pending explicit review. Independently, the migration's preflight fingerprints do not match the live production catalog for 10 of the 12 active functions. Production and local both run PostgreSQL 17.6, so the mismatch is not attributable to a PostgreSQL-version difference.

| Function/signature | Production fingerprint | Migration-required pre-change fingerprint | Target local fingerprint | Callers | Current production authorization | Target tenant derivation/check | Current grants | Path |
|---|---|---|---|---|---|---|---|---|
| `cancel_reservation(uuid)` | `8a8e46f00dcbb9e0eba45d8b5b86b6da` | `c968aee936a8ccca3db268c3eac7b342` | `c5423189dcfab4aa1be39e93e42a6aca` | My Reservations, Admin Reservations, Check-in, `lib/reservation-actions.ts`, load harness | global `profiles.role` (`user/admin/pracownik`); owner check only for `user` | reservation → `reservations.tenant_id`; active owner membership or tenant admin/employee | authenticated + service_role | safe |
| `create_reservation_v2(uuid,date,time,integer,integer,uuid,text)` | `601664ae4957ed0eef29f85ded57a191` | `3f201f96dc413736d564089536b98d7d` | `ff1c273379e9ee3af3a1a60d131af81b` | create-reservation API, load harness | global profile role must be `user` | lane → `shooting_lanes.tenant_id`; active user membership; explicit tenant insert | authenticated + service_role | safe |
| `get_check_in_reservation_v1(uuid)` | `d0c3aa17b9104dd7d7ad70c5abdcb214` | same | `80f207247b98956a7f649dbf3f725638` | Admin Check-in | global profile role admin/pracownik | token → reservation → tenant; tenant admin/employee | authenticated | safe |
| `get_lane_booking_busy_ranges(uuid,date)` | `95accb3363de7fb5e8b2f03bde18555c` | `2bab8b9ba5086ed74931d2f434a3819a` | `b06fa07313e2549d7dead7ba62d9b89d` | retained legacy contract; no active app caller found | no membership check | lane → tenant; active membership | authenticated + service_role | safe |
| `get_lane_booking_busy_ranges_v2(uuid,date)` | `573f69aa8ab31a8f26c5734cebf9a785` | `40f0914451c01c4d1f34bf61b72d1afe` | `dedf2493e3fb428a6a915146004449bd` | retained legacy contract; no active app caller found | no membership check | lane → tenant; active membership | authenticated + service_role | safe |
| `get_lane_booking_busy_ranges_v3(uuid,date)` | `119f24a2b9226fdd4a85b9bec8013e4e` | `3ac61a3195e4f40393c9d38a86367a91` | `249ede970e180faa38d80fd89835e177` | Booking form, load harness | no membership check | lane → tenant; active membership | authenticated + service_role | safe |
| `get_my_reservations_v2()` | `37fc831189c125fd3ba94149813010d3` | `0492a134c20ade26a55b08f28fcb4364` | `f94e8447a935cf184ce3b242598f01a5` | My Reservations, reservation ICS API | `auth.uid()` owner filter only | caller-owned rows plus active membership/tenant per row | authenticated | safe |
| `get_public_check_in_status_v1(uuid)` | `ea4a14a4e8e7d3c6d36d4c9b92da15c5` | same | `94cab3b6cd055d5f14d96b6db5a30842` | public check-in token page | public token lookup, neutral DTO | token → reservation → active tenant | anon | safe |
| `get_reservation_customer_profiles_v1(uuid[])` | `34ca36a24032d4606cec1a3327e1bdaf` | `54a0765ed09b671a3a930bca9030d553` | `5902d87f82e5dd15a71ad6d4842bf5cf` | Admin Check-in, cancellation-email API | global profile role admin/pracownik | all reservations must exist in exactly one tenant; tenant admin/employee | authenticated | safe |
| `update_reservation_admin_note(uuid,text)` | `89830fb63e81252389d5ce30c43fe0da` | `45fa1f94af33276a149cce88172ccadd` | `ee1e857d879499e7f438cb89ef0ffaf0` | Admin Reservations through `lib/reservation-actions.ts` | global profile role admin/pracownik | reservation → tenant; tenant admin/employee | authenticated | safe |
| `update_reservation_attendance(uuid,text)` | `a8b1ac70f0ba227ad53ebed39b2c4c10` | `f0c8467a9481d65b658cfd77dc0d6f6b` | `f2c3d06b2af0ae07d5cc5f0fa961c6fc` | Admin Reservations and Check-in | global profile role admin/pracownik | reservation → tenant; tenant admin/employee | authenticated + service_role | safe |
| `update_reservation_payment(uuid,text)` | `24b46f6834d825020392ee18ba5c11ba` | `3be211e74ee56baf64daa3815289c3a7` | `4d0ea7ed4ef012d13ccea01597d8b28b` | Admin Reservations through `lib/reservation-actions.ts` | global profile role admin/pracownik | reservation → tenant; tenant admin/employee | authenticated | safe |

All 12 live functions are owned by `postgres`, are `SECURITY DEFINER`, have no PUBLIC EXECUTE and use `search_path=pg_catalog, public, pg_temp`. `get_public_check_in_status_v1` is anon-only; the other active browser functions allow authenticated. Existing service-role grants shown above are narrowed by the target migration. No target signature accepts a client-supplied tenant ID.

### 24.3 Unchanged SECURITY DEFINER baseline

The remaining public `SECURITY DEFINER` baseline excluding the target names was captured read-only: 60 functions, aggregate catalog fingerprint `cae9af9620afa12da4a94fbc7e6d5456`. It cannot yet serve as a post-deploy comparison because deployment is blocked before dry-run.

### 24.4 Caller compatibility

Static caller review confirms that no application caller supplies a tenant argument and the target migration preserves all 12 public signatures. No Next.js/API change is expected for the approved target contract. This compatibility conclusion does not override the production fingerprint blocker.

### 24.5 Tenant, owner and check-in authorization target

The reviewed target remains correct: staff actions require `auth.uid()` plus active tenant membership plus an allowed role and resource-tenant equality; global `profiles.role` alone is insufficient. Owner cancellation derives owner and tenant from the reservation. Check-in derives tenant through token → reservation. Invalid, foreign, pending, suspended and missing membership paths fail closed in the local implementation. The production functions remain on their current legacy authorization until an approved migration is deployed.

### 24.6 Reservation creation and temporary defaults

The target wrapper does not alter the preserved core's lock order, hierarchy conflict scope, exclusion handling, event/lane-block conflict rules or idempotency. It patches only the reservation INSERT to persist lane-derived `tenant_id`. All seven CSK defaults remain on production and in the target local database; none is removed by 9D-1.

### 24.7 Local cross-tenant and concurrency evidence

The previously completed local implementation evidence remains valid: focused SQL 32/32 PASS, full DB 784/784 PASS, deterministic concurrency 52/52 PASS, stress concurrency 50/50 PASS, zero deadlocks, zero double booking, zero invariant violations and fixture remaining 0. A fresh preflight rerun was intentionally not started after the mandatory production fingerprint STOP condition.

### 24.8 Runtime baseline

Booking, My Reservations, Admin Reservations, Check-in, Calendar, lane configuration and login/account pre-deploy browser smoke was not started because the function fingerprint prerequisite failed first. This evidence remains outstanding.

### 24.9 Migration history and SHA-256

- branch: `main`;
- HEAD: `02af6857a88e37d30b6e4b1159496cecff91bac1`;
- historical tracked migration diff: none;
- migration SHA-256: `A5968B9EE3B290B03D95FE0751CE57E92CEE30547E1FEBA891AC15E4ED69BF46` — exact match with the approved local value;
- migration history: LOCAL=REMOTE through `20260911120000`; only `20260911140000` is local/pending; no remote-only migration was reported.

### 24.10 Dry-run

`supabase db push --linked --dry-run` was **NOT RUN**. The mandatory prerequisite failed: 10 live production function fingerprints differ from the migration's exact preflight allowlist. Running dry-run after that failure would not make the migration deployable and would violate the requested STOP rule.

### 24.11 Deployment risk

- function replacement/rename risk: **HIGH while fingerprint drift is unresolved**;
- lock risk from the planned function DDL alone: **LOW**;
- backward compatibility risk after reconciled definitions: expected **LOW**, signatures are stable;
- check-in regression risk: **MEDIUM**;
- reservation creation/concurrency risk: **MEDIUM**;
- low-traffic deployment period: likely sufficient only after a corrected migration passes a fresh production preflight and dry-run.

### 24.12 Remaining blocker and required next action

There are two independent blockers. First, production catalog definitions for 10 functions must be reconciled against the repository's expected pre-change definitions. The cause may be an unrecorded production function change or non-reproducible historical migration content; it must not be guessed. Second, the legacy `create_reservation(...)` ACL revocation must either receive explicit approval as a thirteenth scoped function or be removed from this migration and handled in a separately approved step. Before production readiness can be restored, perform a separate read-only semantic diff, decide which live business definitions are authoritative, update the 9D-1 migration only through an explicitly reviewed correction, reset/retest locally, and repeat the complete production preflight. No migration was modified during this preflight.

### 24.13 Production preflight verdict

> Historical result before SAAS-9D-1R reconciliation and local revision. The current local verdict is in sections 26 and 27.

SAAS-9D-1 PRODUCTION PREFLIGHT: **FAIL**

12-RPC SCOPE: **FAIL — legacy `create_reservation(...)` ACL is an additional function-level change**

TENANT DERIVATION: **PASS (target design), deployment blocked**

GLOBAL ROLE BYPASS: **BLOCKED on production; removed only in local target**

CHECK-IN TENANT ISOLATION: **PASS locally / production deployment blocked**

OWNER AUTHORIZATION: **PASS locally / production deployment blocked**

CONCURRENCY: **PASS on completed local evidence; fresh rerun not performed after STOP**

CALLER COMPATIBILITY: **PASS**

READY FOR PRODUCTION PUSH: **NO**

READY FOR SAAS-9D-2: **NO-GO until 9D-1 production PASS and checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 27. Current post-revision verdict

The completed production deployment and post-deploy evidence are recorded in section 29. Section 29 supersedes the historical blockers and pre-deployment verdicts in sections 24, 25 and 28 and is the authoritative current verdict.

MIGRATION REVISION: **PASS**

NORMALIZED FINGERPRINT GUARD: **PASS**

12 RPC HARDENING: **PASS**

LEGACY `create_reservation` ACL-ONLY: **PASS**

LOCAL FULL REGRESSION: **PASS**

SAAS-9D-1 PRODUCTION DEPLOY: **PASS**

SAAS-9D-1 POST-DEPLOY: **PASS**

READY FOR GIT CHECKPOINT: **YES**

READY FOR SAAS-9D-2 PLANNING: **GO**

READY FOR SAAS-9D-2 IMPLEMENTATION: **NO-GO until checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**
