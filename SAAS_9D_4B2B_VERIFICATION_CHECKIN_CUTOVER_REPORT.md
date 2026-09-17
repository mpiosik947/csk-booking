# SAAS-9D-4B-2B — Verification / Check-in Cutover Report

Date: 2026-09-17
Baseline: `0fc7d5f8a830b27fdd4a43ee5dba818805b8f1bf`
Scope: local implementation only
Production write: **NO**

## 1. Exact DB scope

One forward, transactional migration was added:

- `supabase/migrations/20260920150000_cutover_tenant_user_verification.sql`

It adds the approved closed mutation/read helpers, introduces two public
resource/owner boundaries, cuts active readers and booking gates over to
`tenant_user_verifications`, preserves the temporary legacy mirror required by
the two-step rollout, and updates the audit trigger allowlist for the new
tenant-scoped audit actions. It does not add a table, tenant argument, RLS
policy, permissive table grant, ownership default or data rewrite.

## 2. Exact application scope

- `app/admin/check-in/page.tsx`: verification mutation now supplies the
  reservation ID to the resource-bound RPC.
- `app/account/page.tsx`: global profile data and tenant verification are read
  separately; staff verification note is no longer rendered to the owner.
- `app/dashboard/page.tsx`: tenant status is loaded through the owner RPC.
- `app/booking/BookingForm.tsx`: display state uses the owner RPC while the
  lane-derived backend booking check remains authoritative.
- focused Node contracts cover the changed Check-in and owner readers.

No Events, Reports, role, note, routing or account-lifecycle feature was
expanded.

## 3. Exact RPC scope

New approved SECURITY DEFINER boundaries:

1. `update_reservation_customer_verification_v1(uuid,text,text)` —
   authenticated only; reservation -> tenant/user derivation.
2. `get_my_active_tenant_verification_v1()` — authenticated owner-only minimal
   read through the exact-single-active bridge.

New closed SECURITY INVOKER helpers:

- `_apply_tenant_user_verification_v1(uuid,uuid,text,text,text,uuid)`;
- `_tenant_verification_status_for_lane_v1(uuid,uuid)`.

Existing signatures retained with approved body/ACL changes:

- `update_profile_verification(uuid,text,text)`;
- `admin_list_users_v1(integer,integer,text,text,text,text)`;
- `get_reservation_customer_profiles_v1(uuid[])`;
- `update_my_profile_v1(...)`;
- `create_reservation_v2__saas9d1_core(...)` and its unchanged wrapper;
- retained legacy `create_reservation(...)` verification gate.

## 4. Caller inventory

Admin Users keeps its bounded list and transitional generic writer. Check-in
keeps its reservation-scoped reader and moves its mutation to the new
reservation-bound writer. Account, Dashboard and Booking use the new owner
status reader. Reservation creation callers and API payloads remain unchanged.
The cancellation email server path continues to consume only the existing
minimal fields it needs from the hardened reservation reader.

## 5. Resource-bound tenant derivation

The Check-in writer accepts neither `tenant_id` nor `user_id`. It locks the
reservation, derives `tenant_id` and the target user from that row, verifies an
active admin/employee membership in that tenant, applies employee target
restrictions and locks the `(tenant_id,user_id)` verification row. Foreign,
mixed, missing and duplicate resources fail closed.

## 6. Verification source of truth

`tenant_user_verifications` is authoritative for the covered tenant flows.
Missing rows mean `pending/false`. Admin Users, the reservation profile reader,
owner displays and reservation creation contain no read fallback to legacy
profile verification. Focused tests deliberately made legacy and tenant values
different and proved that changing the legacy value does not change the
returned tenant decision.

## 7. Check-in cutover

The app now invokes
`update_reservation_customer_verification_v1(p_reservation_id,...)`. The
existing reservation batch reader returns verification joined by each trusted
reservation tenant/user pair. The attendance RPC is unchanged and the
concurrency matrix proves that attendance and verification can commit without
deadlock or lost state.

## 8. Reader cutover

- Admin Users filters, count and DTO use the resolved tenant decision.
- Check-in profile hydration uses reservation-bound tenant decisions.
- Account/Dashboard/Booking use the minimal four-field owner RPC.
- The owner RPC returns no note, verifier identity, membership metadata or
  foreign tenant row.

## 9. Owner / staff / system contracts

- OWNER reads only its minimal active-tenant decision and may invalidate
  existing own tenant decisions by changing global declarations; it cannot
  approve or reject.
- ADMIN may act only on an approved same-tenant operational relationship.
- EMPLOYEE may mutate only through a reservation-bound Check-in resource and
  cannot target self or tenant staff.
- SYSTEM/service role has no direct table grant and no generic verification
  writer grant.

## 10. Global-role negative case

`profiles.role=admin` without an active target-tenant membership is denied.
Pending, suspended and absent memberships are denied. The hardened authority
paths contain no `profiles.role` check.

## 11. Cross-tenant matrix

Focused rollback-only SQL proved:

- Admin A + reservation A: ALLOW;
- Admin B/global admin/pending/suspended + reservation A: DENY;
- Admin B + reservation B when B is the isolated active test tenant: ALLOW;
- Admin A + reservation B: DENY;
- same User X may hold independent A and B decisions;
- updating either decision does not change the other;
- mixed and duplicate reservation batches fail closed;
- the original active CSK invariant is restored before ROLLBACK.

## 12. PII DTO

The owner DTO contains exactly status, boolean, verification timestamp and
updated timestamp. It excludes staff note, verifier IDs and profile PII.
Cross-tenant tests returned no Tenant B verification or membership metadata.
Audit details contain stable before/after booleans/status and resource identity,
not note text, contact fields, address or declarations.

## 13. Audit

Every changed privileged verification mutation writes a tenant-bound
`tenant_user_verification_*` audit. Tenant is derived from the reservation or
approved operational relationship. No tested tenant verification audit had a
NULL tenant. Denials and no-change do not create a false changed audit.

## 14. No legacy fallback

Active reader bodies contain no `profile.verification_status` fallback. The
legacy profile fields are a one-way write-only compatibility projection during
the two-step rollout and do not authorize or fill missing tenant state.

## 15. Exact 4B-2C residual

Still deferred to 4B-2C or later review:

- global profile verification columns as a write-only compatibility mirror;
- transitional `update_profile_verification` wrapper, including old-app
  employee compatibility;
- the closed legacy reservation-profile core if zero callers are proven;
- retained legacy `create_reservation` service contract pending caller proof;
- transaction settings needed only for the temporary profile mirror;
- legacy profile verification indexes/FKs and trigger dependencies;
- account export/anonymization treatment of tenant verification data (4C);
- global role UI/helper retirement and trigger hardening (4D);
- active-single owner/Admin bridge replacement (9E);
- seven temporary CSK ownership defaults.

## 16. Deployment compatibility

- OLD APP + NEW DB: **PASS**. The old writer signature remains functional for
  related active staff, tenant state is authoritative and the compatibility
  mirror preserves the old display until app deployment.
- NEW APP + NEW DB: **PASS**. Focused Node, DB and Playwright contracts use the
  new RPCs and tenant source.
- NEW APP + OLD DB remains unsupported and is not an allowed rollout order.

Deployment remains DB-first, then application.

## 17. Concurrency

The deterministic local harness passed:

- two concurrent verification decisions serialize to one tenant row;
- both changed decisions produce exactly two tenant-bound audits;
- verification versus Check-in attendance commits both states;
- concurrent Check-in retry produces one `started`, one `already_started` and
  one attendance audit;
- active membership suspension racing a privileged mutation denies the
  mutation after lock serialization;
- valid Tenant A operation racing a foreign Tenant B resource attempt commits A
  and denies B with zero contamination;
- same-user A/B storage rows update concurrently and remain independent;
- deadlocks=0, lost updates=0, cross-tenant effects=0, cleanup=0.

## 18. ACL and security mode

`tenant_user_verifications` remains RLS-enabled with zero policies and direct
table access denied to PUBLIC, anon, authenticated and service_role. New public
RPCs are authenticated-only, owned by postgres and use
`search_path=pg_catalog,public,pg_temp`. Internal helpers are SECURITY INVOKER
and closed to all runtime roles. The unproved service_role grant was removed
from the transitional writer.

## 19. SECURITY DEFINER inventory

Post-migration count: **69**. The +2 are exactly the approved reservation-bound
writer and owner reader. Unexpected drift: **0**. UNKNOWN: **0**.

## 20. Compatibility defaults

Temporary CSK ownership defaults remain **7/7** and are not security authority.

## 21. Migration SHA-256

`F6B86E487018DC54DE8A35A026C991E66B9E1B8857F9CCCCA0C763688DAF1412`

## 22. Test results

- local DB reset/migration application: PASS;
- focused 4B-2B rollback-only SQL: **37/37 PASS**;
- deterministic concurrency matrix: PASS; deadlocks=0; cleanup=0;
- full Supabase DB suite: **40 files / 1260 tests PASS** on a fresh reset;
- all Node tests: **742/742 PASS**;
- TypeScript: PASS;
- production build: PASS (existing middleware-to-proxy warning only);
- focused Playwright Admin Users: 1/1 PASS;
- full Playwright: **31/31 PASS**;
- changed-files ESLint: no new finding; existing baseline remains two errors and
  one warning in pre-existing lines (`loadUser` order, home `<a>`, hook deps);
- `git diff --check`: PASS;
- local synthetic fixture post-check: 0.

`npm audit --omit=dev` was not part of the authorized minimum and was not run:
the environment rejected external registry metadata disclosure. No workaround
was attempted.

## 23. Git status

The working tree intentionally contains the 4B-2B migration, app cutover,
focused/concurrency tests, cumulative regression test updates, plan update and
this report. `AGENTS.md` was pre-existing, unrelated, and remains excluded and
untouched by this implementation. No file was staged or committed.

## 24. Final verdict

SAAS-9D-4B-2B LOCAL: **PASS**

DB COMPATIBILITY LAYER: **PASS**

OLD APP + NEW DB: **PASS**

NEW APP + NEW DB: **PASS**

RESOURCE-BOUND TENANT RESOLUTION: **PASS**

CHECK-IN CUTOVER: **PASS**

READER CUTOVER: **PASS**

TENANT VERIFICATION SOURCE OF TRUTH: **PASS**

LEGACY PROFILES FALLBACK: **ABSENT**

GLOBAL ROLE BYPASS: **REMOVED**

CROSS-TENANT VERIFICATION: **PASS**

CROSS-TENANT PII: **PASS**

AUDIT TENANT BINDING: **PASS**

prevent_non_admin_profile_privilege_changes: **UNCHANGED**

CONCURRENCY: **PASS**

SECURITY DEFINER COUNT: **69**

COMPATIBILITY DEFAULTS: **7/7**

DATA MODEL BLOCKER: **NO**

CALLER COMPATIBILITY: **PASS**

READY FOR 4B-2B PRODUCTION PREFLIGHT: **GO**

READY FOR 4B-2C: **NO-GO until 4B-2B production PASS/checkpoint**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 26. PRODUCTION APP CUTOVER & FINAL VERIFICATION

### 26.1 Deployment artifact and application scope

The approved six-file application cutover was committed as
`28c3373b03c170304c4257ca8e9370c8dae21b10` (`SAAS-9D-4B-2B cut over app to
tenant verification`) and pushed by ordinary fast-forward to `origin/main`.
Local and remote heads are identical and divergence is `0/0`. The commit
contains exactly:

- `app/account/page.tsx`;
- `app/admin/check-in/page.tsx`;
- `app/admin/check-in/profile-read.test.mjs`;
- `app/booking/BookingForm.tsx`;
- `app/dashboard/page.tsx`;
- `app/tenant-verification-cutover.test.mjs`.

`AGENTS.md` remained unrelated, excluded and unstaged. No migration, database
write, migration repair, force push, rebase or reset was performed during the
application cutover.

The GitHub deployment status tied to this exact commit reports `success` and
`Deployment has completed` for the production context
`Vercel - csk-booking-5nwh`. The separate duplicate context
`Vercel - csk-booking` failed as previously observed; it is not the project
serving `https://csk-booking-5nwh.vercel.app` and did not prevent the
production deployment.

### 26.2 NEW APP + NEW DB and deployed-call evidence

The production bundle contains `get_my_active_tenant_verification_v1` on the
Account, Dashboard and Booking paths. The authenticated Check-in bundle
contains `update_reservation_customer_verification_v1` and does not contain
the legacy `update_profile_verification` writer. This ties the deployed
artifact to the approved application cutover rather than merely to a local
build.

Production metadata after deployment confirms:

- migration `20260920150000` present;
- active tenants `1`, active CSK `1`;
- tenant verification foundation rows `9`;
- duplicate keys `0`, orphan tenants `0`, orphan profiles `0`;
- RLS enabled, policies `0`;
- direct DML denied to anon, authenticated and service_role;
- SECURITY DEFINER count `69`;
- compatibility defaults `7/7`;
- frozen `prevent_non_admin_profile_privilege_changes()` normalized hash
  `d28cb697d8355a5e8005296a03ad63ea`, unchanged.

The approved production rollback-only DB matrix remains **37/37 PASS** with
transaction rollback and zero fixture. The application deployment did not
alter any database object or invalidate that evidence.

### 26.3 Check-in, readers, tenant authority and audit

Read-only production definition checks confirm that the Check-in writer:

- resolves tenant and target user from the reservation;
- requires an active tenant membership with an allowed role;
- does not consult global `profiles.role` as authority;
- calls the closed tenant-verification helper with the resolved tenant/user;
- has no caller-supplied tenant authority.

The closed helper uses `tenant_user_verifications` as the source of truth and
writes the audit row with the resolved `p_tenant_id`. The owner reader,
Admin Users reader and reservation-customer reader all use the tenant table.
The two operational readers contain no fallback to
`profiles.verification_status` or `profiles.permissions_verified`. The owner
reader remains the minimal four-field DTO, and no direct browser table CRUD
was introduced.

The previously completed rollback-only matrix and deterministic concurrency
test remain authoritative for the negative cases: foreign tenant, unrelated
user/resource, global admin role without active membership, pending,
suspended and missing membership all deny; same-user Tenant A/B state stays
independent; tenant-bound audit and retry/idempotency invariants pass;
deadlocks, lost updates and cross-tenant effects are zero.

### 26.4 Runtime smoke and cleanup

Authenticated browser smoke rendered `/admin/check-in`, `/admin/users`,
`/admin`, `/account`, `/booking` and `/events`. `/login` rendered normally.
Independent HTTP GET checks returned 200 for public/application pages and
controlled 307 login redirects for anonymous admin entry. No 5xx and no
browser console warning/error were observed.

No synthetic record was created for the app smoke. The last independent
fixture post-check remains zero for synthetic tenants, memberships, users,
profiles, reservations, lanes/config, verifications and audits, with active
CSK and exactly one active tenant preserved.

### 26.5 Exact residual for SAAS-9D-4B-2C

The cutover intentionally leaves the compatibility-only global verification
columns and mirror, the transitional legacy-signature writer, legacy reader
and creator dependencies awaiting zero-caller proof, legacy verification
indexes/FKs and trigger dependencies, the account lifecycle treatment owned
by 4C, global-role UI/helper retirement owned by 4D, selected-tenant context
owned by 9E, and the seven temporary CSK ownership defaults. None was removed
or broadened by this deployment.

### 26.6 Final production verdict

SAAS-9D-4B-2B APP DEPLOY: **PASS**

SAAS-9D-4B-2B FINAL POST-DEPLOY: **PASS**

NEW APP + NEW DB: **PASS**

CHECK-IN CUTOVER: **PASS**

READER CUTOVER: **PASS**

RESOURCE-BOUND TENANT RESOLUTION: **PASS**

TENANT VERIFICATION SOURCE OF TRUTH: **PASS**

LEGACY PROFILES FALLBACK: **ABSENT**

GLOBAL ROLE BYPASS: **REMOVED**

CROSS-TENANT VERIFICATION: **PASS**

CROSS-TENANT PII: **PASS**

AUDIT TENANT BINDING: **PASS**

CONCURRENCY: **PASS**

prevent_non_admin_profile_privilege_changes: **UNCHANGED**

SECURITY DEFINER COUNT: **69**

COMPATIBILITY DEFAULTS: **7/7**

FIXTURE CLEANUP: **PASS**

READY FOR GIT CHECKPOINT: **YES**

READY FOR SAAS-9D-4B-2C PLANNING: **GO**

READY FOR SAAS-9D-4B-2C IMPLEMENTATION: **NO-GO until checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 25. Production preflight & two-step deployment readiness

Production preflight was completed read-only on 2026-09-17 against linked
project `yuyxfodozzpzrdzkmolu`. No migration, SQL write, migration repair,
application deployment, staging or Git write was performed.

### 25.1 Working tree reconciliation

The canonical semantic scope contains exactly 27 4B-2B files. The separate
`AGENTS.md` change is pre-existing, unrelated and excluded.

| Classification | Files |
|---|---|
| 4B-2B DB | `supabase/migrations/20260920150000_cutover_tenant_user_verification.sql` |
| 4B-2B APP | `app/account/page.tsx`; `app/admin/check-in/page.tsx`; `app/booking/BookingForm.tsx`; `app/dashboard/page.tsx` |
| 4B-2B TEST | `app/admin/check-in/profile-read.test.mjs`; `app/tenant-verification-cutover.test.mjs`; `supabase/tests/20260920150000_cutover_tenant_user_verification_test.sql`; `supabase/tests/20260920150000_cutover_tenant_user_verification_concurrency.ps1`; and the 16 cumulative SQL regression files from `20260816143000` through `20260920100000` shown by `git status` |
| 4B-2B REPORT/PLAN | `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md`; `SAAS_9D_4B2B_VERIFICATION_CHECKIN_CUTOVER_REPORT.md` |
| unrelated / excluded | `AGENTS.md` |
| temporary/support | none inside the repository |
| unexpected | none |

Raw `git status`, semantic diff, untracked inventory and diff stat agree with
this classification. The cumulative SQL changes update only the approved ACL,
function-inventory, fingerprint, tenant-verification and SECURITY DEFINER
expectations required by 4B-2B. `git diff --check` is PASS.

### 25.2 Migration identity and exact DB scope

The recalculated SHA-256 is exactly:

`F6B86E487018DC54DE8A35A026C991E66B9E1B8857F9CCCCA0C763688DAF1412`.

The migration introduces four functions:

| Function | Signature | Mode / owner / search path | ACL | Trusted derivation and result |
|---|---|---|---|---|
| `_tenant_verification_status_for_lane_v1` | `(uuid,uuid)` | INVOKER / postgres / `pg_catalog,public,pg_temp` | closed | lane -> tenant; supplied user is the authenticated booking subject; status only |
| `_apply_tenant_user_verification_v1` | `(uuid,uuid,text,text,text,uuid)` | INVOKER / postgres / `pg_catalog,public,pg_temp` | closed | internal caller supplies already authorized tenant/user/resource; locked tenant row; minimal JSON; tenant-bound audit |
| `update_reservation_customer_verification_v1` | `(uuid,text,text)` | DEFINER / postgres / `pg_catalog,public,pg_temp` | authenticated only | reservation -> tenant + target user; active admin/employee membership; minimal decision JSON; tenant-bound audit |
| `get_my_active_tenant_verification_v1` | `()` | DEFINER / postgres / `pg_catalog,public,pg_temp` | authenticated only | exact-single-active tenant + `auth.uid()`; four-field owner DTO without note, actor or profile PII |

It replaces or patches only the approved existing functions:

| Function | Security/ACL target | Tenant/resource/verification target |
|---|---|---|
| `set_audit_log_tenant_id()` | INVOKER, postgres, `pg_catalog`, closed | allowlists tenant verification audits and validates tenant/user operational relationship |
| `update_profile_verification(uuid,text,text)` | DEFINER, authenticated only | exact-active tenant + related target; authoritative tenant row; transitional legacy mirror only |
| `admin_list_users_v1(integer,integer,text,text,text,text)` | DEFINER, authenticated only | active tenant admin; related-user set; tenant verification join; existing bounded PII DTO |
| `get_reservation_customer_profiles_v1(uuid[])` | DEFINER, authenticated only | all reservations unique/existing/same tenant; active staff; reservation tenant/user verification join; DTO unchanged |
| `create_reservation_v2__saas9d1_core(...)` | INVOKER, closed | lane tenant + authenticated subject; tenant verification gate |
| `create_reservation(...)` | existing caller ACL retained | lane tenant + subject; tenant verification gate; no profile read fallback |
| `update_my_profile_v1(...)` | DEFINER, authenticated only | caller-owned declarations; invalidates every existing caller tenant decision; tenant-bound audits |

`create_reservation_v2(...)` remains the unchanged authenticated wrapper and is
fingerprint-frozen by the migration. The migration does not perform 4B-2C
cleanup, remove legacy columns, remove compatibility defaults or alter
`prevent_non_admin_profile_privilege_changes()`.

### 25.3 Production catalog and foundation evidence

Read-only production catalog verification returned:

- active tenants `1`; active CSK `1`;
- `tenant_user_verifications` rows `9`, matching the accepted 4B-2A result;
- duplicate keys `0`, orphan tenants `0`, orphan profiles `0`, rows without an
  operational relationship `0`, rows outside active CSK `0`;
- RLS enabled, policies `0`, direct DML denied to anon, authenticated and
  service_role;
- user-bound reservations without tenant `0`, missing profile `0`,
  reservation/lane tenant mismatches `0`;
- compatibility defaults `7/7`;
- current SECURITY DEFINER count `67`;
- all four newly introduced target functions absent before deployment.

Normalized production fingerprints for all migration inputs match exactly:
`update_profile_verification=a0522b6beb94bde3bdff22799afc1368`,
`prevent_non_admin_profile_privilege_changes=d28cb697d8355a5e8005296a03ad63ea`,
`admin_list_users_v1=2a95b1f3ba9c404adfa84f7eb9b8d425`,
`get_reservation_customer_profiles_v1=5902d87f82e5dd15a71ad6d4842bf5cf`,
`update_my_profile_v1=c160d8797e167741d36fa88348d952d1`,
`create_reservation_v2__saas9d1_core=b16bda3267a5db217d6b3e282b013968`,
`create_reservation_v2=ff1c273379e9ee3af3a1a60d131af81b`, and
`create_reservation=3212b32f37ebc8e665a9a94e94260976`.
Owners, search paths, modes and ACLs also match the migration preconditions.
The frozen profile trigger is unchanged. Target count is exactly `69`, with
the approved reservation writer and owner reader as the only `+2`; unexpected
additions `0`, UNKNOWN `0`.

### 25.4 Resource-bound resolution, source of truth and isolation

The production integrity checks prove that every current user-bound
reservation has a tenant and profile, every reservation tenant matches its
lane tenant, and every existing verification key is unique. The approved
Check-in mutation therefore resolves reservation -> tenant/user without a
caller tenant or caller target-user parameter. Batch reads require unique,
existing, same-tenant reservation IDs. Booking resolves lane -> tenant and
uses the authenticated subject. Admin Users uses only the exact-single-active
bridge plus an approved membership/reservation/event-registration relation.

The target SQL and changed application paths contain no operational fallback
from missing tenant state to `profiles.verification_status` or
`profiles.permissions_verified`; missing tenant state is `pending/false`.
Global `profiles.role=admin` is not authority. Active tenant membership and the
trusted resource/relationship are required; foreign, pending, suspended and
absent membership cases are denied by the tested target. Same-user Tenant A/B
state remains keyed independently by `(tenant_id,user_id)`. Audit tenant ID is
derived from the acted-on reservation or approved relation, and no normal
tenant verification audit may have a NULL tenant.

The owner reader returns only status, boolean and timestamps. Check-in retains
its existing operational DTO but binds verification to each reservation
tenant. There is no foreign verification/membership expansion, full-profile
overfetch added by the cutover, or error path that identifies a foreign
resource.

### 25.5 Application cutover and deployment compatibility

| File | Old call/source | New call/source | Context and PII effect |
|---|---|---|---|
| `app/admin/check-in/page.tsx` | generic `update_profile_verification(user_id,...)` | `update_reservation_customer_verification_v1(reservation_id,...)` | reservation binds tenant and target; result contract remains compatible |
| `app/account/page.tsx` | profile SELECT included legacy tenant decision/note | global profile SELECT plus owner verification RPC | caller + active bridge; staff note removed from owner view |
| `app/dashboard/page.tsx` | legacy profile verification | owner verification RPC | caller + active bridge; minimal four-field DTO |
| `app/booking/BookingForm.tsx` | legacy profile verification for display | owner verification RPC | caller + active bridge; backend lane-derived gate remains authoritative |

There is no direct browser CRUD on `tenant_user_verifications` and no supplied
tenant ID. Admin Users keeps its call/DTO while the DB reader changes source.

OLD APP + NEW DB is PASS: old signatures stay available, the transitional
writer mirrors CSK state only after authoritative tenant mutation, readers
used by the old app remain compatible, no legacy column is removed, and the
new DB does not create a verification/check-in bypass or state loss.

NEW APP + NEW DB is PASS: all changed application paths call the approved
resource/owner contracts and local SQL, Node, Playwright and concurrency
evidence passed. NEW APP + OLD DB remains unsupported, so rollout order is
strictly DB first, production DB verification second, then an app checkpoint
and deployment. No additional schema change is required between DB PASS and
the app cutover; however, the current application artifact is an uncommitted
working tree and must receive a separately reviewed Git/deployment action.

### 25.6 Exact 4B-2C residual

4B-2B intentionally leaves: global profile verification columns as a
write-only compatibility projection; the transitional legacy-signature writer
and its old-app employee branch; the closed legacy reservation-profile core
pending zero-caller proof; retained legacy reservation creator pending caller
proof; mirror-only transaction settings; legacy verification indexes/FKs and
trigger dependencies; 4C account export/anonymization treatment; 4D global
role UI/helper retirement; 9E selected-tenant context; and seven temporary CSK
ownership defaults. None is removed by this migration.

### 25.7 Migration history, dry-run and runtime baseline

Supabase CLI 2.109.1 reports LOCAL = REMOTE for every migration through
`20260920100000`. There are no remote-only, malformed or divergent rows. The
only local-only row is `20260920150000`.

`supabase db push --linked --dry-run` completed successfully and would push
exactly `20260920150000_cutover_tenant_user_verification.sql`. It did not write
to production.

Read-only HTTP smoke returned final HTTP 200 and no 5xx for `/admin/check-in`,
`/admin/users`, `/admin`, `/account`, `/booking`, `/events` and `/login`.
Anonymous admin requests correctly ended on the login redirect. No account or
business record was mutated.

### 25.8 Deployment risk

- DB compatibility deployment: **MEDIUM**. The data volume is tiny and no
  backfill is performed, but active functions are atomically replaced and the
  Check-in/booking authority path changes. The migration has 5-second lock and
  120-second statement timeouts and fails closed on every fingerprint,
  foundation, ACL, default and SECURITY DEFINER invariant.
- application cutover: **MEDIUM**. The schema is already compatible after the
  DB step, but Check-in mutation and Account/Dashboard/Booking displays switch
  source. Focused and full browser tests reduce risk; app rollback remains safe
  while the temporary legacy mirror exists.

### 25.9 Production preflight verdict

SAAS-9D-4B-2B PRODUCTION PREFLIGHT: **PASS**

WORKING TREE SCOPE: **PASS**

SHA: **PASS**

DB SCOPE: **PASS**

APP SCOPE: **PASS**

RPC SCOPE: **PASS**

FOUNDATION INTEGRITY: **PASS**

RESOURCE-BOUND TENANT RESOLUTION: **PASS**

OLD APP + NEW DB: **PASS**

NEW APP + NEW DB: **PASS**

CHECK-IN CUTOVER: **PASS**

READER CUTOVER: **PASS**

TENANT VERIFICATION SOURCE OF TRUTH: **PASS**

LEGACY PROFILES FALLBACK: **ABSENT**

GLOBAL ROLE BYPASS: **REMOVED IN TARGET**

CROSS-TENANT VERIFICATION: **PASS**

CROSS-TENANT PII: **PASS**

AUDIT TENANT BINDING: **PASS**

prevent_non_admin_profile_privilege_changes: **UNCHANGED**

SECURITY DEFINER COUNT: **69**

COMPATIBILITY DEFAULTS: **7/7**

DRY-RUN: **PASS**

READY FOR DB PRODUCTION PUSH: **YES**

READY FOR APP CUTOVER AFTER DB PASS: **YES**

READY FOR 4B-2C: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**
