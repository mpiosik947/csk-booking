# SAAS-9B-2 — Production Preflight Report

Date: 2026-09-08

Mode: read-only production discovery
Planned split: SAAS-9B-2A expand; SAAS-9B-2B backfill, validation, and contract strengthening

No migration was created or executed. No application code, schema, RLS, ACL, RPC, or production data was changed. The only write-shaped production check was the separately approved SAAS-9B-1 guard test, fully contained in a transaction ending in `ROLLBACK`.

## Production volumes

| Table | Rows | Total relation size |
|---|---:|---:|
| `shooting_lanes` | 11 | 81,920 bytes |
| `reservations` | 11 | 139,264 bytes |
| `lane_blocks` | 3 | 81,920 bytes |
| `events` | 11 | 90,112 bytes |
| `event_lanes` | 9 | 73,728 bytes |
| `event_registrations` | 25 | 278,528 bytes |
| `email_deliveries` | 11 | 49,152 bytes |
| `audit_logs` | 112 | 139,264 bytes |

Total inspected rows: 193. Current production volume is small; row count alone is not a maintenance-window driver.

## Orphan / null findings

| Check | Count | Result |
|---|---:|---|
| reservations without valid lane | 0 | PASS |
| lane blocks without valid lane | 0 | PASS |
| event lanes without valid event | 0 | PASS |
| event lanes without valid lane | 0 | PASS |
| event registrations with `event_id IS NULL` | 0 | PASS |
| event registrations with missing event | 0 | PASS |
| email deliveries with unrecognized message type | 0 | PASS |
| email deliveries with missing record target | 0 | PASS |
| audit reservation targets missing | 0 | PASS |
| audit event-registration targets missing | 0 | PASS |
| audit lane-family targets missing | 0 | PASS |

No current orphan, null, unknown, or ambiguous row blocks deterministic CSK ownership backfill. These checks must be repeated fail-closed immediately before 9B-2B; any nonzero result is STOP.

## `email_deliveries` classification

| `message_type` | Rows | Ownership source | Classification |
|---|---:|---|---|
| `reservation_confirmation` | 11 | `record_id` → `reservations.id` | tenant-scoped / deterministic |

There are no unknown message types and no missing reservation targets. Each current row can inherit CSK through its reservation.

Implementation must map only explicitly recognized `message_type` values, resolve exactly one documented target, and require exactly one tenant. Unknown, missing, orphaned, or ambiguous mappings abort 9B-2B. No blanket assignment is permitted.

## `audit_logs` classification map

| Action | Target | Rows | Classification |
|---|---|---:|---|
| `event_registration_cancelled_by_staff` | `event_registration` | 1 | tenant-scoped via registration/event |
| `event_registration_cancelled_by_user` | `event_registration` | 7 | tenant-scoped via registration/event |
| `lane_booking_family_configuration_updated` | `lane_booking_family` | 14 | tenant-scoped via root shooting lane |
| `RESERVATION_ATTENDANCE_RESET` | `reservation` | 1 | tenant-scoped |
| `reservation_created` | `reservation` | 11 | tenant-scoped |
| `RESERVATION_NO_SHOW` | `reservation` | 4 | tenant-scoped |
| `RESERVATION_PAYMENT_STATUS_CHANGED` | `reservation` | 3 | tenant-scoped |
| `RESERVATION_STARTED` | `reservation` | 1 | tenant-scoped |
| `profile_admin_note_updated` | `profile` | 1 | global/account; leave NULL |
| `profile_contact_details_updated` | `profile` | 2 | global/account; leave NULL |
| `profile_identity_updated` | `profile` | 2 | global/account; leave NULL |
| `PROFILE_PERMISSIONS_VERIFICATION_UPDATED` | `profile` | 5 | global/account; leave NULL |
| `profile_role_changed` | `profile` | 5 | global/account; leave NULL |
| `PROFILE_ROLE_CHANGED` | `profile` | 25 | global/account; leave NULL |
| `PROFILE_VERIFICATION_CHANGED` | `profile` | 25 | global/account; leave NULL |
| `profile_verification_rejected` | `profile` | 1 | global/account; leave NULL |
| `profile_verification_verified` | `profile` | 4 | global/account; leave NULL |

| Class | Rows |
|---|---:|
| tenant-scoped event registration | 8 |
| tenant-scoped lane family | 14 |
| tenant-scoped reservation | 20 |
| global/account profile | 70 |
| UNKNOWN | 0 |
| total | 112 |

All tenant-scoped targets resolve to existing records (missing counts 0/0/0). No blanket `audit_logs → CSK` backfill is permitted. `audit_logs.tenant_id` remains nullable. Any new/unrecognized `(action, target_type)` in the mandatory pre-deploy rerun is a STOP condition.

## Legacy writer/default requirements

Legacy INSERT/RPC paths do not supply tenant ownership. A temporary canonical-CSK default is required only for directly owned tables still written before the tenant-aware writer cutover:

| Table | Legacy write path | Temporary CSK default |
|---|---|---|
| `shooting_lanes` | lane-family creation | YES |
| `reservations` | reservation creation | YES |
| `lane_blocks` | lane-block writers | YES |
| `events` | Event V2 writers | YES |
| `event_lanes` | Event V2 lane assignment | YES |
| `event_registrations` | registration/reserve/promotion | YES |
| `email_deliveries` | delivery prepare/claim | YES |
| `audit_logs` | trusted business writers | **NO** |

No direct `tenant_id` is proposed in 9B-2 for:

- `profiles` (global account identity; `profiles.role` stays authoritative);
- `tenant_memberships` (already keyed by tenant and dormant);
- lane booking rules/durations/pricing/configuration versions (derive through lane);
- rate-limit/anti-abuse tables (platform-global);
- `auth.users` (platform-global identity).

The default is only a compatibility bridge. A mandatory gate must remove all temporary defaults **before tenant-aware writer cutover and before a second tenant**.

## Estimated lock risk

### 9B-2A expand

Adding nullable columns/defaults needs brief `ACCESS EXCLUSIVE` locks. With these small relations rewrite/volume risk is low, but lock acquisition can still wait behind active transactions. Add foreign keys as `NOT VALID` where appropriate and use short `lock_timeout`, bounded `statement_timeout`, one table at a time, and fail rather than wait indefinitely.

Technical risk: **LOW**. Production DDL risk: **MEDIUM**.

### 9B-2B backfill and validation

At current volumes deterministic updates cover at most 193 rows; update volume is low. Integrity risk is high if ownership mapping is wrong, controlled by fail-closed preflight and explicit mapping. Constraint validation and `SET NOT NULL` still need controlled locking.

Technical/volume risk: **LOW**. Mapping integrity risk: **HIGH unless gates pass**.

## Maintenance-window recommendation

A full outage is not justified by current sizes. Use a short announced low-traffic deployment window because schema locks remain production-sensitive. Stop if locks cannot be acquired promptly and re-evaluate if counts materially increase.

Recommendation: **LOW-TRAFFIC CONTROLLED WINDOW; NO FULL MAINTENANCE OUTAGE CURRENTLY REQUIRED**.

## Blocking issues

Current data blockers: **none**.

Current process blocker:

- mandatory SAAS-9A / SAAS-9B-1 / SAAS-9B-1P Git checkpoint is not yet reviewed and committed with explicit owner approval.

Implementation gates:

- rerun all orphan/null/email/audit classifications immediately before 9B-2B;
- abort on unknown audit pairs or unknown/ambiguous delivery mapping;
- keep the one-active-tenant guard;
- retain `profiles.role` as legacy runtime authorization;
- do not enable a second tenant;
- do not start tenant-aware RLS/RPC/application cutover here.

## Exact proposed 9B-2A scope

One separate reviewed expand migration:

1. assert the canonical CSK tenant exists exactly once and is the sole active tenant;
2. add nullable `tenant_id uuid` to `shooting_lanes`, `reservations`, `lane_blocks`, `events`, `event_lanes`, `event_registrations`, `email_deliveries`, and `audit_logs`;
3. add temporary CSK defaults to the first seven tables, never `audit_logs`;
4. add simple tenant foreign keys in validation-deferred form where supported;
5. document the bridge-default removal gate;
6. perform no backfill, `NOT NULL`, RLS/policy/ACL, membership, RPC, app, routing, or second-tenant change.

## Exact proposed 9B-2B scope

A second separate reviewed migration:

1. rerun all fail-closed production checks;
2. backfill core tables to canonical CSK through deterministic ownership chains;
3. backfill email deliveries only through explicit `message_type + record_id` mappings;
4. backfill only classified tenant-scoped audits and leave global/account audits NULL;
5. assert zero unknown, orphaned, ambiguous, or unassigned core rows;
6. validate tenant foreign keys;
7. set `tenant_id NOT NULL` on the seven core/delivery tables;
8. keep `audit_logs.tenant_id` nullable;
9. add only minimal single-column support indexes; defer composite same-tenant integrity to SAAS-9B-3;
10. retain temporary defaults only for legacy compatibility, gated for later removal;
11. make no runtime RLS, RPC authorization, membership, routing, or `profiles.role` change.

## GO / NO-GO for implementation

**DATA PREFLIGHT: GO** — current production data is small, referentially clean, and fully classifiable under approved rules.

**SAAS-9B-2 IMPLEMENTATION: NO-GO NOW** — the mandatory Git checkpoint is outstanding and implementation has not been separately authorized.

After checkpoint approval, evidence supports a **conditional GO to prepare 9B-2A only**, followed by its own review/tests before 9B-2B.

**SECOND TENANT: NO-GO**

**SEC-004: OPEN**

## Local implementation handoff — 2026-09-09

The mandatory SAAS-9B-1 checkpoint is now complete and SAAS-9B-2 has been implemented and validated locally in two ordered migrations:

- `20260909100000_add_tenant_ownership_columns.sql` — expand;
- `20260909110000_backfill_csk_tenant_ownership.sql` — fail-closed backfill and validation.

The production facts in this report were not changed or reinterpreted. They remain mandatory pre-deployment gates and must be rerun immediately before a separately approved production push. In particular, the observed delivery inventory (`reservation_confirmation` only), the complete audit classification (42 tenant-scoped, 70 global, 0 unknown), orphan counts, table fingerprints, sole active CSK tenant, and pending migration set must still match.

Local validation passed the focused 32-check ownership test, all 20 SQL test files, all 727 Node tests, TypeScript, build, and the selected Playwright flow set after one isolated retry. See `SAAS_9B_2_TENANT_OWNERSHIP_IMPLEMENTATION_REPORT.md` for the full implementation, compatibility, deployment, and rollback record.

This update does not authorize production deployment. `SECOND TENANT` remains `NO-GO` and `SEC-004` remains `OPEN`.
