# SAAS-9D-4D-1 — Profile Trigger / Direct Profile Privilege Hardening

Date: 2026-09-18
Baseline: `46dd54e2a9863d4f5684b6d01480c4ad2879327c`
Environment: local only
Production write: no

## 1. Exact scope

The implementation changes exactly one database function and preserves its
existing trigger binding.

| Property | Value |
|---|---|
| Function | `public.prevent_non_admin_profile_privilege_changes()` |
| Signature | `()` returning `trigger` |
| Trigger | `prevent_non_admin_profile_privilege_changes_trigger` |
| Table | `public.profiles` |
| Event | `BEFORE UPDATE`, `FOR EACH ROW` |
| Invocation | implicit from every profile UPDATE; controlled writers and CSK role-sync bridge |
| Security mode | `SECURITY DEFINER` |
| Owner | `postgres` |
| Search path | `pg_catalog, public, pg_temp` |
| ACL | owner-only; PUBLIC, anon, authenticated and service_role have no direct EXECUTE |
| Application files | 0 |

No 4D-2 helper/caller cutover and no 4E booking-reader work is included.

## 2. Function and trigger inventory

The preflight requires the exact input normalized MD5, metadata, closed ACL,
one named trigger binding and exact fingerprints for all five approved profile
writers. It stops on any drift before replacing the trigger body.

The target remains a closed trigger boundary. It is not a callable browser or
service endpoint and creates no new grant, RLS policy, table or RPC.

## 3. Protected field matrix

| Field group | Owner self-service | Tenant staff/admin | System/controlled writer | Compatibility | Security authority |
|---|---|---|---|---|---|
| `id`, `user_id`, `email`, `created_at` and unlisted technical fields | deny | deny | only owner-operated PostgreSQL maintenance | no | none |
| `role` | deny | admin only through `admin_set_user_role_v1` and exact sync marker | CSK membership-to-profile mirror after membership role is authoritative | legacy mirror | `tenant_memberships.role`, never `profiles.role` |
| `first_name`, `last_name`, `full_name` | deny direct | admin through `update_profile_identity` for same-tenant operational user | exact identity marker and field-only diff | no | active admin membership + operational relation |
| phone and postal address fields | allow own profile through `update_my_profile_v1` | admin/employee through `update_profile_contact_details`; employee cannot target staff | exact contact marker and field-only diff | no | active membership role + operational relation |
| declaration and qualification booleans in owner RPC | allow own profile | no generic foreign path | owner allowlist; tenant verification invalidation remains in the RPC | no | owner identity only |
| permit identifiers and other non-allowlisted qualifications | deny | deny in 4D-1 | only separately approved owner maintenance | no | none in this trigger |
| `admin_note` | deny | deny | frozen | historical only | tenant note table is operational source |
| all legacy verification fields | deny | deny | frozen for tenant workflows | historical only | `tenant_user_verifications` is operational source |
| `updated_at` | only with an allowed operation | only with an allowed controlled writer | allowed alongside the exact approved diff | technical | none |

## 4. Fingerprints

- Input normalized MD5: `d28cb697d8355a5e8005296a03ad63ea`.
- Target normalized MD5: `8a3cb4dc2d663cbf3c866fc3d9c8dac7`.
- Normalization: `pg_get_functiondef`, CRLF to LF, then CR to LF.
- Writer fingerprints are guarded for self-service, role, identity, contact and
  membership-to-profile sync paths.

## 5. Authority model and global-role removal

The trigger contains no call to `public.is_admin()` and no actor lookup of
`profiles.role`. Tenant privilege comes from:

1. exactly one active tenant bridge for the current single-tenant runtime;
2. `get_my_tenant_role_v1(tenant_id)` backed by an active membership;
3. the exact closed writer actor/target marker;
4. a same-tenant operational relation for foreign identity/contact updates;
5. for role mirroring, equality between the requested legacy mapping and the
   already-written authoritative membership role.

Marker spoofing without these independent conditions is denied. A global
`profiles.role=admin` without active membership has no tenant authority.

## 6. Owner self-service

`update_my_profile_v1` remains compatible. It may change the owner's contact,
address and approved declaration/qualification fields only. Direct attempts to
change role, identity, email, permit data, legacy verification or legacy admin
note are denied. Tenant verification invalidation remains in the controlled
self-service RPC and was verified independently from frozen legacy fields.

## 7. Tenant membership authority

Admin and employee paths require active membership. Pending, suspended and
missing memberships are denied. Employee contact correction remains limited to
the existing scope and cannot target admin, employee or instructor profiles.
Tenant A cannot change a Tenant B-only profile or membership.

## 8. Frozen legacy fields

`profiles.admin_note` and the complete legacy profile verification set remain
frozen for authenticated tenant workflows. The operational sources remain
`tenant_user_admin_notes` and `tenant_user_verifications`. No legacy fallback,
dual-write or global-role authority was reactivated.

## 9. Service-role and system path

The only auth-less bypass is direct database-owner maintenance where
`session_user=postgres` and the effective `role` setting is `none` or
`postgres`. This is required for forward migrations and explicit owner
maintenance. PostgREST service_role operates under `SET ROLE service_role` and
is explicitly outside the exception; a direct protected UPDATE is denied.

Risk is bounded by owner credentials, closed function ACL and the exact role
test. The path neither derives nor grants tenant authority.

## 10. Cross-tenant behavior

Focused and concurrent tests prove:

- Tenant A admin to Tenant A operational user: allowed through the writer;
- Tenant A admin to Tenant B-only user: denied;
- forged actor/target GUC markers: denied;
- Tenant B membership remains unchanged;
- privilege escalation: 0;
- cross-tenant effects: 0.

## 11. Concurrency

The local concurrency suite covered parallel owner updates, admin identity
update versus owner contact/declaration update, an allowed update racing a
protected role escalation, and Tenant A activity against a Tenant B-only user.

- deadlocks: 0;
- lost valid updates: 0;
- privilege escalation: 0;
- cross-tenant effects: 0;
- fixture cleanup: 0.

## 12. ACL and security mode

Owner, search path, `SECURITY DEFINER` mode and closed ACL are unchanged.
Direct authenticated table UPDATE remains denied by the existing ACL/RLS
model; the trigger is a second, writer-level fail-closed boundary.

## 13. SECURITY DEFINER inventory and defaults

- SECURITY DEFINER count after 4D-1: `69`.
- Unexpected SECURITY DEFINER drift: `0`.
- Compatibility tenant defaults: `7/7` unchanged.
- Unknown objects: `0`.

## 14. Migration

File: `supabase/migrations/20260923100000_harden_profile_privilege_trigger.sql`

SHA-256:
`2E0CABC94DA70BFAC023FF5B3E4090A8A9AB7655A9DD6726F0877CA6CE1C23C1`

The migration is minimal, transactional and forward-only. Historical
migrations were not modified. Existing regression tests that intentionally
freeze the live trigger contract were updated to the new target fingerprint.

## 15. Tests

| Check | Result |
|---|---|
| Fresh local DB reset / all migrations | PASS |
| Focused 4D-1 SQL | 36/36 PASS |
| Direct escalation, owner, global-role, membership, frozen fields, service/system, cross-tenant, ACL/fingerprint | PASS |
| Concurrency | PASS; deadlocks/lost updates/escalation/cross-tenant effects all 0 |
| Full Supabase DB suite | 1376/1376 PASS |
| Node suite | 750/750 PASS |
| TypeScript | PASS |
| Production build | PASS; existing middleware deprecation warning only |
| Focused Playwright | 2/2 PASS |
| Fixture cleanup | 0 |

The first sandboxed Playwright attempt could not access the local Docker pipe
during its cleanup. It was rerun with local Docker permission and passed 2/2;
the two synthetic accounts left by the sandboxed cleanup failure were then
removed explicitly and the independent residue count was zero. This was an
environment permission issue, not an application or DB failure.

## 16. Production rollout plan

1. Reconcile real working-tree scope and migration SHA.
2. Read-only production preflight: project identity, current input/writer
   fingerprints, trigger metadata/ACL, SECURITY DEFINER=69, defaults=7/7,
   integrity and exactly one pending migration.
3. Require a separate explicit authorization before `db push`.
4. Deploy DB-only migration.
5. Verify migration history, final dry-run, target fingerprint, firing matrix,
   runtime smoke and rollback-only cleanup.

No production preflight or write was performed in this task.

## 17. Residual 4D-2 dependency

`get_my_role` and application/global role callers are intentionally unchanged.
Their cutover requires the trusted 9E tenant-context contract. Therefore
4D-2 remains NO-GO. 4E remains a separately authorized stage after the 4D-1
checkpoint. SECOND TENANT remains NO-GO and SEC-004 remains OPEN.

## 18. Final verdict

SAAS-9D-4D-1 LOCAL: **PASS**

EXACT SCOPE: **PASS**

DIRECT PROFILE PRIVILEGE PROTECTION: **PASS**

GLOBAL ROLE SECURITY AUTHORITY: **REMOVED**

TENANT MEMBERSHIP AUTHORITY: **PASS**

OWNER SELF-SERVICE: **PASS**

FROZEN LEGACY FIELD PROTECTION: **PASS**

CROSS-TENANT PRIVILEGE ISOLATION: **PASS**

SERVICE_ROLE / SYSTEM CONTRACT: **PASS**

CONCURRENCY: **PASS**

APP CHANGE: **0**

SECURITY DEFINER COUNT: **69**

COMPATIBILITY DEFAULTS: **7/7**

READY FOR 4D-1 PRODUCTION PREFLIGHT: **GO**

READY FOR 4D-2: **NO-GO until trusted 9E context**

READY FOR 4E: **NO-GO in this working tree; separate stage after 4D-1 checkpoint**

READY FOR PRODUCTION WRITE: **NO**

READY FOR 9D-5: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 21. Production deployment and post-deploy verification

### 21.1 Deployment result

The authorized linked production push applied exactly:

`20260923100000_harden_profile_privilege_trigger.sql`

No other migration was pending or deployed. The command completed successfully.
Post-deploy linked migration history is LOCAL = REMOTE through
`20260923100000`; the final linked dry-run returned `Remote database is up to
date.`

### 21.2 Function and trigger state

Fresh production catalog inspection after deployment confirmed:

- normalized function fingerprint:
  `8a3cb4dc2d663cbf3c866fc3d9c8dac7` (exact target match);
- signature: `prevent_non_admin_profile_privilege_changes()`;
- SECURITY DEFINER, owner `postgres`, search path
  `pg_catalog, public, pg_temp`;
- ACL remains closed to PUBLIC, `anon`, `authenticated` and `service_role`;
- exactly one enabled trigger remains bound to `public.profiles`, with the
  original trigger name and BEFORE UPDATE / FOR EACH ROW timing;
- the deployed body no longer uses `public.is_admin` or reads
  `profiles.role` as authorization authority;
- SECURITY DEFINER count remains `69` and compatibility defaults remain
  `7/7`.

Membership duplicates, membership orphans, unknown membership roles and
unknown membership statuses were all `0`; exactly one active tenant remains.

### 21.3 Rollback-only production matrix

A production SQL Editor transaction exercised the deployed boundary and ended
with an explicit `ROLLBACK`. The first fixture attempt was stopped by an
automatically-created membership before any check ran; that aborted transaction
was explicitly rolled back. The corrected idempotent fixture then returned
`12/12 ok` and its final assertion block completed without an exception.

Verified cases included:

- owner self-service allowed-field update;
- active tenant admin controlled identity update;
- active employee related-customer contact update;
- global `profiles.role=admin` without active membership denied;
- pending, suspended and missing membership denied;
- cross-tenant target denied;
- owner direct role escalation denied;
- `service_role` direct protected update denied;
- explicit owner-operated `postgres` maintenance exception retained.

An independent post-rollback query returned zero for synthetic tenants,
`auth.users`, profiles, memberships and test audit fixtures. Production data
persisted by the matrix: `0`.

### 21.4 Concurrency and runtime

The approved local parallel test remains applicable because the deployed
normalized definition exactly matches the locally tested target. It confirmed
parallel owner updates, staff-versus-owner updates and allowed-versus-protected
updates without privilege escalation, cross-tenant contamination, deadlocks or
lost valid updates. Live production stress was intentionally not repeated.

Post-deploy read-only HTTP smoke returned HTTP 200 and no 5xx for `/account`,
`/admin/users`, `/admin`, `/login`, `/register`, `/forgot-password` and
`/reset-password`.

### 21.5 Git state

No staging, commit or push was performed. `AGENTS.md` remains unrelated,
excluded and unstaged. `git diff --check` passes.

## 22. Final production verdicts

SAAS-9D-4D-1 PRODUCTION DEPLOY: **PASS**

SAAS-9D-4D-1 POST-DEPLOY: **PASS**

DIRECT PROFILE PRIVILEGE PROTECTION: **PASS**

GLOBAL ROLE BYPASS: **REMOVED**

TENANT MEMBERSHIP AUTHORITY: **PASS**

OWNER SELF-SERVICE: **PASS**

CONTROLLED STAFF WRITERS: **PASS**

CROSS-TENANT PROFILE ISOLATION: **PASS**

FROZEN LEGACY FIELDS: **PASS**

SERVICE_ROLE / SYSTEM CONTRACT: **PASS**

CONCURRENCY: **PASS**

SECURITY DEFINER COUNT: **69**

COMPATIBILITY DEFAULTS: **7/7**

FIXTURE CLEANUP: **PASS**

RUNTIME SMOKE: **PASS**

READY FOR GIT CHECKPOINT: **YES**

READY FOR SAAS-9D-4D-2: **NO-GO until trusted 9E context**

READY FOR SAAS-9D-4E PLANNING: **GO**

READY FOR SAAS-9D-4E IMPLEMENTATION: **NO-GO until checkpoint/review**

READY FOR SAAS-9D-5: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 19. Production preflight & deployment readiness

The following checks were performed read-only against linked production
project `yuyxfodozzpzrdzkmolu`. No production DML, DDL, fixture, migration
repair or real `db push` was executed.

### 19.1 Working tree

Branch `main` remains at
`46dd54e2a9863d4f5684b6d01480c4ad2879327c`, identical to `origin/main`.
The canonical real working-tree scope is:

| Classification | Files |
|---|---|
| 4D-1 migration | `supabase/migrations/20260923100000_harden_profile_privilege_trigger.sql` |
| 4D-1 focused tests | `supabase/tests/20260923100000_harden_profile_privilege_trigger_test.sql`; `supabase/tests/20260923100000_harden_profile_privilege_trigger_concurrency.ps1` |
| 4D-1 regression tests | five prior SQL tests whose single semantic change advances the frozen live trigger fingerprint to the reviewed 4D-1 target |
| 4D-1 report | this file |
| 4D-1 plan | `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md` |
| Unrelated | `AGENTS.md`, excluded and unstaged |
| Unexpected real diffs | 0 |

`git diff --check` passes. No application source file differs.

### 19.2 Migration SHA and exact scope

Recalculated SHA-256:
`2E0CABC94DA70BFAC023FF5B3E4090A8A9AB7655A9DD6726F0877CA6CE1C23C1`.

The migration contains one `CREATE OR REPLACE FUNCTION` for
`prevent_non_admin_profile_privilege_changes()`, restores the same postgres
owner and same closed ACL, and preserves the existing trigger binding. It
creates or changes no application file, table, column, constraint, RLS policy,
membership schema, verification model or admin-note model. It does not include
4D-2, 4E or 9D-5.

### 19.3 Production input function and trigger inventory

| Property | Production value | Result |
|---|---|---|
| Signature | `prevent_non_admin_profile_privilege_changes()` | PASS |
| Normalized input MD5 | `d28cb697d8355a5e8005296a03ad63ea` | PASS — exact pre-4D-1 baseline |
| Security mode | SECURITY DEFINER | PASS |
| Owner | `postgres` | PASS |
| Search path | `pg_catalog, public, pg_temp` | PASS |
| ACL | `postgres=X/postgres`; PUBLIC/anon/authenticated/service_role EXECUTE all false | PASS |
| Trigger name | `prevent_non_admin_profile_privilege_changes_trigger` | PASS |
| Table/event | `profiles`, BEFORE UPDATE, FOR EACH ROW | PASS |
| Enabled | `O` | PASS |
| Binding count | 1 | PASS — no duplicate |

Production currently contains the expected old global `is_admin()` and
profile-role authority references; this is the exact input condition that the
target migration removes. All five approved writer fingerprints also match
the migration's preflight constants: role writer, owner self-service,
identity writer, contact writer and membership-to-profile sync.

### 19.4 Protected field and authority review

The protected field matrix in section 3 remains authoritative. The production
input matches the expected baseline, and the reviewed target enforces:

- owner contact/declaration allowlist only;
- direct owner role, identity, immutable email/IDs, permit, legacy note and
  legacy verification mutations denied;
- admin identity and admin/employee contact paths bound to their exact closed
  writer markers, active membership role and same-tenant operational relation;
- role mirror allowed only after the authoritative CSK membership role exists
  and maps exactly to the legacy compatibility value;
- global `profiles.role=admin` without active membership provides no tenant
  authority;
- pending, suspended and absent membership cannot authorize privileged paths;
- Tenant A context cannot mutate a Tenant B-only profile or membership.

The operational sources remain `tenant_memberships`,
`tenant_user_verifications` and `tenant_user_admin_notes`. Legacy profile
verification and `admin_note` remain frozen/historical. `profiles.role`
remains compatibility data only in the target.

### 19.5 Production membership and catalog integrity

Read-only production results:

| Check | Result |
|---|---:|
| Active tenants | 1 |
| Duplicate memberships | 0 |
| Orphan memberships | 0 |
| Unknown membership roles | 0 |
| Unknown membership statuses | 0 |
| SECURITY DEFINER count | 69 |
| Unexpected SECURITY DEFINER objects | 0 relative to approved inventory |
| Compatibility defaults | 7/7 |

### 19.6 Service/system exception

| Path | Reason | Scope | Tenant impact | Risk |
|---|---|---|---|---|
| direct `postgres` database-owner execution with no `SET ROLE` | forward migrations and explicit owner maintenance must remain possible | auth-less UPDATE only when `session_user=postgres` and effective role is `none` or `postgres` | does not derive or grant tenant authority | bounded owner-credential risk |
| PostgREST service_role | none | explicitly outside the exception because it uses `SET ROLE service_role` | no tenant bypass | direct protected UPDATE denied |

There is no broad service_role bypass.

### 19.7 Direct escalation and cross-tenant matrix

The target definition plus approved local evidence confirms:

| Case | Target result |
|---|---|
| Owner, own allowed field | ALLOW |
| Owner, protected privilege field | DENY |
| Global profile admin without active membership | DENY |
| Tenant A admin, unrelated/Tenant B-only target | DENY |
| Approved controlled staff writer | ALLOW only within role, marker, relationship and field constraints |
| Direct service_role protected UPDATE | DENY |
| Direct postgres owner maintenance | ALLOW only under the exact system condition |

Cross-tenant privilege effects remain zero in the local functional and
concurrency evidence.

### 19.8 Local evidence reconfirmed

- focused SQL: 36/36 PASS;
- concurrency: PASS;
- full DB: 1376/1376 PASS;
- Node: 750/750 PASS;
- TypeScript: PASS;
- production build: PASS;
- focused Playwright: 2/2 PASS;
- deadlocks: 0;
- privilege escalation: 0;
- cross-tenant effects: 0;
- fixture cleanup: 0;
- `git diff --check`: PASS.

### 19.9 Production runtime baseline

Read-only HTTP requests followed the existing redirect/session boundary and
returned HTTP 200 with no 5xx for:

- `/account`;
- `/admin/users`;
- `/admin`;
- `/login`;
- `/register`;
- `/forgot-password`;
- `/reset-password`.

No real profile or privilege field was mutated.

### 19.10 Migration history and dry-run

Linked migration history is LOCAL = REMOTE through
`20260922100000_harden_account_lifecycle_rpcs.sql`. There are no remote-only
rows or earlier mismatches. The only local-only migration is
`20260923100000_harden_profile_privilege_trigger.sql`.

The final linked command was dry-run only and returned:

```text
DRY RUN: migrations will *not* be pushed to the database.
Would push these migrations:
 • 20260923100000_harden_profile_privilege_trigger.sql
```

No real push was performed. The available CLI upgrade notice is informational
and unrelated to readiness.

### 19.11 Deployment and rollback risk

Overall deployment risk: **MEDIUM**.

The change is DB-only function DDL with no table rewrite or business-data
backfill, so expected catalog locking is brief and a low-traffic deployment is
sufficient. Risk is not classified LOW because this trigger is a central
defense-in-depth boundary for every profile UPDATE and a regression could
affect owner self-service or controlled staff writers.

The migration fails closed on input function/writer fingerprint, owner/path/
ACL/trigger binding, SECURITY DEFINER count and compatibility defaults. A
failed post-deploy smoke must be handled by a reviewed forward migration
restoring the previous function definition; migration repair, manual history
editing and data rollback are not part of the rollback plan.

Blockers before production push: **none found by this preflight**. A separate
explicit production-push authorization remains mandatory.

## 20. Production preflight verdicts

SAAS-9D-4D-1 PRODUCTION PREFLIGHT: **PASS**

WORKING TREE SCOPE: **PASS**

SHA: **PASS**

EXACT SCOPE: **PASS**

PRODUCTION FINGERPRINT: **PASS**

TRIGGER INVENTORY: **PASS**

DIRECT PROFILE PRIVILEGE PROTECTION: **PASS**

GLOBAL ROLE SECURITY AUTHORITY: **REMOVED IN TARGET**

TENANT MEMBERSHIP AUTHORITY: **PASS**

OWNER SELF-SERVICE: **PASS**

FROZEN LEGACY FIELD PROTECTION: **PASS**

CROSS-TENANT PRIVILEGE ISOLATION: **PASS**

SERVICE_ROLE / SYSTEM CONTRACT: **PASS**

APP CHANGE: **0**

SECURITY DEFINER COUNT: **69**

COMPATIBILITY DEFAULTS: **7/7**

DRY-RUN: **PASS**

READY FOR PRODUCTION PUSH: **YES**

READY FOR 4D-2: **NO-GO until trusted 9E context**

READY FOR 4E: **NO-GO until 4D-1 production PASS/checkpoint**

READY FOR 9D-5: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**
