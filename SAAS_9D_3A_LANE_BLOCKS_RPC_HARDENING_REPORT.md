# SAAS-9D-3A — Lane Blocks RPC Hardening Report

Date: 2026-09-14
Repository baseline: `c7f7f10e9d554ef6df3f1a528124d69bde6b8a10` (`main`)
Environment: local Supabase only
Production write: **NO**

## Scope

The implementation is limited to the three lane-block RPCs assigned to
SAAS-9D-3A in `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md`:

1. `admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)`
2. `admin_set_lane_block_active(uuid,boolean)`
3. `admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)`

SAAS-9D-3B, SAAS-9D-3C, SAAS-9D-4+, application code and production are
unchanged.

## Implementation

Migration:

- `supabase/migrations/20260915100000_harden_lane_block_rpcs.sql`
- SHA-256: `BC82409F794647E435EE4465A90AB740F3D2550F2E20390DFD3507F665F332F1`

Each existing implementation is retained as an inaccessible
`SECURITY INVOKER` core. A wrapper with the original public name and signature:

- derives `tenant_id` from the requested lane or locked lane block;
- uses `get_my_tenant_role_v1(tenant_id)` as the authorization authority;
- allows only an active `admin` or `employee` membership in an active tenant;
- denies instructor, ordinary user, pending, suspended, absent-membership and
  global-profile-role-only callers;
- rejects a proposed update lane whose tenant differs from the block tenant;
- never accepts a caller-supplied tenant identifier;
- preserves the existing JSON response shape and business result codes.

The retained business cores now:

- write `lane_blocks.tenant_id` explicitly on create;
- tenant-filter reservation, event-lane and event conflict reads;
- tenant-filter the lane lookup used by update/activation;
- tenant-filter block updates;
- preserve the existing globally ordered family lock and exclusion-constraint
  behavior.

Public wrappers remain `postgres`-owned, `VOLATILE`, `SECURITY DEFINER`, with
`search_path=pg_catalog, public, pg_temp`. Their ACL remains minimal:

| Role | EXECUTE |
|---|---|
| PUBLIC | DENY |
| anon | DENY |
| authenticated | ALLOW |
| service_role | DENY |

All three internal cores deny direct execution to these four roles.

Normalized post-migration wrapper fingerprints for a later production
preflight are:

| Signature | MD5 of normalized `pg_get_functiondef` |
|---|---|
| `admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)` | `8fc6354e5d45c66e44a5cd86f0097db3` |
| `admin_set_lane_block_active(uuid,boolean)` | `de43df8af1f677f60ffbe27738de3d04` |
| `admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)` | `45ad503f604b6547d8b0f64da88dc4f7` |

## Migration guards

The migration is transactional and fails closed on:

- missing tenant authorization helper;
- an existing planned core name;
- lane/block tenant inconsistency;
- normalized CRLF/CR-to-LF fingerprint drift for any of the three original RPCs;
- owner, volatility, `SECURITY DEFINER`, search-path or ACL drift;
- unrelated `SECURITY DEFINER` definition/metadata/ACL drift;
- any change to the approved `SECURITY DEFINER` count;
- any change to the seven temporary CSK compatibility defaults;
- any lane-block business-data mutation during migration.

The migration changes definitions and ACL only. It performs no business-data
backfill.

## Tests changed

- Added `supabase/tests/20260915100000_harden_lane_block_rpcs_test.sql` with
  35 focused assertions.
- Updated `supabase/tests/20260816143000_harden_public_function_execute_acl_test.sql`
  to inventory the three new inaccessible cores (111 -> 114 functions).
- Updated `supabase/tests/20260910120000_tenant_aware_booking_rls_test.sql`
  to replace the historical expected lane-block bypass with the hardened denial.

No existing test was removed or weakened.

## Security and tenant results

- Tenant A admin/employee -> Lane or Block A: **ALLOW**.
- Tenant A staff -> Lane or Block B: **DENY**, no mutation.
- Block A -> proposed Lane B: **DENY**, no reparenting or contamination.
- Global `profiles.role=admin` without membership: **DENY**.
- Pending membership: **DENY**.
- Suspended membership: **DENY**.
- No membership: **DENY**.
- Instructor/user: **DENY**.
- Active Tenant B admin after controlled active-tenant switch in a rolled-back
  test: **ALLOW** only for Tenant B.
- Mismatched `(tenant_id,lane_id)` block row: rejected by composite FK.
- Reservation and event conflicts: preserved and tenant-bound.
- Seven compatibility defaults: **7/7 unchanged**.
- Approved public `SECURITY DEFINER` count: **70 unchanged**.

## Verification results

| Verification | Result |
|---|---|
| Local `supabase db reset --local` | PASS |
| Focused SAAS-9D-3A SQL | PASS — 35/35 |
| Focused ACL + historical 9C contract rerun | PASS — 112/112 |
| IDOR / cross-tenant / membership status matrix | PASS |
| Full cross-writer concurrency | PASS — 52/52 deterministic |
| Concurrency stress | PASS — 50/50 |
| Deadlock `40P01` | 0 |
| Lock timeout `55P03` | 0 |
| Serialization failure `40001` | 0 |
| Cross-writer invariant violations | 0 |
| Concurrency fixture cleanup | PASS |
| Full Supabase DB suite | PASS — 33 files, 1007 tests |
| All Node tests | PASS — 739/739 |
| TypeScript `tsc --noEmit` | PASS |
| Production build | PASS |
| Focused Playwright lane-family/admin regression | PASS — 5/5 |
| Local synthetic fixture post-check | PASS — 0 remaining |
| `git diff --check` | PASS |

Build retained the known Next.js `middleware` -> `proxy` deprecation warning.
No new warning or failure was introduced by SAAS-9D-3A.

## Compatibility and regression assessment

- Function names and identity argument signatures are unchanged.
- Browser callers still send exactly the existing lane/block arguments.
- No `tenant_id` argument was added.
- Existing success/error JSON contracts are preserved.
- Booking, Reservations, Events and lane-family admin behavior passed DB,
  Node, build, cross-writer and Playwright regression coverage.
- No application change is required for the local 9D-3A contract.

## Working-tree note

`AGENTS.md` was already modified outside this implementation and was not read
as authorization to change it, modified, staged, reverted or committed.
The existing planning-file modification also predates this implementation.
No staging, commit, push, link, production SQL or production deployment was
performed.

## Verdict

SAAS-9D-3A LOCAL: PASS

LANE BLOCK TENANT ISOLATION: PASS

GLOBAL ROLE BYPASS: REMOVED

CALLER COMPATIBILITY: PASS

CONCURRENCY: PASS

READY FOR SAAS-9D-3A PRODUCTION PREFLIGHT: GO

READY FOR SAAS-9D-3B: NO-GO until review

READY FOR PRODUCTION WRITE: NO

SECOND TENANT: NO-GO

SEC-004: OPEN

## Production deployment & post-deploy verification

Date: 2026-09-14
Authorized migration:
`20260915100000_harden_lane_block_rpcs.sql`
Production project: `yuyxfodozzpzrdzkmolu`

### Final deployment gate

Immediately before deployment, the fail-closed gate reconfirmed:

- SHA-256:
  `BC82409F794647E435EE4465A90AB740F3D2550F2E20390DFD3507F665F332F1`;
- LOCAL = REMOTE through `20260914150000`;
- exactly one pending migration: the authorized 9D-3A migration;
- all three normalized production fingerprints equal the frozen baselines;
- owner/search-path/volatility/ACL metadata matches for 3/3 targets;
- one active tenant;
- duplicate memberships: 0;
- orphan membership tenants/users: 0/0;
- null lane/block tenant ownership: 0/0;
- orphan lane blocks: 0;
- lane/block tenant mismatches: 0;
- compatibility defaults: 7/7;
- `SECURITY DEFINER` baseline: 70;
- pre-existing `__saas9d3a_core` objects: 0;
- dry-run pending set: exactly the authorized migration.

No gate differed, so the authorized production push proceeded.

### Deployment result

`supabase db push --linked` applied only
`20260915100000_harden_lane_block_rpcs.sql` and completed successfully.
No migration repair, additional migration, application deployment or Git write
was performed.

### Post-deploy database verification

| Check | Result |
|---|---|
| Migration history | PASS — LOCAL = REMOTE including `20260915100000` |
| Final `db push --linked --dry-run` | PASS — `Remote database is up to date` |
| Public wrapper target fingerprints | PASS — 3/3 |
| Wrapper owner/search path/ACL/membership authority | PASS — 3/3 |
| Internal cores | PASS — 3/3 `SECURITY INVOKER`, no client/application EXECUTE |
| Active tenant count | PASS — 1 |
| Duplicate memberships | PASS — 0 |
| Orphan memberships | PASS — 0 |
| Null lane/block tenant ownership | PASS — 0 |
| Orphan lane blocks | PASS — 0 |
| Lane/block tenant mismatch | PASS — 0 |
| Compatibility defaults | PASS — 7/7 |
| `SECURITY DEFINER` count | PASS — 70 |
| Unexpected `SECURITY DEFINER` drift | PASS — 0 |

The migration's transactional unchanged-definer snapshot guard also completed,
which confirms that no unrelated definer body, owner, search path or ACL was
changed by the deployment.

### Rollback-only production authorization matrix

A synthetic, uniquely identified 35-check matrix ran inside one transaction
and ended with the expected controlled rollback marker. No heavy concurrency or
stress test was performed.

- Admin A -> Lane/Block A: **ALLOW**.
- Admin A -> Lane/Block B: **DENY**.
- Employee A -> in-scope Lane/Block A: **ALLOW**.
- Employee A -> Lane/Block B: **DENY**.
- Global `profiles.role=admin` without active target membership: **DENY**.
- Pending membership: **DENY**.
- Suspended membership: **DENY**.
- No membership / ordinary user / instructor: **DENY**.
- Block Tenant A -> Lane Tenant B: **DENY**.
- Anonymous and service-role direct client execution: **DENY**.
- Same-tenant reservation/event conflict semantics: **PASS**.
- Idempotent activation/no-change contract: **PASS**.
- Composite tenant/lane integrity: **PASS**.
- Caller result-code/signature compatibility: **PASS**.

Result: **35/35 PASS, transaction rolled back**. An independent post-check
reported synthetic fixture remaining: **0**.

### Post-deploy runtime smoke

No mutating button, form submission or writer endpoint was invoked.

| Runtime area | Result |
|---|---|
| Booking | PASS — lane families loaded |
| Admin dashboard | PASS — operational dashboard loaded |
| Lane configuration | PASS — real lane hierarchy/configuration loaded |
| Lane blocks | PASS — resource list and existing blocks loaded |
| Calendar | PASS — resource hierarchy and calendar grid loaded |
| Reservations | PASS — filters and production list loaded |
| Events | PASS — public bounded list/empty state loaded |
| Account | PASS — authenticated account data loaded |
| Login | PASS — login form loaded |

No runtime error or 5xx was observed in these checks.

### Production conclusion

SAAS-9D-3A PRODUCTION DEPLOY: PASS

SAAS-9D-3A POST-DEPLOY: PASS

LANE BLOCK TENANT ISOLATION: PASS

GLOBAL ROLE BYPASS: REMOVED

LANE/BLOCK CONSISTENCY: PASS

CALLER COMPATIBILITY: PASS

SECURITY DEFINER DRIFT: 0

READY FOR GIT CHECKPOINT: YES

READY FOR SAAS-9D-3B PLANNING: GO

READY FOR SAAS-9D-3B IMPLEMENTATION: NO-GO until checkpoint/review

SECOND TENANT: NO-GO

SEC-004: OPEN

## Appendix: production preflight & deployment readiness

Date: 2026-09-14
Production project: `yuyxfodozzpzrdzkmolu`
Production access: read-only catalog/data query, CLI migration inspection,
`db push --dry-run`, and non-mutating browser/runtime inspection only
Production write: **NO**

### 1. Working tree

The repository root is
`C:/Users/Mpios/Desktop/APP Krutla/APP Krutla/csk-booking`, branch `main`, at
`c7f7f10e9d554ef6df3f1a528124d69bde6b8a10`.

The 9D-3A scope is limited to:

- `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md`;
- this implementation/report file;
- `supabase/migrations/20260915100000_harden_lane_block_rpcs.sql`;
- `supabase/tests/20260915100000_harden_lane_block_rpcs_test.sql`;
- the approved historical ACL test update;
- the approved historical tenant-aware booking RLS test update.

`AGENTS.md` remains an unrelated pre-existing modification. It was not
modified, reverted, staged or committed. No other untracked or temporary file
exists in the repository. `git diff --check` passes; the only emitted messages
are line-ending conversion notices, not diff errors.

### 2. Migration digest

`20260915100000_harden_lane_block_rpcs.sql` SHA-256:

`BC82409F794647E435EE4465A90AB740F3D2550F2E20390DFD3507F665F332F1`

The migration was not edited after the completed local regression run.

### 3. Exact function scope and normalized fingerprints

Normalization used for every fingerprint: `CRLF -> LF`, then `CR -> LF`.

| Function/signature | Current production | Expected baseline | Target | Resource-derived tenant |
|---|---:|---:|---:|---|
| `admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)` | `fba59c6dbe820ab5c81525bb4dc8659e` | `fba59c6dbe820ab5c81525bb4dc8659e` | `8fc6354e5d45c66e44a5cd86f0097db3` | `lane_id -> shooting_lanes.tenant_id` |
| `admin_set_lane_block_active(uuid,boolean)` | `58fd6523e0b2fa55c6e6afc2a33a1b1b` | `58fd6523e0b2fa55c6e6afc2a33a1b1b` | `de43df8af1f677f60ffbe27738de3d04` | `block_id -> lane_blocks.tenant_id` |
| `admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)` | `66f4ba1fb3fe7686b2a04f335851dc43` | `66f4ba1fb3fe7686b2a04f335851dc43` | `45ad503f604b6547d8b0f64da88dc4f7` | locked block tenant; proposed lane must have the same tenant |

All three production fingerprints exactly equal their frozen migration
baselines. The migration touches no function outside this approved scope.

Current production authorization for all three is the legacy
`auth.uid() + profiles.role in (admin, pracownik)` model. The target wrapper
requires `auth.uid()`, an active tenant membership, an allowed tenant role
(`admin`/`employee`), and equality with the resource-derived tenant. A
caller-supplied tenant identifier is neither accepted nor trusted.

For every production function above:

- owner: `postgres`;
- mode: `SECURITY DEFINER`, `VOLATILE`;
- search path: `pg_catalog, public, pg_temp`;
- `PUBLIC`: no EXECUTE;
- `anon`: no EXECUTE;
- `authenticated`: EXECUTE;
- `service_role`: no EXECUTE.

The target public wrappers preserve the same metadata and ACL. The renamed
cores become `SECURITY INVOKER` and have no direct EXECUTE grant to any of
those client/application roles.

### 4. Fresh production data baseline

The production read was executed through a read-only Management API query.

| Invariant | Result |
|---|---:|
| Tenants total / active | 1 / 1 |
| Tenant memberships | 9 |
| Active admin memberships | 1 |
| Active user memberships | 8 |
| Duplicate memberships | 0 |
| Orphan membership tenants | 0 |
| Orphan membership users | 0 |
| Shooting lanes | 11 |
| Shooting lanes with null tenant | 0 |
| Lane blocks | 3 |
| Lane blocks with null tenant | 0 |
| Orphan lane blocks | 0 |
| Lane/block tenant mismatches | 0 |

All required unknown/orphan/duplicate/mismatch counters are zero.

### 5. Tenant derivation, authorization and consistency

The target contract is confirmed by the migration and the completed local
35-assertion suite:

- create derives tenant ownership from the selected lane;
- activation derives it from the locked block;
- update derives it from the locked block and rejects a proposed lane from a
  different tenant;
- admin/employee with an active membership in Tenant A can mutate only
  Tenant A resources;
- Tenant A staff cannot mutate Tenant B lanes or blocks;
- global `profiles.role=admin` without the target active membership is denied;
- pending, suspended, missing-membership, instructor and ordinary-user cases
  are denied;
- cross-tenant lane/block reparenting and conflict contamination are denied.

The production database contains no pre-existing lane/block ownership
inconsistency that could block this target.

### 6. Caller compatibility

Repository caller inspection and local regression confirm unchanged names,
signatures, argument order and response contracts. No caller must supply a
new `tenant_id`, and no application/API deployment is required for 9D-3A.

### 7. Compatibility defaults and SECURITY DEFINER inventory

- temporary CSK compatibility defaults: **7/7 present**;
- current production `SECURITY DEFINER` count: **70**;
- expected count after 9D-3A: **70** (three public definers are replaced by
  three hardened public definers; their internal cores are invokers);
- unexpected preflight drift in the three targets: **0**.

The create core writes `lane_blocks.tenant_id` explicitly. It does not rely on
the temporary default, although the default intentionally remains in place.

### 8. Concurrency and regression evidence

No production stress test was run. The deployment readiness decision relies on
the completed local evidence: 52/52 deterministic concurrency checks, 50/50
stress runs, and zero deadlocks, lock timeouts, serialization failures or
broken invariants. Focused SQL is 35/35, the full DB suite is 1007/1007, Node is
739/739, TypeScript/build pass, focused Playwright is 5/5, and fixture cleanup
is zero.

### 9. Production runtime baseline

No form was submitted and no mutating action was invoked.

- `/`, `/booking`, `/events`, `/login`, `/account`, `/admin`,
  `/admin/lane-configuration`, `/admin/lane-blocks`, `/admin/calendar` and
  `/admin/reservations` returned HTTP 200 (including expected authenticated
  redirects where applicable).
- In the existing authenticated admin browser session, Dashboard, Lane Blocks,
  Lane Configuration, Calendar, Reservations and Account loaded their real
  production data and controls without runtime error.
- Booking loaded the available lane families; public Events loaded its bounded
  empty state without error.
- Login remained reachable. The existing authenticated session and account
  reader remained operational.

This is a non-mutating availability baseline, not a post-deployment behavior
test of the new writers.

### 10. Migration history and dry-run

`supabase migration list --linked` shows LOCAL = REMOTE through
`20260914150000`. There are no remote-only migrations and no additional local
pending migrations. The only pending row is:

`20260915100000_harden_lane_block_rpcs.sql`

`supabase db push --linked --dry-run` completed successfully and reported
exactly that one migration. No push was executed. The CLI version notice
(installed 2.109.1; 2.117.0 available) is informational and is not a deployment
blocker.

### 11. Deployment risk

| Risk | Rating | Basis |
|---|---|---|
| `CREATE OR REPLACE` / rename-wrapper transition | MEDIUM | Transactional migration with frozen fingerprints and rollback on any guard failure |
| Lane-block mutation behavior | MEDIUM | Critical staff writer; business cores retained and fully regressed |
| Staff authorization regression | MEDIUM | Authority changes from global role to active tenant membership |
| Cross-tenant exposure | LOW | Resource-derived tenant, membership gate and consistency checks passed |
| Caller compatibility | LOW | Public signatures and response contracts are unchanged |
| Lock/concurrency | LOW | Small function-catalog operation; production has only three lane blocks; local concurrency clean |

A low-traffic deployment window is sufficient. Stop and roll back the
transaction on any fingerprint, ACL, invariant, lock-timeout or unrelated
definer guard failure.

### 12. Production preflight blockers

None. All mandatory preflight gates passed. Production deployment still
requires separate explicit authorization.

### Production preflight verdict

SAAS-9D-3A PRODUCTION PREFLIGHT: PASS

WORKING TREE SCOPE: PASS

SHA: PASS

FUNCTION SCOPE: PASS

FINGERPRINTS: PASS

LANE BLOCK TENANT ISOLATION: PASS

GLOBAL ROLE BYPASS: REMOVED IN TARGET

LANE/BLOCK CONSISTENCY: PASS

CALLER COMPATIBILITY: PASS

CONCURRENCY: PASS

READY FOR PRODUCTION PUSH: YES

READY FOR SAAS-9D-3B: NO-GO until 3A production PASS and checkpoint/review

SECOND TENANT: NO-GO

SEC-004: OPEN
