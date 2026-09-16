# SAAS-9D-4B-1A — Tenant User Admin Notes Foundation

## Result

SAAS-9D-4B-1A is implemented and verified locally. No production operation,
Git staging, commit, or push was performed.

## Scope

This phase changes only:

- the tenant-scoped administrative-note data model;
- direct ACL/RLS denial for that model;
- the fail-closed one-way CSK backfill;
- the note source in `admin_list_users_v1`;
- the note writer in `admin_set_user_note_v1`;
- tenant binding for the corresponding audit event;
- focused and affected regression tests.

Role mutation, identity/contact mutation, verification, tenant-local last-admin
logic, account lifecycle, and all 4B-1B+ work remain untouched.

## New model

`public.tenant_user_admin_notes` uses the composite primary key
`(tenant_id,user_id)` and contains:

- `tenant_id` — FK to `public.tenants`, cascade on tenant deletion;
- `user_id` — FK to `auth.users`, cascade on account deletion;
- `admin_note` — maximum 2,000 characters;
- `updated_at` — database timestamp;
- `updated_by` — nullable FK to `auth.users`, set null when the actor account is
  deleted.

This retention behavior keeps the tenant-owned note while the subject account
exists and removes it with account deletion. Actor deletion does not remove the
note. Future leave-tenant and account-wide lifecycle policy remain separate
contracts and were not implemented here.

## Direct access

The table is owned by `postgres`, has RLS enabled and has zero policies.
PUBLIC, anon, authenticated, and service_role have no direct SELECT or DML
privileges. Only the controlled RPC bodies can access it.

## Backfill

The migration resolves exactly one active CSK tenant and calculates four
counts before writing:

1. non-null legacy notes;
2. operationally related users;
3. notes eligible for CSK backfill;
4. non-null notes on unrelated users.

Any unrelated legacy note aborts the migration. Eligible notes are copied once
only when the relationship is proven by tenant membership, tenant-owned
reservation, or an event registration whose tenant matches its event. There
is no blanket CSK assignment and no reverse synchronization.

On the clean local baseline the four migration counts were `0 / 0 / 0 / 0`.
Focused fixture coverage verifies exact eligible-note behavior and the
fail-closed relationship predicates.

## RPC cutover and compatibility

The public signatures and current list DTO are unchanged:

- `admin_list_users_v1(integer,integer,text,text,text,text)`;
- `admin_set_user_note_v1(uuid,text)`.

Both remain SECURITY DEFINER, owned by `postgres`, with
`search_path=pg_catalog, public, pg_temp` and authenticated-only EXECUTE. The
list reads notes exclusively from `tenant_user_admin_notes`; the writer writes
or deletes only that tenant row. Neither RPC reads or writes
`profiles.admin_note`, and there is deliberately no `coalesce` fallback.

The exact-single-active-tenant bridge preserves the current application call
shape until 9E. Zero or more than one active tenant fails closed. This is a
temporary compatibility mechanism, not authority for a second tenant.

## Authorization and isolation

Authorization requires all of:

- `auth.uid()`;
- an active admin membership in the resolved tenant;
- an approved operational relationship between the target user and that
  tenant.

The focused matrix proves separate A/B notes for the same user, A cannot read
or write B, B cannot change A, foreign-only and unrelated users are denied,
and pending/suspended/missing membership is denied. A global
`profiles.role=admin` without active tenant membership is denied.

## Audit

A changed mutation creates exactly one audit with:

- `tenant_id` equal to the resolved tenant;
- actor equal to `auth.uid()`;
- action `tenant_user_admin_note_updated`;
- target type `tenant_user_admin_note`;
- pseudonymous labels and no note contents or other PII.

An idempotent retry returns `no_change` and creates no second audit. The audit
tenant trigger recognizes only this new explicit action/target pair; previous
classification paths remain unchanged.

## Account-wide separation

The normalized definitions of account export and global anonymization are
guarded unchanged. The new note RPC does not invoke export, anonymization,
Auth deletion, or future leave-tenant logic. These remain distinct contracts.

## Test evidence

| Gate | Result |
|---|---|
| Local reset / migration replay | PASS |
| Focused SQL | 37/37 PASS |
| Cross-tenant note isolation | PASS |
| Global-role negative case | PASS |
| Membership-status negative cases | PASS |
| Exact-single-active bridge 0/1/>1 | PASS |
| Backfill exactness / no fallback | PASS |
| Tenant-bound PII-free audit / idempotency | PASS |
| Full Supabase DB suite | 1144/1144 PASS |
| Node full suite | 739/739 PASS |
| Focused admin-users Playwright | 1/1 PASS |
| TypeScript | PASS |
| Production build | PASS |
| Changed-file ESLint | PASS |
| `git diff --check` | PASS |
| Fixture cleanup | 0 |

`npm audit --omit=dev` reports one existing moderate advisory in
`baseline-browser-mapping`; this phase changes no package or lock file and does
not introduce that dependency result.

## Database invariants

- SECURITY DEFINER count: **67** (unchanged).
- Compatibility defaults: **7/7** (unchanged).
- Direct profile DML remains denied.
- Existing account lifecycle definitions remain unchanged.
- No application production code changed; the existing page remains caller
  compatible.

## Files changed by 4B-1A

- `supabase/migrations/20260919100000_add_tenant_user_admin_notes.sql`
- `supabase/tests/20260919100000_add_tenant_user_admin_notes_test.sql`
- `tests/e2e/admin-users-tenant-notes.spec.ts`
- affected historical ACL, audit, profile, tenant foundation, RLS, and reports
  regression tests whose exact catalog expectations include the new model or
  two cut-over RPC definitions;
- `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md`;
- this report.

Migration SHA-256:
`28F7F5F9A69B8B73741D69D56C6151CED06F741EDF75D43B2847806DB0751051`.

`AGENTS.md` is an unrelated pre-existing working-tree change and is excluded.

## Deployment and rollback

Deployment model is DB first / DB only. Production preflight is still
required. The migration is transactional and fail-closed. A migration failure
rolls back automatically. Any post-deploy correction must use a separately
reviewed corrective migration; no migration repair or manual production edit
is authorized.

## Final verdict

SAAS-9D-4B-1A LOCAL: **PASS**

TENANT NOTE MODEL: **PASS**

BACKFILL: **PASS**

NOTE TENANT ISOLATION: **PASS**

GLOBAL ROLE BYPASS: **REMOVED**

LEGACY NOTE FALLBACK: **REMOVED**

AUDIT TENANT BINDING: **PASS**

CALLER COMPATIBILITY: **PASS**

READY FOR 4B-1A PRODUCTION PREFLIGHT: **GO**

READY FOR 4B-1B: **NO-GO until review**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## Production deployment and post-deploy verification

Date: 2026-09-16 (Europe/Warsaw)

### Deployment result

The final fail-closed gate reconfirmed the linked project, approved migration
SHA-256, LOCAL=REMOTE through `20260918100000`, and exactly one pending
migration: `20260919100000_add_tenant_user_admin_notes.sql`. The production
inventory remained: one non-empty legacy note, one deterministic CSK backfill
candidate, zero unrelated notes and zero ambiguous notes. SECURITY DEFINER was
67 and compatibility defaults were 7/7.

`supabase db push --linked` applied only the approved migration. Post-deploy
migration history is LOCAL=REMOTE through `20260919100000`; the final dry-run
reports `Remote database is up to date`.

### Schema, ACL and backfill verification

- `public.tenant_user_admin_notes` exists, is owned by `postgres`, has RLS
  enabled and has zero policies;
- the primary key is `(tenant_id, user_id)` and all three target foreign keys
  exist;
- PUBLIC has no direct ACL and `anon`, `authenticated`, and `service_role`
  have no direct table privileges;
- the one eligible legacy note was backfilled once into the CSK tenant row;
- duplicate `(tenant_id, user_id)` rows: 0;
- `profiles.admin_note` remains legacy/frozen and neither active RPC contains a
  legacy operational fallback.

### RPC and isolation verification

Production normalized fingerprints match the approved target:

- `admin_list_users_v1(integer,integer,text,text,text,text)`:
  `2a95b1f3ba9c404adfa84f7eb9b8d425`;
- `admin_set_user_note_v1(uuid,text)`:
  `e8245e2156b20e6d1dfd48b4adfb747b`.

Both functions remain `SECURITY DEFINER`, owned by `postgres`, use
`search_path=pg_catalog, public, pg_temp`, and expose EXECUTE only to
`authenticated` among the tested client roles.

A production rollback-only synthetic matrix verified:

- the same user can have distinct Tenant A and Tenant B notes;
- Admin A reads and changes only A, while Admin B reads and changes only B;
- cross-tenant, B-only and unrelated targets are denied;
- global `profiles.role=admin` without active target membership is denied;
- pending and suspended memberships are denied;
- operational relationship predicates are enforced;
- retry/no-change does not create a second audit;
- the mutation audit is bound to the resolved tenant and does not include the
  note value;
- zero-active state fails closed and the exact-single-active bridge still
  resolves the current CSK tenant.

The transaction ended with `ROLLBACK`. Independent result counters were:
temporary tenants 0, synthetic profiles 0, tenant notes 0, memberships 0 and
audit fixtures 0. Production persisted fixture data: 0.

### Invariants and runtime

SECURITY DEFINER count remains 67 with no unexpected target drift.
Compatibility defaults remain 7/7. The migration does not modify global
account export, global anonymization, Auth deletion or future leave-tenant
semantics; the account-wide versus tenant-scoped contract is preserved.

Read-only runtime smoke returned no 5xx:

- `/admin/users`, `/admin`, `/admin/reservations`: controlled unauthenticated
  redirect to `/login`, final HTTP 200;
- `/booking`, `/events`, `/account`, `/login`: HTTP 200.

### Production verdicts

SAAS-9D-4B-1A PRODUCTION DEPLOY: **PASS**

SAAS-9D-4B-1A POST-DEPLOY: **PASS**

TENANT NOTE MODEL: **PASS**

LEGACY NOTE BACKFILL: **PASS**

NOTE TENANT ISOLATION: **PASS**

LEGACY NOTE FALLBACK: **REMOVED**

GLOBAL ROLE BYPASS: **REMOVED**

OPERATIONAL RELATIONSHIP: **PASS**

AUDIT TENANT BINDING: **PASS**

PII: **PASS**

ACCOUNT-WIDE CONTRACT: **PRESERVED**

SECURITY DEFINER COUNT: **67**

COMPATIBILITY DEFAULTS: **7/7**

FIXTURE CLEANUP: **PASS**

READY FOR GIT CHECKPOINT: **YES**

READY FOR SAAS-9D-4B-1B PLANNING: **GO**

READY FOR SAAS-9D-4B-1B IMPLEMENTATION: **NO-GO until checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## Production preflight & deployment readiness

### 1. Working tree

The canonical real working-tree scope contains exactly 11 SAAS-9D-4B-1A
files: this report, the implementation plan, the migration, its focused SQL
test, the focused Playwright test, and six affected historical regression
tests. `AGENTS.md` is the only unrelated real diff and remains excluded. No
unexpected real diff was found. CRLF warnings do not change this semantic
scope. `git diff --check` passes.

### 2. Migration identity and exact scope

Target:
`20260919100000_add_tenant_user_admin_notes.sql`

Recalculated SHA-256:
`28F7F5F9A69B8B73741D69D56C6151CED06F741EDF75D43B2847806DB0751051`

The migration is limited to the tenant note table, fail-closed direct access,
deterministic CSK backfill, `admin_set_user_note_v1` and
`admin_list_users_v1` cutover, and explicit tenant audit classification. The
role, identity, contact, verification and last-admin writers are snapshot
guards only. Account export/anonymization definitions are also guarded but not
changed. No application code, leave-tenant, Auth deletion or 4B-1B+ behavior
is implemented.

### 3. Production legacy-note inventory

The read-only production query returned:

| Measurement | Count |
|---|---:|
| Profiles | 9 |
| Non-empty `profiles.admin_note` rows | 1 |
| Legacy-note users related to CSK | 1 |
| Legacy-note users unrelated to CSK | 0 |
| Legacy-note users with multiple tenant candidates | 0 |
| Deterministically eligible CSK rows | 1 |
| Skipped unrelated rows | 0 |

The mandatory blocker is clear: **UNRELATED NON-EMPTY LEGACY NOTES = 0**.
No note contents or profile PII were returned by the preflight.

Four historical event registrations reference users without a current profile.
This existing lifecycle state does not intersect the sole legacy-note source
(which starts from `profiles`) and does not create a backfill candidate or
tenant ambiguity. Reservation users without profiles and registration/event
tenant mismatches are both zero.

### 4. Deterministic backfill matrix

| Class | Source | Eligible | Planned insert | Skipped | Reason |
|---|---:|---:|---:|---:|---|
| CSK-related non-empty legacy note | 1 | 1 | 1 | 0 | membership, reservation or tenant-consistent event registration proves CSK relationship |
| Unrelated legacy note | 0 | 0 | 0 | 0 | migration would abort before write |
| Multi-tenant ambiguous legacy note | 0 | 0 | 0 | 0 | none exists; no tenant is guessed |

The insert is one-way and keyed by `(tenant_id,user_id)`. Production currently
has no target table, as expected before the pending migration. The migration
fails if an unrelated source note exists and does not use a reverse sync or a
runtime legacy fallback.

### 5. Target model, FK, ACL and RLS

The locally replayed target catalog confirms:

- primary key: `(tenant_id,user_id)`;
- `tenant_id -> tenants(id) ON DELETE CASCADE`;
- `user_id -> auth.users(id) ON DELETE CASCADE`;
- `updated_by -> auth.users(id) ON DELETE SET NULL`;
- `admin_note text`, nullable, maximum 2,000 characters;
- `updated_at timestamptz NOT NULL DEFAULT transaction_timestamp()`;
- owner `postgres`, RLS enabled, zero policies;
- PUBLIC, anon, authenticated and service_role: no direct SELECT/INSERT/
  UPDATE/DELETE.

### 6. RPC target and no-legacy-fallback proof

Current production fingerprints match the required pre-migration baseline:

- `admin_list_users_v1`: `e0702f533d7a9ee5b7de93bb68ef3168`;
- `admin_set_user_note_v1`: `e3c20c8cf1cc0d986a54cca8a27bb11d`.

Target local fingerprints are:

- `admin_list_users_v1`: `2a95b1f3ba9c404adfa84f7eb9b8d425`;
- `admin_set_user_note_v1`: `e8245e2156b20e6d1dfd48b4adfb747b`.

Both target functions remain SECURITY DEFINER, owned by `postgres`, with SP1
and authenticated-only EXECUTE. Signatures, list DTO, pagination, filters,
sort order and current caller shape are unchanged. The list source is only
`tenant_user_admin_notes`; the writer modifies only that table. There is no
`coalesce` or equivalent fallback to `profiles.admin_note`, and the legacy
column is not updated.

### 7. Isolation, relationship and same-user semantics

The target requires active tenant-admin membership plus a target relationship
proven by membership, reservation, or tenant-consistent event registration.
User UUID existence and `profiles.role` are insufficient. Local evidence proves
foreign-only, unrelated, global-role-only, pending, suspended and no-membership
denials.

The composite key structurally permits independent A/B notes for one user.
The 37-check matrix proves Admin A sees and changes only A, Admin B sees and
changes only B, and changing either side leaves the other unchanged.

The exact-single-active-tenant bridge currently resolves one production CSK
tenant. Its zero and greater-than-one behavior is fail-closed by definition
and local tests. It remains explicitly temporary until 9E; no second tenant
was activated.

### 8. Audit, PII and account-wide separation

Changed note writes produce one PII-free
`tenant_user_admin_note_updated` audit with the resolved tenant ID. Note
contents are absent, and no-change creates no duplicate. Tenant A cannot read
Tenant B notes or unrelated profile rows; foreign denials return the same
controlled contract without identity details or membership metadata.

Production fingerprints for account export and global anonymization remain
`ffa6b35c5502a347e463110401032061` and
`7e4d950e75e6e5782b139f11269d03a0`. Auth deletion and future leave-tenant are
outside the migration. The account-wide versus tenant-scoped boundary is
preserved.

### 9. Inventories and local evidence

- production SECURITY DEFINER count: **67**;
- target SECURITY DEFINER count: **67**;
- unexpected target count drift: **0**;
- production and target compatibility defaults: **7/7**;
- focused SQL: **37/37 PASS**;
- full DB: **1144/1144 PASS**;
- Node: **739/739 PASS**;
- focused Playwright: **1/1 PASS**;
- TypeScript, build, changed-file ESLint and diff check: **PASS**;
- fixture cleanup: **0**.

### 10. Production runtime baseline

Read-only HTTP smoke returned no 5xx:

- `/admin/users`, `/admin`, `/admin/reservations`: controlled redirect to
  `/login`, final HTTP 200;
- `/booking`, `/events`, `/account`, `/login`: HTTP 200.

No note mutation was performed.

### 11. Migration history and dry-run

Supabase migration history is LOCAL=REMOTE through `20260918100000`. There are
no remote-only migrations and exactly one local-only migration:
`20260919100000_add_tenant_user_admin_notes.sql`.

`supabase db push --linked --dry-run` completed successfully and listed exactly
that one migration. No production push was executed.

### 12. Deployment risk

| Risk | Rating | Assessment |
|---|---|---|
| Table/schema creation | LOW | new isolated table, transactional DDL, no existing caller dependency before function replacement |
| Legacy-note backfill | LOW | one deterministic row, zero unrelated or ambiguous rows |
| Admin-users DTO regression | MEDIUM | broad existing DTO is preserved exactly; focused DB and Playwright evidence pass |
| Note write cutover | MEDIUM | operational storage changes, but signature/result/idempotency remain compatible |
| Audit binding | MEDIUM | explicit new action/target path with regression coverage |
| PII/cross-tenant impact | HIGH impact, controlled likelihood | fail-closed relationship checks, composite key and negative matrix |
| Caller compatibility | LOW | no application change and unchanged RPC signatures/DTO |

Overall deployment risk is **MEDIUM** because the change cuts over an active
administrative write/read path, despite the very small production backfill.
A low-traffic window is sufficient; a maintenance window is not indicated by
the observed volume. Post-deploy verification must still be rollback-only for
synthetic cross-tenant cases.

### 13. Blockers and readiness

No preflight blocker remains. Production write is not authorized by this
report. 4B-1B remains blocked until 4B-1A production PASS and checkpoint review.

SAAS-9D-4B-1A PRODUCTION PREFLIGHT: **PASS**

WORKING TREE SCOPE: **PASS**

SHA: **PASS**

MIGRATION SCOPE: **PASS**

TENANT NOTE MODEL: **PASS**

LEGACY NOTE BACKFILL: **PASS**

UNRELATED LEGACY NOTES: **0**

NOTE TENANT ISOLATION: **PASS**

LEGACY NOTE FALLBACK: **REMOVED IN TARGET**

GLOBAL ROLE BYPASS: **REMOVED IN TARGET**

OPERATIONAL RELATIONSHIP: **PASS**

AUDIT TENANT BINDING: **PASS**

PII: **PASS**

ACCOUNT-WIDE CONTRACT: **PRESERVED**

CALLER COMPATIBILITY: **PASS**

SECURITY DEFINER COUNT: **67**

READY FOR PRODUCTION PUSH: **YES**

READY FOR 4B-1B: **NO-GO until 4B-1A production PASS and checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**
