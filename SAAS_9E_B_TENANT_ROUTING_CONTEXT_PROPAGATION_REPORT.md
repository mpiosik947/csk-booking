# SAAS-9E-B — Tenant-aware routing/context propagation (local)

Status: local implementation only. No Git add/commit/push, production write, DB migration, SQL-function change or deployment. Baseline is checkpoint `47c86f1`; `AGENTS.md` is unrelated, untouched and unstaged. The 9E-A report has **no semantic diff** (`git diff --ignore-cr-at-eol -- SAAS_9E_A_TRUSTED_TENANT_CONTEXT_FOUNDATION_REPORT.md` empty). The 9E-B plan diff was the only pre-existing task change.

## 1. Exact three-surface scope

| Surface | Current URL / target URL | Class and tenant source | Membership / resource check | Compatibility / active DB caller cutover |
|---|---|---|---|---|
| `app/t/[slug]/layout.tsx` | none → `/t/[slug]/*` | public server layout; slug from path, 9E-A active resolver | no membership; no business resource | old routes unchanged; **NO** |
| `app/t/[slug]/page.tsx` | none → `/t/[slug]` | PII-free public venue landing; server context | no membership; no business resource | explicit links to current `/booking` and `/events` **only for `csk`**; **NO** |
| `app/t/[slug]/[...path]/page.tsx` | `/booking`, `/events`, `/my-reservations`, `/my-events`, `/admin/*` stay live → reserved `/t/[slug]/...` shells | public / authenticated user / staff, according to path | user Auth or staff active membership; no business resource in 9E-B | controlled unavailable shell; old CSK path linked only after server checks, no redirect or fallback; **NO** |

The third surface recognizes only approved paths. Unknown non-admin paths return 404; unknown admin paths retain the admin-only permission baseline and then 404. These shells deliberately do not import an existing client business page or call reservation, event, check-in, report or admin-user RPCs. They do not offer a Tenant B path to legacy CSK data. Old CSK URLs remain operational; no old URL is redirected to an unavailable shell. Account, dashboard, login/register, token, ICS and email paths stay global/resource-bound. Per-module temporary GET redirects belong to the later 9E-C equivalence gate, not 9E-B.

## 2. Server-only boundary

Before: `lib/server/tenant-context.ts` had only a directory convention and zero active route callers. After: the canonical route import starts with `import "server-only"`, using declared `server-only@0.0.1` on pinned Next.js 16.3.4. Dependency-injected logic moved without intended semantic change to `tenant-context-core.ts` to preserve direct Node tests; route code imports only the guarded facade via `tenant-route-context.ts`. The core contains no secrets, service-role client or environment access. Package manifest/lockfile changed only to add the marker package.

An intentionally created temporary Client Component imported the facade and `next build` failed with **`'server-only' cannot be imported from a Client Component module`** and a client import trace. The probe was removed immediately; a subsequent production build passed. Permanent focused test additionally verifies that a non-server import throws, the marker is declared, and all three route surfaces use the guarded server adapter. The built `.next/static` client files have no `server-only` or `tenant-context-core` reference. No client tenant authority was added.

## 3. Routing and authorization model

`/t/[slug]` uses a canonical path slug, `resolve_active_tenant_by_slug_v1`, exact PII-free DTO validation, and request-scoped anon-key SSR client. Invalid, unknown and inactive/dormant slugs fail closed with 404. Public context requires no membership. Authenticated user shell calls `auth.getUser`; it does **not** infer staff rights from global identity, route or cookie. Staff shell additionally calls `get_my_tenant_role_v1` for the resolved tenant and applies the existing Admin permission matrix after mapping `pracownik→employee`, `instruktor→instructor`. `profiles.role` and `get_my_role` are absent from all new server route code. Missing session is redirected to login with a constructed, canonical relative return path; forbidden staff context is 404. Existing legacy middleware and pages are unchanged and remain CSK-only during this phase.

There is no tenant preference cookie, session selector, browser UUID authority or mutable selected-tenant state in 9E-B. Tab A/B path selection is independent in focused tests. Legacy links are an explicit `slug === "csk"` compatibility decision, never `missing tenant → CSK`. The landing/shell envelopes expose only public venue name/slug and generic route text; they do not render membership metadata, PII or foreign business rows. The new route can be served only for an active tenant according to the resolver. The production second-active guard remains in place; local active B behavior is tested with isolated mocks, while the browser smoke verifies absent/dormant B denial. No real B was activated.

There is no business resource in any 9E-B shell. The existing `resourceBelongsToTenant` foundation check still denies route A/resource B and the inverse in focused tests, but **every operational resource read/write must be bound inside a versioned DB contract in 9E-C**. A shell's server context is not an authorization capability for existing RPCs. Tenant-owned audit binding likewise remains a 9E-C caller/DB gate, not a 9E-B runtime claim.

## 4. Bridge, 4D-2, security inventory and exact 9E-C residual

`supabase/migrations`, `supabase/tests`, historical functions, RLS and ACL are unchanged. The approved production baseline is 22 bridge-referencing definitions plus the helper, SECURITY DEFINER **70**, and compatibility defaults **7/7**. 9E-B adds no DB migration or function and changes zero existing business callers, so expected post-9E-B inventory is 22 / 70 / 7/7. This is a no-DB-change regression inference, not a fresh production post-deploy measurement; production preflight must re-read it.

4D-2 is **not unlocked**: `middleware.ts`, homepage, Admin root/Calendar/Reports/Users/Events/Lane Configuration and calendar-feed still have global-role dependencies or calls to `get_my_role`; the new shell does not replace those active callers. Admin Check-in, Dashboard and cancellation role boundaries also require exact app/DB inventory. 9E-C must introduce and deploy tenant-aware public, owner and staff DB contracts per domain, change the operational page/API callers, prove resource/route mismatch DENY and zero active global-role caller use, then pass production verification before 4D-2 ACL closure can be reviewed. 9D-5, 9F/9G, second-tenant activation and SEC-004 closure remain outside this implementation.

## 5. Tests and caveats

- Focused tenant context/routing Node: **16/16 PASS**; includes synthetic A/B, Auth A/B, staff role and membership denial, route/resource mismatch, stale preference, role matrix, exact three-surface scope and non-server import rejection.
- Full Node suite: **766/766 PASS**.
- Negative Next client import probe: **build failed as required**; temporary probe removed. Final production build and `npx tsc --noEmit`: **PASS**.
- Changed-file ESLint: **PASS**. Relevant Playwright (tenant routing, existing admin action queues and events responsive): **16/16 PASS** against local Supabase; active CSK shell, invalid/unknown B 404, no legacy-page substitution, unauthenticated staff redirect and old `/booking` compatibility verified.
- `git diff --ignore-cr-at-eol --check`: **PASS**. Synthetic database fixture created by 9E-B: **0**; cleanup residue **0**. DB full suite not required because SQL/DB files changed **0**.
- `npm audit --omit=dev` reports **one moderate advisory** for `baseline-browser-mapping@2.10.30`, which is present in the pre-9E-B `HEAD` lockfile. No dependency remediation was performed beyond the scoped `server-only` addition. Existing Next `middleware` deprecation warning remains unrelated.
- No production runtime or post-deploy evidence is claimed. Admin/user A/B authorization is covered by focused injected-client tests, not a production second-tenant test; the active-second-tenant guard remains intact.

## Final verdict

SAAS-9E-B LOCAL: **PASS**

EXACT ROUTE/CALLER SCOPE: **3**

SERVER-ONLY BOUNDARY: **PASS**

PUBLIC ROUTING: **PASS**

AUTH USER ROUTING: **PASS (focused server-contract tests; no operational data cutover)**

STAFF ROUTING: **PASS (active-membership shell contract; no operational data cutover)**

CLIENT TENANT AUTHORITY: **ABSENT**

GLOBAL ROLE AUTHORITY: **ABSENT from new routes; legacy paths unchanged**

ROUTE/RESOURCE MISMATCH FOUNDATION: **PASS**

BACKWARD COMPATIBILITY: **PASS**

MULTI-TAB / SESSION SAFETY: **PASS (route-determined; no preference cookie)**

OPERATIONAL DB CALLER CUTOVERS: **0**

DB CHANGES: **0**

EXACT-SINGLE-ACTIVE BRIDGE REFERENCES: **22 (unchanged DB baseline)**

4D-2 UNBLOCKED: **NO**

SECURITY DEFINER COUNT: **70 (unchanged DB baseline)**

COMPATIBILITY DEFAULTS: **7/7 (unchanged DB baseline)**

READY FOR 9E-B PRODUCTION PREFLIGHT: **GO**

READY FOR 9E-C: **NO-GO until review**

READY FOR 4D-2: **NO-GO**

READY FOR 9D-5: **NO-GO**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## PRODUCTION DEPLOYMENT & FINAL VERIFICATION — historical blocked attempt (superseded below)

The approved local checkpoint was created as `ac717243dad9c9631c5538726ed481adb63c3d43` (`SAAS-9E-B add tenant-aware routing context`). Staging contained exactly the 14 scoped files in the deployment-readiness table: nine runtime/dependency, three test, and two report/plan files. Both temporary Client Component probes were absent; `AGENTS.md` was excluded and remained unstaged. No migration, SQL, 9E-C, 4D-2 or 9D-5 file was committed. The initial staged whitespace check exposed Markdown hard-break trailing spaces in this report; those were removed, and the repeated `git diff --cached --check` passed before commit.

Pre-deploy regression was repeated: standard Node **767/767**, Playwright **16/16**, TypeScript, production build and changed-file ESLint **PASS**. Both direct client-import denials, positive server import and zero client-chunk references were established in the preceding preflight. `git fetch origin` succeeded; immediately before the attempted push, local `main` was one commit ahead and zero behind `origin/main`, with parent exactly `47c86f1e8ae0a3a48bc3c77f790d58577c59252b`. This was a fast-forward candidate.

The ordinary `git push origin main` could not connect to GitHub from the sandbox. The required elevated retry was **rejected by the environment's approval reviewer** as a risk of transmitting repository contents to the external remote; no push occurred. No alternative mechanism or bypass was attempted. Consequently `origin/main` still refers to the previous commit as last observed, and no Vercel deployment of `ac71724` is established. The target `csk-booking-5nwh` was **not** verified as running the new commit. Production `/t/[slug]` routing, server-only behavior and runtime smoke cannot be marked PASS after deployment because deployment did not occur. The already measured DB preflight baseline (22 bridge references, 70 SECURITY DEFINER, 7/7 defaults, one active CSK) is not a post-deploy measurement. Production DB writes and migrations performed in this checkpoint: **0**.

This is an authorization/environment delivery blocker, **not evidence of an application defect**. To resume, the user must give explicit direct approval for the specific external `git push origin main` of `ac717243dad9c9631c5538726ed481adb63c3d43` to `https://github.com/mpiosik947/csk-booking.git`, acknowledging that it transmits the committed repo diff and triggers Vercel. Then repeat the remote fast-forward gate before pushing; do not assume the remote remained unchanged.

SAAS-9E-B APP DEPLOY: **FAIL — not performed**
VERCEL DEPLOY: **FAIL — not verified**
PRODUCTION VERSION: **FAIL — new commit not established**
EXACT ROUTE/CALLER SCOPE: **3 locally / production unverified**
SERVER-ONLY BOUNDARY: **PASS locally / production unverified**
CLIENT BUNDLE EXPOSURE: **0 in local build / production unverified**
PUBLIC ROUTING: **FAIL — production unverified**
AUTH USER ROUTING: **FAIL — production unverified**
STAFF ROUTING: **FAIL — production unverified**
CSK DATA SUBSTITUTION UNDER FOREIGN SLUG: **ABSENT locally / production unverified**
BACKWARD COMPATIBILITY: **PASS locally / post-deploy unverified**
OPERATIONAL DB CALLER CUTOVERS: **0 in commit**
DB CHANGES: **0 in commit; production SQL write 0**
EXACT-SINGLE-ACTIVE BRIDGE REFERENCES: **22 pre-deploy**
SECURITY DEFINER COUNT: **70 pre-deploy**
COMPATIBILITY DEFAULTS: **7/7 pre-deploy**
SECOND TENANT: **NO-GO**
READY FOR FINAL 9E-B CHECKPOINT: **NO — push/deploy/postcheck pending**
READY FOR 9E-C PLANNING: **NO-GO until 9E-B production PASS**
READY FOR 9E-C IMPLEMENTATION: **NO-GO**
READY FOR 4D-2: **NO-GO**
READY FOR 9D-5: **NO-GO**
SEC-004: **OPEN**

## PRODUCTION PREFLIGHT & DEPLOYMENT READINESS (historical stopped review; superseded below)

**Result: FAIL / NOT READY.** This section supersedes the local report's `SERVER-ONLY BOUNDARY: PASS` and `READY FOR 9E-B PRODUCTION PREFLIGHT: GO` as a deployment decision. The earlier negative Client Component build probe covered only the facade; it did not cover the separately importable implementation. No application, migration, SQL, production, or Git write was performed in this preflight; only this report was updated.

### 1. Working tree and exact scope

`main` HEAD is `47c86f1e8ae0a3a48bc3c77f790d58577c59252b`. Raw `git status --short` reports five task-related tracked modifications, nine task-related untracked files and one unrelated tracked modification (`AGENTS.md`). `git diff --name-only` and `git diff --stat` report the five tracked task files plus `AGENTS.md`; `git ls-files --others --exclude-standard` reports the nine task files below. `git diff --ignore-cr-at-eol --name-only` yields the same tracked set: these are real semantic changes, not CRLF-only artifacts. `git diff --check` passes (Git emits LF/CRLF conversion warnings). The real `AGENTS.md` diff is unrelated and remains excluded/unstaged. The 9E-A report has no semantic diff. No unexpected real diff was found.

| Category | Exact files | Proposed deploy checkpoint |
|---|---|---|
| Runtime route | `app/t/[slug]/layout.tsx`, `app/t/[slug]/page.tsx`, `app/t/[slug]/[...path]/page.tsx` | Required after boundary fix |
| Server/context | `lib/server/tenant-context.ts`, `lib/server/tenant-context-core.ts`, `lib/server/tenant-route-context.ts`, `lib/tenant-routing.ts` | Required after boundary fix |
| Dependency | `package.json`, `package-lock.json` (`server-only` marker) | Required after boundary fix |
| Tests | `lib/server/tenant-context.test.mjs`, `lib/tenant-routing.test.mjs`, `tests/e2e/tenant-routing.spec.ts` | Include in a reviewed checkpoint |
| Report/plan | `SAAS_9E_B_TENANT_ROUTING_CONTEXT_PROPAGATION_REPORT.md`, `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md` | Include after review |
| Unrelated | `AGENTS.md` | **Exclude; do not touch or stage** |

There are exactly **three** route surfaces as described in section 1, and **zero** active operational DB caller cutovers. No migration, SQL function, RLS or ACL file is changed. The old CSK URLs remain intact; `/t/[slug]` and its public/user/staff shells are transitional and do not substitute CSK operational data for a foreign slug. Path slug selection, active resolver, membership for staff, resource mismatch foundation, and no preference-cookie authority are supported by the prior local tests and source inspection; they are **not** production post-deployment claims. The future resource-bound operational cutover and 4D-2/9D-5 closure remain blocked.

### 2. Blocking server-only finding

| File | Server-only mechanism | Client import failure mode | Client bundle references | Gate result |
|---|---|---|---|---|
| `lib/server/tenant-context.ts` | Explicit `import "server-only"` | Prior intentional Client Component import failed during `next build` | None observed in prior `.next/static` search | Guarded facade only |
| `lib/server/tenant-route-context.ts` | Explicit `import "server-only"`; Next server APIs | Server-component-only imports | None observed | Guarded adapter |
| `lib/server/tenant-context-core.ts` | **None**; exports `resolvePublicTenantContext`, `resolveAuthenticatedTenantContext`, `resolveStaffTenantContext` and `resourceBelongsToTenant` directly | No marker/import prohibition on this direct path; the previous negative probe did **not** exercise it | None observed in the current build, but absence of an active import is not an enforceable boundary | **FAIL** |

The core is dependency-injected and has no embedded secret or service-role key, so this is **not evidence of a current client-bundle leak or cross-tenant access**. It is nonetheless a concrete bypass of the requested compile-time rule that *no Client Component can import the trusted helper*: a Client Component can target the unguarded implementation rather than the guarded facade. Its exported functions implement the trusted context resolution and authorization checks, not merely pure slug/path validation. The package/directory name does not impose Next's `server-only` restriction. The exact direct-import negative test has not been run; the enforceable boundary cannot be marked PASS on the facade-only probe. Under the user's explicit “any client-side availability of trusted context logic → STOP” gate, preflight stopped here. No code change is authorized in this read-only phase.

### 3. Remaining gates and deployment risk

Fresh production SQL inventory (22 bridge references, SECURITY DEFINER 70, defaults 7/7, active tenants 1 / active CSK 1), migration history and target Vercel deployment checks were **not continued after STOP**. The previous approved DB baseline and a prior SQL Editor result are not substituted for a fresh gate. Read-only HTTP probes of `/booking`, `/events`, `/admin`, `/account`, `/login`, `/my-reservations`, `/my-events`, `/admin/users`, `/admin/reports` and `/admin/check-in` returned HTTP 200 with redirects followed; these establish no 5xx on those GETs, **not** authenticated role authorization. The repository is on `main` and `origin` points to `mpiosik947/csk-booking`; the known target Vercel project is `csk-booking-5nwh`, not a similarly named project. No Git deployment was attempted.

Risk assessment: route regression **MEDIUM**; backward URL compatibility **LOW** (legacy URLs unchanged); server-only boundary **HIGH for the stated deployment gate** (unguarded direct import, without evidence of present exploit); invalid/inactive slug **LOW** on local tests; accidental CSK fallback **MEDIUM**; client tenant authority **LOW** in current routes; staff membership bypass **MEDIUM**; future route/resource mismatch **HIGH** until 9E-C caller cutover; Vercel rollback **MEDIUM**. These are rollout risks, not newly proven production vulnerabilities. The existing moderate `baseline-browser-mapping@2.10.30` audit advisory predates this change; contrary to the prompt's shorthand “no dependency change,” this scope **does** add `server-only@0.0.1` to `package.json` and lockfile.

Blocking action for a separate authorized implementation/review: make the trusted implementation path unimportable from Client Components, preserve a separately testable pure subset if needed, exercise a direct core-import negative build probe, remove its test artifact, and rerun the full preflight. This report does not implement that change.

### Final preflight verdicts

SAAS-9E-B PRODUCTION PREFLIGHT: **FAIL**
WORKING TREE SCOPE: **PASS**
EXACT ROUTE/CALLER SCOPE: **3**
DB CHANGES: **0**
SERVER-ONLY BOUNDARY: **FAIL**
PUBLIC ROUTING: **PASS (local contract only)**
AUTH USER ROUTING: **PASS (local contract only)**
STAFF ROUTING: **PASS (local contract only)**
CLIENT TENANT AUTHORITY: **ABSENT in active route code; direct core import remains unguarded**
GLOBAL ROLE AUTHORITY: **ABSENT in new routes**
CSK DATA SUBSTITUTION UNDER FOREIGN SLUG: **ABSENT in new shells**
BACKWARD COMPATIBILITY: **PASS (source/local evidence)**
ROUTE/RESOURCE MISMATCH FOUNDATION: **PASS (local contract; not operational cutover)**
MULTI-TAB / SESSION SAFETY: **PASS (local contract)**
OPERATIONAL DB CALLER CUTOVERS: **0**
EXACT-SINGLE-ACTIVE BRIDGE REFERENCES: **22 prior baseline; fresh preflight NOT VERIFIED**
4D-2 UNBLOCKED: **NO**
SECURITY DEFINER COUNT: **70 prior baseline; fresh preflight NOT VERIFIED**
COMPATIBILITY DEFAULTS: **7/7 prior baseline; fresh preflight NOT VERIFIED**
SECOND TENANT: **NO-GO**
STANDARD DEPLOYMENT PATH: **main → origin/main → Vercel `csk-booking-5nwh` (known configuration; not exercised)**
READY FOR 9E-B GIT DEPLOY COMMIT: **NO**
READY FOR 9E-C: **NO-GO**
READY FOR 4D-2: **NO-GO**
READY FOR 9D-5: **NO-GO**
READY FOR PRODUCTION WRITE: **NO**
SEC-004: **OPEN**

## SERVER-ONLY REMEDIATION AND RESUMED PRODUCTION PREFLIGHT

This section is the **current** 9E-B deployment decision. The preceding FAIL records the earlier, correctly stopped read-only review and must not be interpreted as the current result. The separately authorized local remediation added only `import "server-only";` at the start of `lib/server/tenant-context-core.ts`; `lib/server/tenant-context.ts` already had the marker. No dependency was added in this remediation (`server-only@0.0.1` was already declared in the 9E-B working tree). Focused boundary tests were extended in `lib/tenant-routing.test.mjs`. No routing, resolver body, membership/role/resource validation, fallback, DB caller, migration or SQL function changed.

| Module | Enforceable marker | Direct Client Component production-build probe | Valid server import | Client bundle reference |
|---|---|---|---|---|
| `lib/server/tenant-context.ts` | `import "server-only"` | **DENIED**: Turbopack build failed with `'server-only' cannot be imported from a Client Component module` and a browser/SSR import trace | **PASS** with `react-server` condition | **0** |
| `lib/server/tenant-context-core.ts` | `import "server-only"` | **DENIED**: same build error, directly at core line 1 with a browser/SSR import trace | **PASS** with `react-server` condition | **0** |
| `lib/server/tenant-route-context.ts` | Existing `import "server-only"` and Next server APIs | Transitive route adapter; no Client Component caller | **PASS** in normal production build | **0** |

The two negative probes were run **separately** using a temporary `app/server-only-probe/page.tsx` Client Component. Both production builds failed for the intended reason. The probe was then deleted; `Test-Path app/server-only-probe/page.tsx` returned false. The normal production build succeeded. `.next/static` scans for `tenant-context-core` and `resolveStaffTenantContext` returned no matching client chunks. The first probe path used a `__`-prefixed directory, which Next ignored, so it was replaced by the non-private temporary route before counting either negative test. The existing ten server-side context tests and a new positive import test passed under Node's `react-server` condition; the default Node condition intentionally rejects the marker.

### Local regression and semantic scope

- Focused context/routing Node: **17/17 PASS**, including both direct non-server import denials and both valid server imports. The full standard `node --test` suite: **767/767 PASS**. The core unit-test file installs a resolver for the marker in its isolated Node test process only, then dynamically imports the implementation; this does not affect Next, the browser or the separate negative-import tests. A full run with `--conditions=react-server` also passed 767/767.
- TypeScript after the final clean build: **PASS**. Initial TypeScript invocation saw stale generated `.next/types` for the now-deleted temporary probe; rebuilding regenerated types, and the repeat passed.
- Normal production build: **PASS**. Changed-file ESLint (`tenant-context-core.ts`, `tenant-routing.test.mjs`): **PASS**. Focused Playwright plus affected admin/events checks: **16/16 PASS**. `git diff --check`: **PASS** (only pre-existing LF/CRLF conversion warnings).
- Semantic diff for the trusted implementation: exactly the marker import was added to core; slug parsing and active-tenant RPC validation, `auth.getUser`, membership role check and resource-tenant equality are unchanged. The facade, adapter and three route surfaces have no new semantic change in this remediation. Operational DB caller cutovers **0**; DB/migration/RPC/RLS/ACL changes **0**; synthetic fixture **0**.
- Working tree remains the previously reconciled 14 task files plus unrelated `AGENTS.md`. The only remediation changes are core, the two focused test files and this report. `AGENTS.md` remains unrelated, excluded and unstaged. No `git add`, commit, push or deployment was performed.

### Resumed production read-only inventory and deployment scope

The SQL Editor for production project `yuyxfodozzpzrdzkmolu` executed a new **SELECT-only** `jsonb_build_object` count query. Fresh result: `active_tenants=1`, `active_csk=1`, second-active unique `guard=1`, `bridge_refs=22`, public `SECURITY DEFINER` functions `definers=70`, and exact CSK compatibility `defaults=7`. The query did not return customer rows or write data. All 22 referring definitions remain active in the unchanged production DB; **0** were changed by 9E-B. The 22-bridge cutover belongs to 9E-C domain-by-domain and final compatibility-default removal to the later explicit 9D-5 gate, not this deploy. The current single active tenant is CSK; second tenant remains blocked.

The exact route scope remains **3**: `app/t/[slug]/layout.tsx` (public active-slug envelope), `app/t/[slug]/page.tsx` (PII-free venue landing), and `app/t/[slug]/[...path]/page.tsx` (public/user/staff transitional shells). Path slug is a selector, never authority. Existing `/booking`, `/events`, `/my-reservations`, `/my-events`, `/admin/*` and global account/auth routes are not redirected or rewritten. Non-CSK slugs cannot link to or render CSK operational views; there are no operational controls on the shells. The helper derives public context from the active-slug RPC, authenticated context from `auth.getUser`, and staff context from active membership/allowed role. `profiles.role` is not an authority in the new route code. Route/resource mismatch is represented by `resourceBelongsToTenant`, but no claim of operational enforcement before 9E-C is made. No tenant-selection cookie or global tab preference can override an explicit route slug; A/B path-context tests passed locally. The previous read-only HTTP baseline for old CSK URLs was HTTP 200 with redirects followed and no 5xx; it is a reachability baseline, not authenticated authorization proof.

Proposed Git deploy checkpoint is exactly the 14 9E-B task files itemized in the prior scope table: **9 runtime/dependency files**, **3 tests**, **2 report/plan files**. No staging has occurred. `AGENTS.md` is excluded. The standard path remains `main → origin/main → Vercel csk-booking-5nwh`; the similarly named non-target Vercel project must not be used as authority. This preflight does not deploy, confirm a new Vercel commit or exercise a rollback. Risk remains **MEDIUM** overall for additive route/regression and rollout coordination, with explicit second-tenant and future route/resource enforcement blockers. The server-only boundary risk found by the earlier review is now closed locally. The existing moderate `baseline-browser-mapping@2.10.30` advisory remains unrelated and was not remediated here.

4D-2 remains blocked: the existing Admin/Check-in/Calendar/Reports/Users/Events and middleware/application callers have not all been cut over to trusted tenant context and resource-bound DB contracts. 9E-C must inventory and migrate those callers before 4D-2 or 9D-5 can be reconsidered. The new 9E-B shells do not unlock either phase.

### Current final verdicts

SERVER-ONLY REMEDIATION: **PASS**
tenant-context.ts CLIENT IMPORT: **DENIED**
tenant-context-core.ts CLIENT IMPORT: **DENIED**
VALID SERVER IMPORT: **PASS**
CLIENT BUNDLE EXPOSURE: **0**
TRUSTED CONTEXT SEMANTICS: **UNCHANGED**
OPERATIONAL DB CALLER CUTOVERS: **0**
DB CHANGES: **0**
SAAS-9E-B PRODUCTION PREFLIGHT: **PASS**
READY FOR 9E-B GIT DEPLOY COMMIT: **YES**
READY FOR 9E-C: **NO-GO until 9E-B production PASS/checkpoint/review**
READY FOR 4D-2: **NO-GO**
READY FOR 9D-5: **NO-GO**
SECOND TENANT: **NO-GO**
SEC-004: **OPEN**

### Latest delivery state after the approved preflight

The preflight PASS above remains valid, but the dedicated **PRODUCTION DEPLOYMENT & FINAL VERIFICATION — blocked before push** section records the authoritative delivery outcome. Commit `ac717243dad9c9631c5538726ed481adb63c3d43` exists locally; the push was rejected by the environment approval reviewer, so `origin/main` and Vercel have not been advanced or verified. **Do not treat `READY FOR 9E-B GIT DEPLOY COMMIT: YES` as an authorization to report production PASS.** APP DEPLOY and POST-DEPLOY remain incomplete, final checkpoint NO, and 9E-C NO-GO pending a separately authorized push and full post-deploy verification.

## PRODUCTION DEPLOYMENT & FINAL VERIFICATION — completed after direct approval

The preceding blocked-push section is historical. The user explicitly approved pushing **only** `ac717243dad9c9631c5538726ed481adb63c3d43` to `https://github.com/mpiosik947/csk-booking.git`. A fresh `git fetch origin` confirmed local `main` ahead 1, behind 0, with the remote ancestor exactly the commit's parent. A plain, non-force `git push origin main` succeeded (`47c86f1..ac71724`). Afterwards `LOCAL HEAD = origin/main HEAD = ac717243dad9c9631c5538726ed481adb63c3d43`, divergence `0/0`. The deployed commit is the reviewed 14-file 9E-B scope (nine runtime/dependency, three test, two report/plan); `AGENTS.md` and both temporary probe paths were excluded. No SQL/migration or operational caller was in the commit.

The GitHub status for this exact commit reported `Vercel – csk-booking-5nwh: success` with the target deployment `CZZeGe9fjXRgra5w9YAoH283wFC1` and description “Deployment has completed.” The separate `Vercel – csk-booking` status failed, but that is **not** the target. The live target alias subsequently served the new `/t/csk` page and new module shells, establishing the target version rather than relying only on a green check.

Production GET smoke on `https://csk-booking-5nwh.vercel.app`:

| Path / class | Actual result | Contract |
|---|---|---|
| `/t/csk` public landing/layout | HTTP 200, public CSK heading and test-only venue landing | PASS; no operational data |
| `/t/csk/booking`, `/t/csk/events` public dispatcher | HTTP 200, explicit controlled “not yet switched” message, no business view/data | PASS |
| `/t/csk/my-reservations`, `/t/csk/admin` anonymous | HTTP 307 to `/login?redirectTo=...` for their own exact route | PASS; no implicit CSK fallback |
| `/t/csk/my-events` with existing signed-in user session | Controlled user shell and explicit CSK-only old-view link; no registration list fetched | PASS |
| `/t/csk/admin` with existing admin session | Controlled staff shell and explicit CSK-only old-view link; no admin business RPC/page reused | PASS |
| `/t/tenant-b`, `/t/INVALID`, `/t/tenant-b/admin` | 404; no CSK data substituted | PASS for unavailable/invalid slug |
| `/`, `/booking`, `/events`, `/account`, `/login` | HTTP 200, no 5xx | PASS basic reachability |
| old `/admin` | Anonymous 307 to login; existing admin session loaded operational dashboard without error | PASS backward compatibility |

The three deployed routing surfaces are `app/t/[slug]/layout.tsx`, `app/t/[slug]/page.tsx`, and `app/t/[slug]/[...path]/page.tsx`. The URL slug is still a server-resolved selector, not client authority. Auth user and staff shells require their respective Auth and active membership checks; `profiles.role` is not consulted by **new** routes. This smoke uses an existing session and no mutation; it does not claim a live two-active-tenant authorization test. Cross-tenant unavailable slug is fail-closed; new shells cannot issue a legacy CSK operational action. Existing CSK URLs remain unchanged. The local production build's client chunk scan found zero `tenant-context-core` or trusted membership helper references; both direct client-import negative builds denied, while server imports passed. The deployed source has `import "server-only"` in both facade and core.

After target Vercel reported success, a fresh **SELECT-only** query in production Supabase project `yuyxfodozzpzrdzkmolu` returned `active_tenants=1`, `active_csk=1`, second-active `guard=1`, exact-single-active `bridge_refs=22`, public `SECURITY DEFINER` count `70`, compatibility `defaults=7`. No migration, production SQL write, fixture or second-tenant activation occurred. The exact-single-active bridge remains active. 9E-C is not deployed. 4D-2 and 9D-5 remain blocked by their outstanding trusted operational caller and explicit-writer gates; SEC-004 remains open. The new report update is the sole post-commit working-tree change attributable to this verification; `AGENTS.md` remains a separate unrelated modification, unstaged. This post-deploy report is not yet a separate Git checkpoint.

### Final production verdicts

SAAS-9E-B APP DEPLOY: **PASS**
VERCEL DEPLOY: **PASS — target `csk-booking-5nwh`**
PRODUCTION VERSION: **NEW COMMIT ACTIVE — `ac717243dad9c9631c5538726ed481adb63c3d43`**
EXACT ROUTE/CALLER SCOPE: **3**
SERVER-ONLY BOUNDARY: **PASS**
CLIENT BUNDLE EXPOSURE: **0 in reviewed production build**
PUBLIC ROUTING: **PASS**
AUTH USER ROUTING: **PASS — existing signed-in session, transitional shell**
STAFF ROUTING: **PASS — existing admin session, transitional shell**
CSK DATA SUBSTITUTION UNDER FOREIGN SLUG: **ABSENT**
BACKWARD COMPATIBILITY: **PASS**
OPERATIONAL DB CALLER CUTOVERS: **0**
DB CHANGES: **0**
EXACT-SINGLE-ACTIVE BRIDGE REFERENCES: **22**
SECURITY DEFINER COUNT: **70**
COMPATIBILITY DEFAULTS: **7/7**
SECOND TENANT: **NO-GO**
READY FOR FINAL 9E-B CHECKPOINT: **YES — post-deploy report requires separate review/commit**
READY FOR 9E-C PLANNING: **GO**
READY FOR 9E-C IMPLEMENTATION: **NO-GO until checkpoint/review**
READY FOR 4D-2: **NO-GO**
READY FOR 9D-5: **NO-GO**
SEC-004: **OPEN**
