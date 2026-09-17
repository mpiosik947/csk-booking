# SAAS-9D-4C APP-FIRST COMPATIBILITY REPORT

## 1. Authoritative scope

The 4C database phase remains limited to exactly three account-owner RPCs:

1. `update_my_profile_v1(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)`;
2. `export_my_data_v1()`;
3. `anonymize_my_account_v1()`.

This APP-FIRST phase changes none of them. It prepares only the application
contract required before the future export-v2 database body can be deployed.

## 2. Corrected rollout order

The authoritative order is **TWO-STEP / APP-FIRST**:

1. deploy the strict dual v1/v2 export validator;
2. production-smoke the current v1 export;
3. only after that approval, implement and deploy the exact three-function DB
   migration.

`OLD APP + NEW DB` remains unsafe because the former validator accepts only the
six-key v1 payload. No migration or production action belongs to this phase.

## 3. Application file inventory

| File | Caller / responsibility | Current RPC / response | APP-FIRST action |
|---|---|---|---|
| `app/account/page.tsx` | Owner UI for profile update, export and deletion | `update_my_profile_v1`; downloads `/api/account/export`; posts `/api/account/delete` | No change. Future DB bodies preserve both RPC result contracts. Regression tested. |
| `app/api/account/export/route.ts` | Authenticated, parameterless account export | Calls `export_my_data_v1()`, validates with `isAccountExportPayload`, returns no-store attachment | No route change. The imported validator now accepts exact v1 and exact v2. |
| `app/api/account/delete/route.ts` | Owner-confirmed account deletion | Calls `anonymize_my_account_v1()`, then performs server-only Auth Admin deletion | No change. The future DB result remains `anonymized` / `already_anonymized`. Regression tested. |
| `lib/server/account-lifecycle.js` | Export and deletion response contracts | Exact v1 top-level contract; recursive forbidden-key check | Adds strict discriminated v1/v2 structural validation. |
| `lib/server/account-lifecycle.d.ts` | Type contract | v1 payload only | Adds explicit v1/v2 union and tenant-relationship type. |
| `lib/server/account-lifecycle.test.mjs` | Focused lifecycle contract | v1 and deletion tests | Adds realistic v1, valid v2, malformed, semantic, duplicate and PII-negative cases. |
| `tests/e2e/account-lifecycle-compatibility.spec.ts` | Browser/API regression | none previously | Adds `/account` availability and anonymous export/delete fail-closed smoke. |

## 4. Current v1 contract

Version 1 keeps exactly these top-level fields:

- `export_version = 1`;
- `generated_at`;
- `account`;
- `profile`;
- `reservations`;
- `event_registrations`.

The validator now also checks the exact allowlisted nested keys and their
scalar/nullability contracts as emitted by the current production SQL. Extra
keys, malformed row objects and forbidden security fields fail closed.

## 5. Target v2 contract

Version 2 keeps every v1 block and adds exactly one required top-level array:
`tenant_relationships`.

Each array element is exactly:

```text
{
  tenant: { id, name, slug },
  membership: { role, status, created_at, updated_at },
  verification: null | {
    status, permissions_verified, permissions_verified_at, updated_at
  }
}
```

Allowed membership roles are `admin`, `employee`, `user`, `instructor`.
Allowed membership states are `active`, `pending`, `suspended`. Verification
states are `pending`, `verified`, `rejected`. A true `permissions_verified`
requires `verified`. Tenant IDs cannot repeat in one export.

The payload does not include admin notes, verification notes, staff actor IDs,
audit data, tokens, claims, rate-limit internals, secrets or another user's
rows.

## 6. Dual validator design

The validator is a strict discriminated union keyed by `export_version`.
Version 1 must have exactly six top-level fields. Version 2 must have exactly
those six plus `tenant_relationships`. There is no permissive fallback,
passthrough or unchecked `unknown` result. Both versions share the same strict
base DTO validators and recursive forbidden-key rejection.

## 7. Export compatibility

- current empty and populated production-shaped v1 fixtures: PASS;
- exact target v2 with and without a verification row: PASS;
- missing v2 relationships, wrong types or incomplete nested objects: DENY;
- duplicate tenant IDs and contradictory verified state: DENY;
- staff-only notes, tokens and extra top-level data: DENY.

The endpoint remains owner-authenticated, accepts no user or tenant parameter,
uses the caller JWT, and retains attachment/no-store/nosniff behavior.

## 8. Delete compatibility

No app change is required. `executeAccountDeletion` still requires the exact
`anonymized` or `already_anonymized` result before Auth deletion. Service-role
use remains isolated to `auth.admin.deleteUser()` after successful DB work.

## 9. Update-profile compatibility

No app change is required. The 16-argument signature and result fields consumed
by `/account` remain unchanged. Static regression tests confirm that only the
owner contact/declaration allowlist is submitted.

## 10. Account-wide security contract

Identity authority remains `auth.uid()`. Export, profile update and account
deletion are account-owner operations, not tenant-admin workflows. The new
validator treats tenant IDs only as exported data; it grants no authority and
introduces no selected-tenant input. Leave-tenant remains a separate future
contract.

## 11. PII and cross-tenant boundary

The v2 extension exposes only the owner's own allowlisted tenant relationship
and operational verification state. It rejects staff notes, verification notes,
staff actor identifiers, audit internals and foreign rows. Exact nested keys
prevent silent PII expansion.

## 12. Compatibility matrix

| State | Result |
|---|---|
| OLD APP + OLD DB | Current production; reference only |
| NEW APP + OLD DB | PASS — current v1 is accepted |
| NEW APP + target v2 fixture | PASS |
| OLD APP + NEW DB | UNSAFE BY CONTRACT |
| NEW APP + NEW DB | Expected PASS; DB phase still blocked pending app production PASS |

## 13. Tests

- focused lifecycle/API/account Node tests: `19/19` PASS;
- full Node suite: `750/750` PASS;
- TypeScript: PASS after sequential run;
- production build: PASS;
- changed-files ESLint: PASS, zero warnings;
- focused Playwright: `1/1` PASS;
- `npm audit --omit=dev --offline`: `0` vulnerabilities;
- external registry audit: not run because the execution environment rejected
  dependency-metadata egress;
- `git diff --check`: PASS.

The database and all SQL tests are unchanged. No DB test was required for this
application-only gate.

## 14. Git status

The implementation is intentionally unstaged and uncommitted. `AGENTS.md`
remains unrelated, excluded and unstaged. The plan file was already modified by
the approved planning task and now includes this implementation checkpoint.

## 15. Exact residual for DB phase

After APP-FIRST production PASS, the DB phase must replace only the bodies of
the exact three RPCs under normalized fingerprint guards. It must emit the
frozen v2 relationship shape above, harden declaration invalidation and fully
clean tenant relationships during anonymization. Signatures, owner, SP1 ACL,
caller compatibility, SECURITY DEFINER count `69` and defaults `7/7` remain
unchanged. Production write requires a separate approval.

## 16. Final verdict

SAAS-9D-4C APP-FIRST LOCAL: **PASS**

EXACT FUNCTION SCOPE: **3**

APP SCOPE: **PASS**

DUAL VALIDATOR: **PASS**

CURRENT V1 ACCEPTED: **PASS**

TARGET V2 ACCEPTED: **PASS**

MALFORMED V1/V2 REJECTED: **PASS**

ACCOUNT-WIDE CONTRACT: **PRESERVED**

CROSS-TENANT DATA BOUNDARY: **PASS**

PII: **PASS**

NEW APP + OLD DB: **PASS**

OLD APP + NEW DB: **UNSAFE BY CONTRACT**

DB CHANGES: **0**

APP CHANGE REQUIRED: **YES**

READY FOR APP-FIRST PRODUCTION PREFLIGHT: **GO**

READY FOR DB PHASE LOCAL IMPLEMENTATION: **NO-GO until app-first production PASS**

READY FOR PRODUCTION WRITE: **NO**

READY FOR 4D / 4E: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 17. Production preflight & APP-FIRST deployment readiness

### 17.1 Working tree

The canonical semantic implementation scope is exactly six files:

| File | Classification |
|---|---|
| `lib/server/account-lifecycle.js` | 4C APP-FIRST runtime validator |
| `lib/server/account-lifecycle.d.ts` | 4C APP-FIRST validator/types |
| `lib/server/account-lifecycle.test.mjs` | 4C APP-FIRST focused Node test |
| `tests/e2e/account-lifecycle-compatibility.spec.ts` | 4C APP-FIRST Playwright test |
| `SAAS_9D_4C_APP_FIRST_COMPATIBILITY_REPORT.md` | 4C report |
| `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md` | 4C authoritative plan/checkpoint |

`AGENTS.md` is a separate pre-existing semantic diff. It remains unrelated,
excluded and unstaged. No other tracked or untracked semantic diff exists.
`git diff --check` passes; the Windows Git messages about future LF-to-CRLF
conversion are line-ending notices, not additional content changes.

### 17.2 Exact application scope

| File/area | Runtime or test | Current role | Change | v1 impact | v2 impact | PII impact |
|---|---|---|---|---|---|---|
| `account-lifecycle.js` | runtime | validates account lifecycle RPC results | strict v1/v2 discriminated export validator | accepted unchanged | accepted only in approved shape | rejects unknown/forbidden fields recursively |
| `account-lifecycle.d.ts` | runtime types | describes export result | exact v1/v2 union and tenant relationship DTOs | unchanged DTO | typed approved extension | no new fields beyond contract |
| `account-lifecycle.test.mjs` | test | lifecycle unit/regression coverage | positive and negative compatibility matrix | source-exact v1 fixtures pass | valid v2 fixtures pass | forbidden PII fails closed |
| `account-lifecycle-compatibility.spec.ts` | test | browser/account contract smoke | verifies current account/export/delete compatibility | preserved | rollout readiness only | no payload values logged |
| report and plan | documentation | rollout evidence and authoritative phase scope | records APP-FIRST gate | none | blocks DB-first rollout | none |

There are no unrelated UI or product changes.

### 17.3 No-DB-change gate

- new migrations: `0`;
- modified migrations: `0`;
- SQL/function changes: `0`;
- Supabase production writes during preflight: `0`.

A read-only production inventory returned `SECURITY DEFINER = 69` and all
`7/7` approved compatibility defaults. Production therefore remains at the
deployed post-4B-2C database state.

### 17.4 Current production v1 contract

The current deployed v1 shape has the exact six top-level keys documented in
section 4. Required arrays and object fields, primitive types and approved
nullable fields are represented by the strict v1 schema. There was no observed
shape drift.

Production evidence was deliberately PII-minimizing:

- the real authenticated `/account` export action completed successfully;
- the current v1 RPC definition and caller contract remain unchanged;
- empty and fully populated source-exact v1 payloads pass the new validator;
- no personal response body was copied into the report or terminal output.

The in-app browser isolates authenticated response bodies from the filesystem,
so the raw personal download was not exported merely to create evidence. The
combination of a real endpoint success and validation of the exact deployed v1
schema establishes the compatibility gate without disclosing account data.

### 17.5 Target v2 contract

The authoritative v2 contract is v1 plus required `tenant_relationships`.
Relationships use only the allowlisted tenant identity, membership role/state
and operational verification fields from section 5. Tenant IDs must be unique;
membership and verification states must be internally consistent. Valid v2
fixtures, with and without an approved verification row, pass.

### 17.6 Strict validation matrix

| Case | Result |
|---|---|
| malformed v1 | DENY |
| malformed v2 | DENY |
| unknown top-level field | DENY |
| unknown tenant relationship field | DENY |
| wrong primitive type | DENY |
| duplicate tenant relationship | DENY |
| contradictory tenant state | DENY |
| missing required v2 structure | DENY |
| unexpected PII field | DENY |

There is no permissive fallback, coercive compatibility mode or unchecked
`any`-style acceptance.

### 17.7 Compatibility and rollout order

- **NEW APP + OLD DB: PASS.** The new build accepts the current v1 contract;
  `/account`, `/api/account/export` and the unchanged deletion contract remain
  compatible.
- **OLD APP + NEW DB: UNSAFE BY CONTRACT.** The DB phase must not be deployed
  before the new app is confirmed active in production.
- `/api/account/delete` was checked only by a safe non-mutating request. No
  account deletion or anonymization was triggered.
- The `/account` caller and the 16-argument `update_my_profile_v1` contract are
  unchanged.

### 17.8 Account-wide security and PII boundary

`update_my_profile_v1`, `export_my_data_v1` and
`anonymize_my_account_v1` remain owner/account-wide operations deriving
identity from `auth.uid()`. Tenant administrators gain no global account
authority. Exported tenant IDs are data, never authorization input.

The validator rejects foreign-user merging, duplicate/collapsed tenant
relationships, staff-only notes, verification notes, actor identifiers,
tokens, audit internals and any unapproved nested or top-level field.

### 17.9 Local evidence reconfirmed

- focused Node: `19/19` PASS;
- full Node: `750/750` PASS;
- TypeScript: PASS;
- production build: PASS;
- changed-files ESLint: PASS, `0` warnings;
- focused Playwright: `1/1` PASS;
- `npm audit --omit=dev --offline`: `0` vulnerabilities;
- `git diff --check`: PASS.

The online registry audit was not substituted with a workaround after the
execution policy rejected dependency-metadata egress.

### 17.10 Production runtime baseline

Read-only pre-deployment smoke produced:

| Target | Result |
|---|---|
| `/account` authenticated UI | PASS, no 5xx |
| authenticated account export action | PASS, controlled success |
| `/api/account/export` anonymous | controlled `401` |
| `/api/account/delete` safe GET | controlled `405`; no mutation |
| `/login` | `200` |
| `/admin` anonymous HTTP | controlled `307` redirect |
| `/` | `200` |

The Vercel response baseline included `x-vercel-id`
`arn1::2rw9g-1789676321084-5333acb245ea`. No 5xx was observed.

### 17.11 Deployment mechanism and version baseline

The approved deployment path remains `main -> origin/main -> Vercel`. No direct
Vercel CLI workflow is introduced.

- branch: `main`;
- local HEAD: `16a9ab46765638dd993b5b4ee3a39230568d865d`;
- live `origin/main` HEAD: `16a9ab46765638dd993b5b4ee3a39230568d865d`;
- divergence: `0/0`;
- proposed deploy commit scope: exactly the six files in section 17.1;
- `AGENTS.md`: excluded and must remain unstaged.

### 17.12 Deployment risk and blockers

Deployment risk is **LOW**. The deployment is application-only, keeps current
v1 behavior, adds a narrowly scoped future-v2 validator, changes no DB contract
and can be rolled back by reverting the application commit. Strict validation
intentionally converts unexpected contract expansion into a controlled failure
instead of silently accepting additional data.

Blockers before the APP-FIRST Git deploy commit: **none**. The DB phase remains
blocked until the new application commit is deployed and independently passes
production verification.

## 18. Production preflight final verdict

SAAS-9D-4C APP-FIRST PRODUCTION PREFLIGHT: **PASS**

WORKING TREE SCOPE: **PASS**

APP SCOPE: **PASS**

DB CHANGES: **0**

CURRENT PROD V1 CONTRACT: **PASS**

DUAL VALIDATOR: **PASS**

CURRENT V1 ACCEPTED: **PASS**

TARGET V2 ACCEPTED: **PASS**

MALFORMED V1/V2 REJECTED: **PASS**

CROSS-TENANT DATA BOUNDARY: **PASS**

PII: **PASS**

ACCOUNT-WIDE CONTRACT: **PRESERVED**

NEW APP + OLD DB: **PASS**

OLD APP + NEW DB: **UNSAFE BY CONTRACT**

STANDARD DEPLOYMENT PATH: **PASS**

READY FOR APP-FIRST GIT DEPLOY COMMIT: **YES**

READY FOR DB PHASE LOCAL IMPLEMENTATION: **NO-GO until production app PASS**

READY FOR PRODUCTION DB WRITE: **NO**

READY FOR 4D / 4E: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**
