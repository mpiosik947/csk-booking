# SAAS-9B-3 — Production Preflight and Final Technical Plan

Date: 9 September 2026
Repository: `C:\Users\Mpios\Desktop\APP Krutla\APP Krutla\csk-booking`
Baseline HEAD: `2b056bb3e74b0b8c1b92228ff01a67153e0677a6`
Mode: production read-only preflight and implementation planning only

No migration, SQL write, application change, deployment, commit, or push was performed. Production inspection used the existing linked Supabase session. The SQL transaction was explicitly `READ ONLY`; no credential or secret was printed or persisted in the repository.

## 1. Current production schema

SAAS-9B-2 is present and verified:

- `tenant_id uuid` exists on `shooting_lanes`, `reservations`, `lane_blocks`, `events`, `event_lanes`, `event_registrations`, `email_deliveries`, and `audit_logs`;
- the first seven columns are `NOT NULL` and retain the temporary canonical-CSK default;
- `audit_logs.tenant_id` is nullable and has no default;
- all eight simple foreign keys to `public.tenants(id)` are validated;
- one active tenant and the `tenants_single_active_runtime_guard` index remain present;
- `tenant_memberships` remains empty;
- there are no composite same-tenant foreign keys yet;
- no tenant-aware runtime authorization or application context exists yet.

Production security fingerprints remain:

| Surface | Fingerprint |
|---|---|
| public function definitions | `5c40e2dc79e940095c40e6cba72583e4` |
| RLS policies | `f5c428bd4e241af39f690c1aafcfad08` |
| table ACLs | `cf05faffa475999df163338c3c1e805f` |

These match the accepted post-SAAS-9B-2 baseline.

## 2. Data integrity preflight

Captured at `2026-09-09T17:54:39.474941+00:00`.

### Production volumes

| Table | Rows | Total bytes |
|---|---:|---:|
| `shooting_lanes` | 11 | 81,920 |
| `reservations` | 11 | 139,264 |
| `lane_blocks` | 3 | 81,920 |
| `events` | 11 | 90,112 |
| `event_lanes` | 9 | 73,728 |
| `event_registrations` | 25 | 286,720 |
| `email_deliveries` | 11 | 81,920 |
| `audit_logs` | 112 | 172,032 |
| `lane_pricing_rules` | 64 | 131,072 |

### Mandatory integrity checks

| Check | Result |
|---|---:|
| unknown tenant references | 0 |
| missing lane parent | 0 |
| lane/parent tenant mismatch | 0 |
| reservation without lane | 0 |
| reservation/lane tenant mismatch | 0 |
| reservation with NULL pricing rule | 0 |
| reservation with missing pricing rule | 0 |
| reservation/pricing-rule lane mismatch | 0 |
| lane block without lane | 0 |
| lane-block/lane tenant mismatch | 0 |
| event-lane without event | 0 |
| event-lane without lane | 0 |
| event-lane/event tenant mismatch | 0 |
| event-lane/lane tenant mismatch | 0 |
| registration with NULL event | 0 current rows |
| registration with missing event | 0 |
| registration/event tenant mismatch | 0 |

All mandatory data-integrity checks pass. Any nonzero result in the implementation-time rerun is a STOP condition.

## 3. Email message-type inventory

Current production inventory:

| `message_type` | Rows | Target contract |
|---|---:|---|
| `reservation_confirmation` | 11 | `record_id -> reservations.id` |

Schema and repository contracts additionally permit:

- `reservation_cancellation -> reservations.id`;
- `event_registration_confirmation -> event_registrations.id`.

Production checks:

| Check | Result |
|---|---:|
| unsupported message type | 0 |
| missing reservation target | 0 |
| reservation target tenant mismatch | 0 |
| missing event-registration target | 0 |
| event-registration target tenant mismatch | 0 |

The whitelist must contain exactly these three existing repository-backed message types. No future type is included.

## 4. Audit target/action inventory

Current target-type whitelist supported by actual repository contracts:

- tenant-scoped: `reservation`, `event_registration`, `lane_booking_family`;
- global/account: `profile`, `account`.

`account` currently has zero production rows but is an existing implemented contract for `account_anonymized`, not a speculative future type.

Current production pairs:

| Target type | Action | Rows | Class |
|---|---|---:|---|
| `event_registration` | `event_registration_cancelled_by_staff` | 1 | tenant |
| `event_registration` | `event_registration_cancelled_by_user` | 7 | tenant |
| `lane_booking_family` | `lane_booking_family_configuration_updated` | 14 | tenant |
| `profile` | `profile_admin_note_updated` | 1 | global |
| `profile` | `profile_contact_details_updated` | 2 | global |
| `profile` | `profile_identity_updated` | 2 | global |
| `profile` | `PROFILE_PERMISSIONS_VERIFICATION_UPDATED` | 5 | global |
| `profile` | `profile_role_changed` | 5 | global |
| `profile` | `PROFILE_ROLE_CHANGED` | 25 | global |
| `profile` | `PROFILE_VERIFICATION_CHANGED` | 25 | global |
| `profile` | `profile_verification_rejected` | 1 | global |
| `profile` | `profile_verification_verified` | 4 | global |
| `reservation` | `RESERVATION_ATTENDANCE_RESET` | 1 | tenant |
| `reservation` | `reservation_created` | 11 | tenant |
| `reservation` | `RESERVATION_NO_SHOW` | 4 | tenant |
| `reservation` | `RESERVATION_PAYMENT_STATUS_CHANGED` | 3 | tenant |
| `reservation` | `RESERVATION_STARTED` | 1 | tenant |

Integrity results:

- unknown target types: 0;
- tenant-scoped audits with NULL tenant: 0;
- global audits with non-NULL tenant: 0;
- missing tenant-scoped targets: 0;
- tenant mismatch against reservation, registration, or lane-family target: 0.

Any new target type must be added to the classifier before its writer is deployed. Unknown target types fail closed after SAAS-9B-3.

## 5. Composite FK feasibility

The production data is compatible with the following model:

1. `shooting_lanes(tenant_id,parent_lane_id) -> shooting_lanes(tenant_id,id)`.
2. `reservations(tenant_id,lane_id) -> shooting_lanes(tenant_id,id)`.
3. `lane_blocks(tenant_id,lane_id) -> shooting_lanes(tenant_id,id)`.
4. `event_lanes(tenant_id,event_id) -> events(tenant_id,id)`.
5. `event_lanes(tenant_id,lane_id) -> shooting_lanes(tenant_id,id)`.
6. `event_registrations(tenant_id,event_id) -> events(tenant_id,id)`.
7. `reservations(lane_id,pricing_rule_id) -> lane_pricing_rules(lane_id,id)`.

Required referenced unique keys:

- `shooting_lanes(tenant_id,id)`;
- `events(tenant_id,id)`;
- `lane_pricing_rules(lane_id,id)`.

The current globally unique IDs remain unchanged.

To avoid ambiguous PostgREST relationships, the migration must not leave both simple and composite foreign keys active for the same relation. Safe sequence per relation:

1. add the composite FK under a temporary name as `NOT VALID`;
2. validate it;
3. drop the replaced simple FK;
4. rename the composite FK to the original stable constraint name.

Existing `ON DELETE` semantics must be preserved exactly: `RESTRICT` for lane/pricing relations and `CASCADE` for event-owned relations.

## 6. Pricing-rule integrity

Production evidence:

- `reservations.pricing_rule_id` is `NOT NULL`;
- `lane_pricing_rules` has PK `(id)` and FK `lane_id -> shooting_lanes(id)`;
- there is currently no unique key `(lane_id,id)`;
- all 11 reservations have an existing pricing rule;
- all 11 rules belong to the reservation's lane;
- both legacy reservation writers persist the selected `pricing_rule_id` and `lane_id`.

Therefore `UNIQUE(lane_id,id)` plus composite FK `(lane_id,pricing_rule_id)` is feasible and backward-compatible. The existing single-column pricing FK should be replaced atomically to avoid duplicate relationship metadata.

## 7. Trigger architecture

### `email_deliveries`

Use an internal `BEFORE INSERT OR UPDATE OF message_type, record_id, tenant_id FOR EACH ROW` trigger.

Behavior:

- resolve `reservation_confirmation` and `reservation_cancellation` through `reservations`;
- resolve `event_registration_confirmation` through `event_registrations`;
- reject unsupported message types;
- reject missing targets;
- if caller supplied a non-NULL tenant, reject mismatch;
- assign `NEW.tenant_id := resolved_tenant_id`.

### `audit_logs`

Use an internal `BEFORE INSERT OR UPDATE OF target_type, target_id, tenant_id FOR EACH ROW` trigger.

Behavior:

- `reservation`: derive from `reservations`;
- `event_registration`: derive from `event_registrations`;
- `lane_booking_family`: derive from `shooting_lanes`;
- `profile` and `account`: require `NEW.tenant_id IS NULL`;
- reject missing target IDs for tenant-scoped types;
- reject supplied tenant mismatch;
- assign the resolved tenant for tenant-scoped types;
- reject every unknown target type.

No FK from `audit_logs` to business targets is added. Existing audit rows survive later lifecycle removal or anonymization of the target.

Both functions should:

- use fully qualified objects and a safe search path;
- remain internal trigger functions, not public RPC contracts;
- have direct EXECUTE revoked from `PUBLIC`, `anon`, `authenticated`, and `service_role`;
- preserve existing audit-table immutability and ACL/RLS contracts.

## 8. BEFORE vs constraint-trigger decision

Decision: **BEFORE ROW triggers**.

They are required because the approved contract assigns `NEW.tenant_id` before persistence. A PostgreSQL constraint trigger is `AFTER ROW` and cannot provide this mutation contract.

No additional AFTER/deferrable trigger is currently justified:

- target rows already exist before delivery/audit records are written;
- all current relationships are immediate;
- audit intentionally has no reverse FK;
- composite FKs provide cross-table relationship enforcement for core tables.

If a future writer needs deferred creation order, that writer and its integrity model must be reviewed separately rather than weakening this stage.

## 9. Existing index inventory

Production currently has 26 indexes across the inspected tables. Important existing coverage includes:

- lane hierarchy: `(parent_lane_id) WHERE parent_lane_id IS NOT NULL`;
- reservations reports: `(reservation_date,start_time,id)`;
- reservation conflict: GiST `(lane_id,booking_period)` for active states;
- lane blocks: `(lane_id,block_date,is_active,start_time,end_time)`;
- events: `(is_active,event_date,start_time,id)`;
- event lanes: PK `(event_id,lane_id)` and reverse `(lane_id,event_id)`;
- registrations: event/payment, event/reserve, user/history, active uniqueness and promotion-token indexes;
- pricing: lane lookup, active ordering and active-range exclusion;
- delivery: unique `(message_type,record_id)`;
- audit: PK only.

No existing index has `tenant_id` as its left prefix.

## 10. Proposed index deduplication matrix

Integrity-supporting unique keys belong to 9B-3A; query indexes belong to 9B-3B.

| Proposed index | Existing coverage | Decision | Reason |
|---|---|---|---|
| `UNIQUE shooting_lanes(tenant_id,id)` | PK `(id)` only | KEEP / 3A | required referenced key for composite lane FKs |
| `UNIQUE events(tenant_id,id)` | PK `(id)` only | KEEP / 3A | required referenced key for composite event FKs |
| `UNIQUE lane_pricing_rules(lane_id,id)` | PK `(id)` and lane index separately | KEEP / 3A | required referenced key for reservation/pricing integrity |
| `shooting_lanes(tenant_id,parent_lane_id,display_order,id)` | parent-only partial index | KEEP / 3B | covers tenant roots and ordered children; no left-prefix duplication |
| `reservations(tenant_id,reservation_date,start_time,id)` | same suffix without tenant | KEEP / 3B | tenant-scoped reports/calendar date range |
| `reservations(tenant_id,lane_id,reservation_date,start_time,id)` | GiST lane/range plus tenant/date proposal | SKIP | lane UUID is global; current GiST and tenant/date index cover known paths |
| `lane_blocks(tenant_id,block_date,lane_id,is_active,start_time,end_time)` | lane-first schedule index | KEEP / 3B | tenant-wide calendar date scan; existing lane-specific index remains useful |
| `events(tenant_id,is_active,event_date,start_time,id)` | same suffix without tenant | KEEP / 3B | tenant-scoped public/admin event listing |
| `event_lanes(tenant_id,event_id,lane_id)` | PK `(event_id,lane_id)` | KEEP / 3B | bounded tenant-wide relation scan and future RLS predicate |
| `event_lanes(tenant_id,lane_id,event_id)` | existing `(lane_id,event_id)` | SKIP | lane UUID is global and reverse lookup already has efficient coverage |
| `event_registrations(tenant_id,event_id,status,payment,created_at,id)` | event-specific indexes | SKIP | admin participant path is event-bound; event UUID already determines tenant |
| `event_registrations(tenant_id,user_id,created_at DESC,id)` | user-only history index | KEEP / 3B | selected-tenant owner history; no matching left prefix |
| `audit_logs(tenant_id,created_at DESC,id) WHERE tenant_id IS NOT NULL` | PK only | KEEP / 3B | required future tenant audit listing |
| `email_deliveries(tenant_id,...)` | unique message/record and PK | SKIP | no current tenant-list query path; add only with measured 9D requirement |

Existing tenant-unaware indexes must not be removed in 9B-3 because the current application still uses legacy query shapes. Redundant-index removal, if justified by production plans after cutover, belongs to a later measured contract phase.

## 11. Exact 9B-3A scope

Proposed migration: `add_tenant_relationship_integrity`.

1. Fail-closed preflight for canonical tenant state, all current relations, email types/targets, audit whitelist/targets and zero mismatches.
2. Add unique referenced keys:
   - `shooting_lanes(tenant_id,id)`;
   - `events(tenant_id,id)`;
   - `lane_pricing_rules(lane_id,id)`.
3. Add and validate composite FKs for lane hierarchy, reservations, lane blocks, event lanes, event registrations and pricing rules.
4. Atomically replace the corresponding simple FKs and retain their stable names and delete semantics.
5. Create the internal email-delivery BEFORE trigger function and trigger.
6. Create the internal audit BEFORE trigger function and trigger.
7. Revoke direct function execution from client/application roles.
8. Assert exact trigger/function ownership, security mode, safe search path, ACL, constraints and validation state.
9. Assert RLS, table ACL and unrelated RPC definitions were not modified.
10. Keep all seven temporary CSK defaults.

No application, membership, RLS, route, public RPC, report or second-tenant change belongs in 9B-3A.

## 12. Exact 9B-3B scope

Proposed migration: `add_tenant_query_indexes`.

Add only:

1. `shooting_lanes(tenant_id,parent_lane_id,display_order,id)`;
2. `reservations(tenant_id,reservation_date,start_time,id)`;
3. `lane_blocks(tenant_id,block_date,lane_id,is_active,start_time,end_time)`;
4. `events(tenant_id,is_active,event_date,start_time,id)`;
5. `event_lanes(tenant_id,event_id,lane_id)`;
6. `event_registrations(tenant_id,user_id,created_at DESC,id)`;
7. partial `audit_logs(tenant_id,created_at DESC,id) WHERE tenant_id IS NOT NULL`.

Do not add the skipped indexes from the deduplication matrix. No current index is dropped.

## 13. Lock/DDL risk

Data volume is small: 257 rows across the nine inspected tables. Table rewrite is not required.

Risk assessment:

- data compatibility: LOW;
- technical constraint risk: LOW after current preflight;
- lock acquisition risk: MEDIUM because `ALTER TABLE` and ordinary index creation need table locks;
- runtime regression risk: MEDIUM, chiefly PostgREST FK relationship ambiguity and trigger classification.

Controls:

- short `lock_timeout` and bounded `statement_timeout`;
- `NOT VALID` then explicit FK validation;
- atomic FK replacement to avoid duplicate PostgREST relationships;
- 9B-3A and 9B-3B in separate transactions/migrations;
- deployment in a short low-traffic window;
- no full maintenance outage is justified by current volume.

## 14. Test plan

Focused SQL tests must use a dormant synthetic tenant and one rollback-only transaction.

Required cases:

1. same-tenant lane parent, reservation, lane block, event lane and registration relationships allow;
2. cross-tenant lane hierarchy deny;
3. cross-tenant reservation/lane deny;
4. reservation/pricing rule from a different lane deny;
5. cross-tenant lane-block/lane deny;
6. both event-lane mismatch directions deny;
7. cross-tenant registration/event deny;
8. `event_id IS NULL` with retained `tenant_id` allow under `MATCH SIMPLE` semantics;
9. each of three email message types resolves and sets tenant;
10. unsupported email type, missing target and mismatch deny;
11. each tenant-scoped audit type derives tenant;
12. `profile` and `account` require NULL tenant;
13. unknown audit target, missing target and mismatch deny;
14. audit history remains after permitted synthetic target lifecycle simulation;
15. legacy CSK writers still work without supplying tenant IDs;
16. existing reservation conflict/exclusion behavior remains unchanged;
17. PostgREST relationship selectors remain unambiguous;
18. RLS/ACL/RPC fingerprints remain unchanged except the two approved internal trigger functions;
19. seven CSK defaults remain; audit default remains absent;
20. second-active-tenant guard remains effective;
21. fixture count after rollback is zero.

Regression after local implementation:

- focused SAAS-9B-3 SQL tests;
- all Supabase DB tests;
- all Node tests;
- TypeScript;
- production build;
- relevant Booking, Reservations, Calendar, Reports, Events and Check-in tests;
- `npm audit --omit=dev`;
- ESLint baseline comparison;
- `git diff --check`.

## 15. Rollback strategy

- Each migration must be transactional and independently fail closed.
- A preflight failure occurs before DDL.
- Any constraint validation failure rolls back the complete 9B-3A migration.
- Old simple FKs are dropped only after their composite replacements validate, within the same transaction.
- Any trigger postflight failure rolls back function and trigger creation.
- 9B-3B failure cannot undo 9B-3A because it is a separate migration.
- Application rollback remains safe: runtime still ignores tenant context and CSK defaults remain.
- After production deployment, reversal requires a separately reviewed forward migration; do not use migration repair or improvised manual SQL.

## 16. Blocking issues

Current preflight blockers: **none**.

Mandatory implementation/deployment STOP conditions remain:

- any new unknown audit target type;
- any unsupported email message type;
- any orphan or missing target;
- any tenant or pricing mismatch;
- another active tenant;
- missing active-tenant guard;
- schema/index/constraint drift from this inventory;
- inability to atomically replace duplicate FKs without breaking PostgREST relationships.

Temporary CSK defaults explicitly remain. Their removal is a later mandatory gate before tenant-aware writer cutover and before a second tenant.

## 17. GO / NO-GO

**SAAS-9B-3 PREFLIGHT: PASS**

**SAAS-9B-3 PLAN: APPROVED-READY**

**READY FOR LOCAL IMPLEMENTATION: GO** — readiness only; implementation still requires separate explicit approval.

**SECOND TENANT: NO-GO**

**SEC-004: OPEN**
