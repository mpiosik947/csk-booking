# SAAS-9D-4C DB phase — account lifecycle RPC hardening

Date: 2026-09-17

Repository HEAD at implementation start: `34a20549a7c6e294ade2322a837bd87749ca7aba`

Scope: local implementation and verification only

Production write: **NO**

## 1. Exact three-function scope

| Function | Signature | Active caller | Authority |
|---|---|---|---|
| `update_my_profile_v1` | 6 `text` + 10 `boolean` | `/account` | `auth.uid()` only |
| `export_my_data_v1` | `()` | `/api/account/export` | `auth.uid()` only |
| `anonymize_my_account_v1` | `()` | `/api/account/delete` | `auth.uid()` only |

No overload, tenant-admin authority, `profiles.role` authority, caller-supplied
`tenant_id`, application source change, RLS widening or new lifecycle function
was introduced.

## 2. Pre-change fingerprints

All guards normalize `CRLF -> LF` and then `CR -> LF` before hashing.

| Function/dependency | Pre-change normalized MD5 |
|---|---|
| `update_my_profile_v1(...)` | `c8c882630f05763f745788e9a108fb65` |
| `export_my_data_v1()` | `ffa6b35c5502a347e463110401032061` |
| `anonymize_my_account_v1()` | `7e4d950e75e6e5782b139f11269d03a0` |
| `redact_account_audit_details_v1(...)` | `43aab16c26223ca68f4b8a34310bcfb5` |
| `set_audit_log_tenant_id()` | `d3e931ecee92180002d1dddd86fc4f06` |
| `prevent_non_admin_profile_privilege_changes()` | `d28cb697d8355a5e8005296a03ad63ea` |

Target normalized MD5 fingerprints are:

- `update_my_profile_v1(...)`: `eed0787e7c5a67e537b5703289abf536`;
- `export_my_data_v1()`: `d159b7d0a14f7ffc9d6c3e5088d18dc5`;
- `anonymize_my_account_v1()`: `70b5f590399aa3f3a147935459b7f085`.

## 3. Caller inventory and application compatibility

The application had already been deployed APP-FIRST and accepts both the
production v1 export and strict v2 export. Active callers remain unchanged:

- `/account` calls the parameter-compatible self-profile RPC;
- `/api/account/export` calls the parameterless owner export;
- `/api/account/delete` calls DB anonymization with the authenticated user
  client and uses service role only afterward for Auth Admin deletion.

No browser or server caller supplies a target user or tenant. App source
changes in this DB phase: **0**.

## 4. `update_my_profile_v1` hardening

The RPC locks the account through a per-user transaction advisory lock and
then locks the caller's profile row. It updates only the existing allowlisted
contact/address and declaration fields. It cannot mutate a foreign profile,
role, tenant relation, staff-only note or verification decision directly.

When declarations change, every tenant verification row belonging to the
caller is locked in deterministic `tenant_id` order and reset to pending. Each
actual reset writes exactly one explicit tenant-bound, PII-free invalidation
audit. A no-change retry writes no audit. The legacy singular response fields
are resolved only through the existing exact-single-active-tenant bridge for
caller compatibility; the bridge is not authorization.

## 5. Export v2 contract

The existing v1 fields are unchanged and the response adds only the approved
`tenant_relationships` array. Top-level fields are exactly:

`account`, `event_registrations`, `export_version`, `generated_at`, `profile`,
`reservations`, `tenant_relationships`.

The version is `2`. Ordering is deterministic by `tenant_id`. Repeated export
is byte-for-structure stable after removing `generated_at`. The response does
not include tokens, staff notes, audit internals, actor metadata, foreign user
relations or foreign PII.

## 6. Exact tenant relationship mapping

| Source | V2 field |
|---|---|
| `tenants.id` | `tenant.id` |
| `tenants.name` | `tenant.name` |
| `tenants.slug` | `tenant.slug` |
| `tenant_memberships.role` | `membership.role` |
| `tenant_memberships.status` | `membership.status` |
| `tenant_memberships.created_at` | `membership.created_at` |
| `tenant_memberships.updated_at` | `membership.updated_at` |
| `tenant_user_verifications.verification_status` | `verification.status` |
| `tenant_user_verifications.permissions_verified` | `verification.permissions_verified` |
| `tenant_user_verifications.permissions_verified_at` | `verification.permissions_verified_at` |
| `tenant_user_verifications.updated_at` | `verification.updated_at` |

Every membership is filtered by `membership.user_id = auth.uid()`. The
composite membership key prevents duplicate tenant relations. Missing
verification becomes JSON `null`; no note or staff actor is exported.

## 7. Anonymization cleanup matrix

| Table/state | Relation | Action | Tenant scoped | PII | Audit/FK effect |
|---|---|---|---|---|---|
| `profiles` | `user_id` | DELETE | global | yes | removed after audit redaction |
| `tenant_memberships` | `user_id` | DELETE | yes | relationship metadata | deterministic tenant locks; last-active-admin guard |
| `tenant_user_verifications` | `user_id` | DELETE | yes | notes/actors | deleted after audit pseudonymization |
| `tenant_user_admin_notes` | `user_id` | DELETE | yes | yes | deleted after audit pseudonymization |
| `reservations` | `user_id` | ANONYMIZE / RETAIN | yes | yes | operational history, status, timing and pricing retained |
| `event_registrations` | `user_id` | ANONYMIZE / RETAIN | yes | yes | operational history/status retained; promotion claims/tokens cleared |
| `email_deliveries` | `recipient_user_id` | DELETE | yes | delivery identifier | user-owned delivery state removed |
| `confirmation_email_rate_limits` | user scope key | DELETE | technical | identifier | only the caller's user scope is removed |
| `audit_logs` | actor/target/resource | PSEUDONYMIZE / RETAIN | mixed | potentially | safe operational facts retained; direct values/details redacted |
| `auth.users` | account | RETAIN in RPC | global | yes | existing server route performs final Auth Admin deletion only after DB success |
| `tenants`, lanes, events | indirect | RETAIN | yes | no caller PII | business resources remain intact |

The RPC acquires the same per-user advisory lock used by profile updates and
locks each tenant relationship in deterministic order. It denies deletion of
the last active administrator of any tenant. Success writes exactly one global
`account_anonymized` audit with `tenant_id = NULL`. Retry returns
`already_anonymized` and does not create a second audit.

## 8. Account-wide versus tenant-scoped contract

`anonymize_my_account_v1()` remains an explicit account-wide owner action. It
removes all caller tenant relationships but does not represent or implement a
future leave-tenant operation. No leave-tenant function or implicit
membership-only deletion path was added. Other auth users, tenants and their
relationships remain unchanged.

## 9. Service-role boundary

All three RPCs are executable only by `authenticated`; PUBLIC, `anon` and
`service_role` EXECUTE are revoked. `service_role` is not business authority
for these functions. The application retains its separate, narrowly scoped
server-side Auth deletion step after successful DB anonymization.

## 10. Audit and PII

- declaration invalidation: one explicit tenant audit per changed tenant row;
- anonymization: existing related audits are pseudonymized/redacted;
- final lifecycle audit: global (`tenant_id = NULL`), PII-free and idempotent;
- no denial/no-change audit inflation;
- no note contents, contact data, tokens or foreign PII in export/audit tests.

Frozen audit and profile-protection helpers retained their normalized
fingerprints. The migration changes exactly the three approved RPCs.

## 11. Concurrency and idempotency

The local concurrent-session test verified:

- two simultaneous owner profile writes serialize and preserve one row per
  tenant with exactly two invalidation audits;
- anonymization racing a tenant-verification-invalidating profile update ends
  in one valid anonymized state, with zero orphan relationships;
- two simultaneous anonymization calls produce one `anonymized` and one
  `already_anonymized` result;
- exactly one global anonymization audit;
- deadlocks `0`, cross-tenant contamination `0`, fixture cleanup `0`.

## 12. Migration

Forward-only migration:
`supabase/migrations/20260922100000_harden_account_lifecycle_rpcs.sql`

SHA-256:
`8735888B72FE13ECF6265DE9D43797A4ADDB6F5E6702255280F8CEDB768881DD`

The migration is transactional, has fail-closed pre/postflight fingerprint,
metadata, ACL, SECURITY DEFINER and compatibility-default gates, and changes no
table schema or data during deployment.

## 13. Tests

| Check | Result |
|---|---|
| fresh local `supabase db reset` | PASS |
| focused 9D-4C SQL | 44/44 PASS, final ROLLBACK |
| concurrency/idempotency | PASS; deadlocks 0; contamination 0; cleanup 0 |
| full Supabase DB suite | 42 files / 1340 tests PASS |
| all Node tests | 750/750 PASS |
| TypeScript `--noEmit` | PASS |
| production build | PASS |
| focused account lifecycle Playwright | 1/1 PASS |
| application source diff | 0 |
| SECURITY DEFINER | 69 |
| compatibility defaults | 7/7 |

The existing Next.js middleware-to-proxy deprecation warning remains an
unchanged baseline warning and is unrelated to 4C.

## 14. Rollout plan

Deployment model is **DB SECOND / DB ONLY** because APP-FIRST is already in
production. The next action, only after separate authorization, is a read-only
production preflight covering project identity, source fingerprints, migration
history, SHA, integrity, exact one-migration dry-run and runtime baseline. No
production preflight or production write was performed in this phase.

## 15. Final verdict

SAAS-9D-4C DB PHASE LOCAL: **PASS**

EXACT FUNCTION SCOPE: **3**

UPDATE_MY_PROFILE: **PASS**

EXPORT V2: **PASS**

TENANT_RELATIONSHIPS: **PASS**

ANONYMIZATION: **PASS**

ACCOUNT-WIDE CONTRACT: **PRESERVED**

LEAVE-TENANT CONTRACT: **UNAFFECTED**

CROSS-USER DATA ISOLATION: **PASS**

CROSS-TENANT DATA BOUNDARY: **PASS**

PII: **PASS**

AUDIT: **PASS**

APP CHANGE: **0**

NEW APP + NEW DB: **PASS**

CONCURRENCY: **PASS**

SECURITY DEFINER COUNT: **69**

COMPATIBILITY DEFAULTS: **7/7**

READY FOR 4C DB PRODUCTION PREFLIGHT: **GO**

READY FOR 4D / 4E: **NO-GO until 4C production PASS/checkpoint**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 16. Production preflight & deployment readiness

Date: 2026-09-18

Production write performed by this preflight: **NO**

### 16.1 Working tree and repository gate

- branch: `main`;
- local HEAD: `34a20549a7c6e294ade2322a837bd87749ca7aba`;
- local `origin/main` tracking ref: the same commit;
- application source diff: `0`;
- `git diff --check`: PASS;
- `AGENTS.md`: unrelated, excluded and unstaged.

The canonical semantic working-tree scope is:

| File | Classification |
|---|---|
| `supabase/migrations/20260922100000_harden_account_lifecycle_rpcs.sql` | 4C DB migration |
| `supabase/tests/20260922100000_harden_account_lifecycle_rpcs_test.sql` | 4C focused SQL |
| `supabase/tests/20260922100000_harden_account_lifecycle_rpcs_concurrency.ps1` | 4C concurrency |
| `supabase/tests/20260904120000_add_account_pii_lifecycle_test.sql` | 4C regression update |
| `supabase/tests/20260918100000_harden_admin_reservation_reports_test.sql` | 4C regression update |
| `supabase/tests/20260919100000_add_tenant_user_admin_notes_test.sql` | 4C regression update |
| `supabase/tests/20260919150000_harden_tenant_user_role_identity_contact_test.sql` | 4C regression update |
| `supabase/tests/20260921100000_close_legacy_global_verification_path_test.sql` | 4C regression update |
| `SAAS_9D_4C_DB_PHASE_ACCOUNT_LIFECYCLE_REPORT.md` | 4C report |
| `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md` | 4C plan |
| `AGENTS.md` | unrelated / excluded |

Unexpected semantic diff: **0**.

### 16.2 Migration identity and exact scope

Recalculated SHA-256:
`8735888B72FE13ECF6265DE9D43797A4ADDB6F5E6702255280F8CEDB768881DD`.

It exactly matches the approved digest. The migration replaces exactly these
three existing signatures and no other lifecycle function:

| Function | Signature | Caller | Authority model |
|---|---|---|---|
| `update_my_profile_v1` | `(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)` | `/account` | owner identity from `auth.uid()` |
| `export_my_data_v1` | `()` | `/api/account/export` | owner identity from `auth.uid()` |
| `anonymize_my_account_v1` | `()` | `/api/account/delete` | owner identity from `auth.uid()` |

No 4D/4E function, application source, RLS policy, table schema or persistent
data is changed by the migration.

### 16.3 Production input fingerprints and target metadata

Production was queried through read-only catalog inspection. CRLF was
normalized to LF, then any remaining CR to LF, before MD5 hashing.

| Function | Current production | Approved pre-4C baseline | Target | Security / owner / search path | ACL now and target |
|---|---|---|---|---|---|
| `update_my_profile_v1(...)` | `c8c882630f05763f745788e9a108fb65` | same | `eed0787e7c5a67e537b5703289abf536` | DEFINER / `postgres` / `pg_catalog, public, pg_temp` | authenticated only |
| `export_my_data_v1()` | `ffa6b35c5502a347e463110401032061` | same | `d159b7d0a14f7ffc9d6c3e5088d18dc5` | DEFINER / `postgres` / `pg_catalog, public, pg_temp` | authenticated only |
| `anonymize_my_account_v1()` | `7e4d950e75e6e5782b139f11269d03a0` | same | `70b5f590399aa3f3a147935459b7f085` | DEFINER / `postgres` / `pg_catalog, public, pg_temp` | authenticated only |

For every function, PUBLIC, `anon` and `service_role` EXECUTE are denied.
There is no privilege expansion. The normalized digest of every other public
SECURITY DEFINER function is
`b971d1ff5f5e1ffd9d62f0124d684741`, matching the approved local inventory.
Unexpected function drift: **0**; UNKNOWN: **0**.

### 16.4 APP-FIRST production gate

The repository HEAD is the approved APP-FIRST commit
`34a20549a7c6e294ade2322a837bd87749ca7aba`. GitHub deployment status for the
production Vercel context `Vercel - csk-booking-5nwh` is `success` for that
exact SHA. The live alias responds normally and its account/export/delete
contracts match the previously completed APP-FIRST production verification.

- current production v1 accepted: PASS;
- strict target v2 validator: PASS;
- NEW APP + OLD DB: PASS;
- old-validator rollback detected: NO.

An unrelated second Vercel project context reports failure for the same commit;
it is not the `csk-booking-5nwh` production target and does not weaken the
positive target-context evidence.

### 16.5 Profile, export and relationship contracts

`update_my_profile_v1` keeps its signature and updates only the caller profile
selected by `auth.uid()`. It accepts no target user or tenant argument and does
not use `profiles.role` or tenant-admin authority. The `/account` caller remains
parameter-compatible and the allowlist of writable fields is unchanged.

The v2 export is the six-field v1 account export plus required
`tenant_relationships`. It maps production columns as follows:

| Source | Target v2 field |
|---|---|
| `tenants.id/name/slug` | `tenant.id/name/slug` |
| `tenant_memberships.role/status/created_at/updated_at` | `membership.role/status/created_at/updated_at` |
| `tenant_user_verifications.verification_status` | `verification.status` |
| `permissions_verified/permissions_verified_at/updated_at` | identically named verification fields |

Rows are filtered by `membership.user_id = auth.uid()`, ordered by
`tenant_id`, and the composite membership key prevents duplicate
relationships. Verification can be `null`; admin notes, verification notes,
actors, tokens, audit internals and foreign PII are absent.

### 16.6 Production relationship integrity

Only structural counts were recorded; no PII was copied to the report.

| Check | Result |
|---|---|
| auth users / profiles | `9 / 9` |
| tenant memberships | `9` |
| tenant verifications | `9` |
| tenant admin notes | `1` |
| active tenants | `1` |
| duplicate memberships / verifications / notes | `0 / 0 / 0` |
| orphan membership tenant / user | `0 / 0` |
| orphan verification tenant / user | `0 / 0` |
| orphan note tenant / user | `0 / 0` |
| verification / note without membership | `0 / 0` |
| unknown membership role / status | `0 / 0` |

### 16.7 Anonymization, authority, PII and audit

The approved cleanup matrix remains exactly the table in section 7. Business
history in reservations and registrations is anonymized and retained;
caller-owned deliveries, user rate-limit state, notes, verification rows,
memberships and the profile are deleted; related audit rows are pseudonymized
and retained; `auth.users` is deliberately outside the RPC and remains the
subsequent controlled server step.

The migration does not implement or conflate a future leave-tenant action.
Account export and anonymization are owner/account-wide actions whose sole
identity authority is `auth.uid()`. A tenant administrator, including a global
legacy `profiles.role=admin`, gains no ability to export or anonymize another
account. Local negative and concurrency evidence produced zero foreign-user
effects and zero cross-tenant contamination.

The final `account_anonymized` event remains global with `tenant_id = NULL`,
PII-free and idempotent. Tenant verification invalidations caused by the
owner's declaration change remain explicit tenant-bound audits. No single
tenant is incorrectly forced onto the account-wide lifecycle event.

### 16.8 Security inventory and compatibility defaults

- current production SECURITY DEFINER count: `69`;
- migration target count: `69`;
- unexpected DEFINER drift: `0`;
- compatibility defaults: `7/7` unchanged.

### 16.9 Local evidence reconfirmed

| Check | Result |
|---|---|
| fresh reset | PASS |
| focused SQL | 44/44 PASS, rollback |
| full DB | 42 files / 1340 tests PASS |
| Node | 750/750 PASS |
| concurrency / idempotency | PASS |
| deadlocks / orphans / contamination | 0 / 0 / 0 |
| TypeScript | PASS |
| build | PASS |
| focused Playwright | 1/1 PASS |
| fixture cleanup | 0 |
| git diff --check | PASS |

### 16.10 Current production runtime baseline

Safe, non-mutating HTTP checks returned:

| Target | Result |
|---|---|
| `/account` | `200`, private no-store, no 5xx |
| `/api/account/export` anonymous GET | controlled `401`, no-store |
| `/api/account/delete` safe GET | controlled `405`, no mutation |
| `/login` | `200` |
| `/admin` anonymous | controlled `307` to login |

No real export body, account deletion or anonymization was invoked. The current
Vercel response evidence includes target deployment headers and no 5xx.

### 16.11 Migration history and dry-run

Supabase CLI `2.109.1` returned matching local/remote history through
`20260921100000_close_legacy_global_verification_path.sql`, no remote-only row,
and exactly one local-only row:
`20260922100000_harden_account_lifecycle_rpcs.sql`.

`supabase db push --linked --dry-run` completed successfully and reported
exactly:

`Would push these migrations: 20260922100000_harden_account_lifecycle_rpcs.sql`

No `db push`, migration repair or production SQL write was performed.

### 16.12 Deployment risk and blockers

Overall deployment risk: **MEDIUM**. The schema/lock risk is low because the
migration transactionally replaces only three function bodies and performs no
table rewrite or deployment DML. The impact risk is medium because export v2
and account anonymization are privacy-sensitive/destructive contracts. It is
bounded by exact input/target fingerprints, strict APP-FIRST validation,
44 focused checks, the full 1340-test DB suite, serialized/idempotent lifecycle
tests and fail-closed migration postflight gates.

A normal low-traffic deployment window is sufficient; no maintenance outage is
required. Blockers before the separately authorized production push: **none**.

## 17. Production preflight final verdict

SAAS-9D-4C DB PRODUCTION PREFLIGHT: **PASS**

WORKING TREE SCOPE: **PASS**

SHA: **PASS**

EXACT FUNCTION SCOPE: **3**

PRODUCTION FINGERPRINTS: **PASS**

APP-FIRST PRODUCTION GATE: **PASS**

UPDATE_MY_PROFILE: **PASS**

EXPORT V2: **PASS**

TENANT_RELATIONSHIPS: **PASS**

ANONYMIZATION: **PASS**

ACCOUNT-WIDE CONTRACT: **PRESERVED**

LEAVE-TENANT CONTRACT: **UNAFFECTED**

CROSS-USER DATA ISOLATION: **PASS**

CROSS-TENANT DATA BOUNDARY: **PASS**

PII: **PASS**

AUDIT: **PASS**

SECURITY DEFINER COUNT: **69**

COMPATIBILITY DEFAULTS: **7/7**

DRY-RUN: **PASS**

READY FOR PRODUCTION PUSH: **YES**

READY FOR 4D / 4E: **NO-GO until 4C production PASS/checkpoint**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 18. Production deployment and post-deploy verification

Date: 2026-09-18

### 18.1 Final gate and deployment

The final fail-closed gate reconfirmed:

- production project: `yuyxfodozzpzrdzkmolu` / `csk-booking`;
- migration SHA-256:
  `8735888B72FE13ECF6265DE9D43797A4ADDB6F5E6702255280F8CEDB768881DD`;
- local/remote history matched through `20260921100000`;
- the only pending migration was `20260922100000`;
- dry-run listed exactly
  `20260922100000_harden_account_lifecycle_rpcs.sql`;
- pre-change production fingerprints matched 3/3;
- APP-FIRST commit `34a20549a7c6e294ade2322a837bd87749ca7aba`
  remained the successful `csk-booking-5nwh` Vercel deployment;
- SECURITY DEFINER `69`, defaults `7/7`, integrity PASS;
- runtime baseline had no 5xx;
- `AGENTS.md` remained unrelated and excluded.

`supabase db push --linked` then applied exactly the approved migration and no
other file. No migration repair or manual production SQL change was performed.

### 18.2 Migration state after deployment

- migration list: LOCAL = REMOTE including `20260922100000`;
- final dry-run: `Remote database is up to date`;
- production last migration: `20260922100000`.

### 18.3 Exact RPC targets

| Function | Target normalized MD5 | Signature | Mode / owner / search path | ACL |
|---|---|---|---|---|
| `update_my_profile_v1` | `eed0787e7c5a67e537b5703289abf536` | unchanged 6 text + 10 boolean | DEFINER / `postgres` / hardened | authenticated only |
| `export_my_data_v1` | `d159b7d0a14f7ffc9d6c3e5088d18dc5` | `()` | DEFINER / `postgres` / hardened | authenticated only |
| `anonymize_my_account_v1` | `70b5f590399aa3f3a147935459b7f085` | `()` | DEFINER / `postgres` / hardened | authenticated only |

PUBLIC, `anon` and `service_role` EXECUTE remain denied for all three. Target
fingerprints, bodies, owners, search paths and ACLs matched 3/3.

### 18.4 Production rollback-only matrix

The approved focused production matrix was executed through the linked
Management API with the original SQL semantics. Only the two `psql` client
directives were omitted; `BEGIN`, all 44 controls and the final `ROLLBACK`
remained intact.

Result: **44/44 PASS**.

The matrix verified owner-only profile mutation, unchanged foreign profile,
independent Tenant A/B verification invalidation, PII-free tenant audits,
strict export v2 shape and deterministic repeat export, foreign relationship
exclusion, secret exclusion, last-active-admin protection, complete approved
account anonymization, retained anonymized operational history, global
PII-free account audit, idempotent retry, foreign-account preservation and
absence of a leave-tenant contract.

An independent read-only postcheck returned zero remaining fixture tenants,
auth users, profiles, memberships, verifications, notes, reservations,
registrations, lanes and events. Production-persisted synthetic data: `0`.

### 18.5 Export v2 and NEW APP + NEW DB

The authenticated production `/account` UI loaded normally and the real
`Pobierz moje dane` action completed with the controlled success message
`Przygotowano eksport Twoich danych.` The response body was not copied to the
report or logs.

The database matrix independently established:

- `export_version = 2`;
- exact approved top-level structure;
- approved `tenant_relationships` DTO only;
- caller relationships only;
- deterministic relationship order;
- foreign membership/profile data `0`;
- duplicate relationships `0`;
- forbidden PII, admin notes and technical secrets `0`.

Therefore the deployed APP-FIRST validator accepts the actual v2 output and
the final state is **NEW APP + NEW DB — PASS**.

### 18.6 Account lifecycle authority and cleanup

`update_my_profile_v1` and both parameterless account lifecycle RPCs continue
to derive the target solely from `auth.uid()`. No target user or tenant can be
supplied. Tenant administrator status and global `profiles.role` grant no
foreign account authority. Cross-user effects in the production matrix were
zero.

The anonymization matrix confirmed deletion of caller memberships,
verifications, tenant admin notes, delivery state and user-scoped rate-limit
state; anonymization/retention of reservations and event registrations;
pseudonymization of relevant audits; profile removal; and deliberate retention
of `auth.users` for the subsequent controlled server-side Auth deletion step.

The account-wide audit remains global (`tenant_id = NULL`) and PII-free.
Tenant-owned verification invalidation audits retain the correct tenant. A
future leave-tenant operation remains a separate, unimplemented contract.

### 18.7 Concurrency and idempotency

The approved concurrency suite was rerun against the isolated local Supabase
database, not production. The deployed production bodies were independently
proven byte-for-normalized-fingerprint equal to those tested bodies.

- concurrent owner profile updates: PASS;
- tenant invalidation audits: exactly `2`;
- anonymize versus tenant activity: PASS;
- concurrent anonymize retry: PASS;
- account anonymized audit: exactly `1`;
- deadlocks: `0`;
- orphan tenant relationships: `0`;
- cross-tenant contamination: `0`;
- local concurrency fixture cleanup: `0`.

### 18.8 Security inventory and integrity

- SECURITY DEFINER: `69`;
- unexpected function drift: `0`;
- UNKNOWN: `0`;
- compatibility defaults: `7/7`;
- membership orphans: `0`;
- membership duplicates: `0`;
- verification/note orphan relationships: `0`;
- production rollback fixture remaining: `0`.

### 18.9 Runtime smoke

| Target | Result |
|---|---|
| authenticated `/account` | PASS; real v2 export accepted |
| `/account` HTTP | `200`, private/no-store |
| `/api/account/export` anonymous | controlled `401`, no-store |
| `/api/account/delete` safe GET | controlled `405`; no deletion |
| `/login` | `200` |
| `/admin` anonymous | controlled `307` to login |

No 5xx was observed and no real account deletion/anonymization was invoked.

## 19. Production deployment final verdict

SAAS-9D-4C DB PRODUCTION DEPLOY: **PASS**

SAAS-9D-4C POST-DEPLOY: **PASS**

UPDATE_MY_PROFILE: **PASS**

EXPORT V2: **PASS**

TENANT_RELATIONSHIPS: **PASS**

ANONYMIZATION: **PASS**

ACCOUNT-WIDE CONTRACT: **PRESERVED**

LEAVE-TENANT CONTRACT: **UNAFFECTED**

CROSS-USER DATA ISOLATION: **PASS**

CROSS-TENANT DATA BOUNDARY: **PASS**

PII: **PASS**

AUDIT: **PASS**

NEW APP + NEW DB: **PASS**

CONCURRENCY: **PASS**

SECURITY DEFINER COUNT: **69**

COMPATIBILITY DEFAULTS: **7/7**

FIXTURE CLEANUP: **PASS**

READY FOR GIT CHECKPOINT: **YES**

READY FOR SAAS-9D-4D / 4E PLANNING: **GO**

READY FOR SAAS-9D-4D / 4E IMPLEMENTATION: **NO-GO until checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**
