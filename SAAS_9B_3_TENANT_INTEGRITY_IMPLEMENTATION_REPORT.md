# SAAS-9B-3 — Tenant Integrity Implementation Report

## 1. Executive summary

SAAS-9B-3 was implemented locally as two independent migrations: relationship integrity (9B-3A) and tenant-prefixed query indexes (9B-3B). Cross-tenant relationships now fail at the database constraint boundary. Tenant ownership for delivery and audit rows is derived from trusted targets by fail-closed trigger functions. Runtime authorization remains unchanged and single-tenant.

## 2. Files changed

- `supabase/migrations/20260909120000_add_tenant_relationship_integrity.sql`
- `supabase/migrations/20260909130000_add_tenant_query_indexes.sql`
- `supabase/tests/20260909130000_tenant_relationship_integrity_test.sql`
- `supabase/tests/20260816143000_harden_public_function_execute_acl_test.sql` — inventory-only update for the two new protected trigger functions
- `SAAS_9B_3_TENANT_INTEGRITY_IMPLEMENTATION_REPORT.md`

The historical SAAS-9B-1, SAAS-9B-2A and SAAS-9B-2B migrations were not modified. The pre-existing untracked planning document `SAAS_9B_3_PRODUCTION_PREFLIGHT_AND_FINAL_PLAN.md` also remains outside this implementation diff.

## 3. Migration 9B-3A

`20260909120000_add_tenant_relationship_integrity.sql` uses `lock_timeout = 5s` and `statement_timeout = 120s`. Its preflight verifies the canonical CSK tenant, the exact 9B-2 ownership/default state, prior FK definitions, zero ownership mismatches, approved delivery mappings, approved audit target types and absence of planned objects. Any mismatch aborts the migration transaction.

## 4. Composite key/FK changes

Added unique keys:

- `shooting_lanes(tenant_id, id)`
- `events(tenant_id, id)`
- `lane_pricing_rules(lane_id, id)`

The seven simple relationship FKs were replaced atomically by validated composite FKs while retaining their original names and `ON DELETE` semantics:

- lane parent: `(tenant_id, parent_lane_id)` with `ON DELETE RESTRICT`
- reservation lane: `(tenant_id, lane_id)` with `ON DELETE RESTRICT`
- reservation pricing: `(lane_id, pricing_rule_id)` with `ON DELETE RESTRICT`
- lane block lane: `(tenant_id, lane_id)` with `ON DELETE RESTRICT`
- event-lane event: `(tenant_id, event_id)` with `ON DELETE CASCADE`
- event-lane lane: `(tenant_id, lane_id)` with `ON DELETE RESTRICT`
- event registration event: `(tenant_id, event_id)` with `MATCH SIMPLE`, `ON DELETE CASCADE`

Each replacement FK was added `NOT VALID`, validated against existing rows, and only then replaced the simple FK. This removes duplicate PostgREST relationship paths. A null `parent_lane_id` and a null historical `event_registrations.event_id` remain valid.

## 5. Pricing integrity

`reservations(lane_id, pricing_rule_id)` must now resolve to the same lane in `lane_pricing_rules`. Existing pricing ranges, exclusion rules and price calculation behavior were not changed. `reservations_no_overlapping_active_booking` remains present and unchanged.

## 6. Email delivery trigger

`set_email_delivery_tenant_id` runs `BEFORE INSERT OR UPDATE` and supports exactly:

- `reservation_confirmation` → `reservations`
- `reservation_cancellation` → `reservations`
- `event_registration_confirmation` → `event_registrations`

It derives `tenant_id` from the target, rejects unsupported types, missing targets and supplied mismatches, then assigns the trusted value. Legacy CSK writers that omit `tenant_id` continue to work.

## 7. Audit tenant trigger

`set_audit_log_tenant_id` runs `BEFORE INSERT OR UPDATE`. Tenant-scoped targets are `reservation`, `event_registration` and `lane_booking_family`. Global targets are `profile` and `account`, for which `tenant_id` must remain null. Unknown target types, missing tenant targets and supplied mismatches fail closed. No FK from `audit_logs` to lifecycle targets was added, so retained audit history is not coupled to target deletion.

## 8. Trigger security model

Both trigger functions are `SECURITY INVOKER`, owned by `postgres`, use the fixed `search_path=pg_catalog`, and reference all business objects with schema-qualified names. `PUBLIC`, `anon`, `authenticated` and `service_role` have no direct `EXECUTE`. No public RPC or `SECURITY DEFINER` function was added.

## 9. Migration 9B-3B

`20260909130000_add_tenant_query_indexes.sql` is index-only and uses the same short timeouts. Before DDL it inspects existing key columns and fails if any planned index is already left-prefix covered.

## 10. Index deduplication matrix

| Table | Existing relevant prefix | New minimal prefix | Decision |
|---|---|---|---|
| shooting_lanes | `parent_lane_id` | `tenant_id,parent_lane_id,display_order,id` | ADD |
| reservations | `reservation_date,start_time,id` | `tenant_id,reservation_date,start_time,id` | ADD |
| lane_blocks | `lane_id,block_date,is_active,...` | `tenant_id,block_date,lane_id,is_active,...` | ADD |
| events | `is_active,event_date,start_time,id` | `tenant_id,is_active,event_date,start_time,id` | ADD |
| event_lanes | `event_id,lane_id`; `lane_id,event_id` | `tenant_id,event_id,lane_id` | ADD |
| event_registrations | `user_id,created_at,id` | `tenant_id,user_id,created_at DESC,id` | ADD |
| audit_logs | primary key only | `tenant_id,created_at DESC,id` partial | ADD |
| email_deliveries | unique `message_type,record_id` | none | SKIP |

No planned index was redundant on the actual schema. Existing indexes were retained.

## 11. Final indexes added

Exactly seven indexes were added:

1. `shooting_lanes_tenant_hierarchy_order_idx`
2. `reservations_tenant_schedule_idx`
3. `lane_blocks_tenant_schedule_idx`
4. `events_tenant_active_schedule_idx`
5. `event_lanes_tenant_event_lane_idx`
6. `event_registrations_tenant_user_created_idx`
7. `audit_logs_tenant_created_idx` (`WHERE tenant_id IS NOT NULL`)

## 12. Focused test results

- SAAS-9B-3 SQL: **50/50 PASS**, exit 0
- Transaction structure: one fixture transaction, final `ROLLBACK`, independent fixture post-check
- Remaining SAAS-9B-3 fixture: **0**
- Relationship allow/deny, nullable event history, delivery derivation, audit classification, active guard and all seven indexes: **PASS**

## 13. Regression results

- Local migration replay (`supabase db reset --local`): **PASS**
- Full Supabase DB suite: **21 files / 490 checks PASS**
- All Node tests: **727/727 PASS**
- Focused operational Node tests (Booking, Reservations, Calendar, Reports, Events, Check-in, lane configuration): **354/354 PASS**
- TypeScript `tsc --noEmit`: **PASS**
- Production build: **PASS** (known Next.js middleware-to-proxy warning only)
- Playwright full local suite: **29/29 PASS**
- `git diff --check`: **PASS**
- `npm audit --omit=dev`: **1 MODERATE finding** in `baseline-browser-mapping@2.10.30`, pulled by `next@16.3.4` (`GHSA-w5vr-8v7q-w6rv`); this dependency finding is unrelated to SAAS-9B-3 and was not changed out of scope.

## 14. RLS/ACL/RPC fingerprint comparison

- RLS policy fingerprint: unchanged, `f5c428bd4e241af39f690c1aafcfad08`
- Table ACL fingerprint: unchanged, `cc439ed94c9949ad6461925f428940a6`
- `get_my_role()` fingerprint: unchanged, `dc8858eed7d2fd2d1ab47d22b0000b06`
- `create_reservation_v2(...)` fingerprint: unchanged, `3f201f96dc413736d564089536b98d7d`
- SEC-002 exact function inventory test was updated from 75/7 to 77/9 solely for the two new owner-only trigger functions; full ACL suite passes.

## 15. Legacy runtime compatibility

No application, RLS, membership authorization or RPC behavior changed. Existing legacy writers omit `tenant_id`; the seven CSK defaults preserve core inserts, while the two new triggers derive delivery/audit ownership. Local lane-family creation, reservation, event, reports and check-in regressions pass.

## 16. Temporary CSK defaults status

All seven approved temporary CSK defaults remain on `shooting_lanes`, `reservations`, `lane_blocks`, `events`, `event_lanes`, `event_registrations` and `email_deliveries`. `audit_logs` still has no tenant default.

**REMOVE TEMPORARY CSK DEFAULTS BEFORE:**

- SAAS-9D tenant-aware writer cutover
- second tenant activation

## 17. Active-tenant guard status

`tenants_single_active_runtime_guard` remains effective. The focused test proves a second active tenant is denied. `tenant_memberships` remains empty and unused by runtime authorization.

## 18. Temp fixture cleanup

The focused SQL fixture rolled back completely. Playwright-created local lane families were removed by a final local migration replay rather than manual DML. Independent post-checks report zero SAAS-9B-3 fixture and zero `[TEST]` lanes.

TEMP FILES LEFT: **0**

## 19. Rollback plan

Before production, capture catalog definitions and counts. If 9B-3B must be rolled back, drop only its seven named indexes. If 9B-3A must be rolled back, first recreate and validate the original simple FKs with their original delete actions under temporary names, then remove the triggers/functions and composite FKs, rename validated simple FKs, and finally remove only the three new unique constraints. Never remove composite integrity while a second tenant is possible. A failed migration transaction needs no partial cleanup.

## 20. Production deployment plan

Run a fresh read-only production data/catalog preflight and migration-history check, verify SHA-256 of both migration files, then run linked `db push --dry-run`. Deployment must list only `20260909120000` and `20260909130000`. Stop on any new audit target, delivery type, orphan, mismatch, redundant index, lock warning or migration divergence. A separate explicit approval is required before production push. Apply 9B-3A before 9B-3B and run post-deploy integrity/runtime smoke afterward.

## 21. Git status

Implementation remains unstaged and uncommitted. No historical migration changed.

```text
 M supabase/tests/20260816143000_harden_public_function_execute_acl_test.sql
?? SAAS_9B_3_PRODUCTION_PREFLIGHT_AND_FINAL_PLAN.md
?? SAAS_9B_3_TENANT_INTEGRITY_IMPLEMENTATION_REPORT.md
?? supabase/migrations/20260909120000_add_tenant_relationship_integrity.sql
?? supabase/migrations/20260909130000_add_tenant_query_indexes.sql
?? supabase/tests/20260909130000_tenant_relationship_integrity_test.sql
```

## 22. Final verdict

SAAS-9B-3 LOCAL IMPLEMENTATION: **PASS**

SAAS-9B-3A: **PASS**

SAAS-9B-3B: **PASS**

READY FOR SAAS-9B-3 PRODUCTION PREFLIGHT: **GO**

READY FOR PRODUCTION PUSH: **NO**

READY FOR SAAS-9C PLANNING: **NO-GO until production deployment**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## SAAS-9B-3R — APPLICATION SPLIT-READ REMEDIATION

### 44. Root cause and approaches rejected

The production `PGRST200` regression is caused by the application query hint, not by invalid data or an unvalidated foreign key. After SAAS-9B-3 changed the lane self-reference from a simple FK to the validated composite FK `(tenant_id,parent_lane_id) -> shooting_lanes(tenant_id,id)`, PostgREST no longer resolves the runtime selector `shooting_lanes!parent_lane_id`.

Two non-mutating production diagnostics had already proved that neither a PostgREST schema-cache reload nor an explicit `!shooting_lanes_parent_lane_id_fkey` hint restores the self-embed. This hotfix therefore does not add a weaker simple FK, a computed relationship, a migration, or a database workaround.

### 45. Affected runtime query inventory

| File / function | Previous query path | Required UI output |
|---|---|---|
| `app/admin/page.tsx` / `loadDashboard` | today's reservations with nested lane parent | reservation plus `shooting_lanes.parent_lane` for the full hierarchy label |
| `app/admin/page.tsx` / `loadDashboard` | monthly reservations with nested lane parent | same DTO used by dashboard KPI and list presentation |
| `app/admin/reservations/page.tsx` / `loadReservations` | lane search dataset with nested parent | lane rows with `parent_lane` for hierarchy-aware text search |
| `app/admin/reservations/page.tsx` / `loadReservations` | reservation list with nested lane parent | unchanged reservation DTO and lane label shape |
| `app/admin/check-in/page.tsx` / `loadReservations` | operational reservation list with nested lane parent | unchanged check-in reservation DTO and lane label shape |
| `app/admin/check-in/page.tsx` / `refreshReservationAfterAttendance` | refreshed reservation with nested lane parent | refreshed row with the same `parent_lane` shape |

All six runtime self-embeds were removed. The old selector text remains only in a source regression assertion that verifies its absence from the affected runtime files.

### 46. Split-read architecture and tenant safety

`lib/admin/lane-parent-hydration.js` implements the shared, bounded hydration step:

1. Query A reads each lane relation without a self-embed and keeps `id`, `name`, `resource_kind`, `parent_lane_id`, `display_order`, and `is_active`.
2. Parent IDs are accepted only from those database-returned lane rows, filtered to non-empty strings, and deduplicated with a `Set`.
3. When all rows are roots, no second query is issued.
4. Otherwise exactly one `.in("id", parentIds)` query fetches the minimal parent projection.
5. A `Map` reconstructs the existing `lane.parent_lane` object while preserving object/array/null relation cardinality.
6. A failed parent query or a non-null parent ID with no returned parent throws the controlled `LaneParentHydrationError`; affected pages fail closed with a stable Polish UI message.

There is no query per reservation or per child. Dashboard hydration combines the today and month datasets into one parent batch. The reservation search and result datasets each use one batch appropriate to their independent query scopes. Existing RLS remains responsible for each browser read, while the validated composite FK continues to guarantee same-tenant parent integrity. No client-supplied parent identifier is trusted.

### 47. Files changed by SAAS-9B-3R

- `app/admin/page.tsx`
- `app/admin/reservations/page.tsx`
- `app/admin/check-in/page.tsx`
- `lib/admin/lane-parent-hydration.js`
- `lib/admin/lane-parent-hydration.d.ts`
- `lib/admin/lane-parent-hydration.test.mjs`
- `app/admin/admin-hierarchy-labels.test.mjs`
- `tests/e2e/admin-action-queues.spec.ts`
- this report

The pre-existing SAAS-9B-3 migrations, SQL tests, ACL inventory update, and planning report remain separate working-tree changes. SAAS-9B-3R changes no SQL, migration, database object, dependency manifest, middleware, RPC, RLS, or ACL.

### 48. DTO compatibility and query-count verification

The UI contract is unchanged: root lanes receive `parent_lane: null`; child lanes receive the minimal parent object; reservation fields and the Supabase relation cardinality are preserved. Existing `getLaneRelationDisplay(...)` call sites and all operational actions remain unchanged.

Focused helper tests prove:

- root rows issue zero parent queries;
- a child hydrates its correct parent;
- multiple children sharing one parent issue one deduplicated batch lookup;
- multiple distinct parents are fetched in one batch;
- missing parents and parent-read failures fail closed;
- reservation DTO fields and object/array/null lane shape remain unchanged.

### 49. Local verification results

- Parent hydration plus hierarchy source tests: **13/13 PASS**.
- Focused admin/reservations/check-in/hierarchy and operational tests: **50/50 PASS**.
- All Node tests: **734/734 PASS**.
- TypeScript `npx.cmd tsc --noEmit`: **PASS**.
- Next.js production build: **PASS**; only the known middleware-to-proxy deprecation warning remains.
- Changed-files ESLint: **0 errors, 2 existing React hook dependency warnings**.
- Full local Supabase DB suite: **21 files / 490 checks PASS**.
- Focused local Playwright: **5/5 PASS**.
- `git diff --check`: **PASS**.

The focused Playwright run authenticated a synthetic local admin and loaded `/admin`, `/admin/reservations`, and `/admin/check-in`, followed by Booking, Calendar, Reports, Events, and lane configuration. All expected headings rendered and no HTTP 5xx response was observed. The synthetic Auth user was removed by the test cleanup.

### 50. Database and security invariants after the hotfix

Read-only local catalog/data checks and the full DB suite confirm:

- validated composite relationship FKs: **7/7**;
- tenant-prefixed indexes: **7/7**;
- active email-delivery/audit integrity triggers: **2/2**;
- cross-tenant relationship/pricing mismatches: **0**;
- active-tenant guard: **present**;
- temporary CSK defaults: **7/7**;
- `tenant_memberships`: **0**.

The DB suite also reconfirmed the accepted local fingerprints: RLS `f5c428bd4e241af39f690c1aafcfad08`, table ACL `cc439ed94c9949ad6461925f428940a6`, `get_my_role()` `dc8858eed7d2fd2d1ab47d22b0000b06`, and `create_reservation_v2(...)` `3f201f96dc413736d564089536b98d7d`. `profiles.role` remains the legacy runtime authorization source. Tenant membership authorization, middleware, tenant resolution, RPCs, and `SECURITY DEFINER` functions are unchanged.

### 51. Deployment and checkpoint status

This is an **APP ONLY** compatibility hotfix. A separately approved application deployment must precede a production runtime smoke of `/admin`, `/admin/reservations`, and `/admin/check-in`; no DB deployment is required or permitted. Until that production deployment and smoke occur, the historical SAAS-9B-3 post-deploy verification remains failed.

The working tree intentionally remains dirty and unstaged. No `git add`, commit, push, database push, or production deployment was performed.

Final repository identity is branch `main` at `2b056bb3e74b0b8c1b92228ff01a67153e0677a6`. `git status --short` reports the four modified runtime/source-test files, the modified Playwright test, the pre-existing modified ACL inventory test, and the untracked helper/report/SAAS-9B-3 migration-test artifacts listed above. Nothing is staged. The tracked `git diff --stat` is `6 files changed, 131 insertions(+), 55 deletions(-)`; it excludes untracked files by Git design.

### 52. SAAS-9B-3R final verdict

SAAS-9B-3R LOCAL HOTFIX: **PASS**

OLD SELF-EMBED RUNTIME USAGES: **0**

N+1 QUERY RISK: **PASS**

READY FOR APPLICATION PRODUCTION DEPLOY: **YES**

SAAS-9B-3 POST-DEPLOY VERIFICATION: **STILL FAIL until application hotfix deployed**

READY FOR GIT CHECKPOINT: **NO**

READY FOR SAAS-9C PLANNING: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## POST-DEPLOY REGRESSION REMEDIATION

### 44. Exact usage inventory

The obsolete PostgREST self-relation hint occurs in six production select strings across three files:

| File | Function/query context | Uses |
|---|---|---:|
| `app/admin/page.tsx` | dashboard: today's and monthly reservation reads | 2 |
| `app/admin/reservations/page.tsx` | lane search read and reservation list read | 2 |
| `app/admin/check-in/page.tsx` | reservation list and single-reservation refresh | 2 |

One focused test assertion in `app/admin/admin-hierarchy-labels.test.mjs` explicitly requires the old `shooting_lanes!parent_lane_id` selector. No other application self-embed of `shooting_lanes` was found. Other `shooting_lanes(...)` embeds are non-self relationships and are not implicated.

The exact failing inner selection is:

```text
parent_lane:shooting_lanes!parent_lane_id (...)
```

### 45. Production self-FK contract

Production contains exactly one self-FK on `shooting_lanes`:

- constraint: `shooting_lanes_parent_lane_id_fkey`;
- local columns: `(tenant_id,parent_lane_id)`;
- referenced columns: `(tenant_id,id)`;
- definition: `FOREIGN KEY (tenant_id,parent_lane_id) REFERENCES shooting_lanes(tenant_id,id) ON DELETE RESTRICT`;
- validated: true.

The composite constraint correctly permits root/standalone lanes with `parent_lane_id IS NULL`, enforces same-tenant parent/child rows, and rejects a cross-tenant parent relationship.

### 46. Schema-cache reload result

The authorized non-destructive command was executed successfully:

```sql
NOTIFY pgrst, 'reload schema';
```

After waiting for the reload, the exact production REST reproduction still returned:

```text
PGRST200
Could not find a relationship between 'shooting_lanes' and 'shooting_lanes' in the schema cache
hint: parent_lane_id
```

The production browser smoke was repeated after the reload:

- `/admin`: FAIL — today's reservations read error;
- `/admin/reservations`: FAIL — reservation read error;
- `/admin/check-in`: FAIL — reservation read error.

Therefore the cause is not a stale PostgREST schema cache.

### 47. Explicit composite-FK hint result

A second read-only production REST probe replaced the column hint with the exact constraint-name hint:

```text
parent_lane:shooting_lanes!shooting_lanes_parent_lane_id_fkey (...)
```

It also returned `PGRST200`, with details stating that no self-relationship matching `shooting_lanes_parent_lane_id_fkey` was found. The explicit hint is therefore not a viable application-only substitution on the current production PostgREST schema cache.

### 48. Root cause and remediation boundary

Root cause classification: **QUERY HINT / PostgREST composite self-relationship discovery incompatibility**.

SAAS-9B-3 correctly preserved the stable constraint name and composite tenant integrity, but PostgREST does not expose this composite self-FK as an embeddable `shooting_lanes -> shooting_lanes` relationship in the current production contract. Both the old column hint and the exact constraint-name hint fail. The application regression is deterministic and affects all six selectors listed above.

No simple compatibility FK was restored, no composite FK was removed, and no application query was changed during this diagnostic stage.

### 49. Forward-fix options requiring review

1. **Application-only split read (recommended first option).** Remove the nested self-embed from the six queries, retain the direct reservation-to-lane embed, fetch the bounded parent-lane set separately, and assemble hierarchy labels through one shared helper. This preserves every composite FK and requires no DB migration, but changes query orchestration and must be tested for bounded reads, error handling, and refresh consistency.
2. **Computed PostgREST relationship.** Add a narrowly scoped computed relationship for a lane's parent, then use that named relationship in the application. This requires a new migration, careful function ACL/security/search-path review, and a new production deployment.
3. **Simple compatibility FK.** Add an additional `(parent_lane_id) -> shooting_lanes(id)` constraint while retaining the composite FK. This is the last-resort option because it creates overlapping self-relations and requires a separate PostgREST ambiguity and tenant-integrity impact analysis.

Per the approved boundary, implementation stops before choosing or applying any of these alternatives. A separate decision is required. Option 1 has the smallest database/security impact.

### 50. Tests and current production state

- exact production REST reproduction with column hint: FAIL (`PGRST200`);
- exact production REST reproduction with constraint-name hint: FAIL (`PGRST200`);
- post-reload `/admin`: FAIL;
- post-reload `/admin/reservations`: FAIL;
- post-reload `/admin/check-in`: FAIL;
- composite FK: 7/7 remain validated;
- tenant indexes: 7/7 remain present;
- RLS/ACL/critical RPC fingerprints: unchanged from the verified 9B-2 baseline;
- tenant integrity and business data: unchanged;
- temporary diagnostic files: removed.

No local code fix exists in this stage, so the full Node/TypeScript/build/Playwright regression was not rerun. The previously passing SAAS-9B-3 suites remain historical evidence for database integrity, not evidence that the current production read regression is resolved.

### 51. SAAS-9B-3R verdict

SAAS-9B-3R ROOT CAUSE: **QUERY HINT**

SAAS-9B-3R LOCAL FIX: **FAIL — required but not implemented pending option approval**

READY FOR APPLICATION HOTFIX DEPLOY: **NO**

SAAS-9B-3 POST-DEPLOY VERIFICATION: **FAIL**

READY FOR GIT CHECKPOINT: **NO**

READY FOR SAAS-9C PLANNING: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## PRODUCTION PREFLIGHT & DEPLOYMENT READINESS

### 23. Execution boundary

The final production preflight was executed on 9 September 2026 against the linked project `yuyxfodozzpzrdzkmolu`. All database inspection was read-only. The only deployment command was `supabase db push --linked --dry-run`; no migration, SQL write, migration repair, application change, commit, push, or deployment was performed.

Repository baseline:

- branch: `main`;
- HEAD: `2b056bb3e74b0b8c1b92228ff01a67153e0677a6`;
- exactly two new migration files are present;
- historical SAAS-9B-1 and SAAS-9B-2 migrations are unchanged;
- dependency manifests are unchanged;
- the only tracked test change is the SEC-002 ACL inventory update for the two new internal trigger functions.

### 24. Fresh production data preflight

Fresh production counts and sizes remained:

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

Every mandatory integrity counter is zero:

- unknown tenant references;
- missing lane parents and lane/parent tenant mismatches;
- missing reservation lanes, reservation/lane tenant mismatches, missing or NULL pricing rules, and reservation/pricing lane mismatches;
- missing lane-block lanes and tenant mismatches;
- missing event-lane event/lane targets and both tenant mismatch directions;
- NULL or missing registration events and registration/event tenant mismatches.

All tenant-owned rows belong to the canonical CSK tenant. No production data blocker was found.

### 25. Delivery and audit classification

`email_deliveries` contains only `reservation_confirmation` (11 rows). Unsupported message types, missing targets, and target/tenant mismatches are all zero. The repository whitelist remains exactly:

- `reservation_confirmation -> reservations`;
- `reservation_cancellation -> reservations`;
- `event_registration_confirmation -> event_registrations`.

The fresh audit inventory is identical to the approved map: 17 observed action/target pairs, all classified as tenant-scoped or global. Aggregate checks returned:

| Check | Result |
|---|---:|
| unknown audit rows | 0 |
| tenant-scoped audits with NULL tenant | 0 |
| global audits with non-NULL tenant | 0 |
| audits referencing a missing tenant | 0 |

No new `action` or `target_type` appeared. The trigger classifiers therefore remain complete for the current production contract.

### 26. Composite FK and NULL feasibility

All current simple foreign keys are present and validated with the expected delete actions. Production nullability is compatible with the migration:

- `shooting_lanes.parent_lane_id`: nullable;
- `event_registrations.event_id`: nullable;
- `reservations.pricing_rule_id`: not nullable.

The proposed event-registration composite FK uses PostgreSQL `MATCH SIMPLE`, so historical rows with `event_id IS NULL` remain valid. The other relations have no orphan or cross-tenant row. Adding each composite FK as `NOT VALID`, validating it, then replacing the corresponding simple FK in the same migration is feasible on the current data and avoids a lasting duplicate PostgREST relationship.

### 27. Trigger contract verification

Both planned functions remain internal `BEFORE INSERT OR UPDATE` row-trigger functions. They are `SECURITY INVOKER`, owned by `postgres`, use fixed `search_path = pg_catalog`, and fully qualify business objects. Direct execution is revoked from `PUBLIC`, `anon`, `authenticated`, and `service_role`.

- `set_email_delivery_tenant_id()` derives ownership only from the three approved message-type mappings and fails closed for unsupported, missing, or mismatched targets.
- `set_audit_log_tenant_id()` derives ownership for `reservation`, `event_registration`, and `lane_booking_family`; requires NULL tenant for `profile` and `account`; and fails closed for unknown, missing, or mismatched targets.

Neither function is a browser/API RPC, neither is `SECURITY DEFINER`, and no RLS policy or table ACL is changed by the migrations.

### 28. Production index inventory and deduplication

Production has 26 existing indexes across the nine inspected tables. None has `tenant_id` as its left prefix, and none left-prefix covers a planned SAAS-9B-3B index. None of the three planned referenced unique keys or seven named query indexes exists yet.

The final deduplication decision remains exactly seven query indexes: hierarchy, reservation schedule, lane-block schedule, active event schedule, event-lane relation, user event-registration history, and partial tenant audit history. No current index is dropped. No `email_deliveries` tenant index is added because no current tenant-list query path justifies it.

### 29. Migration history and file identity

Linked migration history is aligned through `20260909110000`. There is no remote-only migration and no divergence. The only local pending migrations are:

1. `20260909120000_add_tenant_relationship_integrity.sql`;
2. `20260909130000_add_tenant_query_indexes.sql`.

SHA-256 fingerprints:

| Migration | SHA-256 |
|---|---|
| `20260909120000_add_tenant_relationship_integrity.sql` | `C0452CA98EEB340C0A9B77E63C224ED7ECC61A82F322ECA683B61C3536E0118C` |
| `20260909130000_add_tenant_query_indexes.sql` | `664A83E3BD9FB585AC9CCFF731B5530B1E24036F7A36C733C69E9282F7AFB008` |

### 30. Production security/runtime baseline

Fresh production fingerprints remain equal to the accepted post-SAAS-9B-2 baseline:

- public function definitions: `5c40e2dc79e940095c40e6cba72583e4`;
- RLS policies: `f5c428bd4e241af39f690c1aafcfad08`;
- table ACLs: `cf05faffa475999df163338c3c1e805f`;
- `get_my_role()`: `dc8858eed7d2fd2d1ab47d22b0000b06`;
- `create_reservation_v2(...)`: `601664ae4957ed0eef29f85ded57a191`.

`tenant_memberships` remains empty, `profiles.role` remains the active legacy authorization source, the single-active-tenant guard remains present with exactly one active tenant, and all seven approved temporary CSK defaults remain. The different hashes documented earlier in this report are local-schema fingerprints; they are not used as a production baseline.

### 31. Lock and rollout risk

Total inspected volume is 257 rows and no table rewrite is required.

- data compatibility risk: **LOW**;
- constraint validation/backfill risk: **LOW** (there is no backfill in 9B-3);
- lock acquisition risk: **LOW to MEDIUM** because `ALTER TABLE`, unique-key construction, FK replacement, trigger creation, and ordinary `CREATE INDEX` require locks;
- runtime/PostgREST metadata risk: **MEDIUM**, controlled by atomic FK replacement and stable constraint names.

The migrations set `lock_timeout = 5s` and `statement_timeout = 120s`, so lock contention fails closed instead of waiting indefinitely. Current volume does not justify a full maintenance outage. Deploy in a short low-traffic window, apply 9B-3A before 9B-3B, and stop on any timeout or preflight failure.

### 32. Dry-run result

`npx.cmd supabase db push --linked --dry-run` completed with exit code 0 and explicitly reported that migrations would not be pushed. It listed exactly:

```text
20260909120000_add_tenant_relationship_integrity.sql
20260909130000_add_tenant_query_indexes.sql
```

No other migration was pending. The only warning was that Supabase CLI `2.117.0` is available while the installed CLI is `2.109.1`; this is informational and does not change the successful dry-run result.

### 33. Final production readiness verdict

SAAS-9B-3 PRODUCTION PREFLIGHT: **PASS**

READY FOR PRODUCTION PUSH: **YES**

READY FOR SAAS-9C PLANNING: **NO-GO until SAAS-9B-3 production deployment and post-deploy verification PASS**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

This report stops before the real production push. A new explicit approval is required to deploy either migration.

## PRODUCTION DEPLOYMENT & POST-DEPLOY VERIFICATION

### 34. Final pre-push gate

The final gate passed immediately before deployment:

- linked production project: `yuyxfodozzpzrdzkmolu`;
- branch: `main`;
- HEAD: `2b056bb3e74b0b8c1b92228ff01a67153e0677a6`;
- migration history aligned through `20260909110000`;
- no remote-only migration or divergence;
- pending set contained exactly `20260909120000` and `20260909130000`;
- SHA-256 values matched section 29 exactly;
- orphan, tenant mismatch, pricing mismatch, missing delivery target, unsupported delivery type, and unknown audit counts were all zero;
- active tenants: 1;
- tenant memberships: 0;
- temporary CSK defaults: 7;
- active-tenant guard: 1;
- other active database sessions observed at the final low-traffic gate: 0;
- temporary files and staged files: 0.

### 35. Production deployment result

`supabase db push --linked` completed with exit code 0. It applied exactly, in order:

1. `20260909120000_add_tenant_relationship_integrity.sql`;
2. `20260909130000_add_tenant_query_indexes.sql`.

No lock or statement timeout occurred, no aggressive retry was used, and no additional migration was applied. The CLI upgrade notice (`2.109.1` installed, `2.117.0` available) was informational only.

### 36. Post-deploy migration state

`supabase migration list --linked` reports LOCAL = REMOTE for both `20260909120000` and `20260909130000`. A subsequent `supabase db push --linked --dry-run` returned:

```text
Remote database is up to date.
```

### 37. Composite integrity and pricing verification

All three referenced unique keys and all seven replacement composite foreign keys exist and are validated. Stable relationship constraint names and original delete actions were preserved:

- lane parent: `(tenant_id,parent_lane_id) -> shooting_lanes(tenant_id,id)`, `RESTRICT`;
- reservation lane: `(tenant_id,lane_id) -> shooting_lanes(tenant_id,id)`, `RESTRICT`;
- reservation pricing: `(lane_id,pricing_rule_id) -> lane_pricing_rules(lane_id,id)`, `RESTRICT`;
- lane-block lane: `(tenant_id,lane_id) -> shooting_lanes(tenant_id,id)`, `RESTRICT`;
- event-lane event: `(tenant_id,event_id) -> events(tenant_id,id)`, `CASCADE`;
- event-lane lane: `(tenant_id,lane_id) -> shooting_lanes(tenant_id,id)`, `RESTRICT`;
- event-registration event: `(tenant_id,event_id) -> events(tenant_id,id)`, `CASCADE`, with `MATCH SIMPLE` NULL semantics.

Post-deploy tenant mismatch and pricing mismatch counts are zero. `reservations.pricing_rule_id` remains non-null; nullable historical `event_registrations.event_id` remains supported.

### 38. Delivery and audit trigger verification

Both enabled production triggers are `BEFORE INSERT OR UPDATE FOR EACH ROW`. Their functions are owned by `postgres`, are `SECURITY INVOKER`, have `search_path=pg_catalog`, and expose EXECUTE only to the owner—not to `PUBLIC`, `anon`, `authenticated`, or `service_role`.

A single rollback-only production test completed with exit code 0 and validated 12 cases:

- reservation and event-registration delivery tenant derivation;
- supplied delivery mismatch denial;
- missing delivery target denial;
- unknown delivery type denial;
- delivery UPDATE bypass denial;
- tenant audit derivation;
- supplied audit mismatch denial;
- global profile audit with NULL tenant;
- global audit with tenant denial;
- unknown audit target denial;
- missing tenant-scoped audit target denial.

The transaction ended with `ROLLBACK`. Independent post-checks found `marker_audits=0`; `email_deliveries` remained 11 and `audit_logs` remained 112. No business-target FK was added to `audit_logs`, so audit history remains decoupled from later target lifecycle changes.

### 39. Index verification

Exactly the approved seven tenant-prefixed indexes exist with the planned definitions. No other migration was deployed and no existing index was dropped. The pre-deploy catalog proved none was left-prefix duplicated; the post-deploy catalog contains exactly the seven named objects.

### 40. Security and business-data verification

Production fingerprints remain equal to the SAAS-9B-2 baseline:

- RLS: `f5c428bd4e241af39f690c1aafcfad08`;
- table ACL: `cf05faffa475999df163338c3c1e805f`;
- `get_my_role()`: `dc8858eed7d2fd2d1ab47d22b0000b06`;
- `create_reservation_v2(...)`: `601664ae4957ed0eef29f85ded57a191`.

`profiles.role` remains present as the legacy authorization source, memberships remain empty, the active-tenant guard remains present, and all seven temporary CSK defaults remain. The reservation overlap exclusion object remains present.

All eight business fingerprints excluding `tenant_id` and all row counts are identical to the accepted pre-deploy baseline. Therefore IDs, business values, ownership distribution, and existing data were not changed by 9B-3.

### 41. Runtime smoke and confirmed regression

| Runtime surface | Result | Evidence |
|---|---|---|
| Booking | PASS | Public booking configuration and lane families render. |
| Login/session | PASS | Existing production admin session remains authenticated. |
| Admin dashboard | **FAIL** | Controlled message: `Nie udało się pobrać dzisiejszych rezerwacji.` |
| Reservations | **FAIL** | Its direct reservation reader uses the same broken nested relationship selector. |
| Calendar | PASS | Day view, hierarchy, filters, and data render. |
| Reports | PASS | Report filters/KPI surface renders without runtime error. |
| Events | PASS | Public and admin event surfaces render. |
| Check-in | **FAIL** | Controlled message: `Nie udało się pobrać rezerwacji. Spróbuj ponownie.` |
| Lane family | PASS | Six families, five positions, and configuration data render. |

The failure was reproduced independently through the production PostgREST contract using the public client configuration without exposing credentials:

```text
code: PGRST200
message: Could not find a relationship between 'shooting_lanes' and 'shooting_lanes' in the schema cache
details: Searched for a foreign key relationship between 'shooting_lanes' and 'shooting_lanes' using the hint 'parent_lane_id' ... but no matches were found.
```

Root cause: the migration replaced the simple self-FK `(parent_lane_id)` with the composite FK `(tenant_id,parent_lane_id)`. Existing frontend selectors use `parent_lane:shooting_lanes!parent_lane_id(...)`; PostgREST no longer resolves that single-column hint for the composite relationship. This is a direct application compatibility regression caused by the 9B-3 relationship change, not data loss, ACL/RLS drift, or a transient schema-cache delay. Reloading did not clear it.

No automatic fix, rollback migration, schema mutation, or application deployment was attempted. A separately reviewed compatibility fix and production smoke are required before checkpointing 9B-3 or planning 9C.

### 42. Temp files and remaining risk

The rollback-test SQL and REST-reproduction helper were deleted after use. Final temporary-file check must remain zero. The principal current risk is operational: admin reservation-backed pages cannot resolve the nested parent-lane relationship. Composite integrity itself is active and data remains intact.

### 43. Final post-deploy verdict

SAAS-9B-3 PRODUCTION DEPLOY: **PASS**

SAAS-9B-3 POST-DEPLOY VERIFICATION: **FAIL**

READY FOR GIT CHECKPOINT: **NO**

READY FOR SAAS-9C PLANNING: **NO-GO**

READY FOR SAAS-9C IMPLEMENTATION: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## SAAS-9B-3R — PRODUCTION APPLICATION HOTFIX DEPLOYMENT

### 53. Final local deployment gate

The mandatory pre-deployment gate was repeated on branch `main` at HEAD `2b056bb3e74b0b8c1b92228ff01a67153e0677a6`:

- staging area: **empty**;
- old runtime `shooting_lanes!parent_lane_id` usage: **0**;
- explicit composite self-FK runtime embed hints: **0**;
- temporary diagnostic files: **0**;
- hierarchy/helper tests: **13/13 PASS**;
- focused operational tests: **50/50 PASS**;
- all Node tests: **734/734 PASS**;
- TypeScript: **PASS**;
- production build: **PASS**;
- `git diff --check`: **PASS** (only non-blocking CRLF conversion notices).

The split-read invariants remain covered: parent IDs are deduplicated, an all-root dataset skips the parent request, each non-root dataset uses one batch parent query, the `lane.parent_lane` DTO is preserved, and missing parents fail closed.

### 54. Deployment mechanism blocker

No application production deployment was executed. This checkout has no local `.vercel/project.json` linkage and no installed Vercel CLI command. The established production application workflow is commit-based through the Git-connected `main` branch. Deploying this uncommitted working tree through that workflow therefore requires a checkpoint commit and push.

The authorization for this step explicitly requires stopping before deployment if commit/push is technically required and keeps the Git checkpoint as a separately approved stage. Installing or improvising a new direct Vercel CLI workflow would not be the existing standard workflow and was not attempted.

Consequently, production PGRST200 reproduction, the three affected route checks, full production runtime smoke, production query behavior, and post-application-deploy DB/security verification were not run in this blocked stage. The last verified production state remains unchanged: the database deployment is healthy, but the deployed application still contains the incompatible self-embed until the Git checkpoint/deployment is separately authorized.

### 55. Deployment-stage verdict

SAAS-9B-3R APPLICATION PRODUCTION DEPLOY: **FAIL — NOT EXECUTED; GIT CHECKPOINT/PUSH REQUIRED**

SAAS-9B-3R POST-DEPLOY SMOKE: **FAIL — NOT RUN**

PGRST200 REGRESSION: **NOT RESOLVED ON PRODUCTION**

SAAS-9B-3 POST-DEPLOY VERIFICATION: **FAIL**

READY FOR GIT CHECKPOINT: **YES — REQUIRES SEPARATE APPROVAL**

READY FOR SAAS-9C PLANNING: **NO-GO**

READY FOR SAAS-9C IMPLEMENTATION: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## SAAS-9B-3R — FINAL APPLICATION DEPLOYMENT AND POST-DEPLOY VERIFICATION

### 56. Checkpoint correction and publication

The unpublished checkpoint was corrected by removing only three trailing whitespace characters from lines 3–5 of `SAAS_9B_3_PRODUCTION_PREFLIGHT_AND_FINAL_PLAN.md`. No wording or implementation changed. The commit was amended with the unchanged message:

```text
SAAS-9B-3 tenant integrity and PostgREST hierarchy hotfix
```

The final checkpoint is `2e2b03c1004852a72f253c26e0487b6e9751a985`. It contains exactly the 14 approved SAAS-9B-3/9B-3R files. Before publication, the working tree and staging area were clean, `git diff HEAD^ HEAD --check`, `git show --check --oneline HEAD`, and `git diff --check` all passed, old self-embed runtime usage was zero, and temporary files were zero.

The commit was pushed by a normal fast-forward update to `origin/main`. Local `main` and `origin/main` both resolve to `2e2b03c1004852a72f253c26e0487b6e9751a985`, with divergence `0 0`. No force push, reset, rebase, migration, or production database write was performed during checkpoint publication.

### 57. Application deployment

The relevant Git-connected Vercel deployment context, `Vercel – csk-booking-5nwh`, completed successfully for commit `2e2b03c1004852a72f253c26e0487b6e9751a985` and reported `Deployment has completed`. The production application at `https://csk-booking-5nwh.vercel.app` serves the deployed hotfix.

A separate duplicate Vercel status context named `Vercel – csk-booking` reported failure. It is not the production project used by the application and did not prevent the `csk-booking-5nwh` production deployment. The duplicate integration remains configuration noise to review separately; it is not evidence of a failure of this production deployment.

### 58. PGRST200 regression verification

The three previously affected production surfaces now load successfully without the PostgREST self-relationship error:

| Surface | Result | Evidence |
|---|---|---|
| `/admin` | PASS | Dashboard and reservation-backed operational data render without the controlled load failure. |
| `/admin/reservations` | PASS | Filters and reservation list contract load without `PGRST200`. |
| `/admin/check-in` | PASS | Check-in surface loads with its controlled empty state and no relationship error. |

The additional `/admin/reservations?search=Stanowisko` smoke exercised a result set containing all five Oś 100 m child positions sharing the same parent. The batch parent hydration completed successfully, preserved child resources, and did not emit `PGRST200`.

Production currently has only one family with multiple child positions, so a live-data smoke across multiple distinct parents was not available without creating production fixture. That branch remains covered by the deployed helper contract and focused local tests. A missing parent is structurally constrained by the validated composite foreign key and remains covered by fail-closed helper tests.

### 59. Full production runtime smoke

| Runtime surface | Result | Evidence |
|---|---|---|
| Booking | PASS | Public booking loads all configured lane families. |
| Login/session | PASS | Login page loads and the existing authenticated admin session remains valid. |
| Admin dashboard | PASS | Dashboard loads without the previous reservation-query error. |
| Reservations | PASS | Reservation reader, filters, and empty state render. |
| Calendar | PASS | Root and child hierarchy, including Oś 100 m positions 1–5, renders. |
| Reports | PASS | KPI, filters, hierarchy resources, and details surface load. |
| Events | PASS | Public events and admin events load; hierarchy lane choices include child positions. |
| Check-in | PASS | Reservation-backed check-in surface loads without the previous error. |
| Lane configuration | PASS | Six families, five positions, roots, and children render. |

No production mutation or synthetic fixture was required for this application smoke.

### 60. Production database and security post-check

A read-only production catalog/invariant query returned:

```text
validated_composite_fks = 7
tenant_indexes = 7
integrity_triggers = 2
tenant_mismatches = 0
pricing_mismatches = 0
active_tenant_guard = 1
csk_defaults = 7
tenant_memberships = 0
```

The security fingerprints remain identical to the accepted SAAS-9B-2/9B-3 baseline:

- RLS: `f5c428bd4e241af39f690c1aafcfad08`;
- table ACL: `cf05faffa475999df163338c3c1e805f`;
- `get_my_role()`: `dc8858eed7d2fd2d1ab47d22b0000b06`;
- `create_reservation_v2(...)`: `601664ae4957ed0eef29f85ded57a191`.

Therefore the application-only hotfix did not alter RLS, ACL, the legacy role RPC, the reservation writer, tenant integrity objects, temporary CSK defaults, membership state, or the second-active-tenant guard. `profiles.role` remains the active legacy authorization source.

### 61. Final superseding verdict

Sections 54–55 record the historical pre-checkpoint deployment blocker and are superseded by the completed checkpoint, production deployment, and verification above.

WHITESPACE FIX: **PASS**

AMEND: **PASS**

CHECKPOINT COMMIT: **PASS**

PUSH: **PASS**

APPLICATION PRODUCTION DEPLOY: **PASS**

PGRST200 REGRESSION: **RESOLVED**

SAAS-9B-3 POST-DEPLOY VERIFICATION: **PASS**

READY FOR FINAL DOCUMENTATION CHECKPOINT: **YES**

READY FOR SAAS-9C PLANNING: **GO**

READY FOR SAAS-9C IMPLEMENTATION: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**
