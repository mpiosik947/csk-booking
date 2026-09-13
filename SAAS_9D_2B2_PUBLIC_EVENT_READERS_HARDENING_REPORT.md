# SAAS-9D-2B-2 Public Event Readers Hardening Report

## 1. Executive summary

SAAS-9D-2B-2 is locally implemented and verified. The two public event
readers now resolve the exact active tenant in a stable public wrapper and
delegate to inaccessible tenant-scoped cores. The public signatures, DTO,
anonymous access and product semantics are unchanged. No application code or
write path changed.

## 2. Exact scope

Changed runtime database functions:

1. `get_public_event_availability_v1()`
2. `get_public_event_list_v2(text,text,integer,integer)`

Added internal implementations:

1. `get_public_event_availability_v1__saas9d2b2_core(uuid)`
2. `get_public_event_list_v2__saas9d2b2_core(uuid,text,text,integer,integer)`

No other RPC definition, RLS policy, table ACL, writer, application route or
tenant default was changed.

## 3. Existing fingerprints

The migration preflight normalizes CRLF and CR to LF before MD5 and accepts
only the reviewed pre-2B-2 baselines:

| Function | Pre-2B-2 normalized MD5 |
|---|---|
| `get_public_event_availability_v1()` | `40adf74cb5adec5df3b4745fc7851433` |
| `get_public_event_list_v2(text,text,integer,integer)` | `fe075d7057149b0a0bad0129419a3e99` |

Local post-migration fingerprints are:

| Function | Post-2B-2 normalized MD5 |
|---|---|
| availability wrapper | `665b9ac71f99b3de3421d1534b24f088` |
| list wrapper | `642b84c0d78066e2071a0f0df1ce97ff` |
| availability core | `bac4afc5c5a26fc63d019304b7903f4b` |
| list core | `abe6f9d8e77655b1b5987825caee4c68` |

## 4. Wrapper/core architecture

Both public functions remain stable `SECURITY DEFINER` wrappers. Each calls
`active_single_tenant_id_v1()` and passes only that result to one
`SECURITY INVOKER` core. Client roles cannot call either core directly.

This retains anonymous aggregate access without granting anon any direct
access to participant registrations.

## 5. Active-single-tenant bridge

The caller supplies no tenant argument. The wrapper uses only
`active_single_tenant_id_v1()`, which returns an ID only when exactly one
tenant is active. There is no ordering, `LIMIT 1`, CSK fallback or membership
dependency in the public path.

## 6. 0/1/>1 active tenant behavior

| Active tenant state | Availability | List v2 |
|---|---|---|
| exactly one A | A rows only | successful A-only envelope |
| exactly one B | B rows only | successful B-only envelope |
| zero | zero rows | `ok=true`, `items=[]`, `total=0` |
| more than one | zero rows | `ok=true`, `items=[]`, `total=0` |

Invalid list arguments remain `ok=false, code=invalid_input`.

## 7. Tenant filtering

The availability core filters both `events.tenant_id` and
`event_registrations.tenant_id`, grouping by tenant and event ID. The list
core applies the same explicit tenant predicates before pagination and in the
page count aggregate. Tenant B rows cannot affect Tenant A visibility or
capacity.

## 8. Join consistency

Registration aggregates join events on both tenant ID and event ID. The
readers do not consume lane data, so no lane join was introduced. Existing
validated composite FKs still reject Event A plus Registration B and Event A
plus Lane B. Focused tests exercise both failures.

## 9. Public DTO

The public item/availability row is unchanged and contains exactly:

`event_id`, `title`, `description`, `event_date`, `start_time`, `end_time`,
`location`, `price`, `max_participants`, `registered_count`, `reserve_count`,
`available_spots`, `sold_out`.

The list envelope remains `ok`, `code`, `contract_version`, `filters`,
`pagination`, `items`. `tenant_id` was not added.

## 10. PII analysis

The aggregate response contains no participant name, registration ID, user
ID, email, phone, profile data, membership data, tokens, admin note or audit
metadata. Event title, description and location remain intentionally public
product fields. Tests validate both the exact key allowlist and absence of
synthetic participant PII.

## 11. ACL

| Function class | PUBLIC | anon | authenticated | service_role |
|---|---:|---:|---:|---:|
| public wrappers | no | EXECUTE | EXECUTE | no |
| internal cores | no | no | no | no |

No grant was widened.

## 12. Search path / owner

All four functions are owned by `postgres`, stable and use exactly
`search_path=pg_catalog, public, pg_temp`. Public wrappers are definers; cores
are invokers.

## 13. SECURITY DEFINER necessity

The wrapper must aggregate protected registrations for an anonymous reader.
Keeping this narrow definer avoids granting anon table access. Explicit
tenant predicates and a non-callable tenant-scoped core constrain the bypass.
The public-schema definer inventory remains 73 because the two new cores are
not definers.

## 14. Caller compatibility

`/events` continues calling `get_public_event_list_v2` with the existing four
arguments and parsers in `lib/event-read-contracts.ts` and
`lib/public-event-availability.ts` accept the unchanged DTO. No application
caller changed. The availability RPC remains compatible for external/public
consumers and existing tests.

## 15. Pagination/filter/sort

Search length, `upcoming`/`all`, Europe/Warsaw current-time comparison, stable
`event_date/start_time/id` ordering, page validation and maximum page size 50
remain unchanged. Registration aggregation remains limited to event IDs on
the current page. Local `EXPLAIN` used a sequential scan on the tiny reset
dataset, which is expected; the query is still tenant-filtered and bounded,
and the existing tenant/schedule indexes remain available for production
volume.

## 16. Cross-tenant tests

Focused SQL: 40/40 PASS. It verifies Tenant A only, Tenant B only, zero and
two active tenants, tenant-independent count semantics, cross-tenant relation
denial, DTO, ACL, fingerprints, pagination and fixture rollback.

## 17. Public anon tests

Anon and authenticated callers receive identical public data for the active
tenant. Both wrappers remain executable without a session. Direct core calls
are denied.

## 18. Regression 2A

The complete DB suite includes SAAS-9D-2A registration RPC tests and the
existing availability/registration-flow tests. Result: PASS. No writer or
overbooking contract changed.

## 19. Regression 2B-1

The focused 2B-1 test passes after replacing only its obsolete pre-2B-2
wrapper fingerprint assertion with the approved 2B-2 wrapper fingerprints.
All event-management writers, ACL and tenant isolation remain unchanged.

## 20. Full regression

| Verification | Result |
|---|---|
| clean local DB reset | PASS |
| focused 2B-2 SQL | PASS, 40/40 |
| focused ACL/9C/2B-1 regression | PASS, 113/113 |
| focused availability/2A/2B-1 regression | PASS, 86/86 |
| full Supabase DB suite | PASS, 892/892 |
| full Node suite | PASS, 734/734 |
| TypeScript `tsc --noEmit` | PASS |
| production build | PASS |
| Events Playwright | PASS, 8/8 |
| lane-family/admin Playwright smoke | PASS, 5/5 |
| fixture post-check | PASS, all five categories zero |
| `git diff --check` | PASS |

The known Next.js middleware-to-proxy warning remains unrelated technical
debt; no new build warning was introduced.

## 21. Migration SHA

`20260913150000_harden_public_event_readers.sql`

SHA-256:
`9E2E1A8530CCFB1A17AC5926F22E885033D0957788B0A27776637A82B35293DD`

## 22. Production deployment plan

Deployment is DB-only and signature-compatible. A separate production
preflight must verify the two old normalized fingerprints, exact migration
history, data/tenant invariants, only this pending migration, its SHA and a
successful linked dry-run. Actual production push requires a separate user
approval. Postflight must repeat catalog/ACL/fingerprint checks, public runtime
smoke and rollback-only cross-tenant verification. No production action was
performed in this task.

Compatibility:

- old app + old DB: safe;
- old app + new DB: safe, signatures and DTO are unchanged;
- new app + old DB: not applicable, application code did not change;
- current app + new DB: safe after the required production preflight.

## 23. Git status

The implementation intentionally leaves an unstaged working tree containing
the plan update, this report, one migration, its focused test and three
necessary regression-test updates:

- `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md`
- `SAAS_9D_2B2_PUBLIC_EVENT_READERS_HARDENING_REPORT.md`
- `supabase/migrations/20260913150000_harden_public_event_readers.sql`
- `supabase/tests/20260913150000_harden_public_event_readers_test.sql`
- `supabase/tests/20260816143000_harden_public_function_execute_acl_test.sql`
- `supabase/tests/20260911100000_tenant_aware_events_rls_test.sql`
- `supabase/tests/20260913100000_harden_event_management_rpcs_test.sql`

No `git add`, commit or push was executed.

## 24. Final verdict

SAAS-9D-2B-2 LOCAL: **PASS**

PUBLIC EVENT LIST TENANT ISOLATION: **PASS**

PUBLIC AVAILABILITY TENANT ISOLATION: **PASS**

ACTIVE-SINGLE-TENANT BRIDGE: **PASS**

0/1/>1 TENANT FAIL-CLOSED: **PASS**

PUBLIC DTO: **UNCHANGED**

PII: **PASS**

ANON PUBLIC CONTRACT: **PASS**

CALLER COMPATIBILITY: **PASS**

REGRESSION 2A: **PASS**

REGRESSION 2B-1: **PASS**

READY FOR SAAS-9D-2B-2 PRODUCTION PREFLIGHT: **GO**

READY FOR SAAS-9D-2C: **NO-GO until review**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 25. Production deployment and post-deploy verification

### 27.1 Deployment result

With explicit production approval, `supabase db push --linked` applied
exactly one migration:

`20260913150000_harden_public_event_readers.sql`

The pre-push SHA remained
`9E2E1A8530CCFB1A17AC5926F22E885033D0957788B0A27776637A82B35293DD`,
and the immediately preceding dry-run listed only that migration. No manual
SQL write, migration repair or other migration was executed.

### 27.2 Migration history and final dry-run

Post-deploy migration history is LOCAL = REMOTE through
`20260913150000`. The final linked dry-run returned:

`Remote database is up to date.`

### 27.3 Production function metadata and fingerprints

| Function | Normalized target MD5 | Mode | Owner | Search path | PUBLIC | anon | authenticated | service_role |
|---|---|---|---|---|---:|---:|---:|---:|
| `get_public_event_availability_v1()` | `665b9ac71f99b3de3421d1534b24f088` | DEFINER | postgres | `pg_catalog, public, pg_temp` | no | yes | yes | no |
| `get_public_event_list_v2(text,text,integer,integer)` | `642b84c0d78066e2071a0f0df1ce97ff` | DEFINER | postgres | `pg_catalog, public, pg_temp` | no | yes | yes | no |
| `get_public_event_availability_v1__saas9d2b2_core(uuid)` | `bac4afc5c5a26fc63d019304b7903f4b` | INVOKER | postgres | `pg_catalog, public, pg_temp` | no | no | no | no |
| `get_public_event_list_v2__saas9d2b2_core(uuid,text,text,integer,integer)` | `abe6f9d8e77655b1b5987825caee4c68` | INVOKER | postgres | `pg_catalog, public, pg_temp` | no | no | no | no |

Both wrappers are 2/2 identical to the reviewed target. Both cores remain
SECURITY INVOKER and are directly inaccessible to every tested application
role.

### 27.4 Tenant, relational and compatibility invariants

Production still has exactly one active tenant and it is the established CSK
tenant. `active_single_tenant_id_v1()` resolves that tenant correctly. The
following post-deploy counts are all zero:

- events with null tenant ownership;
- event-registration/event tenant mismatch;
- missing or null registration event;
- event-lane/event tenant mismatch or orphan;
- event-lane/lane tenant mismatch or orphan.

All 7/7 CSK compatibility defaults remain. The public-schema SECURITY
DEFINER count remains 73, hence deployment drift is zero. The migration did
not change a writer, RLS policy, membership rule, compatibility default or
application file.

### 27.5 Public DTO, PII and anonymous behavior

The production availability result exposes exactly the approved 13 fields:

`event_id`, `title`, `description`, `event_date`, `start_time`, `end_time`,
`location`, `price`, `max_participants`, `registered_count`, `reserve_count`,
`available_spots`, `sold_out`.

Three production availability rows were returned and forbidden-field matches
were zero. A real `SET LOCAL ROLE anon` read returned all three availability
rows plus a successful list envelope with `code=ok` and
`contract_version=2`. No email, phone, user ID, registration ID, tenant ID,
token or admin note was exposed. The public list currently contains zero
upcoming items, so item-shape equivalence is additionally supported by the
exact return builder, unchanged parser and completed local regression suite.

Explicit tenant predicates remain on both events and registration aggregates,
joined by tenant and event ID. Thus public list and availability isolation
match the locally exercised A-only, B-only and fail-closed 0/>1 cases.

### 27.6 Runtime smoke

Read-only production browser verification passed for:

- public Events: loaded a controlled empty upcoming state;
- availability: anon RPC returned a successful aggregate response;
- My Events: authenticated list loaded successfully;
- Admin Events: authorized management UI and lane choices loaded;
- Booking: public lane configuration loaded;
- Account: authenticated view completed loading without a generic error;
- Login: login form rendered normally.

There is no current upcoming public event, so public event-detail expansion
and registration-entry CTA could not be exercised live without creating or
changing production data. Their caller signature, response parser and
registration flow remain unchanged, and the relevant local SQL, Node and
Playwright regressions pass. This is an environment-data limitation, not a
detected defect.

### 27.7 Fixture cleanup and repository state

No production fixture was created. An independent read-only marker post-check
returned zero synthetic tenants, events, registrations and profiles for
SAAS-9D-2B-2. Remaining fixture: 0.

The proposed checkpoint scope is exactly:

1. `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md`
2. `SAAS_9D_2B2_PUBLIC_EVENT_READERS_HARDENING_REPORT.md`
3. `supabase/migrations/20260913150000_harden_public_event_readers.sql`
4. `supabase/tests/20260913150000_harden_public_event_readers_test.sql`
5. `supabase/tests/20260816143000_harden_public_function_execute_acl_test.sql`
6. `supabase/tests/20260911100000_tenant_aware_events_rls_test.sql`
7. `supabase/tests/20260913100000_harden_event_management_rpcs_test.sql`

There are no unrelated or temporary files. No staging, commit or Git push was
performed.

### 27.8 Production verdicts

SAAS-9D-2B-2 PRODUCTION DEPLOY: **PASS**

SAAS-9D-2B-2 POST-DEPLOY VERIFICATION: **PASS**

MIGRATION HISTORY: **LOCAL = REMOTE**

FINAL DRY-RUN: **REMOTE DATABASE IS UP TO DATE**

WRAPPER FINGERPRINTS: **2/2 PASS**

CORE SECURITY INVOKER: **PASS**

CORE DIRECT EXECUTE: **DENIED**

ACTIVE-SINGLE-TENANT BRIDGE: **PASS**

PUBLIC EVENT LIST TENANT ISOLATION: **PASS**

PUBLIC AVAILABILITY TENANT ISOLATION: **PASS**

PUBLIC DTO: **UNCHANGED**

PII LEAK: **0**

ANON PUBLIC CONTRACT: **PASS**

CALLER COMPATIBILITY: **PASS**

SECURITY DEFINER DRIFT: **0**

COMPATIBILITY DEFAULTS: **7/7 PASS**

FIXTURE CLEANUP: **0**

READY FOR GIT CHECKPOINT: **YES**

READY FOR SAAS-9D-2C: **NO-GO until checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 26. Archived production preflight evidence

### 25.1 Working tree reconciliation

Canonical Git inspection (`git status --porcelain=v2 --untracked-files=all`,
`git diff --name-only` and `git ls-files --others --exclude-standard`) reports
exactly seven in-scope files:

1. `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md`
2. `SAAS_9D_2B2_PUBLIC_EVENT_READERS_HARDENING_REPORT.md`
3. `supabase/migrations/20260913150000_harden_public_event_readers.sql`
4. `supabase/tests/20260913150000_harden_public_event_readers_test.sql`
5. `supabase/tests/20260816143000_harden_public_function_execute_acl_test.sql`
6. `supabase/tests/20260911100000_tenant_aware_events_rls_test.sql`
7. `supabase/tests/20260913100000_harden_event_management_rpcs_test.sql`

The UI-reported count of eight could not be reproduced by Git. There is no
eighth untracked, ignored-as-tracked, temporary or unrelated file. No
application file is changed. `git diff --check` passes; its only output is
the existing informational LF-to-CRLF working-copy warning.

### 25.2 Migration identity

The SHA-256 recalculated immediately before the production dry-run is:

`9E2E1A8530CCFB1A17AC5926F22E885033D0957788B0A27776637A82B35293DD`

It exactly matches the approved value.

### 25.3 Existing public wrapper baseline and target

| Function | Signature | Production normalized MD5 | Expected baseline | Target MD5 |
|---|---|---|---|---|
| availability | `get_public_event_availability_v1()` | `40adf74cb5adec5df3b4745fc7851433` | `40adf74cb5adec5df3b4745fc7851433` | `665b9ac71f99b3de3421d1534b24f088` |
| list | `get_public_event_list_v2(text,text,integer,integer)` | `fe075d7057149b0a0bad0129419a3e99` | `fe075d7057149b0a0bad0129419a3e99` | `642b84c0d78066e2071a0f0df1ce97ff` |

Fingerprints normalize CRLF and CR to LF. Result: 2/2 PASS. Both current
and target wrappers are stable `SECURITY DEFINER`, owned by `postgres`, with
exactly `search_path=pg_catalog, public, pg_temp`. Current and target ACL is
the same: `anon` and `authenticated` have EXECUTE; `PUBLIC` and
`service_role` do not. Neither wrapper accepts a caller-controlled tenant ID.

### 25.4 New core functions

| Function/signature | Mode | Owner | Search path | PUBLIC | anon | authenticated | service_role | Direct PostgREST exposure |
|---|---|---|---|---:|---:|---:|---:|---:|
| `get_public_event_availability_v1__saas9d2b2_core(uuid)` | SECURITY INVOKER | postgres | `pg_catalog, public, pg_temp` | no | no | no | no | no |
| `get_public_event_list_v2__saas9d2b2_core(uuid,text,text,integer,integer)` | SECURITY INVOKER | postgres | `pg_catalog, public, pg_temp` | no | no | no | no | no |

The cores are stable. All direct client-role EXECUTE paths are revoked. Their
target normalized MD5 values are respectively
`bac4afc5c5a26fc63d019304b7903f4b` and
`abe6f9d8e77655b1b5987825caee4c68`.

### 25.5 Active-tenant and fail-closed behavior

Production has exactly one active tenant: the established CSK tenant,
`slug=csk`, `name=CSK`. The production fingerprint of
`active_single_tenant_id_v1()` is
`6017112df961a334320d98dd0645e570`, and it remains inaccessible to PUBLIC,
anon, authenticated and service_role.

The one-active-tenant production baseline returns the CSK result. The zero
and multiple-active-tenant cases were not produced on production. Definition
inspection and focused local coverage prove both return safe empty public
results. Local evidence also covers A-only, B-only, A-registration/B-event
non-influence and relation mismatch denial, with zero fixture residue.

### 25.6 Tenant filtering and relational consistency

The list core filters `events.tenant_id` before pagination and filters
registration aggregation by the same resolved tenant. Counts join on both
`tenant_id` and `event_id`; Tenant B cannot affect the A list, pagination,
ordering, filters or counts. The availability core applies the same explicit
tenant predicates to events and registrations, including registered,
approved, reserve and cancelled count semantics. Neither reader consumes
`event_lanes` or lane data.

The read-only production baseline reports zero for:

- null event tenant ownership;
- registration/event tenant mismatch;
- null or missing registration event;
- event-lane/event tenant mismatch or orphan;
- event-lane/lane tenant mismatch or orphan.

### 25.7 DTO and PII review

The return DTO remains exactly 13 fields:

`event_id`, `title`, `description`, `event_date`, `start_time`, `end_time`,
`location`, `price`, `max_participants`, `registered_count`, `reserve_count`,
`available_spots`, `sold_out`.

Production availability returned three rows and zero forbidden-key
occurrences. Target SQL contains no `SELECT *` or nested participant object.
It returns no registration ID, owner identity, membership data, email, phone,
profile PII, token, admin note or audit metadata. PII exposure is zero.

### 25.8 Anonymous contract and callers

Production ACL permits anon and authenticated execution of both wrappers and
does not introduce an `auth.uid()` or membership requirement. The production
public Events screen loads without an application error. Its current empty
state contains no upcoming event, so a live registration CTA was deliberately
not mutated during this read-only preflight.

The application runtime has one reader call in `app/events/page.tsx`, using
the unchanged four-argument `get_public_event_list_v2` contract. Existing
parsers keep the same envelope and 13-field item shape. The availability
wrapper remains compatible for public/external consumers. No application or
API change is required.

### 25.9 Catalog, defaults and drift

Production contains 73 public-schema SECURITY DEFINER functions, matching
the post-2B-1 baseline. The target replaces two existing definers and adds
two invoker cores, so the expected count remains 73. No unrelated definer
definition is touched.

All 7/7 temporary CSK compatibility defaults remain present. Static migration
inspection confirms no table DDL, RLS policy change, membership change,
default change, application change, event writer change or registration
writer change. The only runtime definitions are the two wrappers and two
cores plus their exact grants/revokes.

### 25.10 Migration history and dry-run

Linked production history is identical to local history through
`20260913100000`. There is no remote-only migration and no other local
pending migration.

The read-only command `supabase db push --linked --dry-run` completed with
exit code 0 and reported exactly:

`20260913150000_harden_public_event_readers.sql`

No migration was applied. The CLI-only update notice (installed 2.109.1,
available 2.117.0) is informational and does not block this reviewed dry-run.

### 25.11 Regression and runtime baseline

Local regression evidence remains unchanged: focused 2B-2 40/40,
availability/2A/2B-1 86/86, ACL/9C/2B-1 113/113, full DB 892/892, Node
734/734, Events Playwright 8/8 and lane-family/admin smoke 5/5; TypeScript,
build, fixture cleanup and diff check pass.

Read-only production browser smoke passed for public Events, Booking, Login,
Account, My Events and Admin Events. Event management rendered for the
existing authorized admin session. No registration, event, tenant or other
production mutation was attempted. Because production currently has no
upcoming public event, the registration entry behavior is supported by the
unchanged contract and local regression evidence rather than a live write.

### 25.12 Deployment risk

| Risk | Rating | Rationale |
|---|---|---|
| wrapper `CREATE OR REPLACE` | LOW | signatures and return contracts are unchanged; only brief catalog locking |
| new invoker cores | LOW | new names, no client EXECUTE |
| anon/public outage | LOW | existing grants and safe empty behavior preserved |
| DTO regression | LOW | exact 13-field contract and parsers verified |
| availability regression | LOW | status/capacity semantics retained and regression-tested |
| cross-tenant leak | LOW after deployment | explicit tenant predicates on both sides of aggregates |
| ACL | LOW | wrappers unchanged; cores inaccessible |
| caller compatibility | LOW | no argument, signature, envelope or application changes |

A low-traffic deployment window is sufficient; a maintenance window is not
required. Post-deploy verification must recheck history, wrapper/core
fingerprints, metadata, ACL, definer count, public anon output and runtime.

### 25.13 Blockers

No production-push blocker was found. The actual push still requires separate
explicit approval. SAAS-9D-2C, second-tenant activation and SEC-004 closure
remain outside this preflight.

## 27. Archived production preflight verdicts

SAAS-9D-2B-2 PRODUCTION PREFLIGHT: **PASS**

WORKING TREE SCOPE: **PASS**

SHA: **PASS**

WRAPPER FINGERPRINTS: **2/2 PASS**

CORE SECURITY INVOKER: **PASS**

CORE DIRECT EXECUTE: **DENIED**

ACTIVE-SINGLE-TENANT BRIDGE: **PASS**

PUBLIC EVENT LIST TENANT ISOLATION: **PASS**

PUBLIC AVAILABILITY TENANT ISOLATION: **PASS**

PUBLIC DTO: **UNCHANGED**

PII: **PASS**

ANON PUBLIC CONTRACT: **PASS**

CALLER COMPATIBILITY: **PASS**

SECURITY DEFINER DRIFT: **0**

READY FOR PRODUCTION PUSH: **YES**

READY FOR SAAS-9D-2C: **NO-GO until 2B-2 production PASS and checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**
