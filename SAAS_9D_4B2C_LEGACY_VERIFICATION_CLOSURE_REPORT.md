# SAAS-9D-4B-2C — Legacy Global Verification Path Closure

## 1. Exact scope

The local implementation is DB-only and limited to:

- retaining `update_profile_verification(uuid,text,text)` for its one active
  `/admin/users` caller;
- making that retained RPC active-tenant-admin-only;
- removing the global `profiles` tenant-verification mirror from
  `_apply_tenant_user_verification_v1(...)`;
- preserving `tenant_user_verifications` as the sole operational tenant
  verification source;
- updating focused and regression tests for the approved 4B-2C contract.

No application source, historical migration, profile column, RLS policy,
account lifecycle contract, 4D helper, compatibility default or production
state was changed. `AGENTS.md` remains unrelated and excluded.

## 2. Active caller inventory

Runtime source search found exactly one active caller:

`app/admin/users/page.tsx` → `update_profile_verification(uuid,text,text)`.

There are zero server callers and zero Check-in callers. Check-in continues to
use `update_reservation_customer_verification_v1(...)`. Source-contract tests
fail if this inventory changes.

## 3. `update_profile_verification` before and after

Before 4B-2C, the compatibility RPC allowed active admin or employee membership
and delegated to a core that also mirrored tenant state into `profiles`.

After 4B-2C it:

- preserves signature and JSON result compatibility;
- remains SECURITY DEFINER, owner `postgres`, SP1;
- remains executable only by `authenticated`;
- derives the exact active tenant through the existing temporary bridge;
- requires an active `admin` membership;
- requires membership/reservation/event-registration operational relationship;
- never reads `profiles.role` or a caller-provided tenant;
- writes only through the tenant mutation core.

The employee generic compatibility path is closed. Employee Check-in remains
available only through the reservation-bound RPC.

## 4. Removed mirror write

`_apply_tenant_user_verification_v1(...)` no longer:

- looks up an actor profile ID for mirroring;
- sets `csk.profile_verification_rpc_actor` or
  `csk.profile_verification_rpc_target`;
- updates any legacy verification field in `profiles`.

Its tenant row lock, status transition, validation, no-change behavior,
response, and tenant-bound audit contract remain unchanged.

## 5. Tenant source of truth

`tenant_user_verifications(tenant_id,user_id)` is the only operational read and
write source for tenant verification. Admin Users, Check-in, Account,
Dashboard, Booking and reservation admission already consume tenant decisions.

## 6. No legacy fallback

Repository search found no application profile selection of legacy
verification fields. SQL tests set deliberately conflicting profile and tenant
values and prove that Admin Users and reservation-bound readers return the
tenant value. The mutation core and active readers contain no dual-read,
dual-write, `COALESCE` fallback or mirror path.

## 7. Legacy profile field status

The nine legacy fields remain physically present:

- `verification_status`;
- `permissions_verified`;
- `permissions_verified_at`;
- `permissions_verified_by`;
- `permissions_verification_note`;
- `verified_at`;
- `verified_by`;
- `unverified_at`;
- `unverified_by`.

Their status is **FROZEN / HISTORICAL ONLY**. Tenant workflow reads = 0,
tenant workflow writes = 0, tenant fallback = 0. They are not dropped because
account export/anonymization and retention treatment belong to 4C.

## 8. ACL

`update_profile_verification(uuid,text,text)`:

| Role | EXECUTE |
|---|---|
| PUBLIC | DENY |
| anon | DENY |
| authenticated | ALLOW |
| service_role | DENY |

`_apply_tenant_user_verification_v1(...)` remains denied to all four roles.
There is no ACL expansion.

## 9. Authorization

The focused matrix proves:

- active Admin A plus Tenant-A relationship: ALLOW;
- Employee A generic writer: DENY;
- foreign Tenant-B admin: DENY;
- global `profiles.role=admin` without membership: DENY;
- pending, suspended and no-membership actors: DENY;
- unrelated target UUID: DENY;
- reservation-bound employee flow: ALLOW under the existing contract.

## 10. Same-user A/B isolation

The same synthetic user has independent Tenant-A and Tenant-B verification
rows. Mutations in A do not alter B, resource-bound writes do not cross tenant,
and conflicting legacy profile values alter neither tenant result. Concurrency
regression reports cross-tenant effects 0 and deadlocks 0.

## 11. Audit

Every changed tenant verification mutation retains explicit
`audit_logs.tenant_id = resolved tenant`. No ordinary tenant mutation creates a
NULL-tenant audit. Audit details remain free of note contents, email, phone and
address. Denials do not create a tenant mutation audit.

## 12. PII

No DTO was expanded. No tenant verification state or staff note is copied back
to global profile state. Tenant-B state and PII remain unavailable to Tenant-A
callers.

## 13. Frozen trigger proof

`prevent_non_admin_profile_privilege_changes()` was not replaced or altered.
Its normalized fingerprint remains:

`d28cb697d8355a5e8005296a03ad63ea`.

Owner, ACL, search_path and SECURITY DEFINER mode are unchanged.

## 14. Application change

Application source changes: **0**. The existing `/admin/users` RPC call and
result parsing remain compatible. Check-in and owner application cutovers from
4B-2B are unchanged.

## 15. SECURITY DEFINER inventory

Before: **69**. After: **69**. Unexpected drift: **0**. No function is added,
removed or converted between DEFINER and INVOKER.

## 16. Compatibility defaults

All seven temporary CSK ownership defaults remain present: **7/7**. They are
not authorization authority and remain a later 9D-5/9E gate.

## 17. Migration and SHA-256

Migration:

`20260921100000_close_legacy_global_verification_path.sql`

SHA-256:

`56242B2575D46C57F7874216CB0F1AF7BCEE4BA1CE1BC769FEA860B4C1884BA0`

The migration is forward-only, transactional, normalized-fingerprint guarded,
and contains no data rewrite or column removal.

## 18. Tests

- local DB reset including 4B-2C migration: PASS;
- focused 4B-2C SQL: **36/36 PASS**, final ROLLBACK;
- full Supabase DB suite: **41 files / 1296 tests PASS**;
- verification concurrency/IDOR: PASS;
- resource mismatch race: DENY;
- cross-tenant effects: 0;
- deadlocks: 0;
- concurrency fixture cleanup: 0;
- all Node tests: **746/746 PASS**;
- 4B-2C source-contract tests: 4/4 PASS within Node suite;
- TypeScript `--noEmit`: PASS;
- production build: PASS;
- changed-file ESLint: PASS;
- focused `/admin/users` Playwright: **1/1 PASS**;
- relevant Check-in Node and DB regressions: PASS;
- `git diff --check`: PASS;
- independent local fixture post-check: users/profiles/tenants/lanes/audits = 0.

`npm audit` was not part of the exact mandatory 4B-2C list. An attempted
optional run was blocked by the execution policy because it would disclose
dependency metadata to the external npm registry; no workaround was used.

## 19. Production rollout plan

Deployment is **DB-ONLY / SINGLE-STEP**, but production write remains
unauthorized. A future read-only preflight must verify project identity,
migration history, the authoritative SHA, exactly one pending migration, exact
production input fingerprints, caller/integrity baselines, SECURITY DEFINER 69,
defaults 7/7 and a one-migration dry-run. Any mismatch stops deployment.

Post-deploy verification must repeat metadata/fingerprints, ACL, no-mirror/no-
fallback checks, rollback-only A/B authorization matrix, runtime smoke and
fixture cleanup. Rollback is forward-only through a separately reviewed
corrective migration; never migration repair or manual production editing.

## 20. Final verdict

SAAS-9D-4B-2C LOCAL: **PASS**

ACTIVE LEGACY CALLERS: **1**

LEGACY GLOBAL WRITER: **CLOSED**

TENANT VERIFICATION SOURCE OF TRUTH: **PASS**

LEGACY PROFILES FALLBACK: **ABSENT**

LEGACY PROFILE FIELDS: **FROZEN HISTORICAL ONLY**

GLOBAL ROLE BYPASS: **REMOVED**

CROSS-TENANT VERIFICATION: **PASS**

CROSS-TENANT PII: **PASS**

AUDIT TENANT BINDING: **PASS**

prevent_non_admin_profile_privilege_changes: **UNCHANGED**

APP CHANGE: **0**

SECURITY DEFINER COUNT: **69**

COMPATIBILITY DEFAULTS: **7/7**

CALLER COMPATIBILITY: **PASS**

READY FOR 4B-2C PRODUCTION PREFLIGHT: **GO**

READY FOR 4C: **NO-GO until 4B-2C production PASS/checkpoint**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 21. Production preflight and deployment readiness

Date: **2026-09-17**. This phase was read-only. No production SQL write,
`db push`, migration repair, Git staging, commit or push was performed.

### 21.1 Repository and working-tree gate

- repository root: `C:/Users/Mpios/Desktop/APP Krutla/APP Krutla/csk-booking`;
- branch: `main`;
- HEAD: `11466eb157c10bcaf746df6888b77640f5131416`;
- `origin/main...HEAD`: `0/0`;
- `AGENTS.md`: unrelated, excluded and untouched;
- canonical 4B-2C scope consists of the plan/report, one migration, two new
  focused tests and the approved regression-test expectation updates;
- no unexpected semantic diff was found outside that scope;
- `git diff --ignore-cr-at-eol --check`: PASS. CRLF warnings are environmental
  line-ending notices, not additional semantic changes.

### 21.2 Migration identity and semantic scope

Migration:

`20260921100000_close_legacy_global_verification_path.sql`

SHA-256:

`56242B2575D46C57F7874216CB0F1AF7BCEE4BA1CE1BC769FEA860B4C1884BA0`

The SHA matches the approved local artifact. Semantic review confirms that the
migration replaces only:

- `_apply_tenant_user_verification_v1(uuid,uuid,text,text,text,uuid)`; and
- `update_profile_verification(uuid,text,text)`.

It contains no top-level business-data DML, table/column/index/RLS/trigger
change or backfill. It preserves the public writer signature and DTO, removes
the profile mirror/transaction bridge from the INVOKER core and removes the
generic employee compatibility branch from the retained writer.

### 21.3 Caller and dependency inventory

Repository inventory found exactly one active application caller:

`app/admin/users/page.tsx:614`

There are no server/API callers of the compatibility writer. Production
catalog inventory found exactly two callers of the closed mutation helper:

- `update_profile_verification(uuid,text,text)`;
- `update_reservation_customer_verification_v1(uuid,text,text)`.

Admin Users, Check-in, Account, Dashboard and Booking continue using tenant
verification DTOs/readers. Matching field names in TypeScript are DTO names;
they are not direct reads of the retained global profile columns. Reports and
Events have no active dependency on the legacy profile verification state.

### 21.4 Production project and migration history

- linked project reference: `yuyxfodozzpzrdzkmolu`;
- Supabase dashboard project and local linked project reference match;
- LOCAL = REMOTE through `20260920150000`;
- remote-only migrations: **0**;
- local-only migrations: exactly **1**;
- only pending migration: `20260921100000`.

Final read-only command:

`supabase db push --linked --dry-run`

Result: the CLI would push exactly
`20260921100000_close_legacy_global_verification_path.sql`. No migration was
applied. The CLI upgrade notice from 2.109.1 to 2.117.0 is informational and
not a deployment blocker.

### 21.5 Production function fingerprints and metadata

All ten normalized input fingerprints match the migration preflight:

| Function | Production fingerprint | Result |
|---|---|---|
| `_apply_tenant_user_verification_v1(uuid,uuid,text,text,text,uuid)` | `1682c8e32403d21ca5b829b70c244da9` | PASS |
| `update_profile_verification(uuid,text,text)` | `8df439041f082c25e18a632f952623cb` | PASS |
| `prevent_non_admin_profile_privilege_changes()` | `d28cb697d8355a5e8005296a03ad63ea` | PASS |
| `update_reservation_customer_verification_v1(uuid,text,text)` | `b4916056e23c1043baf17cbdab55caeb` | PASS |
| `get_my_active_tenant_verification_v1()` | `951c8262bc118089d8398282e1a95ce8` | PASS |
| `admin_list_users_v1(integer,integer,text,text,text,text)` | `bf37ec48de512ea45f5d4592df5f4eac` | PASS |
| `get_reservation_customer_profiles_v1(uuid[])` | `3f9ff02e63286a2784891ce4bb75c613` | PASS |
| `update_my_profile_v1(...)` | `c8c882630f05763f745788e9a108fb65` | PASS |
| `export_my_data_v1()` | `ffa6b35c5502a347e463110401032061` | PASS |
| `anonymize_my_account_v1()` | `7e4d950e75e6e5782b139f11269d03a0` | PASS |

The two target functions have the expected signatures, owner `postgres`, SP1
`search_path=pg_catalog, public, pg_temp`, security modes and ACLs. The public
writer is DEFINER and executable only by `authenticated`; the internal helper
is INVOKER and closed to PUBLIC, anon, authenticated and service_role. Frozen
dependencies have unchanged metadata and fingerprints.

### 21.6 Current production source and target contract

The pre-deploy source state is exactly the expected input state:

- helper profile mirror: present;
- temporary transaction bridge: present;
- generic employee compatibility branch: present;
- `profiles.role` authority in the writer: absent;
- Admin Users tenant-table reader: present;
- reservation-bound tenant-table reader: present.

The migration target removes the first three items while retaining signatures,
the authenticated caller boundary and resource-bound Check-in compatibility.
`tenant_user_verifications` becomes the only active tenant verification
read/write source. No caller-supplied tenant authority is introduced.

### 21.7 Legacy fields and lifecycle dependencies

All nine legacy verification columns still physically exist in `profiles`.
They remain frozen/historical and are not a tenant authorization source.
`export_my_data_v1()` and `anonymize_my_account_v1()` retain their approved
account-wide lifecycle behavior and exact fingerprints. Physical removal or a
different lifecycle/export policy is explicitly deferred to 4C.

`prevent_non_admin_profile_privilege_changes()` remains unchanged at
`d28cb697d8355a5e8005296a03ad63ea`.

### 21.8 Production data and tenant integrity

- tenants: **1**;
- active tenants: **1**;
- active CSK tenant: **1**;
- `tenant_user_verifications` rows: **9**;
- orphan tenant references: **0**;
- orphan Auth user references: **0**;
- duplicate `(tenant_id,user_id)` keys: **0**;
- non-CSK/cross-tenant rows: **0**;
- RLS enabled: YES;
- policies: **0**;
- direct DML for PUBLIC/anon/authenticated/service_role: DENY.

The target cross-tenant matrix is covered by the accepted local 36/36 SQL and
concurrency evidence: Admin A plus related Tenant-A user ALLOW; Tenant-B-only,
unrelated, employee generic path, global-role-only, pending, suspended and no
membership DENY; same-user A/B state remains independent; audit is explicitly
tenant-bound and PII-free.

### 21.9 Security inventory and compatibility

- current SECURITY DEFINER count: **69**;
- expected post-4B-2C count: **69**;
- expected unexpected drift: **0**;
- compatibility ownership defaults: **7/7**;
- application source change required: **0**.

Current and target ACL review confirms no new PUBLIC, anon, service_role or
direct-table boundary. The retained compatibility writer remains available to
its single authenticated Admin Users caller but is tenant-admin-only in the
target body.

### 21.10 Runtime smoke

Read-only production HTTP smoke returned HTTP 200 with no 5xx for:

- `/admin/users`;
- `/admin/check-in`;
- `/admin`;
- `/account`;
- `/booking`;
- `/events`;
- `/login`.

### 21.11 Deployment and rollback risk

Deployment risk is **LOW**. The migration is one short transactional unit that
replaces two function definitions and verifies catalog invariants. It performs
no row rewrite, table scan backfill, table DDL or long-lived business-table
lock. No maintenance window is required based on this scope.

Fail-closed migration assertions protect fingerprints, overload inventory,
ACLs, SECURITY DEFINER count and defaults. A preflight mismatch rolls the
transaction back. Any post-deploy correction must use a separately reviewed
forward migration; migration repair and manual production SQL are prohibited.

### 21.12 Production preflight verdict

SAAS-9D-4B-2C PRODUCTION PREFLIGHT: **PASS**

MIGRATION SHA: **PASS**

PRODUCTION INPUT FINGERPRINTS: **PASS**

CALLER INVENTORY: **PASS**

TENANT VERIFICATION SOURCE OF TRUTH: **PASS**

LEGACY PROFILES FALLBACK: **ABSENT IN ACTIVE READERS / TARGET WRITER**

LEGACY PROFILE FIELDS: **FROZEN / HISTORICAL ONLY**

GLOBAL ROLE BYPASS: **REMOVED IN TARGET**

CROSS-TENANT VERIFICATION: **PASS**

CROSS-TENANT PII: **PASS**

AUDIT TENANT BINDING: **PASS**

prevent_non_admin_profile_privilege_changes: **UNCHANGED**

APP CHANGE REQUIRED: **NO**

SECURITY DEFINER CURRENT: **69**

SECURITY DEFINER TARGET: **69**

COMPATIBILITY DEFAULTS: **7/7**

DRY-RUN: **ONE MIGRATION ONLY**

READY FOR PRODUCTION PUSH: **YES**

READY FOR 4C: **NO-GO until 4B-2C production PASS/checkpoint**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**
