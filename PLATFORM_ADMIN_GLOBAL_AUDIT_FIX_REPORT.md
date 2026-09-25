# Platform Admin global audit contract fix

Date: 2026-09-25. LOCAL PASS. No staging, commit, push, deployment, production SQL or real-account bootstrap.
Source HEAD: 6a0a01183760757c2ea5e303eceaa3f05b279e3b.

## Migration and scope

New forward-only migration: `20261009150000_add_global_platform_bootstrap_audit.sql`.
SHA-256: `D88E7776AE7A06A15AA23DBBD5F776F1DE6CBA700F8F079239258D6A8262AA90`.
Ordered immediately after deployed 20261009140000 and before frozen 20261010100000 TCM. No existing timestamp or historical migration changed.

Task files:
- this report;
- new migration;
- `supabase/tests/20261009150000_global_platform_bootstrap_audit_test.sql`;
- `scripts/platform-bootstrap-isolated-check.mjs`;
- `tests/e2e/platform-onboarding.spec.ts`;
- exact new function inventory entry/count in `supabase/tests/20260816143000_harden_public_function_execute_acl_test.sql`;
- exact new closed audit-writer allowlist entry/count in `supabase/tests/20260903100000_harden_audit_log_integrity_test.sql`.

The two historical test files also contain pre-existing frozen TCM hunks in the main worktree. Those are preserved and excluded from this task. Tests were run on the clean pre-TCM candidate with only this patch applied. No application or TCM source edits. No production reads/writes were needed in this local task.

## Integrity and provisioning

`platform_audit_logs.tenant_id` becomes nullable only with a compensating validated scope CHECK. All eight existing tenant-scoped actions still require both tenant_id and actor_user_id. The sole new action `platform_admin_bootstrapped` requires tenant_id NULL and actor_user_id NULL. Its details require a target identity, provisioning_role=postgres and a nonempty session_role. The target is initially an exact UUID; the existing account-wide redaction pseudonym is also accepted so anonymization remains functional. Unique partial index prevents duplicate bootstrap audit targets.

actor_user_id is nullable for this operator action because no authenticated human actor is invented. Database current_user and session_user are recorded automatically. These identify the DB execution identity, not a distinct human behind shared DB credentials. Human approval attribution must remain in the operator change record. No email, profile data, token or secret is placed in the event.

`public.operator_bootstrap_platform_admin_v1(uuid)` is SECURITY INVOKER, owned by postgres, fixed search_path pg_catalog/public/pg_temp. PUBLIC, anon, authenticated and service_role have no EXECUTE. It also checks current_user=postgres and auth.uid() IS NULL. It is not called by app UI. Tenant/admin/global-profile roles never authorize it. PostgreSQL administrators able to SET ROLE postgres are within the trusted operator boundary, not tenant/client roles.

The exact target auth row is locked FOR UPDATE, serializing provisioning/account mutations. Null/missing/deleted/banned/anonymous/unconfirmed accounts fail. No user is selected by email or fallback. An absent authority row is inserted active together with the global audit in the same statement/transaction. Audit failure rolls authority back. An already-active row with exactly one bootstrap event returns already_assigned without duplicate audit. Suspended authority or missing audit fails closed rather than silently reactivating/repairing it.

Future execution requires separate production migration/preflight approval, then separate bootstrap authorization for an exact existing UUID. Use a privileged maintenance transaction as postgres without user JWT, verify account identity and expected unchanged state, invoke the function once and verify role/audit before committing. Do not grant EXECUTE to application roles, expose an endpoint or mutate memberships/profiles as a workaround.

Target selected by user: c118d4de-7f5c-42bd-a9ab-2696c0a526aa. Last production lookup: confirmed active account, no Platform Admin assignment, CSK admin/active. This task did not re-query or mutate that account; it is not embedded in migration or fixtures.

## Local evidence

Isolated Windows Docker replay: 125 migrations through 20261009150000, TCM absent, SECURITY DEFINER unchanged at 97. Fresh scratch DB and synthetic identities only; no existing DB reset.

- Focused SQL: 39/39 PASS. Includes role/client denials, bad-account denials, atomic audit failure, idempotency, scope constraints for all eight tenant actions, profile/membership invariants, account anonymization, and cleanup.
- Full pre-TCM DB: 1929/1929 PASS across 63 files.
- Existing onboarding concurrency regression: 6/6 PASS, deadlocks=0. Bootstrap's serialization is implemented by target-row locks; no separate high-load bootstrap stress test claimed.
- Node: 817/817 PASS.
- Playwright no-TCM: 2/2 PASS. Synthetic operator bootstrap replaces direct fixture authority INSERT; service-role REST invocation denied; repeated operator call returns already_assigned. Platform UI/onboarding/tenant setup and protected routes remain functional.
- TypeScript: PASS.
- Production webpack build: PASS.
- ESLint changed JS/TS files: PASS, zero errors/warnings.
- git diff --check: PASS; staging empty.
- Schema comparison before/after SQL/E2E: no residual schema changes. Expected new migration DDL was applied during full replay, not mistaken for zero schema delta.
- Focused/E2E/concurrency fixture cleanup: 0; temporary Auth/REST containers removed=2; scratch database remaining=0.

Initial full-suite failure was the expected exact inventory mismatch for the added closed INVOKER writer; only that entry/count was added, preserving ACL/owner/search_path checks. Initial E2E failure was the explicit old migration-head assertion 09140000; it now asserts 09150000, still requires no TCM and 97 DEFINER. Final full rerun passed.

PRODUCTION WRITE: NO.
BOOTSTRAP PERFORMED: NO for the real target (synthetic local tests only).
TCM: FROZEN. CSK membership/profiles.role/plans/entitlements/tenant lifecycle/DNS/second production tenant: unchanged by this task.
LOCAL RESULT: PASS.
READY FOR PRODUCTION PREFLIGHT: YES, isolated scope must exclude TCM.

## Production preflight retry — 2026-09-25

PASS. HEAD and live origin/main both `6a0a01183760757c2ea5e303eceaa3f05b279e3b`; branch main. No staging or Git history changes.

Isolated CLI workspace: `C:/Users/Mpios/Desktop/APP Krutla/global-bootstrap-preflight-20260925`. Contains 125 byte-verified migration copies through 09150000, no TCM. Project ref verified as `yuyxfodozzpzrdzkmolu`. SHA remains `D88E7776AE7A06A15AA23DBBD5F776F1DE6CBA700F8F079239258D6A8262AA90`.

Live migration history: 124 matched rows through `20261009140000`, no mismatch/remote-only rows, exactly one pending `20261009150000`. Dry-run explicitly reported only `20261009150000_add_global_platform_bootstrap_audit.sql`. Main mixed worktree still also contains the frozen TCM migration; the one-pending claim applies exclusively to the isolated approved scope.

Production READ ONLY transaction confirmed: DEFINER=97, new bootstrap function absent, Platform Admin count=0, tenant count=1, existing audit action CHECK exactly the original eight actions, invalid audit rows=0, audit owner postgres/RLS enabled/client grants=0, platform PUBLIC EXECUTE=0, both technical-table service_role ACLs empty. No drift detected in these checked baseline surfaces; this is not a claim of an unrestricted whole-production schema comparison.

Fresh no-TCM local gate repeated: focused 39/39; full DB 1929/1929; concurrency 6/6 (deadlocks=0); Node 817/817; Playwright 2/2; TypeScript, production webpack build, changed-file ESLint and git diff --check PASS. Before/after SQL and E2E schema comparisons show zero residual changes. Fixtures=0, temporary Auth/REST containers removed=2, scratch database remaining=0.

Patch has no data-loss DDL, grants or historical migration edits. Relaxed NOT NULL columns are protected by validated action/scope constraints; all existing tenant actions retain tenant/actor requirements. Local target remains DEFINER=97 because new operator function is INVOKER. Operator execution/atomicity/idempotency/audit rollback passed locally; browser/authenticated/tenant admin/service_role execution denied. These are target tests, not claims that the still-absent function was executed on production.

PRODUCTION WRITE: NO. BOOTSTRAP: NOT PERFORMED. TCM: EXCLUDED/FROZEN.
PREFLIGHT RESULT: PASS. READY FOR DEPLOYMENT: YES, subject to separate authorization and repeat final gate. READY FOR BOOTSTRAP AFTER DEPLOY: YES only after successful deployment verification and separate explicit exact-UUID authorization with fresh account eligibility checks.
