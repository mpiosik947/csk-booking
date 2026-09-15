# SAAS-9D-4A — Admin reservation reports hardening

Date: 2026-09-15

Scope: local implementation only
Baseline: `d871785a5fb580d1ac7f8ca94c666d5cfdc3202d`

## Result

SAAS-9D-4A hardens the active reservation report and export contracts without
changing application callers, function signatures, report DTOs, filtering,
pagination, revenue, occupancy, CSV limits, or the existing admin-only business
rule. No application file, production resource, RLS policy, table schema, or
compatibility default was changed.

## Exact function scope

| Function | Change |
|---|---|
| `admin_get_reservation_report_v2(date,date,uuid,text,text,text,integer,integer)` | Tenant-bound SECURITY DEFINER wrapper; active tenant admin membership required. |
| `admin_get_reservation_report_export_v1(date,date,uuid,text,text,text)` | Tenant-bound SECURITY DEFINER wrapper; active tenant admin membership required. |
| `admin_get_reservation_report_v1(date,date,integer,integer)` | Body/signature/owner/search path unchanged; client and service EXECUTE revoked because no live caller exists. |
| `_admin_reservation_report_rows_v2(date,date,uuid,text,text,text)` | Existing closed helper unchanged. |
| `_admin_reservation_report_rows_v2__saas9d4a_core(uuid,date,date,uuid,text,text,text)` | New closed SECURITY INVOKER tenant-aware core. |

Functions assigned to 9D-4B, 9D-4C, 9D-4D, 9D-4E, 9D-5, and 9E remain
outside this implementation.

## Authorization and tenant isolation

The active wrappers obtain the sole active tenant through the already approved
temporary bridge and require `get_my_tenant_role_v1(tenant_id) = 'admin'`.
`profiles.role` is not consulted. Employee access remains denied, matching the
current report contract.

The closed core applies `tenant_id` predicates to reservations, resources, and
parent-resource joins before aggregation or pagination. Resource validation,
filter options, capacity, occupancy, KPI, revenue, details, and export are all
computed within the resolved tenant. A foreign and a nonexistent resource fail
with the same controlled `invalid_input` result.

Verified locally:

- active Tenant A admin with active membership: ALLOW;
- global `profiles.role=admin` without membership: DENY;
- pending, suspended, missing membership, ordinary user, and employee: DENY;
- Tenant A report contains no Tenant B totals, rows, resources, revenue, or PII;
- Lane B supplied to Tenant A report/export: DENY, without existence disclosure.

## Operational relationship and lifecycle decisions

Profile administration is not part of 9D-4A. This phase neither introduces nor
changes a target-profile operation, so the target-user operational-relationship
matrix is **not applicable** here and remains mandatory for 9D-4B. The report
itself exposes customer details only when they are attached to a reservation
owned by the caller's tenant, which is an approved operational relationship.

Tenant leave and account-wide lifecycle operations remain separate. The
fingerprints of `export_my_data_v1()` and `anonymize_my_account_v1()` are
unchanged, and no 9D-4A function touches memberships, profiles, `auth.users`,
account export, anonymization, or Auth deletion.

## PII and compatibility

- The report retains only its existing operational detail DTO for the
  tenant-authorized admin.
- Tenant B names, email, phone, and resource labels do not appear in Tenant A
  output.
- Export remains PII-minimal and contains no customer/profile/token/admin-note
  fields.
- Existing v2/export signatures and defaults are unchanged.
- REPORTS-6A and REPORTS-6B behavior, including 720-minute operating days,
  hierarchy, pagination, filters, 5000-row export cap, and CSV contract, remains
  covered by the existing regression suite.
- Compatibility defaults remain `7/7`.
- SECURITY DEFINER count remains `67`; unrelated SECURITY DEFINER definitions,
  owners, search paths, and ACLs are guarded against drift.
- Migration SHA-256 is
  `54D3EE6B3D37D63374F4EBFFD507B89C7797CE6ED0C813F62080BCBDD8408031`.

## Files changed

- `supabase/migrations/20260918100000_harden_admin_reservation_reports.sql`
- `supabase/tests/20260918100000_harden_admin_reservation_reports_test.sql`
- `supabase/tests/20260816143000_harden_public_function_execute_acl_test.sql`
- `supabase/tests/20260905150000_add_admin_reservation_reports_v1_test.sql`
- `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md`
- `SAAS_9D_4A_ADMIN_RESERVATION_REPORTS_HARDENING_REPORT.md`

`AGENTS.md` is unrelated and was not modified by this work.

## Verification

| Check | Result |
|---|---|
| Clean local migration replay (`supabase db reset --local`) | PASS |
| Focused SAAS-9D-4A SQL | 33/33 PASS |
| REPORTS-6A SQL regression | 25/25 PASS |
| REPORTS-6B SQL regression | 34/34 PASS |
| Full function ACL matrix | 17/17 PASS |
| Full Supabase DB suite | 36 files, 1107/1107 PASS |
| Node suite | 739/739 PASS |
| TypeScript | PASS |
| Production build | PASS |
| Reports Playwright | 5/5 PASS |
| Local synthetic fixture cleanup | PASS, zero remaining |
| `git diff --check` | PASS |
| Full ESLint | Existing baseline: 10 errors / 5 warnings; no changed application file |

The build retains the known Next.js `middleware` to `proxy` deprecation
warning. An attempted `npm audit --omit=dev` could not access the public npm
registry under the execution policy; no dependency change was made in 4A.

## Rollback and deployment model

Deployment is DB-only and requires a separate production preflight and explicit
approval. A rollback, if ever needed after deployment, must be a reviewed
forward migration restoring the two active bodies and v1 ACL, then dropping the
new closed core. Do not edit an applied migration or use migration repair.

## Verdict

SAAS-9D-4A LOCAL: **PASS**

TENANT PROFILE ISOLATION: **NOT APPLICABLE**

OPERATIONAL RELATIONSHIP ENFORCEMENT: **PASS**

GLOBAL ROLE BYPASS: **REMOVED**

ACCOUNT-WIDE VS TENANT-SCOPED CONTRACT: **PRESERVED**

PII: **PASS**

CALLER COMPATIBILITY: **PASS**

READY FOR SAAS-9D-4A PRODUCTION PREFLIGHT: **GO**

READY FOR SAAS-9D-4B-1: **NO-GO until review**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## Production deployment and post-deploy verification

The explicitly approved linked push applied only
`20260918100000_harden_admin_reservation_reports.sql`. The command completed
successfully. Linked migration history is now identical locally and remotely
through `20260918100000`; the final linked dry-run reports `Remote database is
up to date`.

Fresh production catalog verification returned:

- target definition/fingerprint/metadata/ACL match: 4/4 (v1, v2, export and
  the closed INVOKER core);
- public-schema SECURITY DEFINER count: 67;
- active tenants: exactly 1;
- reservation/lane tenant mismatch: 0;
- lane hierarchy tenant mismatch: 0;
- compatibility defaults: 7/7;
- account export/anonymization fingerprints: unchanged.

The production rollback-only matrix completed 33/33 checks. It proved active
Tenant-A admin access, employee/ordinary/pending/suspended/no-membership
denial, removal of the global `profiles.role` authorization bypass, Tenant-B
row/PII exclusion, foreign-resource fail-closed behavior, PII-minimal export,
closed legacy v1 ACL, closed SECURITY INVOKER core, unchanged account-wide
lifecycle contracts and no audit/RLS widening. Production's existing
`auth.users` profile trigger was used by the fixture, and report assertions
were scoped to the freshly created synthetic lane so existing CSK capacity
could not affect deterministic expected values. The test ended with
`ROLLBACK`.

An independent post-check returned zero synthetic tenants, lanes,
reservations, profiles and Auth users. Production data persisted by the matrix:
0.

Runtime verification returned HTTP 200 with no 5xx for `/admin/reports`,
`/admin`, `/admin/reservations`, `/booking`, `/events`, `/account` and `/login`.
An authenticated admin `/admin/reports` session loaded resource options, KPI
and the controlled empty state successfully.

### Production verdict

SAAS-9D-4A PRODUCTION DEPLOY: **PASS**

SAAS-9D-4A POST-DEPLOY: **PASS**

REPORT TENANT ISOLATION: **PASS**

EXPORT TENANT ISOLATION: **PASS**

GLOBAL ROLE BYPASS: **REMOVED**

PII: **PASS**

SECURITY DEFINER COUNT: **67**

UNEXPECTED FUNCTION DRIFT: **0**

COMPATIBILITY DEFAULTS: **7/7**

FIXTURE CLEANUP: **0**

RUNTIME SMOKE: **PASS**

READY FOR GIT CHECKPOINT: **YES**

READY FOR SAAS-9D-4B-1 PLANNING: **GO**

READY FOR SAAS-9D-4B-1 IMPLEMENTATION: **NO-GO until checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## Production preflight & deployment readiness

Preflight date: 2026-09-15. All production database inspection in this section
was read-only. No migration, repair, fixture, Git write, or production data
mutation was performed.

### Working tree and SHA

The canonical real 9D-4A scope contains exactly the six approved files listed
in this report. `AGENTS.md` has a separate pre-existing real diff and remains
explicitly unrelated and excluded. No additional tracked or untracked real
content diff was found. `git diff --check` and the equivalent checks for the
three new untracked files pass; Git only reports informational CRLF conversion
warnings.

Migration SHA-256 was recalculated as:

`54D3EE6B3D37D63374F4EBFFD507B89C7797CE6ED0C813F62080BCBDD8408031`

This equals the approved digest.

### Exact function baseline and target

Fingerprints normalize CRLF and lone CR to LF.

| Function/signature | Current production fingerprint | Expected baseline | Target fingerprint | Current → target mode | Current → target ACL | Owner / search path | Tenant source / return |
|---|---|---|---|---|---|---|---|
| `admin_get_reservation_report_v2(date,date,uuid,text,text,text,integer,integer)` | `6ab0ee4d90521efa8dd75d4debd19558` | same | `ded8346e37b87bbf278d3b7b4673ae18` | DEFINER → DEFINER | authenticated only → authenticated only | postgres / `pg_catalog, public, pg_temp` | sole-active tenant bridge plus active admin membership / JSONB v2 unchanged |
| `admin_get_reservation_report_export_v1(date,date,uuid,text,text,text)` | `79c8876e1a4541fffb139e2f5c58a64a` | same | `5a8fd638e4c7a867477781876358dcf1` | DEFINER → DEFINER | authenticated only → authenticated only | postgres / `pg_catalog, public, pg_temp` | same trusted tenant and membership / JSONB export v1 unchanged |
| `admin_get_reservation_report_v1(date,date,integer,integer)` | `f0285e0b1f48aba18b2a83d40eda6c44` | same | same | DEFINER → DEFINER | authenticated only → owner only | postgres / `pg_catalog, public, pg_temp` | legacy body unchanged / JSONB unchanged |
| `_admin_reservation_report_rows_v2__saas9d4a_core(uuid,date,date,uuid,text,text,text)` | absent | absent | `32b9386fb17a2a777e8269531b59b291` | absent → INVOKER | absent → owner only | postgres / `pg_catalog, public, pg_temp` | explicit validated tenant UUID / closed table DTO |

For all existing targets, production normalized fingerprint equals the guarded
baseline. Signatures, owner, search path, volatility, defaults, and return
contracts match the migration preflight. The migration contains no reference to
or definition of any 9D-4B, 9D-4C, or 9D-4E function.

Exact direct EXECUTE target:

| Function | PUBLIC | anon | authenticated | service_role |
|---|---:|---:|---:|---:|
| report v2 | no | no | yes | no |
| export v1 | no | no | yes | no |
| legacy report v1 | no | no | no | no |
| closed tenant core | no | no | no | no |

There is no grant expansion. The current application calls only report v2 and
export v1. Repository caller inventory found no active application caller for
legacy v1; its remaining references are historical migrations/tests. The
approved replacement path therefore already exists.

### Production data baseline and integrity

| Check | Production value |
|---|---:|
| tenants / active tenants / active CSK | 1 / 1 / 1 |
| tenant memberships | 9 |
| membership distribution | 8 active user, 1 active admin |
| duplicate memberships | 0 |
| orphan membership tenant/user | 0 / 0 |
| profiles | 9 |
| reservations | 11 |
| distinct reservation-related users | 1 |
| reservation without related profile | 0 |
| reservation/lane tenant mismatch or orphan lane | 0 |
| SECURITY DEFINER functions | 67 |
| fixed-CSK compatibility defaults | 7/7 |

No unexplained membership, ownership, reservation, profile-relation, or tenant
integrity mismatch was detected. The target core is absent, as expected before
deployment.

### Isolation, operational relationship, and PII

The target report and export wrappers resolve the currently permitted sole
active tenant and require an active `admin` membership. Employee remains denied.
A global `profiles.role=admin`, pending/suspended/no membership, or a foreign
resource cannot authorize the call. Tenant predicates are applied before KPI,
revenue, occupancy, resource options, details, pagination, and export.

Report v2 retains the existing operational detail fields: reservation/resource
IDs and hierarchy labels, customer name/email/phone, date/time/duration, price,
reservation status, and payment status. These details are available only through
a reservation owned by the authorized tenant. No Tenant-B-only or unrelated
global profile can enter a Tenant A result. No membership data, address,
declarations, admin note, token, or other profile internals are returned.

Export v1 remains PII-minimal: date, start/end, resource label, booking type,
reservation/payment status, and total price. Its 5000-row limit and controlled
`export_too_large` result remain unchanged. No employee scope is added.

The new core is SECURITY INVOKER and owner-only. It cannot be invoked through
PostgREST by PUBLIC, anon, authenticated, or service_role; the two controlled
wrappers are the only entry path.

### Account-wide contract separation and compatibility

The migration does not reference or modify account export, global
anonymization, Auth deletion, memberships, profiles, or any future leave-tenant
contract. Account-wide and tenant-scoped lifecycle semantics remain separated.

Application callers require no new argument and no app deployment. Current
`/admin/reports` uses the unchanged v2 and export signatures. The production UI
loaded the report contract successfully in an authenticated admin session,
rendered resource options and KPI/empty state, and recorded no browser console
warning or error.

### Local evidence reconfirmed

- focused 4A: 33/33 PASS;
- REPORTS-6A: 25/25 PASS;
- REPORTS-6B: 34/34 PASS;
- function ACL: 17/17 PASS;
- full DB: 1107/1107 PASS;
- Node: 739/739 PASS;
- TypeScript and production build: PASS;
- Reports Playwright: 5/5 PASS;
- fixture cleanup: 0;
- `git diff --check`: PASS.

### Runtime, migration history, and dry-run

Read-only HTTP smoke returned final HTTP 200 for `/admin/reports`, `/admin`,
`/admin/reservations`, `/booking`, `/events`, `/account`, and `/login`. No 5xx
was observed and no report export or persistent fixture was created.

Linked migration history is identical locally and remotely through
`20260917100000_harden_lane_family_writer_helpers.sql`. There is no remote-only
row or malformed history. Exactly one local-only migration exists:

`20260918100000_harden_admin_reservation_reports.sql`

`supabase db push --linked --dry-run` completed successfully and reported only
that migration under “Would push these migrations”. No push was executed.

### Deployment risk and blockers

| Risk | Assessment |
|---|---|
| Report isolation / PII | MEDIUM impact if wrong, strongly guarded by baseline fingerprints and cross-tenant tests |
| Export contract | LOW after unchanged DTO/filter/limit regression proof |
| Legacy v1 ACL closure | LOW; active caller count is zero and v2 is the deployed replacement |
| Closed INVOKER core | LOW; no client/service EXECUTE and explicit tenant predicates |
| Caller compatibility | LOW; signatures/defaults and application caller payloads are unchanged |
| Migration lock/runtime | LOW; function DDL and ACL only, no table rewrite or data backfill |

Overall deployment risk is **MEDIUM** because the changed boundary protects
operational PII, although execution and lock risk are low. A low-traffic window
is sufficient; a maintenance window is not required. Production push remains a
separate explicitly approved action. There are no preflight blockers.

### Production preflight verdict

SAAS-9D-4A PRODUCTION PREFLIGHT: **PASS**

WORKING TREE SCOPE: **PASS**

SHA: **PASS**

FUNCTION SCOPE: **PASS**

FINGERPRINTS: **PASS**

REPORT V2 TENANT ISOLATION: **PASS**

REPORT EXPORT TENANT ISOLATION: **PASS**

GLOBAL ROLE BYPASS: **REMOVED IN TARGET**

LEGACY V1 ACL: **PASS**

INVOKER CORE: **PASS**

PII: **PASS**

OPERATIONAL RELATIONSHIP: **PASS**

ACCOUNT-WIDE CONTRACT: **PRESERVED**

CALLER COMPATIBILITY: **PASS**

SECURITY DEFINER COUNT: **67**

READY FOR PRODUCTION PUSH: **YES**

READY FOR SAAS-9D-4B-1: **NO-GO until 4A production PASS and checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**
