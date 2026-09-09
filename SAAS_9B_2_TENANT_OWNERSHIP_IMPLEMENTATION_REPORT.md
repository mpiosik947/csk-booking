# SAAS-9B-2 — Tenant Ownership Implementation Report

Date: 2026-09-09

Mode: local implementation and validation only

Branch: `main`
Base HEAD: `63afb42730d5802f77f1114ba372950683c930d5`

No production database operation, Supabase `db push`, migration repair, application deployment, Git commit, or Git push was performed.

## 1. Executive summary

SAAS-9B-2 was implemented as two ordered, transactional migrations. The approved eight tables now have a locally validated tenant ownership model. Seven core/delivery tables have deterministic CSK ownership, validated foreign keys, `NOT NULL`, and a temporary CSK compatibility default. `audit_logs.tenant_id` is nullable, has no default, and is populated only for explicitly classified tenant-scoped records.

Runtime remains single-tenant. No application, RLS, ACL, RPC, `SECURITY DEFINER`, membership authorization, routing, or `profiles.role` behavior changed.

## 2. Files changed

- `supabase/migrations/20260909100000_add_tenant_ownership_columns.sql`
- `supabase/migrations/20260909110000_backfill_csk_tenant_ownership.sql`
- `supabase/tests/20260909110000_backfill_csk_tenant_ownership_test.sql`
- `supabase/tests/20260907100000_add_dormant_tenant_foundation_test.sql`
- `SAAS_9B_2_PRODUCTION_PREFLIGHT_REPORT.md`
- `SAAS_9B_2_TENANT_OWNERSHIP_IMPLEMENTATION_REPORT.md`

No application file was changed.

## 3. Migration 9B-2A

`20260909100000_add_tenant_ownership_columns.sql` is the additive expand phase. It:

- confirms the canonical CSK tenant and sole-active-tenant invariant;
- checks exact pre-migration column fingerprints and rejects schema drift;
- rejects a pre-existing `tenant_id` in any target table;
- adds eight nullable UUID ownership columns;
- adds eight foreign keys as `NOT VALID`;
- adds the seven approved temporary CSK defaults, never an audit default;
- documents the mandatory default-removal gate;
- uses a 5-second lock timeout and 60-second statement timeout;
- changes no existing business row or runtime security contract.

## 4. Migration 9B-2B

`20260909110000_backfill_csk_tenant_ownership.sql` is the fail-closed backfill and validation phase. Before writes it checks the canonical tenant, exact 9B-2A state, lane hierarchy, all approved dependency chains, email mappings, the audit classification whitelist, and audit target existence.

It snapshots row counts and business-column fingerprints, plus function definitions, RLS policies, table ACLs, and membership count. After backfill it validates all eight foreign keys, makes the seven core/delivery ownership columns `NOT NULL`, keeps audit ownership nullable, and rejects any business or runtime-security fingerprint change.

The ownership-only updates temporarily disable `set_shooting_lanes_updated_at` and `lock_lane_blocks_configuration`, then re-enable them before validation in the same transaction. A failure rolls back data and trigger state together.

## 5. Tables changed

Exactly these tables receive `tenant_id`:

- `shooting_lanes`
- `reservations`
- `lane_blocks`
- `events`
- `event_lanes`
- `event_registrations`
- `email_deliveries`
- `audit_logs`

No ownership column is added to `profiles`, `auth.users`, `tenant_memberships`, lane configuration child tables, rate-limit tables, or any other object.

## 6. Temporary CSK defaults

The canonical default `c5c00000-0000-4000-8000-000000000001` is present only on:

- `shooting_lanes`
- `reservations`
- `lane_blocks`
- `events`
- `event_lanes`
- `event_registrations`
- `email_deliveries`

`audit_logs.tenant_id` has no default.

**TEMPORARY CSK DEFAULT MUST BE REMOVED BEFORE tenant-aware writer cutover and before second-tenant activation.**

## 7. FK strategy

9B-2A creates a simple foreign key from each new column to `public.tenants(id)` as `NOT VALID`, minimizing the expand-phase validation work. 9B-2B validates all eight constraints after deterministic backfill. Composite tenant integrity, tenant-prefixed indexes, self-referencing hierarchy constraints, and tenant-scoped uniqueness are deliberately deferred to SAAS-9B-3.

## 8. Backfill strategy

Dependency order is:

1. shooting lanes to canonical CSK, followed by parent/child validation;
2. events to canonical CSK;
3. reservations and lane blocks from their shooting lane;
4. event lanes from their event, with event/lane tenant equality required;
5. event registrations from their event;
6. email deliveries through the explicit message target;
7. tenant-scoped audits through the trusted target.

Unknown, null, orphaned, ambiguous, or cross-tenant relationships abort the migration. There is no guessed or blanket backfill.

## 9. `email_deliveries` handling

The approved production preflight found only `reservation_confirmation` with `record_id → reservations.id`. The migration recognizes only this mapping. A new message type or missing target is a STOP condition. Ownership is inherited from the resolved reservation, not inferred merely from there being one tenant.

## 10. `audit_logs` classification

Audit ownership uses an explicit `(action, target_type)` whitelist:

- reservation, event-registration, and lane-family business audits are tenant-scoped and inherit from their target;
- profile/account lifecycle audits remain global with `tenant_id = NULL`;
- unknown pairs and missing tenant-scoped targets abort before backfill.

No blanket `UPDATE audit_logs SET tenant_id = CSK` exists. The mandatory production gate must still confirm the preflight distribution of 42 tenant-scoped, 70 global/account, and 0 unknown records immediately before deployment.

## 11. Validation results

Local target was explicitly `127.0.0.1:54322` for every SQL command. Results:

- 9B-2A application: PASS;
- 9B-2B application: PASS;
- dependency-aware synthetic backfill: PASS;
- focused SQL contract: 32/32 PASS with final `ROLLBACK`;
- all eight foreign keys present and validated;
- seven core/delivery ownership columns `NOT NULL`;
- audit ownership nullable with no default;
- active tenants: 1;
- dormant memberships: 0;
- remaining marked SAAS-9B-2 fixture: 0.

The existing SAAS-9B-1 test was advanced from the obsolete pre-9B-2 assertion “no business ownership columns” to a stage-aware assertion allowing exactly these eight approved columns while rejecting any scope expansion.

## 12. Business data fingerprint

9B-2B fingerprints every affected table before and after, excluding only the new `tenant_id` field. It aborts if a row count or any existing business value changes. Local fixture validation confirmed unchanged IDs, names, hierarchy, status, timestamps, prices, durations, limits, and relationships. The migrations insert or delete no business record.

## 13. Runtime compatibility

| Application | Database | Result | Reason |
|---|---|---|---|
| Old | Old | SAFE | Existing baseline. |
| Old | 9B-2A | SAFE | Additive nullable columns and temporary defaults. |
| Old | 9B-2A + 9B-2B | SAFE | Legacy writers and authorization remain unchanged. |
| Current unchanged app | 9B-2A + 9B-2B | SAFE | There is no application cutover in this stage. |

`profiles.role` remains authoritative. `tenant_memberships.role` remains dormant. The second-active-tenant guard remains in place.

## 14. Test results

Because Windows Application Control blocks the local Supabase CLI and the local migration ledger has documented historical drift, the migrations and SQL tests were run directly with PostgreSQL 18 `psql`, `ON_ERROR_STOP=1`, against local `127.0.0.1:54322`. No migration repair was used.

| Test | Result |
|---|---|
| Focused SAAS-9B-2 SQL | PASS — 32/32 |
| Full Supabase SQL inventory | PASS — 20/20 files |
| All Node tests | PASS — 727/727 |
| Focused Booking/Events/lane-family/Reports/Calendar/Check-in Node tests | PASS — 378/378 |
| TypeScript `tsc --noEmit` | PASS |
| Production build | PASS — Next.js 16.3.4 |
| `git diff --check` | PASS |

## 15. Regression results

The selected Playwright set covered lane-family creation, Events responsive behavior, Reports responsive behavior, admin action queues, and cancellation/booking deadlines. The first combined run passed 21 tests before one desktop Reports case timed out during the normal loading state after a filter change; one later serial case did not run. The unchanged Reports suite then passed 5/5 immediately. The union of selected cases passed without any application/test change.

There are no dedicated Calendar or Check-in Playwright specifications in the repository. Their focused Node contracts passed as part of the 378/378 flow regression, including hierarchy-aware Calendar and reservation-scoped Check-in.

`npm audit --omit=dev` reached the registry and found one existing transitive moderate advisory in `baseline-browser-mapping@2.10.30` (via `next@16.3.4`), `GHSA-w5vr-8v7q-w6rv`. It is unrelated to these DB migrations. No dependency change was made outside scope; dependency remediation/acceptance remains a release review item.

## 16. Security notes

Function, policy, ACL, and membership fingerprints remain unchanged. No RPC or `SECURITY DEFINER` function was added or modified. No RLS/ACL privilege was expanded. No service-role behavior changed. The single-active-tenant guard remains mandatory.

SAAS-9B-2 does not close tenant isolation: `SEC-004` stays open and a second tenant stays disabled.

## 17. Deferred 9B-3 work

Not implemented here:

- composite tenant foreign keys;
- composite lane hierarchy integrity;
- cross-table same-tenant constraints;
- tenant-prefixed indexes and uniqueness;
- report/calendar index redesign;
- removal of the temporary defaults.

Tenant-aware RLS, membership authorization, RPC checks, app context, and routing remain deferred to SAAS-9C/9D/9E.

## 18. Rollback plan

- 9B-2A failure rolls back its transaction with no partial schema.
- If 9B-2A succeeds but 9B-2B fails, stop and retain evidence. The old app remains compatible because columns are nullable and bridge defaults exist.
- 9B-2B failure rolls back all backfill, validation, `NOT NULL`, and trigger-state changes in that migration.
- After successful 9B-2B, application rollback remains safe because the app still ignores tenant ownership.
- Any database down migration must be separately reviewed; never improvise it after tenant-aware writes begin.

## 19. Production deployment plan

Production deployment is DB-only and requires separate explicit approval:

1. verify the SAAS-9B-1 checkpoint and aligned migration history;
2. rerun row counts, schema fingerprints, canonical tenant/guard, orphan checks, delivery mapping, and exact audit map;
3. STOP on drift, unknowns, ambiguity, or another active tenant;
4. from approved WSL2, run `supabase db push --linked --dry-run`;
5. require the pending set to be exactly `20260909100000` then `20260909110000`;
6. apply only after owner approval, in a short low-traffic window;
7. verify ownership distribution, FK/NULL/default state, unchanged RLS/ACL/RPC fingerprints, dormant memberships, and the active-tenant guard;
8. smoke Booking, login, admin, Reservations, Calendar, Reports, Events, and Check-in.

Measured production volume is 193 rows across affected tables, so no full outage is currently justified. Short lock timeouts make contention fail closed.

## 20. Git status

Working tree is intentionally modified and unstaged. It contains the six files listed in section 2 and no application change. No `git add`, commit, or push was performed. `git diff --check` passes; Git reports only the repository's Windows LF→CRLF warning for the modified prior-stage test.

## 21. Production Deployment Readiness

### Migration history

Production migration history was read through the linked project from Supabase CLI 2.109.1 in Ubuntu 24.04 WSL2. Local and remote histories match through:

- `20260907100000_add_dormant_tenant_foundation.sql`

There is no remote-only migration and no additional local pending migration. The exact pending set is:

1. `20260909100000_add_tenant_ownership_columns.sql`
2. `20260909110000_backfill_csk_tenant_ownership.sql`

No migration repair was run.

### SHA-256 migration fingerprints

The files were hashed before dry-run and verified unchanged afterward:

| Migration | SHA-256 |
|---|---|
| `20260909100000_add_tenant_ownership_columns.sql` | `826165e4604107bd71a65b75e92917d3e1925a961be130327aa786b9298a6dde` |
| `20260909110000_backfill_csk_tenant_ownership.sql` | `ddea15d227e3fc3b128b9cfccbfaab17c049c5a3bf9a02b4a731990cf2233be0` |

Any future migration edit invalidates this readiness result and requires a new complete verification and dry-run.

### Production data re-preflight

All queries ran through `supabase db query --linked` inside `BEGIN READ ONLY`. No production write was executed.

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

Total: 193 rows, unchanged from the approved baseline.

Integrity results:

- canonical CSK tenant: 1;
- active tenants: 1;
- tenant memberships: 0;
- prospective ownership columns before deployment: 0;
- lane hierarchy orphans: 0;
- reservations without lane: 0;
- lane blocks without lane: 0;
- event-lane missing event/lane: 0/0;
- event registrations with null/missing event: 0/0;
- tenant-scoped audit targets missing: 0;
- all eight production schema fingerprints exactly match the 9B-2A preflight constants.

Email classification remains exactly 11 `reservation_confirmation` records, 0 unsupported types, and 0 missing targets.

Audit classification remains exactly:

- tenant-scoped: 42;
- global/account: 70;
- UNKNOWN: 0.

The distinct action/target inventory is unchanged from the approved production preflight report.

### Dry-run result

Command:

```text
supabase db push --linked --dry-run
```

Result: PASS, exit code 0.

```text
Would push these migrations:
 • 20260909100000_add_tenant_ownership_columns.sql
 • 20260909110000_backfill_csk_tenant_ownership.sql
Finished supabase db push.
```

The first local invocation attempt used an incomplete release shim and stopped before connecting because `supabase-go` was absent. It performed no database operation. The official full 2.109.1 release bundle was then loaded in WSL `/tmp`, and the successful dry-run above was performed. The CLI also reported that 2.117.0 is available; no tool or repository update was made.

### Lock and backfill risk

The production volume is unchanged and small. Backfill work covers 193 rows, so data-update volume risk remains low. The additive columns and `SET NOT NULL` operations still require brief table locks; production DDL risk remains medium because lock acquisition depends on concurrent transactions, not row count alone.

The existing 5-second `lock_timeout` makes contention fail closed. A short low-traffic controlled deployment period remains sufficient. Current evidence does not justify a full maintenance window. Any material count increase, long-running transaction, lock contention, or changed preflight result is a STOP condition.

### Temporary file status

`supabase/tests/.tmp_saas9b2_seed.sql` is absent. No seed, cleanup, generated SQL, or other temporary SAAS-9B-2 fixture file remains in the repository.

**TEMP TEST FIXTURES LEFT: 0**

The WSL CLI bundle exists only under `/tmp` and is not part of the repository or deployment changeset.

### Historical test change

`supabase/tests/20260907100000_add_dormant_tenant_foundation_test.sql` changed only its test-30 expectation:

- before 9B-2 it asserted that business tables had no ownership columns;
- after 9B-2 it permits exactly the eight approved ownership columns and still rejects any additional ownership scope;
- it continues to recognize the existing `tenant_memberships.tenant_id` from 9B-1 separately.

This is a test-only stage progression. It changes no schema or runtime behavior.

**`20260907100000_add_dormant_tenant_foundation.sql` HISTORICAL MIGRATION MODIFIED: NO**

### NPM moderate finding

SAAS-9B-2 changed neither `package.json` nor `package-lock.json`. The `baseline-browser-mapping@2.10.30` moderate advisory remains an independent dependency finding inherited through Next.js 16.3.4. It is not caused by, and does not by itself block, the DB-only 9B-2 deployment. Dependencies were not modified in this stage.

## 22. Pre-deployment verdict

**SAAS-9B-2 LOCAL IMPLEMENTATION: PASS**

**SAAS-9B-2 PRODUCTION PREFLIGHT: PASS**

**READY FOR PRODUCTION PUSH: YES** — readiness only; the production push was not executed and still requires separate explicit approval.

**READY FOR SAAS-9B-3: NO-GO** — first deploy and verify SAAS-9B-2 under separate approval.

**SECOND TENANT: NO-GO**

**SEC-004: OPEN**

## 23. PRODUCTION DEPLOYMENT & VERIFICATION

Deployment date: 2026-09-09

Production project ref: `yuyxfodozzpzrdzkmolu`

### Final gate and SHA verification

Immediately before deployment:

- local/remote migration history matched through `20260907100000`;
- there was no remote-only divergence;
- the pending set contained exactly the two approved migrations in the approved order;
- canonical CSK tenant = 1;
- active tenants = 1;
- tenant memberships = 0;
- orphan/integrity failures = 0;
- unsupported email types = 0;
- email targets missing = 0;
- audit UNKNOWN = 0;
- audit tenant target missing = 0;
- all production schema fingerprints matched the migration preflight constants.

Final migration hashes matched the approved values:

| Migration | SHA-256 |
|---|---|
| `20260909100000_add_tenant_ownership_columns.sql` | `826165e4604107bd71a65b75e92917d3e1925a961be130327aa786b9298a6dde` |
| `20260909110000_backfill_csk_tenant_ownership.sql` | `ddea15d227e3fc3b128b9cfccbfaab17c049c5a3bf9a02b4a731990cf2233be0` |

### Exact migrations deployed

The approved production command was executed from Ubuntu 24.04 WSL2 with Supabase CLI 2.109.1:

```text
supabase db push --linked
```

Deployment output:

```text
Applying migration 20260909100000_add_tenant_ownership_columns.sql...
Applying migration 20260909110000_backfill_csk_tenant_ownership.sql...
Finished supabase db push.
```

Exit code: 0. No other migration, manual SQL substitute, migration repair, application change, dependency update, or Git operation was performed.

### Local/remote state and final dry-run

Post-deploy `supabase migration list --linked` reports:

- `20260909100000` LOCAL = REMOTE;
- `20260909110000` LOCAL = REMOTE.

Post-deploy `supabase db push --linked --dry-run` exited 0 with:

```text
Remote database is up to date.
```

### Final schema and ownership distribution

Read-only postflight confirmed:

- exactly eight new `tenant_id` columns;
- `tenant_id NOT NULL` on all seven core/delivery tables;
- `audit_logs.tenant_id` remains nullable;
- eight of eight tenant foreign keys reference `public.tenants(id)` and are validated;
- seven temporary CSK defaults exist on the approved core/delivery tables;
- `audit_logs.tenant_id` has no default;
- core ownership NULL count = 0;
- core non-CSK ownership count = 0;
- unknown/orphan tenant references = 0.

**TEMPORARY CSK DEFAULT MUST BE REMOVED BEFORE:**

- tenant-aware writer cutover;
- second-tenant activation.

### Relational consistency

All post-deploy mismatch counts are zero:

- reservation tenant versus lane tenant: 0;
- lane-block tenant versus lane tenant: 0;
- event-lane tenant versus event and lane tenant: 0;
- event-registration tenant versus event tenant: 0;
- email-delivery tenant versus reservation target tenant: 0.

### Audit classification

Post-deploy audit state remains:

- tenant-scoped rows: 42, all assigned to canonical CSK;
- global/account rows: 70, all retaining `tenant_id = NULL`;
- UNKNOWN rows: 0;
- wrongly assigned tenant audit: 0;
- wrongly assigned global audit: 0.

No blanket audit backfill occurred.

### Business fingerprint

Immediately before and after deployment, row counts remained identical:

| Table | Before | After |
|---|---:|---:|
| `shooting_lanes` | 11 | 11 |
| `reservations` | 11 | 11 |
| `lane_blocks` | 3 | 3 |
| `events` | 11 | 11 |
| `event_lanes` | 9 | 9 |
| `event_registrations` | 25 | 25 |
| `email_deliveries` | 11 | 11 |
| `audit_logs` | 112 | 112 |

Every business-data fingerprint excluding `tenant_id` matched exactly before and after:

- shooting lanes: `e9fe142eac60c7cbfb67f945aa78c196`;
- reservations: `917f8d09378f6aa49b328103b9c3d922`;
- lane blocks: `cd9073c665e99e662ec477bf9c28e721`;
- events: `83947e9d1feda717c38f1e20e1fbcb3f`;
- event lanes: `59c5b8dd70f7bd8c80e98f4545c5d66e`;
- event registrations: `49bca67e444b0e78a9b70fdc0711b7e8`;
- email deliveries: `8e9d9d75bf94fa96dc2e889cb3fe3ae6`;
- audit logs: `071dc6866bd44f6102a95fd02d320279`.

IDs, row counts, and existing business values are unchanged. The only intended logical data change is tenant ownership.

### Security and runtime invariants

External pre/post fingerprints are identical:

- public function definitions: `5c40e2dc79e940095c40e6cba72583e4`;
- RLS policies: `f5c428bd4e241af39f690c1aafcfad08`;
- table ACLs: `cf05faffa475999df163338c3c1e805f`.

Additionally:

- `profiles.role` remains non-null text with the existing `'user'` default and remains the legacy runtime authorization source;
- tenant memberships remain empty and dormant;
- the application, middleware, routing, and tenant context were not changed;
- `tenants_single_active_runtime_guard` remains present;
- no new RPC or `SECURITY DEFINER` contract was added or changed.

### Runtime smoke

The existing authenticated production browser session and public flows were checked without creating or mutating data:

| Flow | Result | Evidence |
|---|---|---|
| Booking | PASS | `/booking` rendered the current selectable lane configuration. |
| Login/session | PASS | Existing authenticated session remained valid on `/dashboard` and admin routes. |
| Admin | PASS | `/admin` loaded without redirect or runtime error. |
| Reservations | PASS | `/admin/reservations` loaded under the admin session. |
| Calendar | PASS | `/admin/calendar` rendered the day view and lane/type controls. |
| Reports | PASS | `/admin/reports` rendered report filters. |
| Events | PASS | `/events` loaded normally. |
| Check-in | PASS | `/admin/check-in` rendered the operational visit list and controls. |

Runtime remains single-tenant CSK. No multi-tenant UX or second-tenant behavior was tested or enabled.

### Remaining risks and gates

- The temporary CSK defaults are intentionally unsafe for a second tenant and must be removed at the later writer-cutover gate.
- Composite same-tenant integrity and tenant-prefixed indexes remain deferred to SAAS-9B-3.
- Tenant-aware RLS/RPC/application context remains deferred; SEC-004 is not closed.
- `baseline-browser-mapping` remains an independent moderate dependency finding; package files were not changed by this DB deployment.
- Supabase CLI 2.117.0 is available, while the reproducible deployment used repository-aligned 2.109.1. This did not affect the successful deployment.

### Final production verdict

**SAAS-9B-2 PRODUCTION DEPLOY: PASS**

**SAAS-9B-2 POST-DEPLOY VERIFICATION: PASS**

**READY FOR GIT CHECKPOINT: YES**

**READY FOR SAAS-9B-3 PLANNING: GO**

**READY FOR SAAS-9B-3 IMPLEMENTATION: NO-GO**

**SECOND TENANT: NO-GO**

**SEC-004: OPEN**
