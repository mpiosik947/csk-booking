# SAAS-9D-3C — Lane Family Writer / Helpers RPC Hardening

Date: 2026-09-15
Repository baseline: `0dfd03c5dd1013d1726160d0b13d7bcbe02e7bf4`
Environment: local Supabase only (`127.0.0.1:54322`)
Production write: **NO**

## Scope

The implementation covers exactly the seven functions assigned to SAAS-9D-3C:

1. `admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)`
2. `admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)`
3. `lane_booking_family_business_snapshot_v2(uuid)`
4. `normalize_lane_booking_family_payload_v2(jsonb)`
5. `validate_lane_booking_rule_capacity()`
6. `validate_shooting_lane_capacity_change()`
7. `validate_shooting_lane_hierarchy()`

No SAAS-9D-4+, application, RLS, table schema, compatibility-default, or
production change is included. `AGENTS.md` is unrelated and excluded.

## Migration

Created:

`supabase/migrations/20260917100000_harden_lane_family_writer_helpers.sql`

SHA-256:

`814F648620F04760874A29C1916104E900ADFFE000B19989282078B27F7C4884`

The migration is fail-closed. It verifies the seven pre-change normalized
fingerprints, signatures, owners, search paths, ACLs, trigger bindings,
relationship integrity, business row counts, the SECURITY DEFINER baseline,
and the seven compatibility defaults before changing function metadata/body.
Its postflight verifies target state, non-target drift, unchanged triggers,
unchanged business data counts, `67` definers, and `7/7` defaults.

## Authorization and tenant binding

The unchanged public V2 signature remains an authenticated-only SECURITY
DEFINER wrapper. Its closed SECURITY INVOKER core:

- derives `tenant_id` from `p_root_lane_id` in `shooting_lanes`;
- requires `get_my_tenant_role_v1(tenant_id) = 'admin'`, which implies an
  active membership;
- rejects a global `profiles.role=admin` without the active membership;
- rejects employee, instructor, ordinary user, pending, suspended, and
  membership-less callers;
- verifies all locked family IDs belong to the derived tenant;
- scopes lane updates and reservation, lane-block, event-lane, event, and audit
  effects to that tenant;
- does not accept caller-supplied `tenant_id` as authority.

Admin A can update Family A. Admin A cannot update Family B, inject a Lane B
into Family A, or create a Parent A / Child B hierarchy. The composite database
integrity constraints remain the final protection layer.

## Execution modes and ACL

| Function group | Result |
|---|---|
| Public active V2 writer | SECURITY DEFINER, `postgres`, SP1, authenticated-only EXECUTE |
| Internal V2 core | SECURITY INVOKER, `postgres`, SP1, no PUBLIC/anon/authenticated/service EXECUTE |
| Dormant legacy writer | SECURITY INVOKER, `postgres`, SP1, closed ACL |
| Snapshot and normalize helpers | SECURITY INVOKER, `postgres`, SP1, closed ACL |
| Three integrity triggers | unchanged definitions, SECURITY DEFINER, closed ACL |

Public signature and response codes (`updated`, `no_change`,
`stale_configuration`, controlled denials) remain compatible with the current
CSK application.

## Deterministic family comparison

Randomized regression exposed a pre-existing order dependency: normalized
payload IDs were UUID-sorted while the lock helper returned family IDs in
hierarchy order. A valid family could therefore be rejected as
`invalid_payload` for some UUID arrangements. The core now UUID-sorts the
locked family ID array before equality comparison. This is a correctness fix,
not a contract or authority expansion.

## Tests

Added:

- `supabase/tests/20260917100000_harden_lane_family_writer_helpers_test.sql`
- `supabase/tests/20260917100000_harden_lane_family_writer_helpers_concurrency.ps1`

Updated historical inventory/regression assertions only where 9D-3C changes
the approved function count, internal core inventory, or execution mode.

Results:

| Check | Result |
|---|---|
| Local reset and migration replay | PASS |
| Focused 9D-3C pgTAP | PASS — 34/34 |
| Cross-tenant / IDOR / membership matrix | PASS |
| Global-role negative test | PASS |
| Direct helper/legacy ACL denial | PASS |
| Concurrent same-family optimistic update | PASS — one winner, one stale |
| Concurrent mixed-tenant payload | PASS — denied, no contamination |
| Concurrent foreign-root operation | PASS — denied |
| Deadlocks / broken invariants | 0 / 0 |
| Full Supabase DB suite | PASS — 35 files, 1074 tests |
| Node full suite | PASS |
| TypeScript (`npx tsc --noEmit`) | PASS |
| Production build | PASS |
| Focused lane-family Playwright | PASS — 5/5 |
| `git diff --check` | PASS |
| Synthetic fixture post-check | PASS — profiles/tenants/lanes/audits all 0 |

Build retains the known Next.js middleware-to-proxy deprecation warning.
`npm audit --omit=dev` reports one unrelated MODERATE
`baseline-browser-mapping` denial-of-service advisory; no HIGH or CRITICAL
advisory was reported. There are no changed application files, so
changed-files ESLint is not applicable.

## Compatibility and residual gates

- Current single-tenant CSK runtime remains compatible.
- Compatibility defaults remain `7/7`; none is used as authorization authority.
- SECURITY DEFINER count changes exactly from `70` to `67`.
- Instructor scope is unchanged.
- Production preflight and production deployment require separate approval.
- SAAS-9D-4 must not start until 9D-3C production and checkpoint review.
- Second tenant remains blocked and SEC-004 remains open.

## Production preflight and deployment readiness

This section records the read-only production preflight performed on
2026-09-15. No migration, SQL write, migration repair, Git write, or production
fixture was executed.

### Project, repository, and migration gates

| Gate | Evidence | Result |
|---|---|---|
| Production project | Linked Supabase project `yuyxfodozzpzrdzkmolu`, name `csk-booking`, region `eu-central-1`, status `ACTIVE_HEALTHY` | PASS |
| Repository | `main` at `0dfd03c5dd1013d1726160d0b13d7bcbe02e7bf4` | PASS |
| Working-tree reconciliation | Canonical semantic diff contains only the 9D-3C implementation/test/report scope; `AGENTS.md` is unrelated and excluded | PASS |
| Migration SHA-256 | `814F648620F04760874A29C1916104E900ADFFE000B19989282078B27F7C4884` | PASS |
| Migration history | LOCAL = REMOTE through `20260916100000`; no remote-only rows | PASS |
| Pending migration | Exactly `20260917100000_harden_lane_family_writer_helpers.sql` | PASS |
| Linked dry-run | Would push exactly `20260917100000_harden_lane_family_writer_helpers.sql` | PASS |

The Windows `npx.cmd supabase` fallback was used for linked CLI reads because
the WSL Docker socket is unavailable. Docker-dependent local tests were not
repeated; the approved local results above remain the verification baseline.

### Exact seven-function production inventory

Production catalog metadata and normalized CRLF/CR-to-LF fingerprints were
verified with one read-only query in the authenticated Supabase SQL Editor.
All seven current definitions match the migration's fail-closed preflight
target.

| Function | Current normalized fingerprint | Current mode / owner / path | Current effective ACL | Migration target |
|---|---|---|---|---|
| `admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)` | `00fc387949410273a7cb33589cd8d1c6` | DEFINER / `postgres` / SP1 | authenticated only | Same public signature and ACL; thin DEFINER wrapper over closed INVOKER core |
| `admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)` | `c60876406d007491187869017df989b5` | DEFINER / `postgres` / SP1 | closed | INVOKER, body/signature/owner/path/closed ACL preserved |
| `lane_booking_family_business_snapshot_v2(uuid)` | `bc891bbdfab6d033fed72ece1c9fc193` | DEFINER / `postgres` / SP1 | closed | INVOKER, signature/owner/path/closed ACL preserved |
| `normalize_lane_booking_family_payload_v2(jsonb)` | `77eee4f69abb6bdf74f1529f8e21589a` | DEFINER / `postgres` / SP1 | closed | INVOKER, signature/owner/path/closed ACL preserved |
| `validate_lane_booking_rule_capacity()` | `78a6c1beb5048645a46d20d735324e2a` | DEFINER / `postgres` / SP1 | closed | Unchanged |
| `validate_shooting_lane_capacity_change()` | `96e0199a327831f40bec66c57d37f5ca` | DEFINER / `postgres` / SP1 | closed | Unchanged |
| `validate_shooting_lane_hierarchy()` | `dd3c97078341a74edc83ca79e9b19c0f` | DEFINER / `postgres` / SP1 | closed | Unchanged |

`SP1` means `search_path=pg_catalog, public, pg_temp`. The three expected
trigger bindings are present. The migration changes no trigger definition.

### Authorization, integrity, and compatibility readiness

- The active writer remains the only application-facing function in this
  scope. Its public signature and authenticated caller contract are unchanged.
- The new core derives the tenant from the root lane/family resource, requires
  an active tenant membership with the existing admin role, explicitly scopes
  all affected resources to that tenant, and never treats a supplied/default
  tenant value as authorization authority.
- A global `profiles.role=admin` without the matching active membership is
  denied. Pending, suspended, membership-less, employee, instructor, and user
  callers remain denied by the approved writer contract.
- Family membership, parent/child/root relationships, reservation conflicts,
  blocks, event-lane references, events, and audits are tenant-bound. The
  existing composite constraints remain the final cross-tenant guard.
- The dormant legacy writer has no active application caller. The two internal
  helpers are invoked by the protected writer path and remain closed to direct
  client/service execution after conversion to SECURITY INVOKER.
- All three trigger functions and their bindings remain unchanged.
- Production has exactly one active tenant and one active admin membership.
  Counts: tenants `1`, memberships `9`, shooting lanes `11`.
- Production integrity checks are clean: no membership duplicates/orphans or
  unknown role/status values; no lane tenant/null/parent mismatch; no invalid
  hierarchy; and no orphan/duplicate/overlapping booking rule, duration, or
  pricing records.
- Current SECURITY DEFINER count is `70`; the exact post-migration target is
  `67`. The net reduction is the legacy writer plus two internal helpers.
- Compatibility defaults are present `7/7` and are not authorization sources.

### Runtime and deployment risk

Read-only HTTP smoke returned HTTP 200 with no 5xx for `/`, `/booking`,
`/events`, `/login`, `/account`, `/admin`, `/admin/lane-configuration`,
`/admin/reservations`, `/admin/lane-blocks`, and `/admin/calendar`. Protected
routes were checked at the HTTP/redirect boundary; authenticated functional
behavior is covered by the approved local SQL, Node, build, and Playwright
evidence rather than by a production mutation.

Deployment risk is **MEDIUM** because the active administrative writer is a
security-sensitive transactional function. The migration performs function
DDL only: it does not rewrite tables or business data. Expected catalog locks
are short, so a maintenance window is not required; deploy in a low-traffic
window and stop on any preflight drift. Rollback is the repository-defined
function-definition reversal only if post-deploy verification fails; no data
rollback or migration repair is planned.

### Production preflight verdict

SAAS-9D-3C PRODUCTION PREFLIGHT: **PASS**

READY FOR PRODUCTION PUSH: **YES**

READY FOR SAAS-9D-4 PLANNING: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## Production deployment and post-deploy verification

The approved migration
`20260917100000_harden_lane_family_writer_helpers.sql` was deployed to the
linked production project `yuyxfodozzpzrdzkmolu`. The CLI applied exactly this
one migration and exited successfully. No migration repair or additional SQL
write was performed.

| Post-deploy check | Evidence | Result |
|---|---|---|
| Migration history | `20260917100000` is present on both LOCAL and REMOTE; no divergence | PASS |
| Final linked dry-run | `Remote database is up to date.` | PASS |
| Public active writer | Same signature; postgres-owned SP1 DEFINER wrapper; authenticated-only EXECUTE | PASS |
| Closed writer core | INVOKER; no client/service EXECUTE; membership-based tenant authorization and tenant predicates present | PASS |
| Legacy writer | SECURITY INVOKER, postgres-owned SP1, closed ACL | PASS |
| Two internal helpers | SECURITY INVOKER, postgres-owned SP1, closed ACL | PASS |
| Three trigger functions | All three normalized pre-deploy fingerprints unchanged | PASS — 3/3 |
| SECURITY DEFINER count | Exact target `67` | PASS |
| Unexpected SECURITY DEFINER drift | Migration's transactional snapshot/postflight completed and exact target count holds | 0 |
| Compatibility defaults | Exact approved bridge baseline remains | PASS — 7/7 |
| Caller compatibility | Public writer signature and authenticated ACL unchanged; application caller requires no change | PASS |
| Runtime HTTP smoke | `/`, Booking, Events, Login, Account, Admin, lane configuration, Reservations, lane blocks, Calendar all HTTP 200; no 5xx | PASS |
| Synthetic fixture | No production fixture was created during deployment verification | cleanup = 0 |

The production writer core now derives tenant authority from the lane-family
resource and requires the matching active admin membership. Global
`profiles.role` is absent from the authority path. Family members and all
reservation/block/event/audit effects are constrained to the derived tenant;
the existing composite hierarchy constraints remain the final guard. Combined
with the approved local 34/34 functional/security matrix and concurrency suite,
this confirms active-writer tenant isolation and hierarchy consistency without
performing an additional production mutation.

The two internal helpers remain compatible because their only supported path
runs inside the protected postgres-owned wrapper/core execution chain. The
dormant legacy writer has no active application caller and is no longer a
SECURITY DEFINER boundary.

## Final verdicts

SAAS-9D-3C LOCAL: **PASS**

LANE FAMILY TENANT ISOLATION: **PASS**

GLOBAL ROLE BYPASS: **REMOVED**

CALLER COMPATIBILITY: **PASS**

CONCURRENCY: **PASS**

SECURITY DEFINER: **70 -> 67**

COMPATIBILITY DEFAULTS: **7/7**

SAAS-9D-3C PRODUCTION PREFLIGHT: **PASS**

SAAS-9D-3C PRODUCTION DEPLOY: **PASS**

SAAS-9D-3C POST-DEPLOY: **PASS**

SECURITY DEFINER COUNT: **67**

UNEXPECTED SECURITY DEFINER DRIFT: **0**

READY FOR GIT CHECKPOINT: **YES**

READY FOR SAAS-9D-4 PLANNING: **GO**

READY FOR SAAS-9D-4 IMPLEMENTATION: **NO-GO until checkpoint/review**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**
