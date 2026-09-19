# SAAS-9E-A — trusted tenant-context foundation

Date: 2026-09-19. Initial local baseline: `main` at `a6324cda94dbdf14ddf850240e0dfe59d9ca96f5`. The local, DB production and app foundation production phases are recorded separately below. `AGENTS.md` is unrelated and excluded.

## Exact scope

| Object | Before | 9E-A target | Consumers / phase |
|---|---|---|---|
| `public.tenants` | closed RLS/ACL, one active CSK, second-active guard | unchanged | resolver reads as postgres owner; no direct client access |
| `resolve_active_tenant_by_slug_v1(text)` | absent | additive `STABLE SECURITY DEFINER`, fixed search path, owner `postgres`, EXECUTE only anon/authenticated; exactly `tenant_id`, `tenant_slug`, `tenant_name`, `tenant_status` | public/auth tenant selector; no PII, no membership grant |
| `lib/server/tenant-context.ts` | absent | canonical path parser and request-scoped public, authenticated, staff and persisted-resource checks | foundation only; no production route caller yet |
| Existing routes, middleware, API, RPC, RLS, triggers, writers | legacy CSK single-active model | unchanged | canonical `/t/[slug]` routing is 9E-B; bounded caller cutover is 9E-C |
| Seven CSK column defaults | compatibility bridge | unchanged, 7/7 | removal is later 9D-5 gate |

Changed files: the new migration and SQL test; server helper and Node test; this report; 9E final plan section; and 18 existing DB test files whose exact function inventory/SECURITY DEFINER baseline now includes the approved resolver. The SEC-002 matrix explicitly adds its signature and exact anon/authenticated ACL; the SAAS-9B-1 helper allowlist adds only this named read-only resolver. All remaining historical test edits are the isolated approved count change 69→70 (including post-rollback assertions). No historical migration, existing app route, business RPC or data table is edited.

## Trust model and contexts

The canonical lowercase slug comes only from a `/t/[slug]` path segment. It is validated to `[a-z0-9]+(-[a-z0-9]+)*`, length 2–63, then resolved by the DB against `status='active'`. Unknown, inactive, malformed or noncanonical slugs return no context, with no arbitrary CSK fallback. The resolver exposes only ID, slug, public name and active status. Neither slug nor the returned ID is an authorization capability.

The server helper accepts a request-scoped anon-key Supabase client, not service role. Ordinary authenticated context verifies `auth.getUser()` and does not infer staff membership or a customer relationship merely from the route. Privileged context additionally calls the existing `get_my_tenant_role_v1(resolved_tenant_id)` and restricts to explicit `admin`/`employee`/`instructor` allowlists; `profiles.role`, pending/suspended/no membership, or a tenant-B path with only tenant-A membership cannot grant access. `resourceBelongsToTenant` compares a separately loaded persisted resource tenant with the resolved route tenant; the resource's tenant is never rewritten to fit the route. The DB resource and membership checks must still occur in every future 9E-C operation.

No cookie, localStorage, query string, client boolean or service-role proxy is authority. No context persistence or caching is introduced. Two browser tabs with different paths resolve independently; stale preference cannot override path/resource checks. There is no tenant-owned mutation in 9E-A, so audit writer behavior and account-wide export/anonymization/Auth deletion remain unchanged.

## Backward compatibility and phase boundaries

No old URL changes or redirects are made in 9E-A; current CSK pages retain their existing single-active RPC contracts. No `/t/[slug]` page is served yet. The bridge inventory remains **22 function bodies referring directly to `active_single_tenant_id_v1()` plus the helper itself**; none is mass-edited. New resolver is additive. Measured local public SECURITY DEFINER count: 69 + 1 = **70**, with 0 unexpected definition changes in the full SQL contract suite; seven CSK defaults remain.

Rollout matrix:

| State | Result |
|---|---|
| OLD APP + OLD DB | existing CSK baseline |
| OLD APP + NEW DB | compatible; unused additive resolver |
| NEW 9E-A helper + OLD DB | not a usable selected-tenant context; DB-first rollout required |
| NEW 9E-A helper + NEW DB | foundation available; existing routes still unchanged |

9E-A is **APP + DB**. 9E-B is planned **APP** canonical routing without authority cutover. 9E-C will require **APP + DB**, DB-first per bounded domain. The exact 9E-C function inventory is a separate review gate. `get_my_role`, `is_admin`, `is_admin_or_employee` and `is_admin_or_staff` remain active/closed according to their existing 4D-2 inventory; 9E-A does not replace their application callers or prove zero-call. **4D-2 remains NO-GO.** 9D-5 and second tenant activation remain NO-GO; SEC-004 remains OPEN.

## Verification

| Check | Result |
|---|---|
| Focused tenant-context Node | 10/10 PASS (including A/B, invalid/inactive, user/staff, role negatives, resource mismatch, multi-tab, PII DTO) |
| Full Node | 760/760 PASS after final role and status assertions |
| TypeScript | PASS |
| Production build | PASS; existing Next middleware-deprecation warning |
| Changed-file ESLint | PASS |
| Relevant Playwright | 9/9 PASS (public booking contract and Events UI) |
| `npm audit --omit=dev` | 1 moderate `baseline-browser-mapping` advisory; dependency remediation outside 9E-A |
| Local reset / migrations | PASS: explicit `--local`, target `127.0.0.1:54322`; full migration chain through `20260925100000` applied; no linked/remote command |
| Focused 9E-A SQL | 25/25 PASS, transaction ROLLBACK plus postcheck |
| Full DB suite | 45 files, 1427/1427 PASS. Historical exact-inventory tests updated for precisely one additive approved resolver. |
| Synthetic DB fixture cleanup | 0 Tenant B, lane, auth user, profile, membership and 9E-A audit fixtures; exactly one active CSK; read-only postcheck against the local container |
| `git diff --check` | PASS (CRLF conversion warnings only, no whitespace errors) |

The SQL test passed 25 checks (24 in-transaction and one rollback cleanup), including closed table ACL, exact resolver DTO/ACL, active/dormant slug behavior, 70 definers, 7 defaults, staff membership states and persisted resource comparison. The first attempt exposed an incomplete synthetic fixture assumption (Auth insert alone had not created a profile/membership); the fixture was aligned with existing project tests by inserting the profile if absent and setting its legacy role through the existing sync trigger. No application/migration behavior was changed for this test correction. The full suite initially failed historical exact-count assertions (69 versus the planned 70); after explicitly incorporating the one new resolver, all 1427 checks passed. This is local evidence, not a production preflight or production second-tenant test.

## Residual and verdict

No current route calls the new helper or resolver. Thus the passing local tests do **not** establish production tenant-aware routing or resource authorization; that is precisely 9E-B/C. No 4D-2 caller has cut over. The unrelated `npm audit` moderate advisory and deprecated Next middleware convention are not changed in this phase.

SAAS-9E-A LOCAL: **PASS**
FOCUSED SQL: **PASS — 25/25**
FULL DB: **PASS — 1427/1427 across 45 files**
EXACT 9E-A SCOPE: **PASS**
TRUSTED TENANT CONTEXT: **PASS at foundation/local level; no route cutover yet**
SERVER-SIDE SLUG VALIDATION: **PASS**
CLIENT TENANT AUTHORITY: **ABSENT in 9E-A foundation**
PUBLIC TENANT CONTEXT: **PASS**
AUTH USER TENANT CONTEXT: **PASS at helper/unit level**
STAFF MEMBERSHIP CONTEXT: **PASS**
RESOURCE-BOUND TENANT CHECK: **PASS at helper/unit level; future RPC enforcement pending 9E-C**
ROUTE/RESOURCE MISMATCH: **DENIED by foundation helper; no route yet**
GLOBAL ROLE AUTHORITY: **ABSENT from new foundation**
CROSS-TENANT ISOLATION: **PASS for local foundation resolver/helper, not all future callers**
CROSS-TENANT PII: **PASS for exact four-field DTO/SQL test**
BACKWARD COMPATIBILITY: **PASS in Node/build/Playwright/full DB**
EXACT-SINGLE-ACTIVE BRIDGE RESIDUALS: **22 bodies + 1 helper**
4D-2 UNBLOCKED: **NO**
APP CHANGE: **YES**
DB CHANGE: **YES**
SECURITY DEFINER COUNT AFTER 9E-A: **70 measured locally**
COMPATIBILITY DEFAULTS: **7/7**
READY FOR 9E-A PRODUCTION PREFLIGHT: **GO (separate authorization and read-only gate)**
READY FOR 9E-B: **NO-GO until review**
READY FOR 4D-2: **NO-GO**
READY FOR 9D-5: **NO-GO**
READY FOR PRODUCTION WRITE: **NO**
SECOND TENANT: **NO-GO**
SEC-004: **OPEN**

## DB production deployment and post-deploy verification

Production project: `yuyxfodozzpzrdzkmolu`. Before the push, the migration file SHA-256 was again `2188D4B332CD1A08598D93BBCEA36FEE959DF25A7A3B171D3AF6BB73CE79ED84`, matching the authoritative preflight report. Linked migration history was paired through `20260924100000`, with no remote-only or mismatched versions and only `20260925100000` pending. Final dry-run listed exactly `20260925100000_add_public_active_tenant_resolver.sql`. Production read-only checks again showed one tenant, the single active CSK, the second-active guard, 69 existing SECURITY DEFINER functions, 7/7 CSK compatibility defaults, 22 bridge references, no membership orphans or tenant-null core rows, and no cross-tenant relationship mismatch. `AGENTS.md` remained unrelated, excluded and unstaged.

The approved `npx supabase db push --linked` applied **only** `20260925100000_add_public_active_tenant_resolver.sql` and exited successfully. Subsequent linked migration history has LOCAL=REMOTE through `20260925100000`, zero pending, zero remote-only and zero mismatches. The final `db push --linked --dry-run` reports **Remote database is up to date**. No application deployment, other SQL write, migration repair or Git write was performed.

### Resolver and security verification

Production `resolve_active_tenant_by_slug_v1(text)` has argument `p_slug text` and return type `TABLE(tenant_id uuid, tenant_slug text, tenant_name text, tenant_status text)`. It is `STABLE SECURITY DEFINER`, owned by `postgres`, with `search_path=pg_catalog, public, pg_temp`. Direct EXECUTE: PUBLIC **DENY**, anon **ALLOW**, authenticated **ALLOW**, service_role **DENY**. Its raw and CRLF-normalized `pg_get_functiondef` MD5 is `8c32a2ba9ae0b86a73593c2580d0ff9f`, equal to the normalized hash measured independently on the local target. The four-field DTO contains no PII. The function body does not read `profiles.role` or `tenant_memberships`, and does not grant a membership or staff capability; the slug selects only an active public tenant context, not an authorization authority.

On production, `csk` returned the CSK UUID and exactly the four approved fields with status `active`. `unknown`, uppercase `CSK`, malformed `csk/other` and NULL returned zero rows. There is no dormant tenant on production (tenant count = 1), so the inactive-slug case was **not** manufactured there; the function definition's `tenant.status = 'active'` predicate and the prior 25/25 local SQL matrix establish this contract. No rollback fixture matrix ran on production and fixture cleanup is **N/A (zero created)**. The local 0/>1 active-tenant behavior remains the evidence for those states; the production active-tenant invariant was never disturbed.

After deployment, production SECURITY DEFINER count is **70** (69 baseline + exactly this approved resolver), with no unexpected function addition from the single applied migration. Compatibility defaults remain **7/7**. Exactly one active CSK and the second-active unique guard remain. The direct tenant table boundary remains closed; the new function did not widen table ACL or RLS. Read-only postchecks found tenant duplicates 0, active ambiguity 0, membership orphans 0, seven-table tenant NULLs 0, and parent/child, reservation/lane, block/lane, event/lane and registration/event tenant mismatches all 0. The existing exact-single-active bridge still has **22** referring function bodies and was not cut over.

Anonymous, redirect-following production GET smoke returned HTTP 200 for `/booking`, `/events`, `/admin`, `/account` and `/login`, with no 5xx. This is availability evidence only, not a claim that anonymous users accessed privileged pages or that future tenant-aware routes already work. Existing resource-owned paths and global role authority were not changed by this additive DB migration. The app foundation helper is not deployed; no route/caller uses the resolver yet.

SAAS-9E-A DB PRODUCTION DEPLOY: **PASS**
SAAS-9E-A DB POST-DEPLOY: **PASS**
PUBLIC SLUG RESOLVER: **PASS**
SERVER-SIDE SLUG CONTRACT: **PASS**
CLIENT TENANT AUTHORITY: **ABSENT**
PUBLIC TENANT CONTEXT: **PASS**
SECOND TENANT: **NO-GO**
SECURITY DEFINER COUNT: **70**
COMPATIBILITY DEFAULTS: **7/7**
EXACT-SINGLE-ACTIVE BRIDGE: **STILL ACTIVE**
RUNTIME SMOKE: **PASS (anonymous HTTP/no-5xx scope)**
FIXTURE CLEANUP: **N/A — no production fixture created**
READY FOR 9E-A APP FOUNDATION DEPLOYMENT: **YES — separate approval and rollout required**
READY FOR 9E-B: **NO-GO until 9E-A full production PASS/checkpoint/review**
READY FOR 4D-2: **NO-GO**
READY FOR 9D-5: **NO-GO**
SEC-004: **OPEN**

## Archived production preflight — read-only, before the deployment above

The production preflight used linked Supabase CLI read operations and read-only `SELECT` in the SQL Editor for project `yuyxfodozzpzrdzkmolu`, matching `supabase/.temp/project-ref`. No SQL write, migration application, Git write or app deployment occurred.

| Gate | Evidence / result |
|---|---|
| Working tree and approved scope | `main` at `a6324cda94dbdf14ddf850240e0dfe59d9ca96f5`. Semantic tracked changes: the 9E plan and 18 SQL tests. Untracked: this report, server helper and test, new migration and SQL test. `AGENTS.md` also has a real but unrelated auto-generated diff; explicitly excluded and unstaged. No historical migration or application route changed. `git diff --ignore-cr-at-eol --check` PASS. CRLF warnings alone are environmental. |
| Migration SHA-256 | `20260925100000_add_public_active_tenant_resolver.sql` = `2188D4B332CD1A08598D93BBCEA36FEE959DF25A7A3B171D3AF6BB73CE79ED84`; matches the local implementation evidence. |
| Migration history | Linked JSON migration list: 101 records; paired LOCAL=REMOTE through `20260924100000`; exactly one local-only `20260925100000`; remote-only 0; mismatched pairs 0. |
| Production tenant boundary | SQL Editor: exactly one active tenant and one active CSK (`csk`); `public.tenants` RLS enabled, owner `postgres`, zero policies, SELECT denied to anon/authenticated/service_role. Partial unique second-active guard present (1). |
| Function/default baseline | At preflight time, public SECURITY DEFINER count was 69; planned target 70 only after the new resolver. Resolver was then absent. 22 existing function bodies referenced the exact-single-active bridge; no bridge cutover in 9E-A. CSK compatibility defaults were 7/7. |
| Production integrity | Read-only counts: membership orphans 0, lane parent/child mismatch 0, reservation/lane mismatch 0, lane-block/lane mismatch 0, event-lane mismatch 0, event-registration/event mismatch 0, and tenant-id NULL across the seven core/default tables 0. |
| Runtime smoke | Anonymous GET with redirect following: `/`, `/booking`, `/events`, `/login`, `/account`, `/admin`, `/admin/lane-configuration`, `/admin/reservations`, `/admin/calendar` returned HTTP 200, with no observed 5xx. This checks reachability, **not** authenticated workflows or tenant-aware routing. |
| Final linked dry-run | `npx supabase db push --linked --dry-run` exited 0 and listed **only** `20260925100000_add_public_active_tenant_resolver.sql`. CLI version notice (2.109.1 → 2.117.0) is informational; no upgrade performed. |

The migration's own fail-closed preflight asserted the same critical count, RLS/ACL, active-CSK, guard and default conditions before any DDL. Before the deployment, the resolver's owner/search-path/ACL/PII-free four-field target, server-side slug validation, staff membership context and persisted-resource comparison had been verified locally by the 25/25 focused SQL and Node/full DB contracts. The 4D-2 caller dependency remains unchanged and blocked. OLD APP + NEW DB is additive; no route/caller cutover was authorized by this preflight.

SAAS-9E-A PRODUCTION PREFLIGHT: **PASS**
READY FOR PRODUCTION PUSH: **YES at the time of preflight; the separately approved push is now complete**
READY FOR SAAS-9E-B: **NO-GO until deployment verification and review**
READY FOR 4D-2: **NO-GO**
SECOND TENANT: **NO-GO**
SEC-004: **OPEN**

## Current final state

The archived preflight readiness decision is superseded by the DB deployment and the app foundation deployment below. The DB migration is complete and no further migration is pending.

## APP FOUNDATION PRODUCTION DEPLOYMENT

### Exact commit and scope

The approved APP-only scope was exactly `lib/server/tenant-context.ts` and `lib/server/tenant-context.test.mjs`. Before staging, `git status --short`, semantic `git diff --ignore-cr-at-eol --name-only/--stat/--check` and the untracked list were reviewed. The plan, report, new SQL migration, SQL tests and unrelated `AGENTS.md` remained outside the APP commit. Explicit staging of only the two named files produced a two-file cached name list, two-file cached stat (282 insertions), and `git diff --cached --check` PASS. Commit `ea61da2978d1d85a8498c91e1d367840803802af` (`SAAS-9E-A add trusted tenant context foundation`) contains only those two files. No `git add .` or `git add -A` was used.

Before push, `git fetch origin` showed branch `main` tracking `origin/main`, behind 0, ahead 1, with only that APP commit and exactly those two paths. Ordinary `git push origin main` fast-forwarded `a6324cd..ea61da2`. Local HEAD and remote `origin/main` are both `ea61da2978d1d85a8498c91e1d367840803802af`; divergence is 0/0. No force, rebase, reset or direct Vercel CLI deployment was used.

### Target Vercel deployment and production version

The GitHub deployment/status records for that exact SHA report **success** for the intended `Production – csk-booking-5nwh` environment, deployment ID `6537214546`, immutable URL `https://csk-booking-5nwh-8uzw2lfuh-mpiosik94-9167s-projects.vercel.app`, and description `Deployment has completed`. The production alias `https://csk-booking-5nwh.vercel.app/` and this immutable deployment URL both returned HTTP 200 with the same prerendered ETag `"f8ba1e8697c24a8ceda7bb132b678f2e"`, proving the alias serves the target deployment content. A **different** Vercel project, `csk-booking`, reported a failed deployment for the same commit; that failure is not used as evidence of the requested target's state and should be investigated separately if that project matters operationally. The private Vercel dashboard itself required login, so the target GitHub production deployment record plus alias/immutable response match are the version evidence.

### Inert foundation and tests

Repository import search found **zero** app route/proxy imports of the new helper; the only import is its focused test. There are **zero** `/t/[slug]` route files and zero references to the new helper/resolver in `.next/static` client bundles after the production build. No `/booking`, `/events`, `/admin` or `/account` caller, redirect or middleware was committed. The helper is therefore inert in current production routing and absent from the client bundle. It lives in `lib/server`; there is no additional compile-time `server-only` import marker in this phase, so future callers must preserve the server-only boundary during review. The helper has no implicit CSK fallback, cookie/query/client authority or `profiles.role` check. It resolves active slug server-side, requires active tenant membership and allowed role for staff, and compares persisted resource tenant ID with route context. These are foundation contracts only; legacy routes still use their prior exact-single-active behavior.

The pre-deployment test gate passed again: focused tenant-context Node **10/10**, full Node **760/760**, TypeScript, production build, changed-file ESLint, relevant Playwright **9/9**, and `git diff --ignore-cr-at-eol --check`. Playwright used local fixtures; no new production fixture was created. Post-deploy anonymous HTTP GET returned **200** for `/booking`, `/events`, `/admin`, `/account` and `/login`, without 5xx. A read-only browser check in an existing signed-in session showed `/account` loaded account controls and `/admin` loaded the operational dashboard. No user data was modified. These are non-destructive runtime checks, not a full authenticated workflow regression or cross-tenant production test.

### DB unchanged and residual gates

After the APP deployment, linked migration history still ends at `20260925100000`, with no pending, remote-only or mismatched migrations. Read-only production SQL showed one active CSK, the second-active guard present, SECURITY DEFINER **70**, CSK compatibility defaults **7/7**, resolver fingerprint still `8c32a2ba9ae0b86a73593c2580d0ff9f`, and **22** exact-single-active bridge references. The APP commit contained no SQL; no production DB write was performed during the APP phase. Client tenant authority is absent. `profiles.role` is not an authority in the **new helper**; existing legacy application authorization was deliberately not cut over. Second tenant remains blocked, and SEC-004 remains open.

At this point, the worktree still has the unrelated, unstaged `AGENTS.md`, the 9E plan and 18 DB regression test edits, plus the untracked 9E-A report, migration and SQL test. The APP helper and Node test are committed and pushed. These remaining approved DB/report files require a separate final checkpoint review; none was silently included in the APP deployment.

SAAS-9E-A APP FOUNDATION DEPLOY: **PASS**
VERCEL DEPLOY: **PASS — target `csk-booking-5nwh`**
PRODUCTION VERSION: **NEW COMMIT ACTIVE — `ea61da2978d1d85a8498c91e1d367840803802af`**
INERT FOUNDATION: **PASS**
SERVER-SIDE CONTEXT HELPER: **PASS for current import/bundle boundary**
CLIENT TENANT AUTHORITY: **ABSENT**
GLOBAL ROLE AUTHORITY: **ABSENT from the new helper; legacy runtime unchanged**
ROUTING CUTOVER: **NOT STARTED**
EXACT-SINGLE-ACTIVE BRIDGE: **STILL ACTIVE**
DB CHANGES: **0 during APP phase**
SECURITY DEFINER COUNT: **70**
COMPATIBILITY DEFAULTS: **7/7**
SECOND TENANT: **NO-GO**
READY FOR FINAL 9E-A CHECKPOINT: **YES — separate review**
READY FOR 9E-B PLANNING/REVIEW: **GO after final 9E-A checkpoint**
READY FOR 9E-B IMPLEMENTATION: **NO-GO until 9E-A checkpoint/review**
READY FOR 4D-2: **NO-GO**
READY FOR 9D-5: **NO-GO**
SEC-004: **OPEN**
