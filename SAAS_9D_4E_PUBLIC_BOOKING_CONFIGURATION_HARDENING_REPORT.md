# SAAS-9D-4E — Public Booking Configuration Tenant Hardening

Date: 2026-09-18
Baseline: `34d4f518ff344593d350a6186b04273565d3a382` (`main` = `origin/main`, divergence `0/0`)
Mode: local implementation only; DB-only; no production write; no Git write

## 1. Exact scope

The implementation changes exactly one existing public RPC contract:

`public.get_public_booking_configuration_v1()`

It adds one closed implementation detail:

`public.get_public_booking_configuration_v1__saas9d4e_core(uuid)`

No application source, RLS policy, writer, 4D-2 object, 9D-5 object, 9E
tenant-routing contract or second-tenant activation path is changed.

## 2. Caller inventory

The only active application caller is `app/booking/page.tsx`. It invokes
`get_public_booking_configuration_v1` without arguments. Repository-wide
inspection found no active API route, server action, background job,
RPC-to-RPC path or service-role runtime caller. Other references are tests,
migrations and documentation.

## 3. Pre-change contract and fingerprint

- Signature: `get_public_booking_configuration_v1()`.
- Result: table with exactly 14 fields.
- Volatility/security: `STABLE SECURITY DEFINER`.
- Owner: `postgres`.
- `search_path`: `pg_catalog, public, pg_temp`.
- ACL: anon, authenticated and service_role; PUBLIC denied.
- Caller tenant argument: none.
- PII: none.
- Actor/global-role dependency: none.
- Authoritative normalized MD5:
  `2aee39e3d37d3d1a19f58c3626aa0365`.

The earlier plan value omitted two characters. The migration uses the full
value above and normalizes CRLF and CR to LF before hashing.

## 4. Wrapper target

The v1 wrapper keeps the same name, zero-argument signature, stability,
owner, search path and exact 14-field result. It resolves tenant authority
only with `active_single_tenant_id_v1()` and delegates to the closed core.
It does not accept a tenant UUID, read `profiles.role`, inspect membership or
trust browser state.

Target normalized wrapper MD5:
`0134f91776a7e967c06a016714f732ca`.

## 5. Closed SECURITY INVOKER core

The new core accepts one already-resolved UUID, is `STABLE SECURITY INVOKER`,
is owned by `postgres`, uses the approved search path and denies direct
EXECUTE to PUBLIC, anon, authenticated and service_role. It is not a PostgREST
API surface.

Target normalized core MD5:
`ff6f0a91a7c8ad66d885e2fd0c5df265`.

## 6. Tenant resolution

The wrapper has these deterministic semantics:

- zero active tenants: core receives `NULL` and returns an empty set;
- exactly one active tenant: returns only that tenant's valid configuration;
- more than one active tenant: helper returns no tenant and the wrapper
  returns an empty set.

The existing partial unique runtime guard normally prevents the third state.
The focused rollback-only test temporarily removed the local guard, proved
the wrapper returns zero rows with two active tenants, restored the guard and
then rolled the complete transaction back.

## 7. Hierarchy and configuration consistency

`shooting_lanes` is filtered by the resolved tenant before aggregation. The
parent join additionally requires `parent.tenant_id = resource.tenant_id`.
Mixed Parent A / Child B relationships are blocked by the validated composite
foreign key `(tenant_id, parent_lane_id) -> shooting_lanes(tenant_id, id)`.

`lane_booking_rules`, `lane_booking_durations` and `lane_pricing_rules` do not
have their own `tenant_id`. Their tenant ownership is derived through their
validated `lane_id` foreign keys to `shooting_lanes`; the migration fails
closed on any orphan or missing/unvalidated FK. No tenant value is guessed.

## 8. Public DTO

The output remains exactly:

1. `lane_id`
2. `parent_lane_id`
3. `resource_kind`
4. `name`
5. `display_name`
6. `display_order`
7. `effective_online_bookable`
8. `whole_lane_bookable`
9. `positions_bookable`
10. `max_people_online`
11. `booking_step_minutes`
12. `currency_code`
13. `durations_minutes`
14. `pricing`

Hierarchy ordering, active/inactive rules, duration coverage, pricing JSON,
currency and whole-lane/position behavior are preserved.

## 9. PII

The public result contains no `tenant_id`, user/profile fields, email, phone,
address, membership metadata, notes, audit data or security token. Focused SQL
checks every returned JSON key against the approved DTO.

## 10. service_role caller proof

There is no active service-role caller. The previous service_role wrapper
grant is therefore removed. The closed core also denies service_role direct
execution. No server workflow relies on either grant.

## 11. ACL

Target ACL:

| Function | PUBLIC | anon | authenticated | service_role |
|---|---:|---:|---:|---:|
| public v1 wrapper | DENY | ALLOW | ALLOW | DENY |
| closed INVOKER core | DENY | DENY | DENY | DENY |

The full ACL inventory was updated from 121 to 122 functions and from five to
four explicit service-role EXECUTE grants.

## 12. Zero/one/multiple-active behavior

Focused rollback-only evidence:

- zero active: safe empty result — PASS;
- one active A: wrapper equals core(A) — PASS;
- one active synthetic B: exactly B, including anon/authenticated — PASS;
- two active after temporary local guard removal: safe empty result — PASS;
- guard restored before the final transaction rollback — PASS.

## 13. Cross-tenant enumeration

The public function accepts no tenant identifier and exposes no tenant key in
its response. A caller cannot select or enumerate a dormant tenant through an
RPC parameter, URL state or role value. Tenant B data was complete through the
closed core but absent from the wrapper while B was dormant.

## 14. OLD APP + NEW DB

Application source changes: `0`. The existing caller still invokes the same
zero-argument v1 RPC and parses the same exact DTO. TypeScript, production
build and focused Playwright against the local target all pass. Deployment is
DB-only; the old app remains compatible with the new DB.

## 15. SECURITY DEFINER inventory

- Before: `69`.
- After: `69`.
- Wrapper remains DEFINER: `1`.
- New core is INVOKER: `1`.
- Unexpected DEFINER additions: `0`.
- Unknown objects: `0`.

## 16. Compatibility defaults

All seven approved temporary CSK `tenant_id` defaults remain present: `7/7`.
SAAS-9D-4E does not remove or use them as tenant authority.

## 17. Migration and SHA-256

Migration:
`supabase/migrations/20260924100000_harden_public_booking_configuration.sql`

SHA-256:
`95DFD2F91523205B0F80412C8A2926F9E3BBA792A50857B8E6139F3B1855500C`

The migration is minimal, forward-only and contains normalized pre-change and
post-change guards. No historical migration is modified.

## 18. Tests

- Focused rollback-only SQL: `26/26 PASS`; final `ROLLBACK`.
- Full Supabase DB suite: `44` files, `1402/1402 PASS`.
- Node: `750/750 PASS`.
- TypeScript: PASS.
- Production build: PASS (existing middleware-to-proxy warning only).
- Focused Playwright Booking: `1/1 PASS`.
- ACL inventory regression: PASS.
- Normalized fingerprint guards: PASS.
- Fixture post-check: synthetic tenant `0`, lane `0`, active tenants `1`.
- SECURITY DEFINER post-check: `69`.
- `git diff --check`: PASS at final verification.
- `npm audit --omit=dev`: one unrelated moderate advisory in
  `baseline-browser-mapping`; not changed in this scoped remediation.

A fresh destructive local `db reset` was not re-run after the final correction
because the host safety reviewer required a separate explicit approval. The
exact migration was applied successfully to the current local schema at the
approved baseline and the complete DB suite passed. No reset result is
claimed.

## 19. Production rollout plan

Deployment model: DB-only. A separate production preflight must independently
verify project identity, migration SHA, history, sole pending migration,
production input fingerprint, function/ACL baseline, integrity, defaults,
read-only runtime baseline and an exact one-migration dry-run. This local task
does not authorize or perform production write.

After an explicitly authorized DB push, verify migration history, final
dry-run, target fingerprints, metadata/ACL, 0/1/>1 semantics, public Booking,
tenant isolation, PII absence, SECURITY DEFINER `69`, defaults `7/7` and
fixture cleanup zero.

## 20. Final verdict

SAAS-9D-4E LOCAL: **PASS**

EXACT FUNCTION SCOPE: **1**

PUBLIC CONTRACT: **PASS**

14-FIELD DTO: **UNCHANGED**

TENANT RESOLUTION: **PASS**

0/1/>1 ACTIVE TENANT: **PASS**

TENANT ISOLATION: **PASS**

MIXED HIERARCHY: **DENIED**

CROSS-TENANT ENUMERATION: **DENIED**

PII: **PASS**

ANON: **PASS**

AUTHENTICATED: **PASS**

SERVICE_ROLE WRAPPER: **DENIED**

CORE DIRECT EXECUTE: **DENIED**

APP CHANGE: **0**

OLD APP + NEW DB: **PASS**

SECURITY DEFINER COUNT: **69**

COMPATIBILITY DEFAULTS: **7/7**

READY FOR 4E PRODUCTION PREFLIGHT: **GO**

READY FOR 9D-5: **NO-GO until 4E production PASS/checkpoint and 9E/4D-2 sequencing is resolved**

READY FOR 4D-2: **NO-GO until trusted 9E context**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## Production deployment and post-deploy verification

The final gate reconfirmed the linked production project
`yuyxfodozzpzrdzkmolu`, migration SHA-256
`95DFD2F91523205B0F80412C8A2926F9E3BBA792A50857B8E6139F3B1855500C`,
the original normalized wrapper fingerprint
`2aee39e3d37d3d1a19f58c3626aa0365`, one active CSK tenant,
zero configuration orphans/mismatches/duplicate rules, SECURITY DEFINER `69`,
compatibility defaults `7/7`, and HTTP 200 for `/booking`, `/login`, `/events`
and `/admin`. Local and remote migration history agreed through
`20260923100000`; the dry-run named only
`20260924100000_harden_public_booking_configuration.sql`. `AGENTS.md` was
unrelated and excluded.

The authorized `npx.cmd supabase db push --linked` applied exactly that one
migration successfully. No other production write, migration repair, app
deployment or Git write was performed. The immediate CLI `migration list`
encountered intermittent `LegacyDbConnectError`, although the final linked
dry-run succeeded with `Remote database is up to date`. An independent
production read of `supabase_migrations.schema_migrations` returned 100 rows,
last version `20260924100000`, and ordered-version MD5
`1a94a5be9352a3cde017e2d449c0034b`; the local set has exactly 100
versions, the same last version and the same digest. Thus LOCAL = REMOTE is
confirmed without relying on the transiently failing CLI listing.

Production `pg_get_functiondef` normalized fingerprints match the approved
targets: wrapper `0134f91776a7e967c06a016714f732ca` and closed core
`ff6f0a91a7c8ad66d885e2fd0c5df265`. The wrapper retains its zero-argument
signature, 14-field DTO, `postgres` owner, stable SECURITY DEFINER mode and
`pg_catalog, public, pg_temp` search path. Anon and authenticated retain
EXECUTE; service_role does not. The new core is stable SECURITY INVOKER with
the same owner/search path and no direct EXECUTE for PUBLIC, anon,
authenticated or service_role. The wrapper derives its tenant only from
`active_single_tenant_id_v1()`; the core accepts the resolved tenant UUID
and binds the root and parent resource tenant. There is no caller tenant
selector, public core exposure or unexpected SECURITY DEFINER drift.

The approved focused SQL matrix was executed in the production SQL Editor as
one `BEGIN`/`ROLLBACK` script. Only the two psql display/error directives were
omitted for SQL Editor syntax; the 26 test conditions and assertion remained
unchanged. The editor returned **26 rows, all `ok`**, with no exception from
the final assertion. It covered 0/1/>1 active tenant semantics, dormant B
isolation, anon/authenticated, ACL, exact DTO, no PII/internal keys,
same-tenant hierarchy, and configuration joins. Its temporary second-active
guard replacement was transactional. A separate post-rollback SELECT found
the unique guard present, CSK the sole active tenant, and zero fixture rows in
tenants, lanes, booking rules, durations and pricing. Production data persisted
from the matrix: **0**.

The post-deploy read also found zero tenant-null lanes, parent tenant
mismatches, rule/duration/pricing orphans and duplicate booking rules.
SECURITY DEFINER remains `69`; compatibility defaults remain `7/7`.
`/booking`, `/login`, `/events` and `/admin` each returned HTTP 200 with no
5xx. The production Booking form loaded the same five selectable lane
families. This is OLD APP + NEW DB with no application deployment.

Git remains uncommitted. The exact proposed 4E checkpoint scope is the plan,
this report, the new migration, its focused SQL test, the three adapted
existing SQL tests, and the focused Playwright test. `AGENTS.md` is a separate
pre-existing change and must remain excluded. `git diff --check` passed;
Git's LF/CRLF conversion warnings do not indicate whitespace errors.

### Final production verdicts

SAAS-9D-4E PRODUCTION DEPLOY: **PASS**

SAAS-9D-4E POST-DEPLOY: **PASS**

PUBLIC CONTRACT: **PASS**

14-FIELD DTO: **UNCHANGED**

TENANT RESOLUTION: **PASS**

0/1/>1 ACTIVE TENANT: **PASS**

TENANT ISOLATION: **PASS**

MIXED HIERARCHY: **DENIED**

CROSS-TENANT ENUMERATION: **DENIED**

PII: **PASS**

ANON: **PASS**

AUTHENTICATED: **PASS**

SERVICE_ROLE WRAPPER: **DENIED**

CORE DIRECT EXECUTE: **DENIED**

OLD APP + NEW DB: **PASS**

SECURITY DEFINER COUNT: **69**

COMPATIBILITY DEFAULTS: **7/7**

FIXTURE CLEANUP: **PASS**

READY FOR GIT CHECKPOINT: **YES**

READY FOR SAAS-9E PLANNING: **GO**

READY FOR SAAS-9E IMPLEMENTATION: **NO-GO until checkpoint/review**

READY FOR 4D-2: **NO-GO until trusted 9E context**

READY FOR 9D-5: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

---

# Historical Production Preflight & Deployment Readiness (before deployment)

Preflight date: 2026-09-18
Production project: `yuyxfodozzpzrdzkmolu` (`csk-booking`)
Mode: read-only; no DB push, migration repair, production mutation or Git write

## 1. Working tree

`main` remains at `34d4f518ff344593d350a6186b04273565d3a382`, equal
to `origin/main` with divergence `0/0`. `git diff --check` passes.

The canonical real working-tree scope is:

- 4E migration:
  `supabase/migrations/20260924100000_harden_public_booking_configuration.sql`;
- 4E focused test:
  `supabase/tests/20260924100000_harden_public_booking_configuration_test.sql`;
- 4E regression/ACL tests:
  `supabase/tests/20260816143000_harden_public_function_execute_acl_test.sql`,
  `supabase/tests/20260915100000_harden_lane_block_rpcs_test.sql`, and
  `supabase/tests/20260923100000_harden_profile_privilege_trigger_test.sql`;
- 4E Playwright regression:
  `tests/e2e/public-booking-configuration.spec.ts`;
- 4E report: this file;
- 4E plan: `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md`;
- unrelated and explicitly excluded: `AGENTS.md`.

Unexpected semantic diffs: `0`.

## 2. SHA-256

Recalculated migration SHA-256:
`95DFD2F91523205B0F80412C8A2926F9E3BBA792A50857B8E6139F3B1855500C`.

It matches the approved value exactly.

## 3. Exact scope

The production change remains exactly the existing
`get_public_booking_configuration_v1()` wrapper plus its new closed internal
SECURITY INVOKER core. Application source changes are zero. There is no 4D-2,
9D-5, 9E or second-tenant enablement in the migration.

## 4. Production input fingerprint

Read-only production inspection returned:

- normalized wrapper MD5:
  `2aee39e3d37d3d1a19f58c3626aa0365` — exact match;
- signature: zero arguments;
- output fields: `14`;
- volatility: stable (`s`);
- security: SECURITY DEFINER;
- owner: `postgres`;
- search path: `pg_catalog, public, pg_temp`;
- current ACL: PUBLIC deny, anon allow, authenticated allow, service_role
  allow;
- target core does not yet exist.

No unexplained production drift was found.

## 5. Caller inventory

The active runtime caller remains exactly `app/booking/page.tsx`, using the
zero-argument v1 contract. Repository references outside that caller are
tests, migrations, baseline documentation or regression scripts.

## 6. service_role caller proof

No API route, server action, job, runtime script or RPC-to-RPC production path
calls the wrapper with service_role. The target may safely remove the wrapper
service_role grant. The new core denies service_role direct execution.

## 7. Active tenant baseline

Production has exactly one active tenant and it is the canonical CSK tenant
(`name=CSK`, `slug=csk`, canonical UUID). The helper definition still contains
the exact-count guard and therefore does not select an arbitrary first tenant.
Production tenant state was not mutated.

## 8. Wrapper target

The migration preserves the name, zero-argument signature, 14-field DTO,
STABLE SECURITY DEFINER mode, owner and search path. The wrapper resolves only
`active_single_tenant_id_v1()`, has no `profiles.role` or caller-provided
tenant authority and calls only the closed core.

## 9. INVOKER core

Target metadata from the approved migration:

- signature:
  `get_public_booking_configuration_v1__saas9d4e_core(uuid)`;
- argument: one explicit resolved tenant UUID;
- return: the same 14-field table DTO;
- mode: STABLE SECURITY INVOKER;
- owner: `postgres`;
- search path: `pg_catalog, public, pg_temp`;
- ACL: direct EXECUTE denied to PUBLIC, anon, authenticated and service_role.

## 10. Same-tenant hierarchy

Production integrity checks returned:

- lane `tenant_id` nulls: `0`;
- missing parents: `0`;
- parent/child tenant mismatches: `0`;
- booking-rule orphans: `0`;
- duration orphans: `0`;
- pricing orphans: `0`;
- duplicate booking-rule rows per lane: `0`;
- validated configuration FKs: `3/3`;
- validated composite parent/tenant FK: `1/1`.

The target filters the root lane by resolved tenant, constrains the parent join
to the same tenant and obtains rules, durations and pricing only through their
validated lane FKs. Mixed hierarchy is excluded rather than hidden or guessed.

## 11. Public DTO

Production confirms 14 output fields. The migration keeps their names, types,
ordering and semantics unchanged. No tenant selector or private metadata is
added. The current wrapper returns ten configuration rows to its owner-level
read; the deployed anonymous Booking page renders five selectable lane
families successfully.

## 12. PII

The wrapper body and target core reference only booking configuration tables.
The DTO contains no profile, membership, note, audit, user identifier, email,
phone, address or tenant-administration field. PII exposure remains zero.

## 13. Zero/one/multiple-active behavior

- zero active: helper returns no UUID; target returns the approved safe empty
  set;
- one active: production baseline resolves CSK and current public Booking
  succeeds;
- more than one active: helper's exact-count predicate returns no UUID and the
  target returns an empty set; the production unique guard separately blocks
  creation of that state.

The preflight did not mutate tenant state. Direct behavioral proof for all
three states remains the local rollback-only 26/26 matrix.

## 14. Cross-tenant enumeration

The public wrapper accepts no tenant UUID, slug, resource tenant override or
query parameter. Its response contains no tenant key. Dormant/foreign tenant
configuration therefore cannot be selected or enumerated through this API.

## 15. OLD APP + NEW DB

The existing caller, signature and DTO are unchanged and no additional auth
requirement is introduced. Production `/booking` currently loads successfully
for an anonymous visitor and displays the complete booking form. The migration
only scopes the underlying rows and removes an unused service-role grant.

OLD APP + NEW DB: **PASS**.

## 16. Production data integrity

All relevant null, orphan, duplicate, parent/child mismatch and configuration
FK checks are zero/valid. No real production inconsistency would be silently
hidden by the target. No production data was changed.

## 17. SECURITY DEFINER inventory

Current production count: `69`. Target count: `69`. The wrapper remains
DEFINER and the new core is INVOKER. Unexpected target additions: `0`.
Unknown functions: `0`.

## 18. Compatibility defaults

Production confirms all approved compatibility defaults remain present:
`7/7`. The migration neither removes them nor treats them as authority.

## 19. Local evidence

- focused SQL: `26/26 PASS`, final ROLLBACK;
- full DB: `1402/1402 PASS`;
- Node: `750/750 PASS`;
- TypeScript: PASS;
- build: PASS;
- focused Booking Playwright: `1/1 PASS`;
- fixture cleanup: `0`;
- `git diff --check`: PASS.

The fresh destructive reset was not repeated because the environment safety
gate prohibited it. This is not a preflight blocker: the exact migration was
applied locally, focused and complete DB suites passed, and app/build/runtime
regressions passed.

## 20. Runtime baseline

Read-only HTTP smoke:

- `/booking`: `200`;
- `/login`: `200`;
- `/events`: `200`;
- `/admin`: `200` after the normal redirect/auth handling chain.

The real production Booking page completed its public RPC load and rendered
the booking form without a raw/configuration error. No 5xx was observed.

## 21. Migration history

Linked migration history is identical locally and remotely through
`20260923100000`. There are no remote-only rows. Exactly one local-only row is
present: `20260924100000`.

No migration repair was performed.

## 22. Dry-run

`supabase db push --linked --dry-run` completed successfully and reported
exactly:

`20260924100000_harden_public_booking_configuration.sql`

No production migration was applied.

## 23. Deployment risk

Risk: **LOW**.

The function is public and business-critical, but the rollout is a small,
transactional DB-only replacement with exact fingerprint gates, unchanged
signature/DTO, proven anon/auth compatibility, one active tenant, clean data
integrity and no service-role caller. A low-traffic deployment window is
sufficient; no maintenance window is required. Immediate post-deploy Booking
and ACL smoke remains mandatory.

## 24. Blockers

Blocking issues: **none**.

The informational Supabase CLI update notice is unrelated and does not block
deployment. This preflight grants no production-write authority.

## Production preflight verdicts

SAAS-9D-4E PRODUCTION PREFLIGHT: **PASS**

WORKING TREE SCOPE: **PASS**

SHA: **PASS**

EXACT FUNCTION SCOPE: **1**

PRODUCTION FINGERPRINT: **PASS**

PUBLIC CONTRACT: **PASS**

14-FIELD DTO: **UNCHANGED**

TENANT RESOLUTION: **PASS**

ACTIVE TENANT BASELINE: **PASS**

0/1/>1 ACTIVE TENANT: **PASS**

TENANT ISOLATION: **PASS**

MIXED HIERARCHY: **DENIED**

CROSS-TENANT ENUMERATION: **DENIED**

PII: **PASS**

ANON: **PASS**

AUTHENTICATED: **PASS**

SERVICE_ROLE CALLERS: **0**

SERVICE_ROLE WRAPPER: **DENIED IN TARGET**

CORE DIRECT EXECUTE: **DENIED**

APP CHANGE: **0**

OLD APP + NEW DB: **PASS**

SECURITY DEFINER COUNT: **69**

COMPATIBILITY DEFAULTS: **7/7**

DRY-RUN: **PASS**

READY FOR PRODUCTION PUSH: **YES**

READY FOR 9E: **NO-GO until 4E production PASS/checkpoint**

READY FOR 4D-2: **NO-GO until trusted 9E context**

READY FOR 9D-5: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

The preflight verdict above records the earlier read-only gate. The subsequent
production deployment and post-deploy verification are recorded in the
preceding section; its final production verdicts supersede the preflight-only
readiness statements. Current state: **4E PROD PASS**, checkpoint not yet
committed, **9E planning GO**, second tenant **NO-GO**, SEC-004 **OPEN**.
