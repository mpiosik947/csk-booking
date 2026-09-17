# SAAS-9D-4B-1B — Tenant Profile Admin Hardening

## 1. Exact scope

Local-only implementation at HEAD `4f2a521b94a2b0905eca7bfad52c750a231a6f3b`:

- body hardening: `admin_set_user_role_v1(uuid,text)`,
  `update_profile_identity(uuid,text,text)`,
  `update_profile_contact_details(uuid,text,text,text,text,text,text)`;
- tenant-audit classification only: `set_audit_log_tenant_id()`;
- frozen regression dependency: `admin_list_users_v1(integer,integer,text,text,text,text)`;
- no application, RLS, table, verification, account-lifecycle or production change.

`update_profile_verification` remains 4B-2. `AGENTS.md` is unrelated and was
not modified by this work.

## 2. Pre-change inventory and fingerprints

| Function | Caller | Mode / owner / path | ACL | Previous authority and tenant source | Target / relationship / PII | Audit | Baseline fingerprint |
|---|---|---|---|---|---|---|---|
| `admin_set_user_role_v1(uuid,text)` | `app/admin/users/page.tsx` browser RPC | DEFINER / postgres / SP1 | authenticated | global actor/target role; no tenant | user UUID; global profile role | global `profile_role_changed` | `8dcbd9595f464a823cc92cb98f354175` |
| `update_profile_identity(uuid,text,text)` | same | DEFINER / postgres / SP2 | authenticated, service_role | global admin; no tenant | user UUID; first/last/full name | tenantless profile audit | `9601c3086d40ea7061ad2d224d8ef54a` |
| `update_profile_contact_details(uuid,text,text,text,text,text,text)` | same | DEFINER / postgres / SP2 | authenticated, service_role | global admin/pracownik; no tenant | user UUID; phone/address | tenantless profile audit | `6cb660a2817d73f3c8ccc6e97dee52e4` |
| `set_audit_log_tenant_id()` | audit trigger only | INVOKER / postgres / `pg_catalog` | closed | explicit target dispatcher | audit row | enforces ownership | `66154375df9ee963c266c0ff468d2526` |
| `admin_list_users_v1(...)` | `app/admin/users/page.tsx` | DEFINER / postgres / SP1 | authenticated | active tenant admin after 4B-1A | approved operational relation; 30-column DTO | none | `2a95b1f3ba9c404adfa84f7eb9b8d425` |

No repository service caller exists for identity/contact. Tests are the only
non-page callers. Scope matches the approved plan; UNKNOWN = 0.

## 3. Resulting fingerprints and metadata

| Function | Result fingerprint | SECURITY | ACL result |
|---|---|---|---|
| `admin_set_user_role_v1` | `9732b7d53eaa080ebc6348cd1dd68ca2` | DEFINER, postgres, SP1 | authenticated only |
| `update_profile_identity` | `33e0a05fb0d142cd9ba7d99cc66c6652` | DEFINER, postgres, SP1 | authenticated only |
| `update_profile_contact_details` | `ce0146bccc9a1cc1d89c3e4d26462586` | DEFINER, postgres, SP1 | authenticated only |
| `set_audit_log_tenant_id` | `0b6bc80c569f88798f2899fdf3f2cd1b` | INVOKER, postgres, `pg_catalog` | closed |
| `admin_list_users_v1` | `2a95b1f3ba9c404adfa84f7eb9b8d425` | unchanged | unchanged |

PUBLIC/anon/service_role cannot execute the three public writers. No direct
profile UPDATE privilege was introduced.

## 4. Authorization and operational relationship

All privileged calls require `auth.uid()`, exactly one active tenant, an
active membership and the operation's allowed tenant role. Target eligibility
is membership, same-tenant reservation, or tenant-consistent event
registration. Relationship checks occur before target PII is selected.

Admin A can operate on related User A. Tenant-B-only and unrelated global
users are denied. A global `profiles.role=admin` without active membership,
pending/suspended membership, and no membership are denied.

## 5. Tenant-local role mutation and last-admin protection

The role writer changes only the existing `tenant_memberships` row. It never
creates membership. UI mappings are `admin↔admin`, `user↔user`,
`pracownik↔employee`, `instruktor↔instructor`. The existing CSK bridge mirrors
only the CSK role; a non-CSK mutation leaves `profiles.role` unchanged.

A deterministic tenant advisory lock and ordered active-admin row locks
serialize role changes. Authorization is rechecked after locking. Counts use
only active admins in the resolved tenant. One admin cannot be demoted; with
two, one demotion is allowed. A Tenant-B admin is never counted for Tenant A.

The real two-session test produced one successful demotion, one controlled
denial, one remaining active admin, one audit, zero deadlocks and zero
cross-tenant effects. A second two-session test ran identity and contact
updates simultaneously against one related profile; both independent changes
and both audits persisted, with zero deadlocks and zero lost updates.

## 6. Identity, contact, owner and staff

Identity remains active tenant-admin only. Contact remains active tenant admin
or employee. Employee may update only a related operational customer and may
not target self or any tenant member with admin/employee/instructor role.
Instructor receives no new permission.

Administrative RPCs do not gain an owner bypass. Existing owner contact and
declaration self-service remains in `update_my_profile_v1`; its regression
tests pass. Account export, global anonymization, Auth deletion and future
leave-tenant are untouched.

## 7. PII least-privilege matrix

| Field | Owner read/write | Admin read/write | Employee read/write | Reason | Tenant scope |
|---|---|---|---|---|---|
| first/last/full name | separate existing contract only / no new permission | read+write for related target | none | operational identity correction | resolved tenant relation |
| phone | self-service read+write | read+write for related target | read+write for related customer | operational contact | resolved tenant relation |
| postal code/city/street/house/apartment | self-service read+write | read+write for related target | read+write for related customer | operational address | resolved tenant relation |
| role | own legacy display only; no admin mutation | tenant membership read+write | none | tenant authorization | exact membership tenant |
| email, permits, verification, admin note, tokens, Auth metadata | unchanged/no new access | not returned or modified by these writers | none | outside 4B-1B | denied |

Responses retain existing per-writer shapes and never return membership
metadata or other-tenant relationships.

## 8. Tenant-bound audit

Successful changed operations emit exactly one audit with DB timestamp,
`auth.uid()` actor and resolved tenant. Explicit targets/actions are:

- `tenant_user_role` / `tenant_user_role_updated`;
- `tenant_user_identity` / `tenant_user_identity_updated`;
- `tenant_user_contact` / `tenant_user_contact_updated`.

Labels are pseudonymous. Details contain only role identifiers or changed
field names/counts. No email, names, phone/address values, tokens or membership
metadata are stored. Denial/no-change emits no audit. Global `profile` and
`account` audits still require `tenant_id IS NULL`.

## 9. Frozen contracts and compatibility

`admin_list_users_v1` body, fingerprint, DTO, filtering, pagination, role
mapping and tenant-note source are unchanged. `update_profile_verification`,
profile privilege trigger, account export and anonymization fingerprints are
unchanged. SECURITY DEFINER count is 67; unexpected functions 0; compatibility
defaults 7/7.

Caller signatures and arguments are unchanged; no application cutover or
tenant argument is required. Deployment model is DB-first/DB-only. The active
single-tenant bridge is temporary and is not authority for a second tenant.

## 10. Tests

- local DB reset and complete migration history: PASS;
- focused 4B-1B SQL: 48/48 PASS;
- operational relationship, role mapping, cross-tenant PII, audit, list freeze,
  ACL and owner/self-service regression: PASS;
- real concurrent last-admin demotion: PASS; active admins 1, changed audits 1,
  deadlocks 0, contamination 0;
- full Supabase DB: 1192/1192 PASS;
- Node: 739/739 PASS;
- TypeScript: PASS;
- production build: PASS (existing middleware→proxy warning only);
- focused admin/users Playwright: 1/1 PASS;
- changed-file ESLint and `git diff --check`: PASS;
- `npm audit --omit=dev`: one pre-existing moderate
  `baseline-browser-mapping` advisory; no dependency change in scope.

Fixture cleanup is 0 for tenants, memberships, users/profiles, reservations,
event registrations and audit fixtures.

## 11. Migration and production plan

Migration:
`supabase/migrations/20260919150000_harden_tenant_user_role_identity_contact.sql`

SHA-256:
`A9E1B684A8CA70EA76C3CF7FFEFB0EACBAB28DFA1C2FB80C142FC822C4A383ED`

Production preflight must revalidate the exact current fingerprints, service
caller absence, active CSK/admin integrity, list freeze, SECURITY DEFINER 67,
defaults 7/7 and exact one-migration dry-run. No production preflight or write
was performed in this task.

## 12. Git status and final verdict

Intended 4B-1B scope:

- this report and the updated hardening plan;
- the new migration and focused SQL test;
- the concurrency test;
- ACL and CLEAN-005 regression expectation updates.

`AGENTS.md` remains unrelated/excluded. No file was staged or committed.

SAAS-9D-4B-1B LOCAL: **PASS**

TENANT PROFILE ISOLATION: **PASS**

OPERATIONAL RELATIONSHIP: **PASS**

GLOBAL ROLE BYPASS: **REMOVED**

ROLE MUTATION TENANT ISOLATION: **PASS**

LAST-ADMIN PROTECTION: **PASS**

LEGACY ROLE MAPPING: **PASS**

OWNER SELF-SERVICE: **PASS**

CROSS-TENANT PII: **PASS**

AUDIT TENANT BINDING: **PASS**

admin_list_users_v1: **UNCHANGED**

ACCOUNT-WIDE CONTRACT: **PRESERVED**

CALLER COMPATIBILITY: **PASS**

CONCURRENCY: **PASS**

READY FOR 4B-1B PRODUCTION PREFLIGHT: **GO**

READY FOR 4B-2: **NO-GO until review**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## Final repository state after production PASS

`git diff --check`: PASS. No `git add`, commit or push was performed.

Proposed SAAS-9D-4B-1B checkpoint scope:

1. `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md`
2. `SAAS_9D_4B1B_TENANT_PROFILE_ADMIN_HARDENING_REPORT.md`
3. `scripts/saas9d4b1b-concurrency.mjs`
4. `supabase/migrations/20260919150000_harden_tenant_user_role_identity_contact.sql`
5. `supabase/tests/20260919150000_harden_tenant_user_role_identity_contact_test.sql`
6. `supabase/tests/20260816143000_harden_public_function_execute_acl_test.sql`
7. `supabase/tests/20260905100000_harden_profile_direct_updates_test.sql`

`AGENTS.md` remains unrelated, unstaged and explicitly excluded.

## Production deployment and post-deploy verification — 2026-09-17

The approved migration SHA-256 was rechecked as
`62CBFF411F1330CA8601D10FE0A5722933AA2E5B902BE295D4DA5F767C2D5276`.
All fail-closed pre-push gates passed and `supabase db push --linked` applied
only `20260919150000_harden_tenant_user_role_identity_contact.sql`.

Post-deploy migration history is LOCAL = REMOTE through `20260919150000` and
the final linked dry-run reports `Remote database is up to date`.

Production verification confirmed:

- target normalized fingerprints: role writer
  `9732b7d53eaa080ebc6348cd1dd68ca2`, identity writer
  `33e0a05fb0d142cd9ba7d99cc66c6652`, contact writer
  `ce0146bccc9a1cc1d89c3e4d26462586`, audit classifier
  `0b6bc80c569f88798f2899fdf3f2cd1b`;
- the three writers remain `SECURITY DEFINER`, owned by `postgres`, use
  `search_path=pg_catalog, public, pg_temp`, and grant EXECUTE only to
  `authenticated` besides the owner;
- `set_audit_log_tenant_id()` remains closed `SECURITY INVOKER`, owned by
  `postgres`, with `search_path=pg_catalog` and no client/service EXECUTE;
- `admin_list_users_v1` remains unchanged at
  `2a95b1f3ba9c404adfa84f7eb9b8d425`, with its signature, DTO, owner,
  search path and ACL unchanged;
- active tenants 1, active CSK tenants 1, memberships 9, duplicate
  memberships 0, orphan tenant links 0, orphan user links 0, unknown roles 0
  and unknown statuses 0;
- SECURITY DEFINER count 67 and compatibility defaults 7/7;
- production HTTP smoke returned no 5xx for `/admin/users`, `/admin`,
  `/account`, `/booking`, `/events` and `/login`; authenticated
  `/admin/users` rendered the expected nine-account admin list.

### Rollback-only matrix status

The exact existing test was first rejected before SQL execution because the
Supabase SQL Editor does not support the `psql`-only `\\set`/`\\pset`
directives. After removing only those client formatting directives, execution
entered the transaction but stopped during fixture setup with SQLSTATE 23505:
the production `auth.users` trigger had already created each `profiles` row,
and the test then attempted a second manual `INSERT public.profiles`.

No security assertion ran. This is a production-fixture compatibility defect,
not evidence of a deployed-function defect. The failed transaction persisted
no data. An independent read-only post-check returned tenants 0, Auth users 0,
profiles 0 and memberships 0 for the SAAS-9D-4B-1B markers.

The approved SQL-Editor adaptation removed only the three `psql` directives
and the redundant profile INSERT, retaining the trigger-created profile UPDATE,
all 48 functional checks, `BEGIN` and `ROLLBACK`. The full matrix then ran and
failed closed on checks 33, 34, 42 and 43.

Checks 33-34 are not isolated from the real CSK baseline. Production has one
pre-existing active CSK administrator, so demoting the synthetic administrator
cannot create the intended last-admin condition. The deployed writer therefore
correctly allows the mutation while the test incorrectly expects `last_admin`.
The existing real administrator was never modified.

Checks 42-43 contain obsolete local raw MD5 values (`919d...` and `7a16...`).
Read-only production evidence confirms both raw and normalized hashes are the
already approved frozen values: verification
`a0522b6beb94bde3bdff22799afc1368` and privilege trigger
`d28cb697d8355a5e8005296a03ad63ea`. This is test expectation drift, not
function drift.

The failed transaction persisted no data. A repeated independent post-check
again returned tenants 0, Auth users 0, profiles 0 and memberships 0 for the
SAAS-9D-4B-1B markers.

The final approved correction isolated checks 32-34 in the synthetic tenant:
CSK was made dormant, the synthetic tenant was made active, two synthetic
administrators exercised the multi-admin and last-admin paths, and the states
were reversed before checks 35-48. The exact-one-active-tenant invariant was
preserved throughout. Checks 42-43 now normalize CRLF and lone CR to LF before
hashing.

| Frozen function | Raw production hash | Normalized production hash | Normalized expected hash | Match |
|---|---|---|---|---|
| `update_profile_verification(uuid,text,text)` | `a0522b6beb94bde3bdff22799afc1368` | `a0522b6beb94bde3bdff22799afc1368` | `a0522b6beb94bde3bdff22799afc1368` | YES |
| `prevent_non_admin_profile_privilege_changes()` | `d28cb697d8355a5e8005296a03ad63ea` | `d28cb697d8355a5e8005296a03ad63ea` | `d28cb697d8355a5e8005296a03ad63ea` | YES |

The final production matrix completed **48/48 PASS** and returned
`ok 48 - rollback removed every SAAS-9D-4B-1B fixture`. The explicit final
`ROLLBACK` remained in place. An independent post-check confirmed exactly one
active tenant, CSK active, one unchanged active CSK administrator, and zero
synthetic tenants, Auth users, profiles, memberships and recent test-shaped
audit rows.

### Current production verdict

SAAS-9D-4B-1B PRODUCTION DEPLOY: **PASS**

SAAS-9D-4B-1B POST-DEPLOY: **PASS**

FINGERPRINTS: **PASS**

TENANT PROFILE ISOLATION: **PASS**

OPERATIONAL RELATIONSHIP: **PASS**

GLOBAL ROLE BYPASS: **REMOVED**

ROLE MUTATION TENANT ISOLATION: **PASS**

LAST-ADMIN PROTECTION: **PASS**

LEGACY ROLE MAPPING: **PASS**

OWNER SELF-SERVICE: **PASS**

CROSS-TENANT PII: **PASS**

AUDIT TENANT BINDING: **PASS**

admin_list_users_v1: **UNCHANGED**

ACCOUNT-WIDE CONTRACT: **PRESERVED**

SECURITY DEFINER COUNT: **67**

COMPATIBILITY DEFAULTS: **7/7**

FIXTURE CLEANUP: **PASS (0)**

RUNTIME SMOKE: **PASS**

READY FOR GIT CHECKPOINT: **YES**

READY FOR SAAS-9D-4B-2 PLANNING: **GO**

READY FOR SAAS-9D-4B-2 IMPLEMENTATION: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## NORMALIZED FINGERPRINT GUARD

The approved canonical algorithm is:

```sql
md5(regexp_replace(pg_get_functiondef(p.oid), E'\r\n?', E'\n', 'g'))
```

An isolated regression self-check passed:

- identical semantic content encoded with LF, CRLF and lone CR normalized to
  the same MD5 `b81e722771977ee32a6822155f761acd`;
- a semantic content change produced a different MD5
  `a40185c2f9fcae35125ba26daa6b4597`;
- therefore line-ending representation is ignored while semantic drift still
  fails closed.

The authoritative normalized comparison is:

| FUNCTION | RAW PROD HASH | NORMALIZED PROD HASH | NORMALIZED EXPECTED HASH | MATCH? |
|---|---|---|---|---|
| `admin_set_user_role_v1(uuid,text)` | `f30c0568743acb638e316e13f32496f5` | `f30c0568743acb638e316e13f32496f5` | `f30c0568743acb638e316e13f32496f5` | PASS |
| `update_profile_identity(uuid,text,text)` | `4c535b7788eb39606f8f8202c9a4b135` | `4c535b7788eb39606f8f8202c9a4b135` | `4c535b7788eb39606f8f8202c9a4b135` | PASS |
| `update_profile_contact_details(uuid,text,text,text,text,text,text)` | `eaa03f94556c709e84dda089f3d010fd` | `eaa03f94556c709e84dda089f3d010fd` | `eaa03f94556c709e84dda089f3d010fd` | PASS |
| `update_profile_verification(uuid,text,text)` | `a0522b6beb94bde3bdff22799afc1368` | `a0522b6beb94bde3bdff22799afc1368` | `a0522b6beb94bde3bdff22799afc1368` | PASS |
| `prevent_non_admin_profile_privilege_changes()` | `d28cb697d8355a5e8005296a03ad63ea` | `d28cb697d8355a5e8005296a03ad63ea` | `d28cb697d8355a5e8005296a03ad63ea` | PASS |

Normalized baselines are therefore 5/5 PASS.

### Integration blocker

The target migration was required to remain byte-for-byte unchanged. Its
SHA-256 is still
`A9E1B684A8CA70EA76C3CF7FFEFB0EACBAB28DFA1C2FB80C142FC822C4A383ED`.
Consequently its transaction preflight still contains all five CRLF-derived
expected hashes and still calculates the actual value using raw
`md5(pg_get_functiondef(...))` at line 24. It does not call the approved
normalization algorithm.

This creates an unavoidable constraint conflict: the same normalized method
cannot be installed in the migration's own preflight guard while both the
migration bytes and SHA are required to remain unchanged. External preflight
normalization cannot make an unchanged in-migration guard safe or executable.
No target migration, test or application file was changed to conceal this
condition.

## RESUMED PRODUCTION PREFLIGHT

The resumed attempt revalidated the working-tree scope, exact function scope,
approved migration SHA and normalized 5/5 production baselines. The previously
captured read-only production baseline remains valid: one active CSK tenant,
one active tenant admin, zero membership/profile mapping mismatch, zero
tenant-integrity issue, SECURITY DEFINER count 67 and compatibility defaults
7/7.

The mandatory fingerprint-guard integration gate then failed closed for the
reason above. Later gates were not represented as newly executed PASS:
runtime smoke and the linked dry-run were not run. In particular, a dry-run
would only enumerate migration files; it would not execute and validate the
raw SQL guard that is known to reject the current production representation.

The target/local evidence for tenant profile isolation, operational
relationship enforcement, removal of global-role authority, tenant-local role
mutation and last-admin protection, legacy role mapping, owner self-service,
cross-tenant PII denial, tenant audit binding, frozen
`admin_list_users_v1`, account-wide contract preservation and caller
compatibility remains unchanged and PASS locally. It does not override the
failed production deployment gate.

### Resumed preflight verdict

FINGERPRINT GUARD NORMALIZATION: **FAIL — algorithm proven, but not integrated into the unchanged migration guard**

NORMALIZED BASELINES: **5/5 PASS**

MIGRATION SHA UNCHANGED: **PASS**

SAAS-9D-4B-1B PRODUCTION PREFLIGHT: **FAIL**

WORKING TREE SCOPE: **PASS**

FUNCTION SCOPE: **PASS**

FINGERPRINTS: **FAIL — in-migration guard still raw**

TENANT PROFILE ISOLATION: **PASS (TARGET / LOCAL); PRODUCTION PREFLIGHT NOT COMPLETED**

OPERATIONAL RELATIONSHIP: **PASS (TARGET / LOCAL); PRODUCTION PREFLIGHT NOT COMPLETED**

GLOBAL ROLE BYPASS: **REMOVED IN TARGET**

ROLE MUTATION TENANT ISOLATION: **PASS (TARGET / LOCAL)**

LAST-ADMIN PROTECTION: **PASS (TARGET / LOCAL)**

LEGACY ROLE MAPPING: **PASS**

OWNER SELF-SERVICE: **PASS**

CROSS-TENANT PII: **PASS (TARGET / LOCAL)**

AUDIT TENANT BINDING: **PASS (TARGET / LOCAL)**

admin_list_users_v1: **UNCHANGED**

ACCOUNT-WIDE CONTRACT: **PRESERVED**

CALLER COMPATIBILITY: **PASS (TARGET / LOCAL)**

SECURITY DEFINER COUNT: **67**

COMPATIBILITY DEFAULTS: **7/7**

READY FOR PRODUCTION PUSH: **NO**

READY FOR 4B-2: **NO-GO until 4B-1B production PASS and checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## FINGERPRINT DRIFT FORENSIC RECONCILIATION

### Scope and safety

This reconciliation was read-only with respect to production. No `db push`,
migration repair, SQL write, function replacement, ACL change, application
change, Git staging, commit or push was performed. The pending migration
`20260919150000_harden_tenant_user_role_identity_contact.sql` was not changed;
its approved SHA-256 remains
`A9E1B684A8CA70EA76C3CF7FFEFB0EACBAB28DFA1C2FB80C142FC822C4A383ED`.

Read-only normalized schema evidence was saved outside the repository as:

- `C:\Users\Mpios\Desktop\APP Krutla\saas9d4b1b-prod-schema.sql`;
- `C:\Users\Mpios\Desktop\APP Krutla\saas9d4b1b-local-schema.sql`.

These are schema-only forensic artifacts and contain no data dump, token,
credential or `.env` content.

### Fingerprint algorithm and root cause

The authoritative comparison uses the same catalog source and normalization
for every function:

```sql
md5(regexp_replace(pg_get_functiondef(p.oid), E'\r\n?', E'\n', 'g'))
```

Production and local PostgreSQL are both PostgreSQL 17.6
(`server_version_num = 170006`), so server-version rendering is not the
cause. Exact function blocks extracted from the production schema dump are
byte-for-byte equal, after CRLF/CR-to-LF normalization, to the definitions in
`20260816090000_remote_baseline.sql`. The semantic diff for all five functions
is zero lines.

The old 4B-1B values were calculated with raw
`md5(pg_get_functiondef(...))` against a local database whose function bodies
contained CRLF. Production stores the same bodies with LF. A read-only
production simulation that replaced LF in `prosrc` with CRLF reproduced every
old expected hash exactly. This proves the mismatch is a fingerprint
normalization defect, not a body, metadata or authorization change.

### Actual production catalog evidence

| Function / exact signature | OID | Arguments / result | Security / owner | Language / properties | Search path | Effective ACL |
|---|---:|---|---|---|---|---|
| `admin_set_user_role_v1(uuid,text)` | 29072 | `p_target_user_id uuid, p_new_role text` / `jsonb` | DEFINER / `postgres` | `plpgsql`, VOLATILE, PARALLEL UNSAFE, not strict | `pg_catalog, public, pg_temp` | `postgres`, `authenticated` EXECUTE |
| `update_profile_identity(uuid,text,text)` | 18738 | target user, first name, last name / `jsonb` | DEFINER / `postgres` | `plpgsql`, VOLATILE, PARALLEL UNSAFE, not strict | `public, pg_temp` | `postgres`, `authenticated`, `service_role` EXECUTE |
| `update_profile_contact_details(uuid,text,text,text,text,text,text)` | 18716 | target user and six contact fields / `jsonb` | DEFINER / `postgres` | `plpgsql`, VOLATILE, PARALLEL UNSAFE, not strict | `public, pg_temp` | `postgres`, `authenticated`, `service_role` EXECUTE |
| `update_profile_verification(uuid,text,text)` | 18542 | target user, action, optional note / `jsonb` | DEFINER / `postgres` | `plpgsql`, VOLATILE, PARALLEL UNSAFE, not strict | `public, pg_temp` | `postgres`, `authenticated`, `service_role` EXECUTE |
| `prevent_non_admin_profile_privilege_changes()` | 17947 | none / `trigger` | DEFINER / `postgres` | `plpgsql`, VOLATILE, PARALLEL UNSAFE, not strict | `pg_catalog, public, pg_temp` | `postgres` only |

`prosrc`, `pg_get_functiondef`, signatures, owner, security mode, search path,
language, volatility, parallel safety, strictness, arguments and return types
all agree with the deployed legal chain. There is no semantic difference in
auth logic, `profiles.role` logic, tenant-membership logic, audit logic, PII
logic or role mapping.

### Last-writer and deployed-chain timeline

| Migration | Action on the five functions | Body | Security/search path/owner | ACL | Applied on production? |
|---|---|---|---|---|---|
| `20260816090000_remote_baseline.sql` | Creates all five exact signatures and assigns owner | Defines current bodies | Defines current DEFINER mode, paths and owner | Defines baseline explicit grants/revokes | YES |
| `20260816143000_harden_public_function_execute_acl.sql` | Trigger-function ACL hardening | Unchanged | Unchanged | Removes client EXECUTE from `prevent_non_admin_profile_privilege_changes()`; no body change | YES |
| `20260905100000_harden_profile_direct_updates.sql` | Existence checks only for four profile RPCs | Unchanged | Unchanged | Unchanged for these five | YES |
| `20260919100000_add_tenant_user_admin_notes.sql` | Captures four RPC definitions as unchanged regression baseline | Unchanged | Unchanged | Unchanged for these five | YES |
| `20260919150000_harden_tenant_user_role_identity_contact.sql` | Pending target: would rewrite role/identity/contact only | Not applied | Not applied | Not applied | NO |

The deployed migration history is aligned through
`20260919100000_add_tenant_user_admin_notes.sql`; the only local-only row is
`20260919150000_harden_tenant_user_role_identity_contact.sql`. Therefore the
expected current production definition is the baseline body plus the approved
SEC-002 trigger ACL closure, exactly as observed.

Git history independently confirms the historical baseline file has one
originating commit only: `1442563ab430efd87bd5b239475c849bef11d6c7`
(`Consolidate Supabase migration baseline`, 2026-08-16). `git log --follow`,
`git blame` and `git show` provide no evidence that the historical migration
was edited after deployment. Its current SHA-256 is
`2752963E6D9CF086DDF1014906EE53B6FB2C1A64A64FC8DAA90B036F1DBFEB02`.

### Decision matrix

| FUNCTION | PROD HASH (normalized) | OLD EXPECTED HASH (raw local) | LAST WRITER MIGRATION | LAST WRITER APPLIED? | EXPECTED FROM CHAIN | SEMANTIC DIFFERENCE | CLASSIFICATION | BLOCKER? | NEW AUTHORITATIVE BASELINE |
|---|---|---|---|---|---|---|---|---|---|
| `admin_set_user_role_v1(uuid,text)` | `f30c0568743acb638e316e13f32496f5` | `8dcbd9595f464a823cc92cb98f354175` | `20260816090000_remote_baseline.sql` | YES | exact match | none; CRLF/LF only | **B. HARMLESS REPRESENTATION DIFFERENCE** | NO | `f30c0568743acb638e316e13f32496f5` using normalized method |
| `update_profile_identity(uuid,text,text)` | `4c535b7788eb39606f8f8202c9a4b135` | `9601c3086d40ea7061ad2d224d8ef54a` | `20260816090000_remote_baseline.sql` | YES | exact match | none; CRLF/LF only | **B. HARMLESS REPRESENTATION DIFFERENCE** | NO | `4c535b7788eb39606f8f8202c9a4b135` using normalized method |
| `update_profile_contact_details(uuid,text,text,text,text,text,text)` | `eaa03f94556c709e84dda089f3d010fd` | `6cb660a2817d73f3c8ccc6e97dee52e4` | `20260816090000_remote_baseline.sql` | YES | exact match | none; CRLF/LF only | **B. HARMLESS REPRESENTATION DIFFERENCE** | NO | `eaa03f94556c709e84dda089f3d010fd` using normalized method |
| `update_profile_verification(uuid,text,text)` | `a0522b6beb94bde3bdff22799afc1368` | `919ddef5b9865495027f05952663e564` | `20260816090000_remote_baseline.sql` | YES | exact match | none; CRLF/LF only | **B. HARMLESS REPRESENTATION DIFFERENCE** | NO | `a0522b6beb94bde3bdff22799afc1368` using normalized method |
| `prevent_non_admin_profile_privilege_changes()` | `d28cb697d8355a5e8005296a03ad63ea` | `7a16280259e73d186f30afd7892d705a` | body: `20260816090000`; ACL: `20260816143000` | YES / YES | exact body and approved closed ACL | none; CRLF/LF only | **B. HARMLESS REPRESENTATION DIFFERENCE** | NO | `d28cb697d8355a5e8005296a03ad63ea` using normalized method |

The two 4B-2 functions are not remediated here. Their production definitions
are nevertheless fully explained by the same deployed chain: verification is
the legal baseline definition; the trigger is the legal baseline definition
with the later approved client-ACL closure. Neither shows unexplained drift.

### Resume condition

All five functions classify as B; classifications D and E are zero. It is
therefore safe to update the authoritative fingerprint baselines and resume
the 4B-1B preflight. It is **not** yet safe to push the current pending
migration unchanged: its raw-hash preflight guard still embeds the five
CRLF-derived values. A separate reviewed change must convert that guard to the
normalized algorithm and normalized baselines, recalculate and re-approve the
migration SHA, and rerun the complete production preflight before any push.

### Final forensic verdict

FINGERPRINT NORMALIZATION: **PASS**

DEPLOYED MIGRATION CHAIN RECONSTRUCTED: **PASS**

LOCAL VS PROD DIFFERENCE EXPLAINED: **PASS**

STALE BASELINES: **0**

HARMLESS REPRESENTATION DIFFERENCES: **5**

APPROVED/EXPLAINED DRIFT: **0**

HISTORICAL MIGRATION FILE DRIFT: **0**

UNEXPLAINED PRODUCTION DRIFT: **0**

SAFE TO UPDATE AUTHORITATIVE BASELINES: **YES**

SAFE TO RESUME 4B-1B PRODUCTION PREFLIGHT: **YES — after a separately reviewed normalized-guard update**

READY FOR PRODUCTION PUSH: **NO**

READY FOR 4B-2: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## CURRENT RESUMED PREFLIGHT STATUS

The approved normalization method and 5/5 authoritative baselines are proven,
but the separately required normalized-guard update has not been authorized
for the target migration. Because that migration and its SHA were explicitly
required to remain unchanged, its raw guard is still a deterministic blocker.
This is the current and final status for this resumed attempt.

FINGERPRINT GUARD NORMALIZATION: **FAIL — not integrated into target migration**

NORMALIZED BASELINES: **5/5 PASS**

MIGRATION SHA UNCHANGED: **PASS**

SAAS-9D-4B-1B PRODUCTION PREFLIGHT: **FAIL**

READY FOR PRODUCTION PUSH: **NO**

READY FOR 4B-2: **NO-GO until 4B-1B production PASS and checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## PRODUCTION PREFLIGHT & DEPLOYMENT READINESS

### 1. Working tree

Preflight ran from `main` at
`4f2a521b94a2b0905eca7bfad52c750a231a6f3b`. The canonical real 4B-1B
scope is:

- `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md`;
- `SAAS_9D_4B1B_TENANT_PROFILE_ADMIN_HARDENING_REPORT.md`;
- `scripts/saas9d4b1b-concurrency.mjs`;
- `supabase/migrations/20260919150000_harden_tenant_user_role_identity_contact.sql`;
- `supabase/tests/20260919150000_harden_tenant_user_role_identity_contact_test.sql`;
- `supabase/tests/20260816143000_harden_public_function_execute_acl_test.sql`;
- `supabase/tests/20260905100000_harden_profile_direct_updates_test.sql`.

`AGENTS.md` has a pre-existing real content diff and remains unrelated,
excluded and untouched. No other real tracked or untracked diff exists.
`git diff --check` passes; Git emits only expected working-copy line-ending
warnings.

### 2. SHA

Recalculated SHA-256:
`A9E1B684A8CA70EA76C3CF7FFEFB0EACBAB28DFA1C2FB80C142FC822C4A383ED`.
It matches the approved artifact.

### 3. Exact scope

The migration changes only `admin_set_user_role_v1(uuid,text)`,
`update_profile_identity(uuid,text,text)`,
`update_profile_contact_details(uuid,text,text,text,text,text,text)` and the
narrow audit classifier `set_audit_log_tenant_id()`. It freezes
`admin_list_users_v1(integer,integer,text,text,text,text)`. Verification,
account lifecycle and privilege-trigger functions are preflight guards only;
4B-2 is not implemented here.

### 4. Production fingerprints — fail-closed blocker

CRLF and lone CR were normalized to LF. The production query returned the
same raw and normalized fingerprint for every inspected function.

| Function | Production normalized | Migration baseline | Target | Result |
|---|---|---|---|---|
| `admin_set_user_role_v1(uuid,text)` | `f30c0568743acb638e316e13f32496f5` | `8dcbd9595f464a823cc92cb98f354175` | `9732b7d53eaa080ebc6348cd1dd68ca2` | **BLOCKED** |
| `update_profile_identity(uuid,text,text)` | `4c535b7788eb39606f8f8202c9a4b135` | `9601c3086d40ea7061ad2d224d8ef54a` | `33e0a05fb0d142cd9ba7d99cc66c6652` | **BLOCKED** |
| `update_profile_contact_details(uuid,text,text,text,text,text,text)` | `eaa03f94556c709e84dda089f3d010fd` | `6cb660a2817d73f3c8ccc6e97dee52e4` | `ce0146bccc9a1cc1d89c3e4d26462586` | **BLOCKED** |
| `set_audit_log_tenant_id()` | `66154375df9ee963c266c0ff468d2526` | `66154375df9ee963c266c0ff468d2526` | `0b6bc80c569f88798f2899fdf3f2cd1b` | PASS |
| `admin_list_users_v1(...)` | `2a95b1f3ba9c404adfa84f7eb9b8d425` | same | unchanged | PASS |

Two frozen preflight dependencies also differ from the migration baseline:

- `update_profile_verification(uuid,text,text)`: production
  `a0522b6beb94bde3bdff22799afc1368`, migration guard
  `919ddef5b9865495027f05952663e564`;
- `prevent_non_admin_profile_privilege_changes()`: production
  `d28cb697d8355a5e8005296a03ad63ea`, migration guard
  `7a16280259e73d186f30afd7892d705a`.

Therefore the migration's first transaction block would fail before changing
the schema. This is semantic/canonical definition drift, not a CRLF artifact.

### 5. Production membership/admin baseline

Read-only production catalog checks passed:

- active tenants: 1; active CSK tenants: 1;
- memberships: 9; role distribution: `admin=1`, `user=8`;
- status distribution: `active=9`;
- active CSK admins: 1;
- duplicate memberships, orphan tenant/user references, unknown roles and
  unknown statuses: 0;
- CSK active membership/profile legacy-role mismatches: 0;
- reservation/lane and event-registration/event tenant-integrity issues: 0.

### 6. Role mutation isolation

Target review remains correct: tenant is resolved by the active-single-tenant
bridge; caller authority is an active tenant admin membership; the mutation
updates an existing `tenant_memberships.role` row only. Membership,
reservation or tenant-consistent event registration provides the operational
relationship. Global `profiles.role`, bare user existence and caller-supplied
tenant data are not authority. This target was locally verified but is not
production-deployable while the baseline gate differs.

### 7. Last-admin protection

The target takes a tenant-keyed advisory transaction lock, locks active admin
rows in deterministic user order, rechecks caller authority after locking and
counts active admins only in the resolved tenant. One active tenant admin
cannot be demoted; with two, one may be demoted. Another tenant's admin never
satisfies this invariant. The real local two-session evidence remains PASS.

### 8. Legacy role bridge

The approved mapping remains `admin<->admin`, `user<->user`,
`pracownik<->employee`, `instruktor<->instructor`. The existing sync trigger
is limited to the CSK tenant; a non-CSK membership mutation cannot alter the
global legacy role. Production currently has zero active CSK mapping mismatch.

### 9. Identity update

The target signature is unchanged. Administrative identity correction
requires active tenant-admin membership plus an approved operational
relationship. It does not grant an administrative owner bypass and rejects a
Tenant-B-only or unrelated target.

### 10. Contact update

The target signature is unchanged. Active admin or employee membership is
required. Employee scope remains customer-only and excludes self plus
admin/employee/instructor membership targets. Fields remain phone, postal
code, city, street, house number and apartment number. Instructor scope is not
expanded.

### 11. Operational relationship

The target uses only tenant membership, a tenant-owned reservation or a
tenant-consistent event registration joined to its event. Bare `user_id` and
`profiles.role` are insufficient.

### 12. Global-role negative case

The target bodies deny a global admin without active target-tenant membership.
Pending, suspended and missing membership likewise fail privileged role,
identity and contact paths. This is proven locally; no production mutation was
attempted during preflight.

### 13. Owner self-service

Existing owner contact/declaration self-service stays in
`update_my_profile_v1`. 4B-1B changes no owner RPC or application caller and
does not make tenant staff membership a requirement for the owner flow.

### 14. PII

The target does not expand DTOs. Relationship checks precede target profile
selection. Identity returns only corrected names; contact returns only the
existing contact fields. Tenant-B and unrelated-user PII remain denied.

### 15. Tenant audit binding

The target audit classifier adds only the three approved tenant-user
target/action pairs, requires a real target profile plus the same operational
relationship and requires non-null `tenant_id`. Audit details contain role
identifiers or changed field names/counts, not PII values. Existing global
`profile` and `account` audit remains tenant-null.

### 16. `admin_list_users_v1` freeze

Production fingerprint is exactly
`2a95b1f3ba9c404adfa84f7eb9b8d425`. Mode, owner, SP1 and authenticated-only
ACL match the frozen contract. The 4B-1A tenant-note source, signature and DTO
are unchanged.

### 17. Account-wide separation

Production fingerprints for `export_my_data_v1()` and
`anonymize_my_account_v1()` remain respectively
`ffa6b35c5502a347e463110401032061` and
`7e4d950e75e6e5782b139f11269d03a0`. Auth deletion and future leave-tenant
contracts are outside this migration.

### 18. Caller compatibility

Repository callers and RPC signatures require no new tenant argument. The
current admin/users page and owner account/profile flows remain compatible.
No repository service caller exists for the identity/contact administrative
RPCs.

### 19. Production ACL, owner and search path

| Function | Current mode / owner / path | Current EXECUTE |
|---|---|---|
| role writer | DEFINER / postgres / SP1 | authenticated only |
| identity writer | DEFINER / postgres / `public, pg_temp` | authenticated + service_role |
| contact writer | DEFINER / postgres / `public, pg_temp` | authenticated + service_role |
| audit classifier | INVOKER / postgres / `pg_catalog` | closed |
| list RPC | DEFINER / postgres / SP1 | authenticated only |

The target narrows all three writers to SP1 and authenticated-only. It adds no
grant. The current metadata is consistent with the observed production bodies,
but the strict body baseline mismatch blocks migration readiness.

### 20. SECURITY DEFINER inventory

Production count is 67, equal to the target count. No count drift was found;
the five strict fingerprint mismatches above remain blocking definition drift.

### 21. Compatibility defaults

All 7/7 CSK compatibility defaults remain present. 4B-1B does not remove
them.

### 22. Local evidence

Focused SQL 48/48, full DB 1192/1192, Node 739/739, TypeScript, build,
changed-file ESLint, Playwright 1/1, concurrency and cleanup all remain PASS.
Deadlocks, lost updates and remaining fixture are 0. The single npm audit
finding is the pre-existing moderate `baseline-browser-mapping` advisory.

### 23. Runtime baseline

Not executed after the fingerprint blocker. The fail-closed instruction was
honored before later gates; no application or production data was mutated.

### 24. Migration history

CLI read-only history is aligned through deployed
`20260919100000_add_tenant_user_admin_notes.sql`. There are no remote-only or
malformed rows. The only local-only migration is
`20260919150000_harden_tenant_user_role_identity_contact.sql`.

### 25. Dry-run

**NOT RUN.** The mandatory fingerprint gate failed first. Running a later gate
would not change the fact that the migration's own preflight would abort.

### 26. Deployment risk

- role mutation / tenant-local last-admin: HIGH impact, controlled locally;
- identity/contact PII and audit binding: HIGH impact, controlled locally;
- legacy bridge, caller and owner regression: MEDIUM;
- concurrency: MEDIUM, local evidence PASS;
- current deployment readiness: **HIGH / BLOCKED**, because the checked-in
  baseline does not describe the current production definitions.

A low-traffic window is not sufficient until the five baseline discrepancies
are reconciled by a separate reviewed change. No automatic repair is
authorized.

### 27. Blockers and verdict

The sole deployment-readiness blocker is the strict production fingerprint
drift listed in section 4. No SQL write, `db push`, migration repair, staging,
commit or push was performed.

SAAS-9D-4B-1B PRODUCTION PREFLIGHT: **FAIL**

WORKING TREE SCOPE: **PASS**

SHA: **PASS**

FUNCTION SCOPE: **PASS**

FINGERPRINTS: **FAIL**

TENANT PROFILE ISOLATION: **PASS (TARGET / LOCAL)**

OPERATIONAL RELATIONSHIP: **PASS (TARGET / LOCAL)**

GLOBAL ROLE BYPASS: **BLOCKED**

ROLE MUTATION TENANT ISOLATION: **PASS (TARGET / LOCAL)**

LAST-ADMIN PROTECTION: **PASS (TARGET / LOCAL)**

LEGACY ROLE MAPPING: **PASS**

OWNER SELF-SERVICE: **PASS**

CROSS-TENANT PII: **PASS (TARGET / LOCAL)**

AUDIT TENANT BINDING: **PASS (TARGET / LOCAL)**

admin_list_users_v1: **UNCHANGED**

ACCOUNT-WIDE CONTRACT: **PRESERVED**

CALLER COMPATIBILITY: **PASS**

READY FOR PRODUCTION PUSH: **NO**

READY FOR 4B-2: **NO-GO until 4B-1B production PASS and checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## POST-FORENSIC CURRENT STATUS

The preceding production-preflight FAIL remains an accurate historical record
of the fail-closed stop. The completed forensic reconciliation above
supersedes its explanation of the blocker: the five hash mismatches are proven
CRLF/LF representation artifacts, with zero semantic, manual, historical-file
or unexplained production drift.

FINGERPRINT NORMALIZATION: **PASS**

DEPLOYED MIGRATION CHAIN RECONSTRUCTED: **PASS**

LOCAL VS PROD DIFFERENCE EXPLAINED: **PASS**

STALE BASELINES: **0**

HARMLESS REPRESENTATION DIFFERENCES: **5**

APPROVED/EXPLAINED DRIFT: **0**

HISTORICAL MIGRATION FILE DRIFT: **0**

UNEXPLAINED PRODUCTION DRIFT: **0**

SAFE TO UPDATE AUTHORITATIVE BASELINES: **YES**

SAFE TO RESUME 4B-1B PRODUCTION PREFLIGHT: **YES — after a separately reviewed normalized-guard update**

READY FOR PRODUCTION PUSH: **NO**

READY FOR 4B-2: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## FINAL STATUS AFTER RESUMED PREFLIGHT

The forensic result remains PASS, but deployment readiness remains fail-closed:
the unchanged target migration still contains raw, CRLF-derived fingerprint
guards. The approved normalization method is not integrated into that guard.

FINGERPRINT GUARD NORMALIZATION: **FAIL — not integrated into target migration**

NORMALIZED BASELINES: **5/5 PASS**

MIGRATION SHA UNCHANGED: **PASS**

SAAS-9D-4B-1B PRODUCTION PREFLIGHT: **FAIL**

READY FOR PRODUCTION PUSH: **NO**

READY FOR 4B-2: **NO-GO until 4B-1B production PASS and checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## FINGERPRINT GUARD REMEDIATION

### Root cause and approved edit

The forensic result remains authoritative: the former failure came only from
raw `pg_get_functiondef` hashing across CRLF/LF representations. Because
`20260919150000_harden_tenant_user_role_identity_contact.sql` is still pending,
its fingerprint preflight was corrected in place under the explicit approval
for guard-only remediation.

The migration now hashes every frozen definition only after deterministic
normalization:

```sql
md5(regexp_replace(pg_get_functiondef(signature), E'\r\n?', E'\n', 'g'))
```

The five CRLF-dependent expected values were replaced by the authoritative
normalized values reconstructed from the deployed legal migration chain:

| Function | Normalized production | Normalized expected | Result |
|---|---|---|---|
| `admin_set_user_role_v1(uuid,text)` | `f30c0568743acb638e316e13f32496f5` | `f30c0568743acb638e316e13f32496f5` | PASS |
| `update_profile_identity(uuid,text,text)` | `4c535b7788eb39606f8f8202c9a4b135` | `4c535b7788eb39606f8f8202c9a4b135` | PASS |
| `update_profile_contact_details(uuid,text,text,text,text,text,text)` | `eaa03f94556c709e84dda089f3d010fd` | `eaa03f94556c709e84dda089f3d010fd` | PASS |
| `update_profile_verification(uuid,text,text)` | `a0522b6beb94bde3bdff22799afc1368` | `a0522b6beb94bde3bdff22799afc1368` | PASS |
| `prevent_non_admin_profile_privilege_changes()` | `d28cb697d8355a5e8005296a03ad63ea` | `d28cb697d8355a5e8005296a03ad63ea` | PASS |

### Guard self-test

The migration preflight contains an executable fail-closed self-test. LF,
CRLF and lone-CR variants of identical semantic content produce the same
normalized MD5. A semantic change produces a different MD5. The independent
local check produced:

- LF = CRLF = CR: `b81e722771977ee32a6822155f761acd`;
- semantic change: `a40185c2f9fcae35125ba26daa6b4597`;
- normalization equality: PASS;
- semantic-change inequality: PASS.

The self-test was also exercised successfully by a complete local database
reset that applied the corrected pending migration.

### SHA transition

OLD SHA:
`A9E1B684A8CA70EA76C3CF7FFEFB0EACBAB28DFA1C2FB80C142FC822C4A383ED`
— **OBSOLETE / NOT APPROVED FOR DEPLOYMENT**.

NEW SHA:
`62CBFF411F1330CA8601D10FE0A5722933AA2E5B902BE295D4DA5F767C2D5276`
— **AUTHORITATIVE CANDIDATE**.

### Semantic migration-scope proof

The edit is confined to the initial frozen-definition preflight block:

- one normalization self-test was added;
- five expected fingerprints were replaced;
- the frozen-definition calculation now normalizes CRLF and CR to LF before
  MD5.

No role mutation, tenant-local last-admin locking, legacy role bridge,
identity/contact authorization, audit binding, ACL, owner, search path,
function signature, `admin_list_users_v1` freeze or 4B-2 function logic was
changed. After reset the target function fingerprints remain exactly the
previously approved targets: role `9732b7d53eaa080ebc6348cd1dd68ca2`,
identity `33e0a05fb0d142cd9ba7d99cc66c6652`, contact
`ce0146bccc9a1cc1d89c3e4d26462586` and audit classifier
`0b6bc80c569f88798f2899fdf3f2cd1b`. `admin_list_users_v1` remains
`2a95b1f3ba9c404adfa84f7eb9b8d425`.

### Full local revalidation

- local DB reset and corrected migration application: PASS;
- focused 4B-1B SQL: 48/48 PASS;
- normalization self-test: PASS;
- role mutation, last-admin, global-role negative, owner self-service,
  cross-tenant PII and audit-binding assertions: PASS in focused SQL;
- concurrency: PASS; active admins 1, changed role audits 1, deadlocks 0,
  contamination 0;
- identity/contact concurrency: PASS; lost updates 0, deadlocks 0;
- concurrency fixture cleanup: 0;
- full Supabase DB suite: 1192/1192 PASS;
- Node: 739/739 PASS;
- TypeScript: PASS;
- production build: PASS (only the existing middleware deprecation warning);
- changed-file ESLint: PASS;
- focused Playwright: 1/1 PASS;
- final local fixture count: 0;
- `git diff --check`: PASS; only pre-existing CRLF working-copy warnings.

Local security inventory is unchanged: SECURITY DEFINER 67, compatibility
defaults 7/7 and `admin_list_users_v1` unchanged.

### Resumed production preflight

Read-only production verification confirmed:

- project ref `yuyxfodozzpzrdzkmolu`;
- migration history LOCAL = REMOTE through `20260919100000`;
- the only local-only migration is `20260919150000`;
- normalized frozen fingerprints match 5/5;
- one active tenant and one active CSK tenant;
- memberships 9: admin 1, user 8; all 9 active;
- active CSK admins 1;
- duplicate memberships, orphan tenant/user links, unknown roles/statuses and
  active CSK legacy-role mismatches: 0;
- reservation/lane and event-registration/event tenant mismatches: 0;
- SECURITY DEFINER count 67;
- compatibility defaults 7/7;
- `admin_list_users_v1` unchanged;
- target authorization, operational relationship, global-role denial,
  tenant-local role mutation, last-admin locking, owner self-service,
  cross-tenant PII denial, tenant audit binding and caller compatibility remain
  supported by the complete local target evidence;
- production runtime returned no 5xx for `/`, `/login`, `/booking`, `/events`,
  `/account`, `/admin`, `/admin/users` and `/admin/reservations`; authenticated
  `/admin` and `/admin/users` rendered successfully in the production browser.

The final linked dry-run passed and listed exactly:

`20260919150000_harden_tenant_user_role_identity_contact.sql`

No real `db push`, production SQL write, migration repair, Git staging, commit
or push was performed.

### Final remediation verdict

FINGERPRINT GUARD REMEDIATION: **PASS**

NORMALIZATION SELF-TEST: **PASS**

SEMANTIC MIGRATION SCOPE UNCHANGED: **PASS**

OLD SHA: **OBSOLETE**

NEW SHA: **62CBFF411F1330CA8601D10FE0A5722933AA2E5B902BE295D4DA5F767C2D5276**

LOCAL REGRESSION: **PASS**

SAAS-9D-4B-1B PRODUCTION PREFLIGHT: **PASS**

FINGERPRINTS: **PASS**

TENANT PROFILE ISOLATION: **PASS**

GLOBAL ROLE BYPASS: **REMOVED IN TARGET**

ROLE MUTATION TENANT ISOLATION: **PASS**

LAST-ADMIN PROTECTION: **PASS**

OWNER SELF-SERVICE: **PASS**

CROSS-TENANT PII: **PASS**

AUDIT TENANT BINDING: **PASS**

admin_list_users_v1: **UNCHANGED**

SECURITY DEFINER COUNT: **67**

COMPATIBILITY DEFAULTS: **7/7**

READY FOR PRODUCTION PUSH: **YES**

READY FOR 4B-2: **NO-GO until 4B-1B production PASS and checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**
