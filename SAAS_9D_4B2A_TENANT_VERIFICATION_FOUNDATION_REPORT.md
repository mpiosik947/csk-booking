# SAAS-9D-4B-2A — Tenant Verification Foundation

## 1. Scope and result

This local-only phase adds tenant-scoped verification storage and a closed,
deterministic CSK backfill. It does not change application code, existing
readers, `update_profile_verification`, the profile privilege trigger, or any
production object.

Migration:
`20260920100000_add_tenant_user_verification_foundation.sql`

SHA-256:
`3C328182BF2534FB437332F34C0673D62F75A583DD78BC159F971C1F278D99F9`

## 2. Exact verification field inventory

| Field | Type | Current table | Active readers | Active writers | Meaning | Scope | PII / audit relevance |
|---|---|---|---|---|---|---|---|
| `verification_status` | `text` | `profiles` | Booking, Account, Dashboard, Admin Users, Check-in, reservation creation RPCs | verification RPC; owner declaration reset trigger | tenant operational decision | tenant-specific | personal operational state; audit status transition |
| `verified_at` | `timestamptz` | `profiles` | Check-in DTO, account lifecycle | verification RPC | successful decision time | tenant-specific | personal metadata; audit provenance |
| `verified_by` | `uuid` | `profiles` | Check-in DTO, account lifecycle | verification RPC | verifier profile identifier | tenant-specific | pseudonymous staff identifier |
| `verification_note` | `text` | `profiles` | account lifecycle only | no active controlled writer | older legacy note | legacy/global frozen | potentially sensitive PII; not copied |
| `unverified_at` | `timestamptz` | `profiles` | Check-in DTO, account lifecycle | verification RPC | pending/rejected decision time | tenant-specific | personal metadata |
| `unverified_by` | `text` | `profiles` | Check-in DTO, account lifecycle | verification RPC | legacy verifier profile ID as text | tenant-specific | pseudonymous staff identifier |
| `permissions_verified` | `boolean` | `profiles` | Account, Dashboard, Admin Users, Check-in | verification RPC; declaration reset trigger | tenant approval of global declarations | tenant-specific | personal operational state |
| `permissions_verified_at` | `timestamptz` | `profiles` | Account, Admin Users, Check-in | verification RPC; declaration reset trigger | approval time | tenant-specific | personal metadata |
| `permissions_verified_by` | `uuid` | `profiles` | Check-in DTO, account lifecycle | verification RPC; declaration reset trigger | approving profile ID | tenant-specific | pseudonymous staff identifier |
| `permissions_verification_note` | `text` | `profiles` | Account, Admin Users, Check-in, account lifecycle | verification RPC; declaration reset trigger | tenant staff verification note | tenant-specific | sensitive operational PII; never public |

The `permission_*` and `qualification_*` columns remain global owner
declarations. Identity/contact fields remain global profile data. Neither group
is copied into the new table.

## 3. New tenant model

`public.tenant_user_verifications` has primary key `(tenant_id,user_id)` and
contains only:

- tenant/user identity;
- normalized `pending|verified|rejected` state;
- permissions decision and timestamp;
- tenant verification note;
- verified/unverified timestamps and actor UUIDs;
- row update timestamp.

Foreign keys bind tenant to `tenants`, user and actor UUIDs to `auth.users`.
Actor IDs from legacy profile rows are deterministically translated from
`profiles.id` to `profiles.user_id`. Unresolvable provenance aborts the
backfill. A secondary `(user_id,tenant_id)` index supports account-oriented
cleanup and later owner reads.

The same user can physically hold independent rows for Tenant A and Tenant B.
The focused test proves modifying B does not alter A.

## 4. RLS and ACL

- RLS: enabled;
- policies: zero;
- PUBLIC: no table access;
- anon: no table access;
- authenticated: no direct table access;
- service_role: no direct table access;
- backfill helper: SECURITY INVOKER, `postgres` owner, closed to all runtime
  roles.

No browser CRUD or PostgREST table surface is introduced.

## 5. Deterministic backfill

The closed helper `_backfill_csk_tenant_user_verifications_v1()` resolves only
the exact single active CSK tenant. Zero or multiple active tenants fail closed;
the existing unique index prevents a second active tenant.

Operational relationship is the union of tenant membership, tenant-owned
reservation, and tenant-consistent event registration. A meaningful legacy
state with no relationship, a relationship only to another tenant, or more
than one tenant aborts before any insert. Unsupported status and unresolved
actor provenance also abort.

Backfill is one-way and uses `ON CONFLICT (tenant_id,user_id) DO NOTHING`:

- rerun is idempotent;
- an existing tenant state is never overwritten;
- no state is duplicated to another tenant;
- `niezweryfikowane` and `pending` normalize to tenant `pending`;
- legacy writer/readers remain untouched until 4B-2B.

After a clean local reset the real-data inventory is empty: meaningful `0`,
eligible `0`, unrelated `0`, ambiguous `0`, skipped `0`. Synthetic tests cover
all fail-closed and positive paths. A fresh production inventory is mandatory
before any deployment; no production read or write was performed here.

## 6. PII and retention classification

| Data | PII | Tenant scoped | Retention / access |
|---|---|---|---|
| decision status and boolean | yes, operational | yes | owner sees selected-tenant result after 4B-2B; related staff only |
| decision timestamps | yes | yes | retained with tenant verification until account-wide deletion |
| verifier UUIDs | pseudonymous PII | yes | operational/admin access only; FK becomes NULL when actor Auth identity is deleted |
| verification note | sensitive PII | yes | least-privilege staff workflow; never public; max 2000 characters |
| global declarations | yes | no | remain in profile; owner-controlled; not duplicated |
| legacy `verification_note` | potentially sensitive | no, frozen | not copied; requires separate 4B-2B/4D disposition |

Future leave-tenant does not delete the global account or other tenants' rows.
Account-wide Auth deletion cascades the account's tenant verification rows.

## 7. Audit and provenance

Foundation backfill is migration provenance, not a user business action, and
does not create ordinary audit rows. It is deterministic from frozen legacy
state. Future privileged writes in 4B-2B must create tenant-bound, PII-minimal
audits; NULL-tenant business verification audits remain prohibited.

## 8. Frozen compatibility contracts

Normalized fingerprints remain:

- `update_profile_verification(uuid,text,text)`:
  `a0522b6beb94bde3bdff22799afc1368`;
- `prevent_non_admin_profile_privilege_changes()`:
  `d28cb697d8355a5e8005296a03ad63ea`.

Migration snapshots and postflight-compares both functions plus
`admin_list_users_v1` and `get_reservation_customer_profiles_v1`, including
body, mode, owner, search path and ACL. Application readers and Check-in remain
on legacy fields for compatibility. There is no fallback from tenant storage
to profile data because tenant storage is not yet a runtime source.

## 9. Test evidence

- local DB reset and full migration history: PASS;
- focused 4B-2A SQL: 30/30 functional checks plus rollback cleanup check PASS;
- full Supabase suite: 39 files, 1223 tests PASS;
- Node: 739/739 PASS;
- TypeScript: PASS;
- production build: PASS;
- focused Admin Users Playwright: 1/1 PASS;
- local fixture cleanup: 0;
- SECURITY DEFINER: 67;
- unexpected drift: 0;
- compatibility defaults: 7/7;
- `npm audit --omit=dev`: one existing moderate
  `baseline-browser-mapping` advisory; no dependency change was authorized.

No JavaScript/TypeScript application file changed, so changed-file ESLint is
not applicable. `git diff --check` is run as the final repository gate.

## 10. Rollout and rollback plan

Production rollout is DB-only for 4B-2A and requires a fresh read-only
inventory proving deterministic CSK classification, exact frozen fingerprints,
SECURITY DEFINER 67, defaults 7/7, exact migration SHA and one pending
migration. The migration is transactional. Any pre/postflight difference rolls
back the entire migration. No migration repair or manual partial SQL is an
acceptable rollback.

4B-2B remains blocked until 4B-2A production PASS and checkpoint/review. It
will own resource-bound verification/check-in writers and reader/application
cutover. 4B-2C will close the global path. The profile privilege trigger stays
frozen until 4D.

## 11. Production preflight & deployment readiness

### 11.1 Working tree and target identity

- repository: `C:/Users/Mpios/Desktop/APP Krutla/APP Krutla/csk-booking`;
- branch: `main`;
- checkpoint HEAD: `567dfa8ca3a971f8ea2d0490a19594f94199960f`;
- linked production project: `csk-booking`, ref `yuyxfodozzpzrdzkmolu`,
  `eu-central-1`, `ACTIVE_HEALTHY`;
- staging area: empty;
- application diff: zero JavaScript/TypeScript/application files;
- `AGENTS.md`: pre-existing unrelated semantic diff, excluded and untouched;
- 4B-2A scope: plan, migration, focused test, report and four regression
  inventory/fixture tests;
- temporary/support files: zero;
- unexpected semantic diffs: zero;
- `git diff --check`: PASS (line-ending conversion warnings only; no error).

### 11.2 Migration SHA and exact scope

Recalculated SHA-256:
`3C328182BF2534FB437332F34C0673D62F75A583DD78BC159F971C1F278D99F9`
(exact approved match).

The migration creates only `tenant_user_verifications`, its constraints and
index, fail-closed RLS/ACL, and the closed SECURITY INVOKER CSK backfill
helper. It snapshots and verifies four existing functions without replacing
them. There is no app/check-in/admin-users/account cutover, no change to
`update_profile_verification`, no change to the profile privilege trigger, no
legacy closure, no 4B-2B/2C work and no 9E work.

### 11.3 Production legacy verification inventory

Read-only inventory on 2026-09-17:

| Metric | Count |
|---|---:|
| total profiles / source rows | 9 |
| meaningful legacy verification rows | 4 |
| meaningful rows related only to active CSK | 4 |
| unrelated meaningful rows | 0 |
| ambiguous meaningful rows | 0 |
| wrong-tenant meaningful rows | 0 |
| unresolvable actor provenance | 0 |
| unsupported legacy status | 0 |
| eligible CSK rows | 9 |
| expected inserts | 9 |
| skipped rows | 0 |
| skipped: no relationship | 0 |
| skipped: other tenant only | 0 |
| rows already represented in target table | 0 (target absent) |

The production target table and helper are both absent before deployment.
Every meaningful row has exactly one deterministic tenant relationship and it
is the active CSK tenant. The insert set is all nine CSK-related profiles;
there is no inferred ownership and no skip reason in the current dataset.

### 11.4 Backfill determinism

The production candidate matrix satisfies the migration's fail-closed gates:
source `9`, eligible `9`, expected insert `9`, skipped `0`. The helper resolves
the exact single active CSK tenant, rejects unrelated/ambiguous/wrong-tenant
meaningful state and unresolved actor provenance, uses tenant-owned membership,
reservation and tenant-consistent event-registration relationships, and writes
with `(tenant_id,user_id) ON CONFLICT DO NOTHING`. It is deterministic,
idempotent and one-way; it neither overwrites an existing tenant state nor
duplicates state into another tenant.

### 11.5 Target table, isolation and direct access

The migration's actual target schema is the composite primary key
`(tenant_id,user_id)` plus status, permission decision/note, decision
timestamps, actor UUIDs and `updated_at`. Tenant and subject FKs cascade on
delete; actor FKs set NULL. Constraints limit status, enforce the verified
boolean/status relationship and cap the note at 2000 characters. The
`(user_id,tenant_id)` index supports account cleanup/read paths.

RLS is enabled with zero policies. All table privileges are revoked from
PUBLIC, anon, authenticated and service_role. The helper is SECURITY INVOKER,
owned by postgres, has `pg_catalog,public,pg_temp` search path and no runtime
EXECUTE grants. The composite key structurally permits the same user to hold
independent Tenant A and Tenant B states; neither row can overwrite the other.

### 11.6 Legacy and function freeze

Production normalized fingerprints and metadata match the migration target:

| Function | Hash | Mode | Owner | Search path | ACL |
|---|---|---|---|---|---|
| `update_profile_verification(uuid,text,text)` | `a0522b6beb94bde3bdff22799afc1368` | SECURITY DEFINER | postgres | `public, pg_temp` | authenticated + service_role; anon denied |
| `prevent_non_admin_profile_privilege_changes()` | `d28cb697d8355a5e8005296a03ad63ea` | SECURITY DEFINER | postgres | `pg_catalog, public, pg_temp` | postgres only; anon/authenticated/service_role denied |

The migration freeze also includes `admin_list_users_v1` and
`get_reservation_customer_profiles_v1`. Existing profile verification fields,
legacy readers/writers and app behavior remain unchanged. No app, Check-in,
Admin Users, Account/Profile, reservation or event caller changed.

### 11.7 PII, provenance and audit

Only operational status/boolean, tenant verification note, timestamps and
pseudonymous actor UUIDs are copied. Global declaration values, identity,
contact details and legacy `verification_note` are not duplicated. All copied
fields are required for later tenant-scoped decision display, provenance or
account cleanup. Subject deletion cascades the row; actor deletion nulls actor
provenance without deleting the subject decision.

The migration backfill emits no ordinary business audit row. Its provenance is
the versioned migration plus frozen source state; it creates no NULL-tenant
business audit and attributes no ambiguous tenant activity.

### 11.8 Security and compatibility baselines

- active CSK tenants: `1`;
- active tenants total: `1`;
- SECURITY DEFINER count: `67` (expected after deployment: `67`);
- unexpected function drift: `0`;
- unknown classifications: `0`;
- compatibility defaults: `7/7` unchanged.

### 11.9 Local evidence reconfirmed

- local DB reset: PASS;
- focused SQL: 30/30 plus rollback cleanup PASS;
- full DB: 1223/1223 PASS;
- Node: 739/739 PASS;
- TypeScript: PASS;
- production build: PASS;
- focused Playwright: 1/1 PASS;
- fixture cleanup: 0;
- `git diff --check`: PASS.

### 11.10 Production runtime baseline

Read-only HTTP smoke returned HTTP 200 and no 5xx for `/admin/users`, `/admin`,
`/account`, `/booking`, `/events`, `/login`, `/admin/check-in` and an invalid
public `/check-in/[token]` route. No verification state or other production
data was mutated.

### 11.11 Migration history and dry-run

Supabase CLI 2.109.1 reports LOCAL = REMOTE for every migration through
`20260919150000_harden_tenant_user_role_identity_contact.sql`. There are no
remote-only rows or malformed/divergent history entries. The only local-only
row is `20260920100000`.

`supabase db push --linked --dry-run` completed successfully and would push
exactly:

`20260920100000_add_tenant_user_verification_foundation.sql`

No production push, migration repair or SQL write was performed.

### 11.12 Deployment risk and blockers

Risk is **LOW**. The change creates a new table and indexes, reads nine profile
rows and inserts nine tenant rows in one transaction. It does not rewrite an
existing business table or cut over a caller. FK/index work is limited to the
new small table; PII is minimized and closed behind zero-policy RLS and revoked
ACL. A normal low-traffic deployment window is sufficient; a maintenance
window is not required for the observed production volume.

Pre-deploy blocking issues: **none**. Separate deployment authorization was
subsequently granted. 4B-2B remains blocked until checkpoint/review.

## 12. Production deployment and post-deploy verification

The separately authorized production command applied exactly
`20260920100000_add_tenant_user_verification_foundation.sql`. No migration
repair, manual schema write, application change or additional migration was
performed.

Post-deploy migration history is LOCAL = REMOTE through `20260920100000` and
the final `supabase db push --linked --dry-run` returned `Remote database is up
to date`.

Production catalog and data verification established:

- table exists with the composite `(tenant_id,user_id)` primary key;
- all five expected foreign keys, three CHECK constraints and both expected
  indexes match the migration;
- RLS enabled, policies `0`, PUBLIC ACL entries `0`;
- anon, authenticated and service_role direct DML: denied;
- helper: SECURITY INVOKER, postgres owner, closed runtime ACL;
- target rows `9`, expected rows `9`;
- missing `0`, unexpected `0`, value mismatches `0`, duplicate keys `0`;
- cross-tenant target rows `0`;
- frozen writer fingerprint
  `a0522b6beb94bde3bdff22799afc1368` unchanged;
- frozen trigger fingerprint
  `d28cb697d8355a5e8005296a03ad63ea` unchanged;
- SECURITY DEFINER `67`, compatibility defaults `7/7`.

The production rollback-only matrix covered closed table/helper access,
composite identity, unrelated/ambiguous fail-closed classification,
deterministic backfill, actor provenance, idempotency, no-overwrite behavior,
same-user/two-tenant independence, active-tenant guards and frozen
function/default inventories. Final result: `20/20 PASS`, explicit
`ROLLBACK`, synthetic tenant/auth users/profiles/memberships/verifications all
`0`, active CSK `1`.

Two preliminary matrix attempts were stopped by automatically created CSK
memberships from the existing Auth-user trigger. Each attempt left every
fixture counter at `0`. The final fixture used idempotent membership setup and
explicitly removed only the synthetic relationship needed for the unrelated
case; test meaning and production logic were unchanged.

Final HTTP smoke returned HTTP 200 for `/admin/users`, `/admin`, `/account`,
`/booking`, `/events`, `/login`, `/admin/check-in` and the invalid public
Check-in token route. No caller cutover occurred: legacy profile readers,
writers, Check-in, Admin Users, Account, reservations and events remain on the
pre-4B-2B contract.

## 13. Final verdict

SAAS-9D-4B-2A LOCAL: **PASS**

TENANT VERIFICATION MODEL: **PASS**

DATA MODEL BLOCKER: **RESOLVED / PROD PASS**

BACKFILL: **PASS**

TENANT VERIFICATION ISOLATION: **PASS**

LEGACY GLOBAL VERIFICATION: **UNCHANGED**

update_profile_verification: **UNCHANGED**

prevent_non_admin_profile_privilege_changes: **UNCHANGED**

PII: **PASS**

CALLER COMPATIBILITY: **PASS**

SECURITY DEFINER COUNT: **67**

COMPATIBILITY DEFAULTS: **7/7**

SAAS-9D-4B-2A PRODUCTION PREFLIGHT: **PASS**

WORKING TREE SCOPE: **PASS**

SHA: **PASS**

MIGRATION SCOPE: **PASS**

PRODUCTION LEGACY VERIFICATION INVENTORY: **PASS**

UNRELATED: **0**

AMBIGUOUS: **0**

UNRESOLVABLE: **0**

BACKFILL: **PASS**

TENANT VERIFICATION ISOLATION: **PASS**

DIRECT ACCESS: **DENIED**

LEGACY GLOBAL VERIFICATION: **UNCHANGED**

update_profile_verification: **UNCHANGED**

prevent_non_admin_profile_privilege_changes: **UNCHANGED**

CALLER COMPATIBILITY: **PASS**

PII: **PASS**

SECURITY DEFINER COUNT: **67**

COMPATIBILITY DEFAULTS: **7/7**

READY FOR PRODUCTION PUSH: **YES**

SAAS-9D-4B-2A PRODUCTION DEPLOY: **PASS**

SAAS-9D-4B-2A POST-DEPLOY: **PASS**

TENANT VERIFICATION MODEL: **PASS**

FIXTURE CLEANUP: **PASS**

READY FOR GIT CHECKPOINT: **YES**

READY FOR SAAS-9D-4B-2B PLANNING: **GO**

READY FOR SAAS-9D-4B-2B IMPLEMENTATION: **NO-GO until checkpoint/review**

READY FOR 4B-2B: **NO-GO until 4B-2A production PASS and checkpoint/review**

READY FOR PRODUCTION WRITE: **NO — separate explicit authorization required**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**
