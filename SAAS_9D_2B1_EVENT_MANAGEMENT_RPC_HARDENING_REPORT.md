# SAAS-9D-2B-1 — Staff Event Management RPC Hardening

Local implementation and verification date: 2026-09-13 (Europe/Warsaw).

Repository baseline: `b37386902b42c12f6902de27e172e516c69ed9d4` on `main`.

## 1. Executive summary

SAAS-9D-2B-1 is implemented and verified locally. The four active staff event-management RPC signatures remain unchanged, but their `SECURITY DEFINER` boundaries now authorize with `auth.uid()` plus an active tenant membership and the allowed tenant role. Resource mutations derive tenant ownership from the event; contextless create/list operations use the approved fail-closed single-active-tenant bridge until SAAS-9E.

The three zero-caller legacy event-management functions are now owner-only. Public event readers are byte-semantically unchanged and remain deferred to SAAS-9D-2B-2. No application file, historical migration, production system or remote Supabase project was changed.

## 2. Exact function scope

Active functions hardened:

1. `admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])`
2. `admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])`
3. `admin_set_event_active_v2(uuid,boolean)`
4. `admin_list_events_v1(text,text,text,integer,integer)`

Legacy ACL cleanup:

5. `admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])`
6. `admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])`
7. `admin_set_event_active(uuid,boolean)`

Explicitly deferred and unchanged:

- `get_public_event_availability_v1()`
- `get_public_event_list_v2(text,text,integer,integer)`

## 3. Pre-change inventory and fingerprints

Fingerprints normalize CRLF and CR to LF before MD5, matching SAAS-9D-1/2A.

| Function | Normalized fingerprint | Caller | Definer / path | Current pre-change auth and grant | Tenant source / target role / risk |
|---|---|---|---|---|---|
| `admin_create_event_v2(...)` | `6b8d29b11797a346ae9387a9bd3ec6b9` | `app/admin/events/page.tsx` | yes / SP1 | global `profiles.role`; `authenticated` | no resource; approved bridge; admin/employee; global create and mixed-lane risk |
| `admin_update_event_v2(...)` | `a525123389f3a646cd3da6f26e466ed5` | `app/admin/events/page.tsx` | yes / SP1 | global `profiles.role`; `authenticated` | `events.tenant_id`; admin/employee; foreign event/lane binding risk |
| `admin_set_event_active_v2(uuid,boolean)` | `ad56e445e74634f540425d92ff93acb1` | `app/admin/events/page.tsx` | yes / SP1 | global `profiles.role`; `authenticated` | `events.tenant_id`; admin/employee; foreign activation risk |
| `admin_list_events_v1(...)` | `7972f35024b6202a149afbe09f50d5a2` | `app/admin/events/page.tsx` | yes / SP1 | global `profiles.role`; `authenticated` | no resource; approved bridge; admin/employee/instructor; global list risk |
| `admin_create_event(...)` | `26f51acb0a0f56677a86dbddec9974b2` | none | yes / SP2 | global `profiles.role`; `service_role` | legacy global create risk |
| `admin_update_event(...)` | `60301f5e0b290117105bc9637f10d3ce` | none | yes / SP2 | global `profiles.role`; `service_role` | legacy global mutation risk |
| `admin_set_event_active(uuid,boolean)` | `b547b0c8d2b056273b10fe57f78f89c0` | none | yes / SP2 | global `profiles.role`; `service_role` | legacy global mutation risk |

SP1 is `pg_catalog, public, pg_temp`; SP2 is `public, pg_temp`.

Static caller inventory found exactly four active browser calls, all in `app/admin/events/page.tsx`, and zero TypeScript/JavaScript callers for the three legacy signatures. There is no active server or `service_role` caller for the legacy signatures.

Frozen out-of-scope public fingerprints:

- availability: `40adf74cb5adec5df3b4745fc7851433`;
- public list: `fe075d7057149b0a0bad0129419a3e99`.

## 4. Active-single-tenant bridge

Only create and admin list use `active_single_tenant_id_v1()` because neither current signature carries a trusted resource or tenant context. The helper returns a tenant only when exactly one tenant is active. The wrappers then require an active membership in that exact tenant.

Verified locally:

- exactly one active tenant resolves CSK and permits an eligible member;
- zero active tenants returns `not_allowed` without a write;
- two active tenants returns `not_allowed` without selecting the first row;
- no client-supplied tenant UUID exists in either signature.

Create takes row-share locks on the tenant registry before resolving the bridge, preventing a concurrent active-tenant cutover from changing scope between wrapper authorization and core execution. The read-only list retains its `STABLE` contract and therefore uses one statement snapshot for bridge resolution and the bounded query. This compatibility bridge must be replaced by trusted host/slug-selected tenant context in SAAS-9E before Tenant B is activated.

## 5. Staff authorization

The active wrapper boundary now requires:

`auth.uid()` → resource/bridge tenant → active `tenant_memberships` row → allowed membership role → resource/lane tenant match.

Allowed roles:

- create/update/activate: `admin`, `employee`;
- admin list: `admin`, `employee`, `instructor`.

Missing, pending and suspended memberships are denied. A global `profiles.role=admin` without an active target membership is denied.

## 6. Global role removal

Global profile role no longer authorizes a client-reachable `SECURITY DEFINER` event-management operation. The frozen business implementations remain behind four owner-only `SECURITY INVOKER` cores; any retained legacy profile check inside those inaccessible cores is compatibility validation after the tenant wrapper, not an authorization path.

The focused negative test proves that a global admin profile without membership cannot activate or list events.

## 7. Event create

`admin_create_event_v2` keeps its exact signature and response contract. It resolves the sole active tenant, requires active admin/employee membership, rejects any existing requested lane belonging to another tenant before entering the business core, and explicitly writes:

- `events.tenant_id = resolved tenant`;
- `event_lanes.tenant_id = resolved tenant`.

Missing lanes continue to reach the existing `invalid_lane` business validation. Empty-lane creation remains supported. Existing time, price, capacity, operating-hours, hierarchy and conflict rules are unchanged.

## 8. Event update

`admin_update_event_v2` derives tenant from `events.tenant_id`, requires active admin/employee membership in that tenant and rejects every cross-tenant lane before the existing lock/conflict/replacement flow. Replacement relations explicitly write the event tenant. Event tenant ownership itself is not mutable through the RPC.

## 9. Active/status operations

`admin_set_event_active_v2` derives tenant from the event and requires active admin/employee membership. Existing `invalid_input`, `event_not_found`, `no_change`, `activated`, `deactivated` and conflict behavior is preserved. Instructor, no-membership, pending and suspended callers are denied.

## 10. Admin event listing

`admin_list_events_v1` resolves the sole active tenant and requires active admin/employee/instructor membership. Its base rows, summary counts and lane relationships are all tenant-filtered. Tenant A tests return zero Tenant B events; filtering is performed in the DB contract, not the frontend.

## 11. Event/lane consistency

Create, update and lane replacement reject `Event Tenant A + Lane Tenant B` before mutation. The business cores additionally scope reservation, lane-block and event conflict reads by the derived tenant. Existing composite tenant foreign keys remain a second integrity layer.

## 12. Instructor behavior

Instructor access is unchanged: the instructor retains the existing read-only admin event-list scope within the active tenant and gains no create, update or activation permission. No instructor-event assignment model was added and SEC-008 remains deferred.

## 13. Legacy service-grant cleanup

The three legacy functions had no active browser, server or service-role callers. Their `service_role` EXECUTE grants were revoked; they are owner-only. This cleanup is ACL-only: bodies, signatures, owners and production `search_path = public, pg_temp` are unchanged.

## 14. service_role analysis

No active 2B-1 function is callable by `service_role`. Service role is not treated as a business admin. The four active wrappers are `authenticated`-only; the four cores and three legacy functions are owner-only.

## 15. Public contract regression

Both deferred public reader definitions retain their exact normalized pre-change fingerprints. The public Events contract remained callable by anon and PII-free in focused SQL and Playwright. No public reader body or grant changed.

## 16. Caller compatibility

All active signatures, argument names/defaults and JSON business contracts are preserved. No application source change was required. The current admin Event create/edit/activate/list calls continue to use the same four RPC names.

Compatibility matrix:

| State | Result |
|---|---|
| old app + old DB | current baseline |
| old app + new DB | compatible; same signatures, membership backfill required and already verified by SAAS-9C-1 |
| new app + old DB | not applicable; no app change |
| current app + current DB | local PASS |

## 17. Temporary defaults

| Table | Writer | Current CSK default | Explicit tenant now? | Default still used? | Removal gate |
|---|---|---:|---:|---:|---|
| `events` | `admin_create_event_v2` | yes | yes, bridge tenant | no by active writer | SAAS-9D-5/9E before second tenant |
| `event_lanes` | create/update V2 | yes | yes, event tenant | no by active writers | SAAS-9D-5/9E before second tenant |

The compatibility defaults remain present. **REMOVE DEFAULT BEFORE TENANT-AWARE WRITER CUTOVER AND BEFORE SECOND TENANT** remains an explicit later gate.

## 18. Cross-tenant tests

Focused SQL: 32/32 PASS. Coverage includes Admin A and Employee A own-tenant allow, Tenant B denial, instructor read-only behavior, ordinary-user denial, global-admin/no-membership denial, pending/suspended denial, mixed-lane create/update denial, tenant-scoped list, explicit ownership writes and atomic no-partial-write checks.

## 19. Bridge fail-closed tests

All three required states pass: one active tenant resolves; zero active denies; two active denies. The two-active case is created only inside the rolled-back local test transaction by temporarily replacing the single-active index, then restoring it before rollback.

## 20. Concurrency/conflict tests

The existing full cross-writer harness passed:

- deterministic executions: 52/52;
- stress iterations: 50/50;
- deadlocks `40P01`: 0;
- lock timeouts `55P03`: 0;
- serialization failures `40001`: 0;
- unexpected SQLSTATE: 0;
- final invariant violations: 0;
- protected fingerprints unchanged: true;
- cleanup complete: true.

This covers event create/update/activate, lane reassignment and reservation/lane-block/event conflict ordering.

## 21. Full regression

- local DB reset with all migrations: PASS;
- focused SAAS-9D-2B-1 SQL: 32/32 PASS;
- full Supabase DB suite: 29 files / 852 tests PASS;
- SAAS-9D-2A regression: PASS;
- Node full suite: 734/734 PASS;
- TypeScript `tsc --noEmit`: PASS;
- production build: PASS;
- Events Playwright: 8/8 PASS;
- admin/booking/account/login operational Playwright: 6/6 PASS;
- independent synthetic fixture post-check: tenants 0, profiles 0, lanes 0, events 0, registrations 0;
- `git diff --check`: PASS.

The build retains the known Next.js middleware-to-proxy deprecation warning; it is unrelated to this change.

## 22. Deferred 2B-2 functions

`get_public_event_availability_v1()` and `get_public_event_list_v2(...)` remain unchanged and are not considered implemented by this phase. SAAS-9D-2B-2 remains NO-GO until separate review and authorization.

## 23. Production deployment plan

Deployment is DB-only and not authorized by this work. A later production preflight must verify the seven normalized fingerprints, zero legacy callers, membership consistency, migration history, exact single pending migration and a dry-run. Production deployment requires separate explicit approval, followed by a rollback-only cross-tenant smoke and catalog/fingerprint verification.

Rollback, if required, must be a reviewed forward migration restoring the four prior definitions and three legacy ACL states. Do not edit applied migrations and do not use migration repair.

## 24. Git status

The working tree is intentionally changed and unstaged. No `git add`, commit or push was performed. The changed set consists of the existing plan update, the new migration/report/focused test, and three updated historical test expectations required to recognize the approved 2B-1 contract. No historical migration was modified.

## 25. Final verdict

SAAS-9D-2B-1 LOCAL: **PASS**

STAFF EVENT MANAGEMENT TENANT ISOLATION: **PASS**

GLOBAL ROLE BYPASS: **REMOVED**

EVENT/LANE CONSISTENCY: **PASS**

ACTIVE-SINGLE-TENANT BRIDGE: **PASS**

LEGACY SERVICE GRANTS: **HARDENED**

INSTRUCTOR SCOPE: **UNCHANGED**

PUBLIC EVENT CONTRACT: **PASS**

CONCURRENCY / CONFLICTS: **PASS**

CALLER COMPATIBILITY: **PASS**

READY FOR SAAS-9D-2B-1 PRODUCTION PREFLIGHT: **GO**

READY FOR SAAS-9D-2B-2: **NO-GO until review**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## SAAS-9D-2B-1 — production deploy and post-deploy verification

### Deployment result

The explicitly authorized production command applied exactly one migration:

```text
20260913100000_harden_event_management_rpcs.sql
```

The file SHA-256 was recalculated immediately before deployment and matched the approved value:

```text
554BD4D887F03040AD9DADD567BB78AB5536330785E1C325D79CA8A3EE637886
```

No migration repair, manual replacement SQL, application deployment, Git staging, commit or push was performed.

### Migration history and final dry-run

- `supabase migration list --linked`: LOCAL = REMOTE through `20260913100000`.
- No other local migration is pending.
- `supabase db push --linked --dry-run`: `Remote database is up to date.`

### Production RPC verification

The four active RPCs are present with their reviewed signatures, are owned by `postgres`, remain `SECURITY DEFINER`, use SP1 (`pg_catalog, public, pg_temp`) and expose `EXECUTE` only to `authenticated`:

| RPC | Production normalized full-definition MD5 |
|---|---|
| `admin_create_event_v2(...)` | `44c5a76fb1eecab62462ad0efc014f54` |
| `admin_update_event_v2(...)` | `b87b87d6842c77238f4806073436fabb` |
| `admin_set_event_active_v2(uuid, boolean)` | `6c9df46f20e0caf905d65c9928cb63d1` |
| `admin_list_events_v1(...)` | `e9fbe38591aa39b760d3c5e6e9a0be52` |

The three legacy RPCs retain their signatures, bodies, `postgres` ownership, `SECURITY DEFINER` flag and SP2 (`public, pg_temp`) search path. Their full-definition/body fingerprints remain:

| Legacy RPC | Full MD5 | Body MD5 |
|---|---|---|
| `admin_create_event(...)` | `26f51acb0a0f56677a86dbddec9974b2` | `9ad97eb12fbb4aeff35845e12a3b6231` |
| `admin_update_event(...)` | `60301f5e0b290117105bc9637f10d3ce` | `196433b57ceb24f509b949e662742cd1` |
| `admin_set_event_active(...)` | `b547b0c8d2b056273b10fe57f78f89c0` | `725ac582182c0861e0d5e36c5025d393` |

For all three legacy RPCs, `EXECUTE` is denied to `PUBLIC`, `anon`, `authenticated` and `service_role`. This is the approved ACL-only change.

### Metadata and compatibility invariants

- Four active wrappers exist and four renamed cores are invoker-only and client-inaccessible.
- The public-schema `SECURITY DEFINER` inventory remains at the reviewed count of 73; no unexpected drift was detected.
- All seven temporary CSK `tenant_id` compatibility defaults remain present.
- Exactly one active tenant remains, the active-single-tenant bridge resolves to CSK, role mappings have zero mismatches and active memberships reference no non-active tenant.
- Production event/lane ownership checks report zero orphans and zero tenant mismatches.

### Rollback-only production behavior test

A single transaction used uniquely generated synthetic users, profiles, memberships, a dormant tenant, lanes, events and event-lane relations. It completed all 21 post-deploy assertions and deliberately raised:

```text
ERROR: P0001: SAAS9D2B1_POSTDEPLOY_ALL_21_PASS_ROLLBACK
```

The assertions confirmed:

- a global `profiles.role = admin` user without active tenant membership is denied;
- admin and employee preserve authorized management inside the active CSK tenant;
- cross-tenant event update is denied;
- `Event A + Lane B` create and lane replacement are denied atomically;
- instructor write scope remains denied while the existing read-only event-list scope remains available;
- the active-single-tenant bridge selects CSK only under the exact-one-active invariant;
- public Events remains available and PII-free;
- the seven compatibility defaults remain present.

An independent query after the controlled exception returned zero synthetic Auth users, profiles, tenants, lanes, events and event-lane rows. `fixture cleanup = 0`.

### Post-deploy runtime smoke

Fresh production responses were verified after the database deployment:

- public `/events`: rendered successfully, authoritative public contract available, zero captured browser errors;
- `/admin/events`: rendered successfully for the authenticated admin session;
- create form, edit controls and activate/deactivate controls are present;
- lane assignment controls render in the create form;
- participant list and status/payment filters render;
- `/booking`: rendered successfully, zero captured browser errors;
- `/admin`: operational dashboard rendered successfully, zero captured browser errors;
- `/account`: account view rendered successfully, zero captured browser errors.

Only read operations and local form/panel expansion were used. No event create, edit, activation, lane assignment or participant mutation was submitted.

### Proposed Git checkpoint scope

The exact proposed checkpoint is the current seven-file SAAS-9D-2B-1 implementation set:

1. `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md`
2. `SAAS_9D_2B1_EVENT_MANAGEMENT_RPC_HARDENING_REPORT.md`
3. `supabase/migrations/20260913100000_harden_event_management_rpcs.sql`
4. `supabase/tests/20260913100000_harden_event_management_rpcs_test.sql`
5. `supabase/tests/20260816143000_harden_public_function_execute_acl_test.sql`
6. `supabase/tests/20260911100000_tenant_aware_events_rls_test.sql`
7. `supabase/tests/20260912100000_harden_event_registration_rpcs_test.sql`

No staging action has been performed.

### Final production verdict

SAAS-9D-2B-1 PRODUCTION DEPLOY: **PASS**

SAAS-9D-2B-1 POST-DEPLOY VERIFICATION: **PASS**

MIGRATION HISTORY LOCAL = REMOTE: **PASS**

FINAL DRY-RUN: **PASS — Remote database is up to date**

4 ACTIVE RPC: **PASS**

3 LEGACY RPC ACL-ONLY: **PASS**

GLOBAL ROLE WITHOUT MEMBERSHIP: **DENY / PASS**

ADMIN / EMPLOYEE TENANT ISOLATION: **PASS**

INSTRUCTOR SCOPE: **UNCHANGED**

EVENT A + LANE B: **DENY / PASS**

ACTIVE-SINGLE-TENANT BRIDGE: **PASS**

PUBLIC EVENTS CONTRACT: **PASS**

SECURITY DEFINER INVENTORY: **PASS — no unexpected drift**

7/7 COMPATIBILITY DEFAULTS: **PASS**

RUNTIME SMOKE: **PASS**

FIXTURE CLEANUP: **0 / PASS**

READY FOR GIT CHECKPOINT: **YES**

READY FOR SAAS-9D-2B-2: **NO-GO until checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 27. SAAS-9D-2B-1R — PRODUCTION PREFLIGHT RETRY

This section supersedes the stopped preflight recorded in section 26. It verifies the corrected, fully re-tested migration candidate. All production SQL used for this retry was read-only. The only Supabase deployment command was `supabase db push --linked --dry-run`; no migration, production mutation, migration repair or Git write was performed.

### 27.1 Working tree reconciliation

Branch and revision:

- branch: `main`;
- HEAD: `b37386902b42c12f6902de27e172e516c69ed9d4`.

`git status --short`, `git diff --name-only` and `git ls-files --others --exclude-standard` reconcile to exactly the approved seven-file scope:

1. `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md`;
2. `SAAS_9D_2B1_EVENT_MANAGEMENT_RPC_HARDENING_REPORT.md`;
3. `supabase/migrations/20260913100000_harden_event_management_rpcs.sql`;
4. `supabase/tests/20260913100000_harden_event_management_rpcs_test.sql`;
5. `supabase/tests/20260816143000_harden_public_function_execute_acl_test.sql`;
6. `supabase/tests/20260911100000_tenant_aware_events_rls_test.sql`;
7. `supabase/tests/20260912100000_harden_event_registration_rpcs_test.sql`.

There is no eighth modified or untracked file. `git diff --check` passes; its LF-to-CRLF notices are working-copy conversion warnings, not whitespace errors.

### 27.2 SHA verification

Fresh SHA-256 for `20260913100000_harden_event_management_rpcs.sql`:

```text
554BD4D887F03040AD9DADD567BB78AB5536330785E1C325D79CA8A3EE637886
```

It exactly equals the approved digest: PASS.

### 27.3 Exact final 4 + 3 scope

The migration changes exactly seven existing public surfaces.

Active body/authorization hardening:

1. `admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])`;
2. `admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])`;
3. `admin_set_event_active_v2(uuid,boolean)`;
4. `admin_list_events_v1(text,text,text,integer,integer)`.

Legacy ACL-only cleanup:

1. `admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])`;
2. `admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])`;
3. `admin_set_event_active(uuid,boolean)`.

The four generated `__saas9d2b1_core` functions are internal implementation details of the four active surfaces, are changed to `SECURITY INVOKER`, and have owner-only execution. No additional business function is in scope.

### 27.4 Active production fingerprints

Fresh production catalog reads, with definitions normalized from CRLF/CR to LF, equal all frozen baselines:

| Active RPC | Production normalized fingerprint | Expected baseline | Result |
|---|---|---|---|
| `admin_create_event_v2(...)` | `6b8d29b11797a346ae9387a9bd3ec6b9` | `6b8d29b11797a346ae9387a9bd3ec6b9` | PASS |
| `admin_update_event_v2(...)` | `a525123389f3a646cd3da6f26e466ed5` | `a525123389f3a646cd3da6f26e466ed5` | PASS |
| `admin_set_event_active_v2(uuid,boolean)` | `ad56e445e74634f540425d92ff93acb1` | `ad56e445e74634f540425d92ff93acb1` | PASS |
| `admin_list_events_v1(...)` | `7972f35024b6202a149afbe09f50d5a2` | `7972f35024b6202a149afbe09f50d5a2` | PASS |

Result: 4/4 PASS. All four are currently `postgres`-owned `SECURITY DEFINER` functions with SP1 (`pg_catalog, public, pg_temp`); authenticated has EXECUTE and PUBLIC, anon and service role do not.

### 27.5 Legacy ACL-only and search-path proof

| Legacy RPC | Production / target full fingerprint | Production / target body fingerprint | Owner | Search path | Current ACL | Target ACL | Result |
|---|---|---|---|---|---|---|---|
| `admin_create_event(...)` | `26f51acb0a0f56677a86dbddec9974b2` | `9ad97eb12fbb4aeff35845e12a3b6231` | `postgres` | `public, pg_temp` | service-role EXECUTE only | owner-only | PASS |
| `admin_update_event(...)` | `60301f5e0b290117105bc9637f10d3ce` | `196433b57ceb24f509b949e662742cd1` | `postgres` | `public, pg_temp` | service-role EXECUTE only | owner-only | PASS |
| `admin_set_event_active(uuid,boolean)` | `b547b0c8d2b056273b10fe57f78f89c0` | `725ac582182c0861e0d5e36c5025d393` | `postgres` | `public, pg_temp` | service-role EXECUTE only | owner-only | PASS |

The corrected migration contains no legacy `ALTER FUNCTION ... SET search_path`, owner, signature or body change. It only revokes the remaining service-role EXECUTE. Legacy search path and body are preserved 3/3.

### 27.6 Caller proof

Fresh repository search proves:

- active application callers: one per active RPC in `app/admin/events/page.tsx`;
- active TypeScript/JavaScript callers of the three legacy names: 0;
- SQL callers in active `supabase/migrations` and `supabase/tests`: 0;
- service-role runtime paths calling the three legacy event RPCs: 0.

Direct legacy invocations exist only in `supabase/tests_legacy_20260816`, an archived and non-active historical test directory. They are not application, API, server-action, current test-suite or deployment callers. Caller compatibility: PASS.

### 27.7 Fresh production baseline

| Check | Fresh result |
|---|---|
| active tenants | 1 (`csk`) |
| tenant memberships | 9 |
| membership roles | admin 1; user 8 |
| membership statuses | active 9 |
| duplicate memberships | 0 |
| orphan memberships | 0 |
| profiles / profiles without membership | 9 / 0 |
| memberships without profile | 0 |
| unknown profile roles | 0 |
| unknown membership roles | 0 |
| profile-to-membership role mapping mismatches | 0 |
| non-CSK memberships | 0 |
| events | 11 |
| event lanes | 9 |
| shooting lanes | 11 |
| orphan event tenants | 0 |
| event-lane vs event/lane tenant mismatches | 0 |

The production dataset therefore has zero duplicate, orphan, unknown or mismatched rows relevant to this phase.

### 27.8 Active-single-tenant bridge

Production has exactly one active tenant, `csk`. The owner-only helper returns that tenant only when the active count equals one. Focused local tests prove:

- exactly one active tenant: resolves the tenant;
- zero active tenants: fail closed;
- more than one active tenant: fail closed.

Create takes row-share locks on the tenant registry before bridge resolution and membership authorization. Admin list uses one `STABLE` statement snapshot. The production partial unique active-tenant guard remains in force. No second tenant was activated or created during preflight.

### 27.9 Staff authorization and global-role negative case

The target wrappers authorize with `auth.uid()` plus an active membership in the derived/resolved tenant:

- create, update and set-active: tenant role `admin` or `employee`;
- admin list: tenant role `admin`, `employee` or `instructor`;
- missing, pending or suspended membership: DENY;
- ordinary tenant user: DENY for privileged paths;
- global `profiles.role=admin` without an active tenant membership: DENY for create, update, set-active and list.

The fresh bridge audit found 0 missing profiles/memberships and 0 role-map mismatches. Global profile role is not an independent target authorization source.

### 27.10 Create, update, set-active and list behavior

- Create resolves the sole active tenant, requires active admin/employee membership, locks tenant rows, rejects every existing foreign-tenant lane before mutation, and the patched business core explicitly inserts `events.tenant_id` and `event_lanes.tenant_id` from the resolved tenant.
- Update derives authority from `events.tenant_id`, requires active admin/employee membership in that tenant, rejects foreign replacement lanes, preserves event tenant immutability and explicitly writes tenant ownership to replacement `event_lanes`.
- Set-active derives tenant from the event and denies no-membership, pending, suspended, ordinary-user, instructor and global-role-only callers.
- Admin list resolves the sole active tenant, requires an authorized active membership, and constrains base rows, total rows and lane relations to that tenant.

All public signatures, defaults and response shapes remain unchanged.

### 27.11 Instructor scope and event/lane consistency

Instructor retains the prior tenant-scoped list/read capability only. It gains no create, update or activation capability. SEC-008 remains unchanged.

Event Tenant A plus Lane Tenant B is rejected for create, update and lane replacement before mutation. Conflict reads for reservations, lane blocks and events are tenant constrained, and composite tenant foreign keys remain the independent integrity barrier. Atomic cross-tenant failure tests pass locally.

### 27.12 ACL, owner, search path and SECURITY DEFINER inventory

Fresh production effective ACL:

- four active RPCs: authenticated EXECUTE only among PUBLIC/anon/authenticated/service_role;
- three legacy RPCs: service-role EXECUTE only before deployment;
- all seven: owner `postgres`, `SECURITY DEFINER`;
- active path: SP1; legacy path: SP2.

Target ACL removes service-role EXECUTE from legacy without widening any grant. Active path remains SP1, legacy path remains SP2. Production contains exactly 73 public-schema `SECURITY DEFINER` functions, matching the expected inventory with zero drift. The target keeps the count at 73 because its four internal cores are invokers.

### 27.13 Temporary defaults

Fresh production catalog inspection confirms all 7/7 approved `tenant_id` compatibility defaults remain present. The migration neither removes nor adds a compatibility default. The existing gate remains mandatory: **REMOVE DEFAULT BEFORE TENANT-AWARE WRITER CUTOVER AND BEFORE SECOND TENANT**.

### 27.14 Concurrency evidence

The corrected migration candidate retains the fully repeated local evidence:

- deterministic: 52/52 PASS;
- stress: 50/50 PASS;
- deadlocks: 0;
- lock timeouts: 0;
- serialization failures: 0;
- unexpected SQLSTATE: 0;
- broken invariants: 0;
- cross-tenant lane attachment: 0;
- cleanup complete: true.

No heavy stress test was run against production. Fresh production read-only lock inspection found 0 ungranted locks, 0 non-idle competing sessions and 0 transactions older than five minutes.

### 27.15 Migration history and dry-run

`supabase migration list --linked` shows LOCAL = REMOTE through `20260912100000`. There is no remote-only migration or divergence. The only local pending migration is `20260913100000`.

After every preceding gate passed, `supabase db push --linked --dry-run` completed with exit code 0 and reported exactly:

```text
DRY RUN: migrations will *not* be pushed to the database.
Would push these migrations:
 • 20260913100000_harden_event_management_rpcs.sql
Finished supabase db push.
```

The CLI version notice (`2.109.1` installed; `2.117.0` available) is informational. No database push was executed.

### 27.16 Read-only production runtime baseline

Fresh browser smoke on the deployed application passed without a production mutation:

- public Events loaded its bounded public list/empty state;
- public Booking loaded the configured lane selector;
- authenticated Account loaded;
- Admin dashboard loaded for the existing admin session;
- Reservations, Calendar, Reports, Admin Events and Check-in loaded and completed their initial reads;
- Admin Events rendered create/edit/activate controls, lane assignment controls and event rows;
- participant listing was opened read-only and loaded successfully.

No create, edit, activate/deactivate, participant, payment, reservation or check-in mutation was submitted. No 5xx or runtime blocker was observed.

### 27.17 Deployment risk

| Risk | Rating | Evidence / mitigation |
|---|---|---|
| transactional rename/create wrappers | MEDIUM | short catalog/function locks; frozen fingerprint fail-closed guards; no table rewrite |
| active-single bridge | MEDIUM | temporary compatibility architecture; exact-one guard, membership checks, create row locks and tests |
| create/update/set-active/list | MEDIUM | operationally critical RPCs; unchanged signatures/contracts; full local regression and fresh runtime reads |
| lane consistency | LOW | pre-mutation tenant checks plus composite tenant FKs |
| legacy ACL revoke | LOW | zero active required callers; owner-only target |
| caller compatibility | LOW | stable signatures and one existing caller per active RPC |
| lock/data volume | LOW | no backfill/table rewrite; 0 competing sessions, long transactions or ungranted locks |

A low-traffic deployment window is sufficient. STOP before push if SHA, production fingerprints, migration history, active-tenant count, ACL baseline or lock baseline changes.

### 27.18 Remaining blockers and controlling verdicts

No preflight blocker remains for the reviewed SHA. Production push is technically ready but was deliberately not performed and still requires a separate explicit authorization. SAAS-9D-2B-2 remains gated on 2B-1 production PASS followed by checkpoint/review.

SAAS-9D-2B-1 PRODUCTION PREFLIGHT RETRY: **PASS**

WORKING TREE SCOPE: **PASS**

SHA: **PASS**

4 ACTIVE RPC FINGERPRINTS: **4/4 PASS**

3 LEGACY ACL-ONLY: **PASS**

LEGACY SEARCH_PATH: **PRESERVED**

LEGACY BODY: **PRESERVED**

ACTIVE-SINGLE-TENANT BRIDGE: **PASS**

STAFF TENANT ISOLATION: **PASS**

GLOBAL ROLE BYPASS: **REMOVED IN TARGET**

EVENT/LANE CONSISTENCY: **PASS**

INSTRUCTOR SCOPE: **UNCHANGED**

CALLER COMPATIBILITY: **PASS**

READY FOR PRODUCTION PUSH: **YES**

READY FOR SAAS-9D-2B-2: **NO-GO until 2B-1 production PASS and checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## SAAS-9D-2B-1R — LEGACY ACL-ONLY SCOPE CORRECTION

Revision and local revalidation date: 2026-09-13 (Europe/Warsaw).

### 27.1 Preflight blocker and stop decision

The first production preflight correctly stopped before deployment because migration SHA `4B5478AAEA230F2A9BBEA88FE9291170A2EC17F4512076431E1C37B954B53DE4` contained three unintended `ALTER FUNCTION ... SET search_path=pg_catalog,public,pg_temp` statements. That changed the legacy production SP2 metadata even though the approved legacy scope was ACL-only. The successful dry-run did not override this scope gate. No production push or SQL write occurred.

### 27.2 Exact legacy RPC inventory and ACL-only proof

| Function | Production path | Revised target path | Production definition fingerprint | Revised target fingerprint | Production owner | Target owner | Production effective ACL | Revised target ACL | Contract result |
|---|---|---|---|---|---|---|---|---|---|
| `admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | SP2 | SP2 | `26f51acb0a0f56677a86dbddec9974b2` | `26f51acb0a0f56677a86dbddec9974b2` | postgres | postgres | postgres owner + service_role EXECUTE | postgres owner only | PASS |
| `admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | SP2 | SP2 | `60301f5e0b290117105bc9637f10d3ce` | `60301f5e0b290117105bc9637f10d3ce` | postgres | postgres | postgres owner + service_role EXECUTE | postgres owner only | PASS |
| `admin_set_event_active(uuid,boolean)` | SP2 | SP2 | `b547b0c8d2b056273b10fe57f78f89c0` | `b547b0c8d2b056273b10fe57f78f89c0` | postgres | postgres | postgres owner + service_role EXECUTE | postgres owner only | PASS |

For all three functions:

- `SEARCH_PATH MATCH = YES` (`public, pg_temp`);
- `BODY MATCH = YES`;
- `SIGNATURE MATCH = YES`;
- `OWNER MATCH = YES` (`postgres`);
- return type, volatility, argument defaults and business logic remain encoded in the identical full-definition fingerprints;
- the only approved delta is removal of `service_role EXECUTE`; PUBLIC, anon and authenticated remain denied.

The independently compared normalized body fingerprints remain:

- create: `9ad97eb12fbb4aeff35845e12a3b6231`;
- update: `196433b57ceb24f509b949e662742cd1`;
- set active: `725ac582182c0861e0d5e36c5025d393`.

### 27.3 Revised migration and frozen SHA-256

Only `supabase/migrations/20260913100000_harden_event_management_rpcs.sql` was revised in migration scope. The three unintended legacy path alterations were removed. The four approved active RPC definitions, the deferred public readers, application files and historical migrations were not changed by 2B-1R.

Revised frozen SHA-256:

```text
554BD4D887F03040AD9DADD567BB78AB5536330785E1C325D79CA8A3EE637886
```

Any further edit to this migration invalidates this hash and requires another complete local retest.

### 27.4 Active RPC hardening remains unchanged

The four active target definition fingerprints after the clean reset are unchanged from the approved implementation:

| Active RPC | Revised local target fingerprint | Path | Effective client ACL |
|---|---|---|---|
| `admin_create_event_v2(...)` | `44c5a76fb1eecab62462ad0efc014f54` | SP1 | authenticated only |
| `admin_update_event_v2(...)` | `b87b87d6842c77238f4806073436fabb` | SP1 | authenticated only |
| `admin_set_event_active_v2(uuid,boolean)` | `6c9df46f20e0caf905d65c9928cb63d1` | SP1 | authenticated only |
| `admin_list_events_v1(...)` | `e9fbe38591aa39b760d3c5e6e9a0be52` | SP1 | authenticated only |

Tenant authorization, active membership handling, single-active bridge behavior, event/lane consistency and instructor read-only behavior are unchanged from the approved 2B-1 implementation.

### 27.5 Required local contract and regression evidence

- clean local DB reset with every migration: PASS;
- focused SAAS-9D-2B-1R SQL: 32/32 PASS;
- exact legacy ACL-only/path/fingerprint contract: 3/3 PASS within focused check 5;
- global role, missing membership, pending/suspended membership and instructor matrix: PASS;
- event/lane mismatch and atomic denial: PASS;
- zero/one/two-active single-tenant bridge cases: PASS;
- SAAS-9D-2A and public Events regression: PASS;
- full Supabase DB suite: 29 files / 852 tests PASS;
- Node full suite: 734/734 PASS;
- TypeScript `tsc --noEmit`: PASS;
- production build: PASS;
- focused Events/admin-action/deadline Playwright: 14/14 PASS;
- `git diff --check`: PASS.

The known Next.js middleware-to-proxy deprecation warning and Node module-type warnings remain unrelated baseline diagnostics.

### 27.6 Concurrency and cleanup

- deterministic executions: 52/52 PASS;
- stress iterations: 50/50 PASS;
- deadlocks `40P01`: 0;
- lock timeouts `55P03`: 0;
- serialization failures `40001`: 0;
- unexpected SQLSTATE: 0;
- final invariant violations: 0;
- protected function fingerprints unchanged: true;
- harness cleanup complete: true;
- temporary harness logs removed: true.

Independent post-check found zero remaining SAAS-9D-2B-1 fixtures in auth users, profiles, tenants, tenant memberships, shooting lanes, events, event lanes, event registrations and audit logs. Playwright temporary files remaining: 0.

### 27.7 SECURITY DEFINER inventory delta

The public-schema `SECURITY DEFINER` count remains 73.

- four active RPC definitions changed exactly as approved;
- three legacy bodies, signatures, owners and SP2 paths are unchanged;
- three legacy ACLs changed only by removing service-role EXECUTE;
- the four internal cores are owner-only `SECURITY INVOKER` functions;
- all other 66 `SECURITY DEFINER` definitions/metadata/ACLs remain protected by the migration snapshot and postflight comparison;
- both deferred public reader fingerprints remain frozen and unchanged.

### 27.8 Production preflight retry requirements

No production preflight was rerun in 2B-1R. A separately authorized retry must use the new frozen SHA and repeat the read-only production fingerprints, exact SP2 legacy paths, zero-caller inventory, owner/ACL inventory, membership/data invariants, migration history, lock baseline and `supabase db push --linked --dry-run`. It must show only `20260913100000_harden_event_management_rpcs.sql` pending. The actual push remains forbidden without later explicit approval.

### 27.9 Final verdicts

SAAS-9D-2B-1R LOCAL: **PASS**

4 ACTIVE RPC HARDENING: **PASS**

3 LEGACY RPC ACL-ONLY: **PASS**

LEGACY SEARCH_PATH PRESERVED: **PASS**

LEGACY BODY PRESERVED: **PASS**

CONCURRENCY: **PASS**

FULL REGRESSION: **PASS**

READY FOR PRODUCTION PREFLIGHT RETRY: **GO**

READY FOR PRODUCTION PUSH: **NO**

READY FOR SAAS-9D-2B-2: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 26. Historical production preflight & deployment readiness — superseded SHA

Preflight date: 2026-09-13 (Europe/Warsaw). All production database operations in this section were read-only. `supabase db push --linked --dry-run` was executed, but the actual push was not executed.

### 26.1 Working tree reconciliation

Repository root is `C:/Users/Mpios/Desktop/APP Krutla/APP Krutla/csk-booking`, branch `main`, baseline HEAD `b37386902b42c12f6902de27e172e516c69ed9d4`.

The working tree contains exactly seven expected files, not eight:

1. `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md`;
2. `SAAS_9D_2B1_EVENT_MANAGEMENT_RPC_HARDENING_REPORT.md`;
3. `supabase/migrations/20260913100000_harden_event_management_rpcs.sql`;
4. `supabase/tests/20260913100000_harden_event_management_rpcs_test.sql`;
5. `supabase/tests/20260816143000_harden_public_function_execute_acl_test.sql`;
6. `supabase/tests/20260911100000_tenant_aware_events_rls_test.sql`;
7. `supabase/tests/20260912100000_harden_event_registration_rpcs_test.sql`.

There is no eighth file, unrelated file, temporary artifact or unexpected scope. The four tracked changes are substantive test/plan changes rather than CRLF-only changes. `git diff --check` passes; Git reports only harmless future LF-to-CRLF conversion warnings.

### 26.2 Frozen migration SHA-256

`supabase/migrations/20260913100000_harden_event_management_rpcs.sql`:

```text
4B5478AAEA230F2A9BBEA88FE9291170A2EC17F4512076431E1C37B954B53DE4
```

The migration was not modified after this hash was captured.

### 26.3 Exact seven-surface function scope

| Function | Type | Production/expected baseline fingerprint | Target fingerprint | Current authorization/grant | Target authorization/grant | Path current -> target |
|---|---|---|---|---|---|---|
| `admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | body hardening | `6b8d29b11797a346ae9387a9bd3ec6b9` | `44c5a76fb1eecab62462ad0efc014f54` | global `profiles.role`; authenticated | sole-active tenant + active admin/employee membership; authenticated | SP1 -> SP1 |
| `admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | body hardening | `a525123389f3a646cd3da6f26e466ed5` | `b87b87d6842c77238f4806073436fabb` | global `profiles.role`; authenticated | target event tenant + active admin/employee membership; authenticated | SP1 -> SP1 |
| `admin_set_event_active_v2(uuid,boolean)` | body hardening | `ad56e445e74634f540425d92ff93acb1` | `6c9df46f20e0caf905d65c9928cb63d1` | global `profiles.role`; authenticated | target event tenant + active admin/employee membership; authenticated | SP1 -> SP1 |
| `admin_list_events_v1(text,text,text,integer,integer)` | body hardening | `7972f35024b6202a149afbe09f50d5a2` | `e9fbe38591aa39b760d3c5e6e9a0be52` | global `profiles.role`; authenticated | sole-active tenant + active admin/employee/instructor membership; authenticated | SP1 -> SP1 |
| `admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | ACL-only target, but see blocker below | `26f51acb0a0f56677a86dbddec9974b2` | `3285a68343d073a378d72ff31279ac39` | global legacy check; service role | owner-only; body inaccessible to clients/service | SP2 -> SP1 |
| `admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | ACL-only target, but see blocker below | `60301f5e0b290117105bc9637f10d3ce` | `a733f2b8724f6f79abb72f823d939afd` | global legacy check; service role | owner-only; body inaccessible to clients/service | SP2 -> SP1 |
| `admin_set_event_active(uuid,boolean)` | ACL-only | `b547b0c8d2b056273b10fe57f78f89c0` | `d572eaf4301f207a148c25142e972b66` | global legacy check; service role | owner-only; body inaccessible to clients/service | SP2 -> SP1 |

All seven are and remain owned by `postgres` and remain `SECURITY DEFINER`. SP1 is `pg_catalog, public, pg_temp`; SP2 is `public, pg_temp`. The apparent legacy full-definition fingerprint change is exclusively the approved search-path normalization. Their bodies are unchanged after CRLF/CR normalization:

| Legacy body | Production | Target local | Result |
|---|---|---|---|
| `admin_create_event` | `9ad97eb12fbb4aeff35845e12a3b6231` | `9ad97eb12fbb4aeff35845e12a3b6231` | PASS |
| `admin_update_event` | `196433b57ceb24f509b949e662742cd1` | `196433b57ceb24f509b949e662742cd1` | PASS |
| `admin_set_event_active` | `725ac582182c0861e0d5e36c5025d393` | `725ac582182c0861e0d5e36c5025d393` | PASS |

The four renamed `__saas9d2b1_core` implementations are an internal part of these four active surfaces: they are `SECURITY INVOKER`, owner-only and have no PUBLIC, anon, authenticated or service-role EXECUTE. No other business function is modified.

**Blocking scope discrepancy:** the mandatory production-preflight contract classifies the three legacy changes as ACL-only and requires each legacy `search_path` to remain unchanged. The target migration additionally executes `ALTER FUNCTION ... SET search_path=pg_catalog,public,pg_temp` for all three, changing SP2 to SP1. This is a security-hardening metadata change, but it is still outside the newly required ACL-only definition. Therefore exact final scope is not approved by this preflight.

### 26.4 Normalized production fingerprints

Production normalized definition fingerprints equal the frozen expected baseline for all four active functions: 4/4 PASS. The three legacy normalized body fingerprints are unchanged: 3/3 PASS. Frozen public reader fingerprints also remain unchanged:

- `get_public_event_availability_v1()` = `40adf74cb5adec5df3b4745fc7851433`;
- `get_public_event_list_v2(text,text,integer,integer)` = `fe075d7057149b0a0bad0129419a3e99`.

### 26.5 Legacy ACL-only proof and callers

Repository caller search found exactly one active application caller for each active RPC, all in `app/admin/events/page.tsx`, and zero TypeScript/JavaScript callers for each legacy RPC. No server or service-role caller requires any of the three legacy grants.

Current legacy ACL is owner `postgres` plus `service_role EXECUTE`; PUBLIC, anon and authenticated are denied. Target ACL is owner-only; PUBLIC, anon, authenticated and service role are denied. Signature, owner and normalized body remain unchanged. Removing service-role EXECUTE is compatible with the deployed application.

However, the mandatory proof also requires unchanged `search_path`. Current is SP2 and target is SP1 for all three legacy functions. Consequently the ACL result itself is correct, but the requested **ACL-only cleanup proof fails 0/3 on the unchanged-search-path condition**. This is the sole preflight blocker.

### 26.6 Fresh production data baseline

| Check | Production result |
|---|---|
| active tenants | 1 (`csk`) |
| memberships | 9 |
| membership roles | admin 1; user 8 |
| membership statuses | active 9 |
| duplicate memberships | 0 |
| orphan membership tenant/user | 0 / 0 |
| unknown role/status | 0 / 0 |
| events | 11 |
| event lanes | 9 |
| shooting lanes | 11 |
| orphan event tenant | 0 |
| orphan event-lane tenant | 0 |
| event-lane vs event tenant mismatch | 0 |
| event-lane vs shooting-lane tenant mismatch | 0 |

No production data blocker was found.

### 26.7 Active-single-tenant bridge

Production has exactly one active tenant, `csk`. `active_single_tenant_id_v1()` is owner-only and returns an ID only when exactly one tenant is active. Local focused tests prove one active tenant resolves CSK, zero active tenants fail closed and more than one active tenant fails closed. No second-active-tenant production test was performed.

Create locks the tenant registry rows `FOR SHARE` before resolving the bridge and authorizing the membership. Admin list retains its `STABLE`, single-statement snapshot semantics. The bridge is concurrency-safe for the currently approved single-active runtime and remains temporary until trusted routing in SAAS-9E.

### 26.8 Staff authorization and global-role negative case

The target uses `auth.uid()` and active `tenant_memberships`, never global `profiles.role` alone:

- create/update/set-active: active `admin` or `employee` membership;
- list: active `admin`, `employee` or `instructor` membership;
- no membership, pending, suspended and ordinary user: DENY;
- global legacy admin profile without active membership: DENY for create/update/set-active/list.

### 26.9 Event create

`admin_create_event_v2` keeps its signature. It resolves the approved sole-active tenant, requires an active admin/employee membership, validates every requested lane against that tenant, explicitly writes `events.tenant_id` and `event_lanes.tenant_id`, and stabilizes tenant resolution with row-share locks. A Tenant B lane while operating in Tenant A is denied before mutation.

### 26.10 Event update

`admin_update_event_v2` derives tenant from the locked event, authorizes active admin/employee membership in that tenant, validates replacement lanes against the same tenant and explicitly writes the event tenant to replacement `event_lanes`. Admin/Employee A can update Event A and cannot update Event B.

### 26.11 Set active

`admin_set_event_active_v2` derives tenant from the event. Active admin/employee membership is required. Global profile role without membership, pending/suspended membership and missing membership are denied. Existing no-change and conflict behavior is preserved.

### 26.12 Admin listing

`admin_list_events_v1` resolves the sole active tenant, authorizes admin/employee/instructor membership and applies tenant predicates to base rows, totals and lane relations in the database. It is not a global list followed by frontend filtering.

### 26.13 Instructor scope

Instructor retains only the existing tenant-scoped read/list capability. Instructor does not gain create, update or set-active. Cross-tenant access is denied. SEC-008 and the future instructor assignment model are unchanged.

### 26.14 Event/lane consistency

Create, update and lane replacement reject Event Tenant A plus Lane Tenant B atomically. Reservation, lane-block and event conflict reads are scoped to the same derived tenant. Composite tenant foreign keys remain the independent integrity layer.

### 26.15 Public contract regression

The two public readers are unchanged, remain available without a membership requirement and keep their PII-free DTOs. Production `/events` rendered successfully without 5xx, and local focused SQL/Playwright coverage confirms anon/authenticated availability and no public mutation expansion.

### 26.16 Caller compatibility

Active caller counts are exactly one per active RPC and zero per legacy RPC. All public signatures, argument names/defaults and business response shapes are unchanged. No Next.js/API change or new `tenant_id` argument is needed. Old application + target DB is compatible after the already completed membership backfill.

### 26.17 ACL, owner and search path

For every active wrapper, target effective grants are authenticated only; PUBLIC, anon and service role are denied. For every internal core and legacy RPC, target is owner-only. All affected functions are postgres-owned and use SP1 after the migration. No grant is widened.

### 26.18 SECURITY DEFINER inventory

Fresh production inventory after SAAS-9D-2A contains exactly 73 public-schema `SECURITY DEFINER` functions. Its CR-normalized fingerprint is `a27145dc2ec5635eb93de73fc904af13`.

The local target also contains exactly 73 definers. Its corresponding target fingerprint is `b9b4d52ea4a0de7fe96aad19230e7ae2`. The allowlisted delta is limited to the four active wrapper definitions plus the approved search-path metadata of the three legacy functions. The four internal cores are invokers, so the total remains 73. No unexpected definer appears.

### 26.19 Temporary CSK defaults

All seven approved compatibility defaults remain present on `email_deliveries`, `event_lanes`, `event_registrations`, `events`, `lane_blocks`, `reservations` and `shooting_lanes`.

| Table | Active writer | Default | Tenant explicitly set/derived | Default still needed now? |
|---|---|---|---|---|
| `events` | `admin_create_event_v2` | CSK | bridge tenant explicitly written | no for this active writer; retained for other legacy compatibility |
| `event_lanes` | create/update V2 cores | CSK | derived event/bridge tenant explicitly written | no for these active writers; retained for other legacy compatibility |

**REMOVE DEFAULT BEFORE TENANT-AWARE WRITER CUTOVER AND BEFORE SECOND TENANT** remains a mandatory later gate. 2B-1 removes no default.

### 26.20 Fresh local concurrency evidence

The unchanged frozen migration was rechecked against the isolated local database after the production preflight:

- deterministic executions: 52/52;
- stress iterations: 50/50;
- deadlocks `40P01`: 0;
- lock timeouts `55P03`: 0;
- serialization failures `40001`: 0;
- unexpected SQLSTATE: 0;
- cross-tenant lane attachment: 0;
- broken final invariants: 0;
- protected function fingerprints unchanged: true;
- cleanup complete: true;
- temporary logs removed: true.

### 26.21 Migration history

`supabase migration list --linked` shows LOCAL = REMOTE through `20260912100000`. The only local-only/pending migration is `20260913100000`. There is no remote-only migration or divergence. No migration repair was performed.

### 26.22 Dry-run

`supabase db push --linked --dry-run` completed successfully and reported exactly:

```text
Would push these migrations:
 • 20260913100000_harden_event_management_rpcs.sql
Finished supabase db push.
```

The CLI update notice (`2.109.1` installed, `2.117.0` available) is informational and not a deployment blocker. The actual database push was not executed.

### 26.23 Production runtime baseline

Read-only browser smoke passed for public Booking, public Events, login, Account, Admin dashboard, Reservations, Calendar, Reports, Admin Events and Check-in. Admin Events rendered the create form, lane assignments, event list and the existing Edit, Show participants and Activate/Hide controls. No control that creates, edits, activates or deactivates an event was submitted. No 5xx or runtime blocker was observed.

### 26.24 Deployment and lock risk

| Risk | Rating | Basis |
|---|---|---|
| transactional rename/create wrappers | MEDIUM | brief catalog/function lock; fail-closed fingerprint gates |
| active-single bridge | MEDIUM | temporary architecture, but exact-one guard, membership check and create row locks are tested |
| create/update/set-active/list behavior | MEDIUM | critical operational paths, unchanged signatures/contracts, full local regression |
| event/lane consistency | LOW | pre-mutation checks plus composite tenant FKs |
| legacy ACL revoke | LOW | zero active callers |
| concurrency | LOW | 52/52 + 50/50, zero database concurrency errors |
| caller compatibility | LOW | no application change and stable signatures |

Fresh production lock check found zero non-idle competing sessions, zero transactions older than five minutes and zero ungranted locks. The small current relations (`events` 122,880 bytes, `event_lanes` 90,112 bytes) and absence of table backfill keep data-lock risk low. A low-traffic deployment window is sufficient; a maintenance window is not required. STOP if the pre-push fingerprint, migration history, lock baseline or SHA changes.

### 26.25 Remaining blockers and final verdicts

One preflight blocker remains: all three legacy functions change `search_path` even though this preflight requires an ACL-only change with unchanged path. The successful dry-run does not override that scope gate. The migration must not be pushed in its current form. Any decision to remove the three `ALTER FUNCTION ... SET search_path` statements, or to explicitly approve SP2 -> SP1 as part of scope, requires a new reviewed instruction; modifying the migration would require a complete local retest and a new SHA-256/preflight.

SAAS-9D-2B-1 PRODUCTION PREFLIGHT: **FAIL**

WORKING TREE SCOPE: **PASS**

NORMALIZED FINGERPRINTS: **PASS**

FINAL FUNCTION SCOPE: **FAIL — legacy search_path change exceeds ACL-only gate**

LEGACY ACL-ONLY CLEANUP: **FAIL — ACL is correct, but search_path is changed for 3/3**

ACTIVE-SINGLE-TENANT BRIDGE: **PASS**

STAFF TENANT ISOLATION: **PASS**

GLOBAL ROLE BYPASS: **REMOVED IN TARGET**

EVENT/LANE CONSISTENCY: **PASS**

INSTRUCTOR SCOPE: **UNCHANGED**

PUBLIC CONTRACT: **PASS**

CALLER COMPATIBILITY: **PASS**

READY FOR PRODUCTION PUSH: **NO**

READY FOR SAAS-9D-2B-2: **NO-GO until 2B-1 production PASS and checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## Current controlling verdict after SAAS-9D-2B-1R

Section 26 records the correctly stopped production preflight for the superseded SHA. The later local 2B-1R correction and complete revalidation above are now authoritative for the migration candidate.

SAAS-9D-2B-1R LOCAL: **PASS**

READY FOR PRODUCTION PREFLIGHT RETRY: **GO**

READY FOR PRODUCTION PUSH: **NO**

READY FOR SAAS-9D-2B-2: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## Final controlling verdict after SAAS-9D-2B-1R production preflight retry

The completed evidence in **SAAS-9D-2B-1R — PRODUCTION PREFLIGHT RETRY** supersedes the historical failed preflight and the earlier local-only controlling verdict. The reviewed SHA is unchanged, migration history is aligned, the corrected legacy contract is ACL-only with its SP2 path and body preserved, and the dry-run reports only `20260913100000_harden_event_management_rpcs.sql`. No production push was performed.

SAAS-9D-2B-1 PRODUCTION PREFLIGHT RETRY: **PASS**

WORKING TREE SCOPE: **PASS**

SHA: **PASS**

4 ACTIVE RPC FINGERPRINTS: **4/4 PASS**

3 LEGACY ACL-ONLY: **PASS**

LEGACY SEARCH_PATH: **PRESERVED**

LEGACY BODY: **PRESERVED**

ACTIVE-SINGLE-TENANT BRIDGE: **PASS**

STAFF TENANT ISOLATION: **PASS**

GLOBAL ROLE BYPASS: **REMOVED IN TARGET**

EVENT/LANE CONSISTENCY: **PASS**

INSTRUCTOR SCOPE: **UNCHANGED**

CALLER COMPATIBILITY: **PASS**

READY FOR PRODUCTION PUSH: **YES**

READY FOR SAAS-9D-2B-2: **NO-GO until 2B-1 production PASS and checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## Final controlling verdict after production deployment

The production deployment and post-deploy evidence recorded in **SAAS-9D-2B-1 — production deploy and post-deploy verification** supersedes every earlier local-only and preflight verdict in this chronological report.

SAAS-9D-2B-1 PRODUCTION DEPLOY: **PASS**

SAAS-9D-2B-1 POST-DEPLOY VERIFICATION: **PASS**

READY FOR GIT CHECKPOINT: **YES**

READY FOR SAAS-9D-2B-2: **NO-GO until checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**
