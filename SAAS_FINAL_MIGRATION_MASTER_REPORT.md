# SAAS FINAL MIGRATION MASTER REPORT

Updated: 2026-09-23 (Europe/Warsaw)

## Current stage

**Stage F — SAAS-9H final security audit and SEC-004 closure review.** SAAS-9G local two-active-tenant E2E is PASS with 39/39 Playwright, 1608/1608 DB tests, current concurrency matrices PASS, zero cross-tenant effects, zero deadlocks and zero fixture residue. Second production tenant remains NO-GO until the 9H verdict.

## Completed stages

- SAAS-9A through SAAS-9E-B: closed according to the authoritative prior reports/checkpoints.
- SAAS-9E-C Phase 1: CLOSED / PROD PASS.
- SAAS-9E-C Phase 2: CLOSED / PROD PASS; checkpoint `634ca40c8684292681e83855b87f4a09a3fc3dce`.
- SAAS-9E-C Phase 3 DB: production migration `20260928100000_add_c3_owner_calendar_and_global_profile_contracts.sql`, SHA-256 `012A0472EA74CF17FD912C37B78A63B3BA68DF50144A46B35A0EAD5C2CAD6D0D`; history 107/107 and pending 0; rollback-only 16/16; fixture residue 0.
- SAAS-9E-C Phase 3 app: commit `b3a85bba9797f4ea056fbd41d6b3e990af59b2cc`, pushed to `origin/main` by fast-forward; authenticated production screen smoke PASS with stated ICS/mutating limitations.
- SAAS-9E-C Phase 3 final checkpoint: `9d8c893b401436a1ac2fb122eeeae179bd165f16`, pushed to `origin/main`; repository reproducible.
- SAAS-9D-4D-2: production migration `20260929100000_close_global_role_helper_execute.sql`, SHA-256 `4086E195BCE1F3A1CB0C107AC5231923BCBAED24132083990A3763BDC335D7AE`; deploy and post-deploy PASS.
- SAAS-9D-5: CLOSED / PROD PASS; final checkpoint `38f3a79454b6316e7588b871c3cc5f384bdf9589`, LOCAL=origin/main, divergence 0/0, bridges 0, defaults 0, SECURITY DEFINER 73.
- SAAS-9F: module audit and minimal cutover complete; production migration `20261002100000_add_my_active_tenants_reader.sql`, app commit `05cde069aaedac465a98b6d0f57e17e12296d2ad`, authoritative Vercel project `csk-booking-5nwh` PASS, runtime GET smoke PASS, operational residuals 0.
- SAAS-9G: local-only two-active-tenant E2E PASS; global selector A+B, public A/B, admin A/B denial, current concurrency matrices, full regression and cleanup all PASS.

## Current production state

- Application: SAAS-9F target commit `05cde069aaedac465a98b6d0f57e17e12296d2ad` live on `csk-booking-5nwh.vercel.app`.
- Database: SAAS-9F selector target live; SECURITY DEFINER 74; bridge definitions 0; compatibility defaults 0.
- Migration history: LOCAL = REMOTE through `20261002100000`; final dry-run reports remote database up to date.
- Runtime callers at deployed source: legacy operational 0; `get_my_role()` 0; direct `is_admin*` application helper callers 0.
- Legacy global-role helper ACL: PUBLIC/anon/authenticated/service_role EXECUTE denied on all four; bodies retained owner-only for 9D-5.
- Active production tenants: exactly one active CSK tenant. Second production tenant remains NO-GO.
- SEC-004 remains OPEN pending Stages B–F.

## Latest test counts

- Clean local replay through `20261002100000`: PASS.
- Focused 9F selector SQL: 8/8 PASS.
- Full DB: 55 files, 1608/1608 PASS.
- Node: 789/789 PASS.
- TypeScript: PASS.
- Production build: PASS (known middleware→proxy deprecation warning).
- Changed-file ESLint: PASS, 0 new errors/warnings.
- Playwright: 39/39 PASS, including the dedicated two-active-tenant local E2E.
- `npm audit --omit=dev`: one moderate `baseline-browser-mapping` DoS advisory; 0 HIGH, 0 CRITICAL.
- Local fixture cleanup: 0 test users/profiles/lanes/events; one active tenant; 95 definers.
- `npm audit --omit=dev`: not rerun during the A2 blocker correction because the environment did not authorize the registry metadata request; no dependency files changed.
- Production C3 rollback-only DB matrix: 16/16 PASS; persisted fixture 0.

## Security and compatibility counters

| Counter | Current |
|---|---:|
| SECURITY DEFINER | 74 production / 74 local 9F target |
| Unexpected C3 DEFINER drift | 0 |
| Bridge definitions | 0 |
| Compatibility defaults | 0 |
| Legacy operational app callers | 0 |
| `get_my_role()` app/API callers | 0 |
| Cross-tenant anomalies in C3 production integrity checks | 0 |
| Closed legacy global-role helper ACLs | 4/4 |
| Active RLS/routine/trigger dependencies on those helpers | 0/0/0 |

## Blockers and exclusions

- Second production tenant remains blocked until Stage G readiness verdict.
- SEC-004 remains OPEN.
- `AGENTS.md` is unrelated and always excluded. `supabase/drafts/*` is non-deployable and always excluded.
- Production owner ICS download was not exercised after app deployment because the authenticated account had no active reservation. No production mutating E2E or two-active-tenant UI test was performed.
- Legal/GDPR public-launch gate remains separate and incomplete until the final legal/tracker/consent review.

## Next stage

Complete SAAS-9H final tenant-isolation audit and decide SEC-004 closure and technical second-tenant readiness. Do not activate a second production tenant automatically.

## SAAS-9D-5A TENANT-AWARE ONBOARDING CUTOVER

### Legacy trigger problem

The pre-9D-5A model coupled global identity and tenant authority. Creating/updating a global profile could select the exact single active tenant and mirror `profiles.role` into `tenant_memberships`; the inverse membership trigger mirrored the tenant role back to the global profile. `prevent_non_admin_profile_privilege_changes()` also depended on the exact-single-tenant helper. This made the current one-tenant deployment an implicit authority source and blocked safe continuation of 9D-5.

### Chosen architecture and onboarding flow

- `auth.users` plus `profiles` creates a global account only; no tenant, membership, role or verification is inferred.
- Membership is created only when an authenticated user enters a validated tenant-scoped booking or event-registration write flow.
- The application validates the target resource and its tenant first, invokes self-onboarding second, and performs the business write third.
- The DB resolves an active tenant from the canonical server-validated slug. It never trusts a supplied `tenant_id`, `profiles.role`, an exact-single-active-tenant assumption or a hidden CSK fallback.
- Self-onboarding can create only the caller's own `role=user,status=active` membership. It is idempotent under the existing `(tenant_id,user_id)` key and preserves every existing membership, including privileged or non-active state.
- `/account` and `/dashboard` remain global and do not create membership.

### Migrations and contracts

1. `20260930100000_add_tenant_self_onboarding.sql` — SHA-256 `3B774502775B56DD0A76A33ED4DD213878B8926438D9297714E9D3620AFA3B58`.
   Adds `self_onboard_tenant_v1(text)` as an authenticated-only, fixed-search-path, owner-`postgres` contract. It validates the active tenant slug and authenticated user, inserts only an own user membership, returns a minimal relationship DTO and writes a tenant-bound PII-free audit record only for a new relationship. Local intermediate SECURITY DEFINER count: 97.
2. Application cutover — `create-reservation` and `register-event` call the server-only onboarding helper only after resource/tenant validation. No browser service-role use and no client tenant authority were introduced.
3. `20260930110000_retire_implicit_csk_onboarding.sql` — corrected forward-only SHA-256 `D30EF39EB5331A6CD7E4F60EA6B38E5206B3F86C315461B37B7300779F299B4E`.
   Preserves the canonical auth-signup profile trigger, positively verifies its exact trigger metadata and global-profile-only function semantics, conditionally creates it only for canonical clean replays where the public-schema baseline could not contain an `auth.users` trigger, retires both role-sync triggers/functions, and rewrites the profile privilege guard without exact-single-tenant or global-role authority. The existing identity/contact writers pass an explicit validated tenant context for their narrow protected-field workflow. Local final SECURITY DEFINER count: 95.

### Retired and retained state

- `sync_profile_role_to_csk_membership`: removed locally.
- `sync_csk_membership_role_to_profile`: removed locally.
- `profiles.role`: retained physically as **LEGACY / NON-AUTHORITATIVE / SYSTEM-ONLY** and frozen against operational owner mutation.
- Profile privilege guard exact-single dependency: removed locally.
- Exact-single helper runtime/dependency inventory after the cutover: 0 local dependencies.
- Existing staff membership/role/status management and last-admin protections remain authoritative and unchanged in scope.
- Compatibility defaults remain 7/7 until normal 9D-5; 9D-5A does not remove them.

### Local verification

- Clean migration replay against `127.0.0.1:54322`: PASS.
- Focused onboarding matrix: 24/24 PASS, including no signup membership, user-only self-onboarding, idempotency, inactive/invalid/anonymous denial, two-tenant isolation, existing membership preservation, role-escalation denial, frozen profile role and trigger retirement.
- Full Supabase DB suite: 53 files, 1579/1579 PASS.
- Node: 782/782 PASS; TypeScript: PASS; production build: PASS.
- Changed-file ESLint: PASS; Playwright: 38/38 PASS.
- Local fixture cleanup: users 0, profiles 0, lanes 0, events 0; active tenants 1.
- Trigger inventory: legacy sync triggers 0. Exact-single dependencies: 0. Final local SECURITY DEFINER count: 95.
- `git diff --check`: PASS (Windows line-ending notices only).

### A2 auth-profile trigger blocker review

Production contains exactly one enabled non-internal trigger on `auth.users`:

`CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION handle_new_user()`

`public.handle_new_user()` has an empty signature, owner `postgres`, `SECURITY DEFINER`, fixed `search_path=public, pg_temp`, and no direct EXECUTE for PUBLIC, anon, authenticated or service_role. Its production normalized `pg_get_functiondef` fingerprint is `10a0141f56f2baf69aa3e767d58338c0`; its normalized-EOL `prosrc` fingerprint is `9765e3a659e1e3f6395848dd52f74fb6`; and the cross-environment semantic whitespace-normalized body fingerprint is `1de0460e8b4298219dd8be7d953bb0f5`. Clean local replay produces the same semantic fingerprint (the raw definition differs only because the baseline dump formats the function body differently).

The function reads identity/contact metadata from the new auth user and inserts/upserts only `public.profiles`, initializing the legacy global defaults `role='user'` and `verification_status='pending'`. It does not read or write `tenant_memberships`, resolve CSK or an exact-single-active tenant, assign tenant role/status/verification/admin-note state, invoke onboarding, invoke a role-sync helper, or call a bridge RPC.

- AUTH PROFILE TRIGGER PURPOSE: **GLOBAL PROFILE ONLY**
- IMPLICIT MEMBERSHIP CREATION: **NO**
- IMPLICIT CSK: **NO**
- LEGACY ROLE MIRROR: **NO**

Root cause classification: **A (stale) + B (incorrect) + D (canonical migration boundary)**. The remote public-schema baseline contains `handle_new_user()` but cannot faithfully carry an `auth.users` trigger. The later trigger-preservation migration explicitly accepted zero or one canonical trigger. A2 incorrectly converted that dump limitation into a zero-trigger production invariant; production was not unsafe and showed no semantic drift.

The forward-only correction therefore does not edit historical migrations and does not drop/recreate a correct production trigger. It verifies the function metadata, ACL, semantic fingerprint and forbidden tenant side effects; accepts exactly one matching canonical trigger; creates that trigger only when clean replay has zero; and fails closed on missing function, alternate target, extra trigger, unexpected WHEN clause, fingerprint drift or tenant behavior. The focused test still contains 24 semantic assertions. Legacy SQL fixtures were updated only to tolerate the now-canonical profile auto-creation, and local Playwright fixture writes were moved to the existing local-postgres setup so the production profile guard remains unchanged.

### Compatibility and production state

| Combination | Status |
|---|---|
| Current app + current DB | Existing production baseline; PASS |
| Current app + onboarding-capability DB | Compatible; new RPC is additive and old implicit onboarding remains until retirement migration |
| New app + onboarding-capability DB | Target transition state; explicit onboarding available while legacy behavior remains compatible |
| New app + final 9D-5A DB | Local PASS; legacy sync and exact-single profile-guard dependency removed |
| Current app + final 9D-5A DB | Not an approved rollback target because old callers can still assume implicit membership |

Production staged state:

- `20260930100000_add_tenant_self_onboarding.sql`: **PROD PASS**; migration history LOCAL=REMOTE for A1, normalized RPC fingerprint `2b3e722279bfe2372cbe951e16f8d315`, ACL/owner/search_path PASS, SECURITY DEFINER 97, sync triggers still 2, defaults 7/7.
- Application checkpoint `dd02b3138a591966697d89cce7d72c2a3b3b054d`: pushed fast-forward and deployed successfully to the authoritative `csk-booking-5nwh` Vercel project. Public runtime smoke: 12/12 routes without 5xx; the write endpoint rejects an unsupported method with 405 and `private, no-store`.
- A second legacy/parallel Vercel project named `csk-booking` failed its duplicate deployment, while the authoritative `csk-booking-5nwh` deployment succeeded. No production alias failure was observed.
- `20260930110000_retire_implicit_csk_onboarding.sql`: **NOT DEPLOYED**. The migration transaction aborted at its first preflight block; migration history still shows it as the sole pending migration and dry-run still lists exactly A2.
- Drift evidence: production trigger `on_auth_user_created` is enabled on `auth.users` and executes `public.handle_new_user()`; normalized function fingerprint `10a0141f56f2baf69aa3e767d58338c0`. The pending migration expected zero such triggers. Existing frozen guard fingerprint remains `8a3cb4dc2d663cbf3c866fc3d9c8dac7`, SECURITY DEFINER remains 97, and both legacy sync triggers remain enabled. Therefore no partial A2 change persisted.

The required order DB capability → application → retirement DB migration completed successfully. The corrected A2 production preflight verified project `yuyxfodozzpzrdzkmolu`, final SHA-256 `D30EF39EB5331A6CD7E4F60EA6B38E5206B3F86C315461B37B7300779F299B4E`, LOCAL=REMOTE through A1, A2 as the sole pending migration, canonical trigger/function semantics, legacy sync baseline 2/2, SECURITY DEFINER 97, compatibility defaults 7/7, one active tenant and zero checked integrity anomalies. The dry-run listed exactly A2.

Production deployment and post-deploy verification:

- `20260930110000_retire_implicit_csk_onboarding.sql`: **PROD PASS**.
- Migration history: LOCAL=REMOTE through A2; pending 0; final dry-run: remote database is up to date.
- Canonical `auth.users.on_auth_user_created -> public.handle_new_user()`: present exactly once, enabled, AFTER INSERT/FOR EACH ROW/no WHEN; semantic fingerprint remains `1de0460e8b4298219dd8be7d953bb0f5`.
- Legacy sync triggers/functions: 0/0.
- Profile guard forbidden bridge references (`active_single_tenant_id_v1`, `profile_role_rpc`): 0. Tenant-membership checks retained inside explicitly tenant-bound identity/contact workflows are operational-relationship validation, not global role mirroring.
- SECURITY DEFINER: 95; compatibility defaults: 7/7; active tenants: 1; checked membership/reservation/event integrity anomalies: 0.
- Production rollback-only A2 matrix: 24/24 PASS. It covered canonical profile-only signup, no implicit membership, explicit onboarding, idempotency, inactive/invalid/anonymous denial, two-tenant independence, role escalation denial, no role mirroring, controlled profile updates, defaults and inventory. Final `ROLLBACK` executed.
- Persistent fixture residue after rollback: tenants 0, auth users 0, profiles 0, memberships 0, audits 0; active tenants restored to exactly 1.
- Runtime HTTP smoke: `/`, `/booking`, `/events`, `/login`, `/account`, `/admin`, `/admin/reservations`, `/admin/calendar`, `/admin/reports`, `/admin/check-in` all returned 200; no 5xx.

### Final residual inventory

- Obsolete bridge/default retirement remains normal SAAS-9D-5 work after 9D-5A production PASS.
- Compatibility defaults: 7/7 retained.
- Second production tenant: NO-GO.
- SEC-004: OPEN until SAAS-9H.
- `AGENTS.md`, `supabase/drafts/*` and the pre-existing C3-only plan diff remain unrelated/excluded.

## SAAS-9D-5 NORMAL COMPATIBILITY RETIREMENT — LOCAL BLOCKER REVIEW

The post-A2 read-only inventory confirms **22 exact-single bridge definitions**
(the resolver plus 21 function bodies that call it), **zero active app/API
callers**, **zero policy dependencies** and **zero trigger dependencies**.
Three closed internal chains remain entirely inside that retirement set:
event create wrapper/core, event list wrapper/core and lane-configuration v2/v1.
The catalog also contains three owner-only, zero-caller legacy event writers
(`admin_create_event`, `admin_update_event`, `admin_set_event_active`) already
closed by ACL in 9D-2. The only repository references outside SQL regression
tests are two local harnesses: the load test and the old optional branch of the
4B-1B concurrency script.

All active production insert paths for the seven tenant-owned tables either
supply `tenant_id` explicitly or derive it from a trusted resource (the email
delivery trigger). The only insert paths still relying on the fixed CSK default
are functions inside the proposed retirement set. All seven columns are `NOT
NULL`; local clean replay found zero null tenant rows. A forward-only candidate
`20261001100000_retire_single_tenant_compatibility.sql` therefore removes the
22 bridge definitions, the three closed legacy event writers and all seven
defaults. Its fail-closed fingerprints matched the clean chain, replay passed,
and its focused test passed **21/21**. Expected SECURITY DEFINER is **95 -> 73**.

The full DB gate then stopped before any production preflight or write. The
historical regression architecture has two wider dependencies which were not
represented in the initial 9D-5 object inventory:

- 36 historical SQL files contain direct fixture inserts into tables that used
  the CSK default; the first full run failed those fixtures after default
  removal unless their setup is made explicitly tenant-bound;
- 30 historical SQL files still assert or execute one or more retired bridge
  contracts. Replacing them is not a count/fingerprint-only change because
  many old signatures lack a tenant argument and their current replacements
  enforce membership/resource-bound authorization.

The focused migration evidence is PASS, but the full suite is FAIL and no
production preflight/deploy is permitted. Silencing or bulk-skipping those
assertions would violate the semantic-regression rule. A reviewed historical
test-retirement/cutover strategy is required before continuing implementation.

- SAAS-9D-5 LOCAL: **BLOCKED — FULL DB SEMANTIC TEST CUTOVER REQUIRED**
- production write: **0**
- bridge/default production state: **22 / 7**
- second tenant: **NO-GO**
- SEC-004: **OPEN**

## SAAS-9F / 9G / 9H FINAL CUTOVER

### SAAS-9F

The final module audit found and closed a minimal operational scope: a
membership-backed global tenant selector, slug-preserving navigation, and
tenant-required owner cancellation paths. Production migration
`20261002100000_add_my_active_tenants_reader.sql` and application commit
`05cde069aaedac465a98b6d0f57e17e12296d2ad` passed production verification.
Final checkpoint `ace379f0bb79a5027566e95d26493e605826381b` is on `origin/main`.

SAAS-9F: **CLOSED / PROD PASS**

### SAAS-9G

Two active tenants were exercised locally across the selector, public booking
and events, owner contracts, staff/admin routes, reporting, user/PII flows,
verification, notes, check-in, email/promotion and concurrency matrices.
Cross-tenant effects, PII leaks and deadlocks were all zero. Final checkpoint
`7662c0032168aed855e7dd3f55b2483e14b98e34` is on `origin/main`.

SAAS-9G: **CLOSED / LOCAL PASS**

### SAAS-9H local final audit

The final audit found no remaining operational bridge, compatibility default,
implicit CSK authority, global role authority, caller-controlled tenant
authority or cross-tenant PII path. The only technical readiness blocker was
the rollout-only `tenants_single_active_runtime_guard`. Forward migration
`20261003100000_remove_single_active_tenant_guard.sql` removes only that guard
under fail-closed catalog/data preconditions and does not activate a second
production tenant.

- focused 9H: **10/10 PASS**
- full DB: **1618/1618 PASS**
- Node: **789/789 PASS**
- Playwright: **39/39 PASS**
- SECURITY DEFINER: **74**
- bridge definitions: **0**
- compatibility defaults: **0**
- local active tenants after cleanup: **1**
- local single-active guard: **absent**
- new CRITICAL/HIGH: **0 / 0**

Production preflight confirmed LOCAL=REMOTE through `20261002100000`, exactly
one pending migration and an exact-one dry-run. Migration
`20261003100000_remove_single_active_tenant_guard.sql` (deployment-input
SHA-256 `BCCB00461D8379E15862F150013ED1947EBE6BCEA1B30C92F9D08B1B6D27F0C2`;
canonical checkpoint SHA-256 after terminal-blank normalization
`D145E3F19920DF07E9487EE45E251D8EC9CFDAFC854B51BCAF0AA2376A2911D9`)
was deployed successfully. Post-deploy history is LOCAL=REMOTE through
`20261003100000`; the final dry-run reports `Remote database is up to date`.
The migration changed no business row, function, ACL, RLS policy or application
code, and its postcondition retained exactly one active production tenant and
SECURITY DEFINER count 74.

Authoritative Vercel smoke returned 200 for public/owner entry routes and
controlled 307 for unauthenticated admin routes, with no 5xx.

SAAS-9H: **CLOSED / PROD PASS**

SEC-004: **CLOSED**

SECOND TENANT READINESS: **READY**

TECHNICAL SAAS READINESS: **YES**

SECOND PRODUCTION TENANT: **NOT CREATED / NOT ACTIVATED**

LEGAL/GDPR PUBLIC-LAUNCH GATE: **INCOMPLETE**

## SAAS-9D-5T SEMANTIC TEST CUTOVER — FINAL LOCAL EVIDENCE

The historical suite has been moved to the explicit tenant architecture without
reintroducing a CSK default, exact-single-tenant resolver, global
`profiles.role` authority, or compatibility RPC. The applied A2 migration
`20260930110000_retire_implicit_csk_onboarding.sql` remains byte-for-byte
unchanged (filesystem/deployed SHA-256
`D30EF8779A7B1F0FD09B30E60DB2758E40564FA94E74D5C611AD2ACF299B4F299`).
All normal 9D-5 schema work is isolated in the new forward-only migration
`20261001100000_retire_single_tenant_compatibility.sql`.

### Authoritative failure classification

The initial replay had 66 failing historical cases. No case was classified as
UNKNOWN or as a product regression. The fixture ledger below accounts for all
36 implicit-CSK failures; each was rewritten to declare the tenant,
membership, or trusted resource relationship used by the behavior under test.

| IDs | Test file(s) | Test case / old assumption | New invariant | Action | Replacement coverage | Security impact |
|---|---|---|---|---|---|---|
| F01-F03 | `20260816100000`, `20260816130000`, `20260816143000` | fixture rows inherited CSK and ACL inventory included compatibility objects | explicit CSK fixture only where the scenario is CSK-specific; exact final ACL inventory | A / B | family creation, reserve confirmation, 128-function ACL matrix | stronger; no implicit authority |
| F04-F07 | `20260902120000`, `20260902160000`, `20260903100000`, `20260903160000` | ACL/check-in/audit/event DML fixtures omitted tenant ownership | fixture tenant and membership are explicit | A | ACL, token privacy, 19 trusted audit writers, direct-DML denial | preserved |
| F08-F11 | `20260904120000`, `20260904180000`, `20260904200000`, `20260905100000` | account/email/reservation/profile fixtures depended on defaults or legacy verification | resource-bound tenant plus tenant verification source of truth | A / B | lifecycle, idempotency, delete denial, re-verification | stronger |
| F12-F15 | `20260905120000`, `20260905150000`, `20260905170000`, `20260905190000` | availability/report/event-list fixture ownership was implicit | explicit tenant selectors and tenant-owned rows | A / B | public counts, reports, filters/export, scalable readers | preserved |
| F16-F19 | `20260907100000`, `20260909110000`, `20260909130000`, `20260910110000` | foundation/backfill fixtures assumed compatibility defaults | explicit ownership/backfill end state | A / B | foundation, ownership, FK integrity, membership auth | preserved |
| F20-F23 | `20260910115000`, `20260910120000`, `20260911100000`, `20260911120000` | RLS fixtures and phased inventories referenced bridge-era boundaries | explicit tenant A/B fixtures and final boundaries | A / B | cross-tenant RLS, recursion, profile/lane isolation | stronger |
| F24-F27 | `20260912100000`, `20260913100000`, `20260913150000`, `20260914100000` | event/email RPC fixtures selected the sole active tenant | explicit event/resource tenant; inactive selector fails closed | A / B | event ownership, public PII-free DTO, email claims | stronger |
| F28-F31 | `20260914150000`, `20260915100000`, `20260916100000`, `20260917100000` | promotion/lane fixtures inherited CSK | explicit tenant and hierarchy binding | A | promotion replay, lane/block/family isolation and concurrency | preserved |
| F32-F34 | `20260918100000`, `20260919100000`, `20260919150000` | reports/admin-user helpers injected CSK internally | helper receives explicit tenant; A/B state tested independently | A / B | report isolation, notes, role/identity/contact isolation | stronger |
| F35-F36 | `20260920100000`, `20260920150000` | verification fixtures used implicit foundation rows/legacy argument shape | explicit foundation state and tenant selector | A / B | verification ownership, source of truth, negative membership states | stronger |

The RPC ledger accounts for all 30 compatibility-call/assertion failures.
`A`/`B` below correspond to REWRITE FIXTURE / REWRITE ASSERTION; `C` means the
behavior was moved to the current contract plus explicit retirement coverage.
No test was silently deleted.

| IDs | Test file / contract family | Old assumption | New invariant | Action | Replacement coverage | Security impact |
|---|---|---|---|---|---|---|
| R01-R04 | `20260816100000`, `20260816143000` — lane family V1/admin config inventory | V1 creator/readers remain callable | V2/V3 explicit tenant contracts; retired signatures absent | C | focused 9D-5 assertions plus Playwright scenarios 1-5 | preserved |
| R05-R08 | `20260905120000`, `20260905190000` — public/admin event readers | bridge selects CSK | V3/V2 explicit tenant; stable bounded DTO | B / C | availability/list pagination and PII checks | stronger |
| R09-R12 | `20260911100000`, `20260912100000` — event management/registration | legacy writer inventory is authoritative | current V3/V2 writers and closed retained compatibility surface | B / C | tenant A/B IDOR, role and ownership matrix | preserved |
| R13-R16 | `20260913100000`, `20260913150000` — event writer/public wrappers | exact-single behavior yields empty result | selected active tenant is authoritative; inactive is controlled not-found/deny | B / C | two-active explicit-isolation transaction | stronger |
| R17-R20 | `20260915100000`, `20260916100000`, `20260917100000` — lane block/family chains | bridge-era cores/helpers remain current | current entry points plus closed invoker cores; obsolete chains absent | B / C | hierarchy, membership state, concurrency | preserved |
| R21-R24 | `20260918100000`, `20260919100000`, `20260919150000` — reports/admin users | helpers/callers omit tenant | exact tenant argument and operational relationship | A / C | cross-tenant report/PII/note/role isolation | stronger |
| R25-R27 | `20260920150000`, `20260921100000`, `20260924100000` — verification/public booking | legacy arg names/fallback and exact-single public selection | tenant verification only; explicit active public selector | B / C | fallback absence, inactive fail-closed, A/B isolation | stronger |
| R28-R30 | `20260926100000`, `20260928100000`, `current_remote_baseline_contracts_test.sql` | 95 definers, 21 bridge references, seven defaults and V2 event writers | actual final inventory 73/0/0 and current V3 writers | B / C | exact inventory and final remote-baseline contract | preserved |

Allowed-action accounting: A (fixture rewrite) 36; B/C (assertion or current
contract replacement) 30; D (silent obsolete-test deletion) 0; E (real product
regression) 0; UNKNOWN 0. Unique coverage remains for authentication,
tenant isolation, role and membership status, last-admin, PII, event and
reservation ownership, lane hierarchy, onboarding, and account/profile
protection.

### Retirement and dependency accounting

- 22 bridge definitions: production dependency 0, application/API caller 0,
  trigger dependency 0, policy dependency 0; target state absent. Historical
  test references were rewritten to current tenant-scoped contracts.
- Seven `tenant_id` defaults (`shooting_lanes`, `reservations`, `lane_blocks`,
  `events`, `event_lanes`, `event_registrations`, `email_deliveries`): active
  writers explicitly provide or derive tenant ownership; target state no
  default.
- Two closed legacy event writers covered by the frozen retirement inventory:
  runtime callers 0 and client ACL 0; they are retired, while current V3 writer
  behavior remains covered.
- Final local inventory: bridge definitions 0; compatibility defaults 0;
  SECURITY DEFINER 73; unexpected definer 0; implicit CSK authority 0;
  exact-single tenant authority 0; `profiles.role` tenant authority 0.

### Validation after cutover

- Clean replay: PASS, canonical chain through `20261001100000`, ghost
  migrations 0, unexpected filesystem-only migrations 0.
- Focused 9D-5: 21/21 PASS.
- Full DB: 54 files, 1600/1600 PASS; ignored/xfail/blanket skip 0.
- Node: 782/782 PASS. TypeScript: PASS. Production build: PASS.
- Playwright: 38/38 PASS after replacing the final V1 lane-family test caller
  with V2 plus explicit tenant.
- Concurrency: last-admin and profile races PASS; deadlocks 0, contamination 0,
  lost updates 0; cleanup 0.
- ESLint: existing baseline 6 errors / 5 warnings; no new error in the 9D-5
  application/test scope.
- `npm audit --omit=dev`: one existing moderate
  `baseline-browser-mapping` advisory; not introduced by 9D-5.

### Before / after accounting

- HISTORICAL FAILURES BEFORE: **66**
- FIXTURE TESTS REWRITTEN: **36**
- RPC TESTS REPLACED: **30**
- OBSOLETE TESTS RETIRED: **0** (obsolete behavior replaced, not silently removed)
- NEW RETIREMENT TESTS: **21 assertions**
- NEW TENANT-AWARE TESTS: **66 rewritten cases plus current two-tenant suites**
- REAL PRODUCT REGRESSIONS: **0**
- FULL DB AFTER: **1600/1600 PASS**
- SECURITY COVERAGE LOST: **0**
- APPLIED MIGRATION DRIFT: **0**
- SEMANTIC TEST CUTOVER: **PASS**
- READY FOR NORMAL SAAS-9D-5 PRODUCTION PREFLIGHT: **YES**

## SAAS-9D-5 NORMAL COMPATIBILITY RETIREMENT — PRODUCTION CLOSEOUT

Production preflight and deployment were completed on 23 September 2026
against linked project `yuyxfodozzpzrdzkmolu`. The frozen forward-only
migration was `20261001100000_retire_single_tenant_compatibility.sql`, SHA-256
`878F1F65603FDF82926F4BFCAF5224486FC57BD9B6E066079276BEE5229DAE4C`.

### Final production preflight

- Migration history was LOCAL=REMOTE through `20260930110000`; the only
  local-only migration was `20261001100000`.
- `supabase db push --linked --dry-run` listed exactly the 9D-5 migration.
- Fresh production catalog/data evidence: active tenants 1, SECURITY DEFINER
  95, bridge definitions 22, compatibility defaults 7/7, target objects 25/25,
  null tenant ownership rows 0 and checked tenant/resource integrity anomalies
  0.
- Trigger dependencies 0, policy dependencies 0, external catalog function
  dependencies 0 and active application/API callers 0.
- The production schema dump independently matched the exact 22-object bridge
  inventory. The migration's normalized fingerprints and transactional
  fail-closed preflight matched all 25 retirement targets before any DDL ran.

### Deployment and post-deploy verification

- Production deployment: **PASS**. Supabase applied only
  `20261001100000_retire_single_tenant_compatibility.sql`.
- Migration history after deployment: LOCAL=REMOTE through `20261001100000`.
  Final dry-run: **Remote database is up to date**.
- Rollback-only focused production matrix: **21/21 PASS**. Final `ROLLBACK`
  executed; the transaction-created result table was absent afterward.
- Final catalog state: bridge definitions 0, compatibility defaults 0,
  retired target objects remaining 0, SECURITY DEFINER 73, unexpected drift 0.
- Tenant ownership columns remain NOT NULL; null tenant rows 0; one active
  tenant remains. Replacement tenant-scoped event, lane-family, reporting,
  admin-user, verification, booking and account contracts remain present.
- Runtime HTTP smoke returned 200 for `/`, `/booking`, `/events`, `/login`,
  `/account`, `/admin`, `/admin/calendar`, `/admin/reports`,
  `/admin/reservations`, `/admin/events` and `/admin/check-in`.
- Authenticated browser smoke loaded the admin dashboard, users, check-in,
  reports and calendar with live data, plus account, booking and events, with
  no 5xx or removed-RPC runtime regression.
- Fixture cleanup: **0 persisted production fixtures**. The production test
  created no business fixture and all temporary test objects were rolled back.

### Final 9D-5 verdict

- SEMANTIC TEST CUTOVER: **PASS**
- HISTORICAL TESTS DEPENDING ON IMPLICIT CSK: **0**
- HISTORICAL TESTS REQUIRING RETIRED RPC: **0**
- SECURITY COVERAGE LOST: **0**
- FULL DB: **1600/1600 PASS**
- APPLIED MIGRATION DRIFT: **0**
- SAAS-9D-5 PRODUCTION DEPLOY: **PASS**
- SAAS-9D-5 POST-DEPLOY: **PASS**
- BRIDGE DEFINITIONS: **0**
- COMPATIBILITY DEFAULTS: **0**
- SECURITY DEFINER COUNT: **73**
- FIXTURE CLEANUP: **PASS**
- RUNTIME SMOKE: **PASS**
- SECOND TENANT: **NO-GO**
- SEC-004: **OPEN**
