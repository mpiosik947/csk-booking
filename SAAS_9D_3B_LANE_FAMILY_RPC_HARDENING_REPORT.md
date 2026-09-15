# SAAS-9D-3B — Lane Family RPC Hardening Report

Date: 2026-09-14
Repository baseline: `e3cf1103eb943b274d66770d514ac55b59549068` (`main`)
Environment: local Supabase only
Production write: **NO**

## 1. Exact scope

The implementation changes exactly these existing public functions:

1. `admin_create_lane_booking_family_v1(jsonb)`
2. `admin_get_lane_booking_configuration_v1()`
3. `admin_get_lane_booking_configuration_v2()`

SAAS-9D-3C, SAAS-9D-4+, application code, historical migrations and
production are unchanged.

## 2. Fingerprints

Function definitions are fingerprinted after normalizing `CRLF -> LF` and
then `CR -> LF`. The migration fails before replacement if any frozen baseline
does not match.

| Function | Frozen baseline MD5 | Local target MD5 |
|---|---|---|
| `admin_create_lane_booking_family_v1(jsonb)` | `69ec76ae348f83387045a5c343dd906f` | `1fd4b47a640b52564568670d079e7659` |
| `admin_get_lane_booking_configuration_v1()` | `2684f7ea8a3b9eba6dae4d4f7aad653c` | `9c6b9b10c6de8359aca5d88981b52523` |
| `admin_get_lane_booking_configuration_v2()` | `5c729f01536d476a5c8b3cf0d9b40c62` | `ff748a9030e88f8e395805d30b33ac93` |

The transactional postflight snapshot verifies that no non-target
`SECURITY DEFINER` function definition or metadata changes.

## 3. Create-family tenant derivation

`admin_create_lane_booking_family_v1(jsonb)` retains its signature and payload
contract. A new family has no trusted existing resource from which ownership
can be derived, so the function resolves the exact single active tenant through
the approved compatibility bridge. It then requires an active `admin`
membership for `auth.uid()` in that tenant.

Every inserted root and child `shooting_lanes` row receives the resolved
`tenant_id` explicitly. Display-order calculation is tenant-scoped. The audit
row also receives the same explicit tenant. No caller-supplied tenant UUID is
accepted or trusted, and the temporary CSK column default is not used as an
authorization mechanism.

## 4. Active-single-tenant bridge

Focused tests prove the temporary bridge contract:

- zero active tenants: fail closed;
- exactly one active tenant: resolve deterministically;
- more than one active tenant: fail closed.

There is no `ORDER BY ... LIMIT 1` fallback. The bridge is temporary until the
trusted application tenant context is introduced in SAAS-9E and must not be
used to authorize a second tenant.

## 5. Staff authorization

The creator requires both authenticated identity and
`get_my_tenant_role_v1(resolved_tenant) = 'admin'`. This preserves the existing
admin-only business contract; it does not expand employee or instructor scope.
The legacy profile-role check remains as compatibility/defence in depth, but
cannot authorize without the active target membership.

The readers retain their existing effective admin-only contract and now also
require active tenant membership for the resolved tenant. Pending, suspended,
missing-membership and global-role-only callers are denied.

## 6. Global-role bypass removal

A global `profiles.role = 'admin'` is no longer sufficient for any of the
three targets. Negative tests cover global admin without membership, pending
membership, suspended membership and no membership. All deny without creating
or exposing tenant data.

## 7. Hierarchy consistency

Creation inserts the root and all children with one explicit tenant inside the
same transaction. Existing hierarchy validation remains active. The migration
preflight rejects pre-existing orphaned hierarchy rows, while focused and
concurrency tests prove:

- root and children remain in one tenant;
- Tenant A operations cannot create or expose Tenant B hierarchy;
- no orphan, sibling projection, duplicate child assignment or partial family
  survives a failure;
- all family/rule/duration/pricing writes remain atomic.

## 8. Reader tenant isolation

Both configuration readers resolve the exact active tenant, enforce the active
admin membership, and scope the root/resource selection to that tenant. All
nested booking rules, duration rows and pricing rows are reached only through
the tenant-scoped lane set. V2 scopes configuration-version and root counts to
the same tenant and reuses the hardened V1 result.

Tests with two tenant datasets confirm that Reader A returns zero Tenant B
resources or nested configuration.

## 9. DTO compatibility

No `tenant_id` was added to either response.

V1 remains `{ contract_version, resources }`. Each resource retains:
`lane_id`, `name`, `resource_kind`, `parent_lane_id`, `display_order`,
`is_active`, `max_shooters`, `whole_lane_bookable`, `positions_bookable`,
`booking_step_minutes`, `currency_code`, `online_bookable`,
`max_people_online`, `durations` and `pricing`, with the existing nested field
names, sorting and active/inactive semantics.

V2 remains `{ contract_version, families }`; each family retains
`root_lane_id`, `configuration_version` and the same resource DTO. Pricing,
duration, hierarchy and ordering representations are unchanged.

## 10. ACL, search path and owner

All three functions remain `postgres`-owned, `SECURITY DEFINER`, with
`search_path=pg_catalog, public, pg_temp`.

| Function | PUBLIC | anon | authenticated | service_role |
|---|---:|---:|---:|---:|
| create family | DENY | DENY | ALLOW | DENY |
| config reader V1 | DENY | DENY | DENY | DENY |
| config reader V2 | DENY | DENY | ALLOW | DENY |

Direct V1 execution is no longer part of the client contract; V2 remains the
application entry point and calls V1 internally. No grant was widened.

## 11. Caller compatibility

Repository inspection found the live application calls V2 without arguments
and the creator with the existing `p_family` payload. V2 internally calls V1.
All names, identity argument signatures and response shapes are unchanged, so
no application change or new `tenant_id` argument is required. The current
lane-configuration flow passed focused Playwright 5/5.

## 12. Compatibility defaults

All seven temporary CSK `tenant_id` defaults remain present and unchanged:
**7/7**. New family lanes and their audit entry receive tenant ownership
explicitly. Default removal remains a later gated cutover before activation of
a second tenant.

## 13. Cross-tenant tests

The 33 focused SQL assertions cover:

- Admin A -> family/config A: allow;
- Admin A -> family/config B: deny/no disclosure;
- employee and instructor: unchanged, no new creator access;
- global admin without membership: deny;
- pending, suspended and absent membership: deny;
- bridge states 0/1/>1;
- explicit tenant ownership for root, children and audit;
- tenant-scoped nested rules, durations and pricing;
- ACL, owner, mode, search path, fingerprints and exact DTO;
- rollback and fixture cleanup.

Result: **33/33 PASS**.

## 14. Concurrency

The dedicated local PowerShell harness exercised concurrent family creation,
simultaneous child assignment, Tenant A/B concurrent negative paths and
hierarchy integrity under race.

| Invariant | Result |
|---|---|
| Concurrent family create | PASS |
| Simultaneous child assignment | PASS |
| Tenant A/B concurrent negative | PASS |
| Hierarchy integrity under race | PASS |
| Deadlocks | 0 |
| Cross-tenant hierarchy | 0 |
| Duplicate/broken family invariants | 0 |
| Remaining fixture | 0 |

## 15. Regression

| Verification | Result |
|---|---|
| Local `supabase db reset` | PASS |
| Focused SAAS-9D-3B SQL | PASS — 33/33 |
| Focused ACL test | PASS — 17/17 |
| Concurrency harness | PASS |
| Full Supabase DB suite | PASS — 34 files, 1040 tests |
| All Node tests | PASS — 739/739 |
| TypeScript `tsc --noEmit` | PASS |
| Production build | PASS |
| Focused Playwright lane-family suite | PASS — 5/5 |
| Local synthetic fixture post-check | PASS — 0 remaining |
| `git diff --check` | PASS |

The full DB suite covers Booking, Reservations, lane blocks, Check-in, Events,
event registrations/management, public event readers, confirmation email and
reserve promotion. Build retains the known Next.js middleware-to-proxy warning;
Node retains only known module-type warnings. `npm audit --omit=dev` could not
be refreshed because external registry egress was not authorized; the last
known unrelated residual is the MODERATE transitive
`baseline-browser-mapping` advisory.

No JavaScript/TypeScript application file changed, so changed-files ESLint is
not applicable to this SQL/test/report-only slice.

## 16. SECURITY DEFINER inventory

Local post-migration inventory: **70**, as required. The three approved targets
remain definers, no new definer is introduced, unknown targets are zero, and
the migration's snapshot guard confirms zero unexpected non-target drift.
SAAS-9D-3C/4/5 functions are untouched.

## 17. Migration SHA

Migration:
`supabase/migrations/20260916100000_harden_lane_family_creation_readers.sql`

SHA-256:
`E7A6ABDE21384ED2CC37E6AB3E133A2D06701A43C2BD2E8A64C12736021EA4B7`

## 18. Production deployment and verification

The approved migration was deployed to production and verified:

- migration history: LOCAL = REMOTE through `20260916100000`;
- final `db push --linked --dry-run`: `Remote database is up to date`;
- target fingerprints, signatures, owner, search path and ACL: 3/3 PASS;
- active CSK tenant: exactly 1;
- membership and lane-hierarchy integrity findings: 0;
- compatibility defaults: 7/7;
- SECURITY DEFINER count: 70, unexpected drift: 0;
- production runtime smoke: 10/10 routes returned HTTP 200;
- exact focused production matrix in Supabase SQL Editor: 33/33 PASS;
- transaction: ROLLED BACK;
- remaining fixture: 0;
- production data persisted by the verification: 0.

The first linked-CLI attempt stopped before fixture creation because its login
role could not write `auth.users`. The exact existing matrix was subsequently
run as `postgres` in the production SQL Editor and completed through
`ok 33 - rollback removed every SAAS-9D-3B fixture` with no `ERROR` or
`not ok` result.

Any future rollback must be a reviewed forward migration restoring the captured
function definitions and ACL. Do not edit the applied migration or use migration
repair.

## 19. Git status

Expected SAAS-9D-3B working-tree scope:

- `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md`;
- this report;
- `supabase/migrations/20260916100000_harden_lane_family_creation_readers.sql`;
- `supabase/tests/20260916100000_harden_lane_family_creation_readers_test.sql`;
- `supabase/tests/20260916100000_harden_lane_family_creation_readers_concurrency.ps1`;
- focused updates to the historical ACL inventory and phased 9C test.

`AGENTS.md` is an unrelated modification and is excluded. It was not manually
edited, staged, reverted or committed for this task.

## 20. Final verdict

SAAS-9D-3B LOCAL: **PASS**

LANE FAMILY TENANT ISOLATION: **PASS**

CONFIG READERS TENANT ISOLATION: **PASS**

GLOBAL ROLE BYPASS: **REMOVED**

ACTIVE-SINGLE-TENANT BRIDGE: **PASS**

HIERARCHY CONSISTENCY: **PASS**

DTO COMPATIBILITY: **PASS**

CALLER COMPATIBILITY: **PASS**

CONCURRENCY: **PASS**

SECURITY DEFINER COUNT: **70**

SAAS-9D-3B PRODUCTION DEPLOY: **PASS**

SAAS-9D-3B POST-DEPLOY: **PASS**

ROLLBACK-ONLY MATRIX: **33/33 PASS**

FIXTURE CLEANUP: **0**

READY FOR FINAL SAAS-9D-3B GIT CHECKPOINT: **YES**

READY FOR SAAS-9D-3C PLANNING: **GO**

READY FOR SAAS-9D-3C IMPLEMENTATION: **NO-GO until checkpoint/review**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**
