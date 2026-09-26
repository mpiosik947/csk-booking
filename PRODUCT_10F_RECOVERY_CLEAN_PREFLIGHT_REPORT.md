# PRODUCT-10F RECOVERY — CLEAN CANDIDATE PREFLIGHT

Base: 541e195e45a2c2fb5b190506a820be1cafd3cab4 (fresh origin/main).
Branch: recovery-clean-preflight-20260926.
Status: PASS — clean candidate + read-only production preflight, 2026-09-26.

## Exact source manifest

Raw files: 62. The user-mentioned 52 is not the current inventory.
Included source files: 61. New preflight report is one additional F document.

A runtime; B migration; C SQL regression; D repeatable Node/Playwright/local DB tests; E approved Account Header and required dependencies; F report; G excluded.

| File | Category |
| --- | --- |
| `app/account/page.tsx` | E |
| `app/dashboard/page.tsx` | E |
| `app/reset-password/page.tsx` | A |
| `lib/password-policy.test.mjs` | D |
| `middleware.ts` | A |
| `supabase/tests/20260816143000_harden_public_function_execute_acl_test.sql` | C |
| `supabase/tests/20260902120000_harden_public_table_sequence_acl_test.sql` | C |
| `supabase/tests/20260909110000_backfill_csk_tenant_ownership_test.sql` | C |
| `supabase/tests/20260909130000_tenant_relationship_integrity_test.sql` | C |
| `supabase/tests/20260913100000_harden_event_management_rpcs_test.sql` | C |
| `supabase/tests/20260913150000_harden_public_event_readers_test.sql` | C |
| `supabase/tests/20260914100000_harden_shared_confirmation_email_rpcs_test.sql` | C |
| `supabase/tests/20260914150000_harden_event_reserve_promotion_rpcs_test.sql` | C |
| `supabase/tests/20260915100000_harden_lane_block_rpcs_test.sql` | C |
| `supabase/tests/20260916100000_harden_lane_family_creation_readers_test.sql` | C |
| `supabase/tests/20260917100000_harden_lane_family_writer_helpers_test.sql` | C |
| `supabase/tests/20260918100000_harden_admin_reservation_reports_test.sql` | C |
| `supabase/tests/20260919100000_add_tenant_user_admin_notes_test.sql` | C |
| `supabase/tests/20260919150000_harden_tenant_user_role_identity_contact_test.sql` | C |
| `supabase/tests/20260920100000_add_tenant_user_verification_foundation_test.sql` | C |
| `supabase/tests/20260920150000_cutover_tenant_user_verification_test.sql` | C |
| `supabase/tests/20260921100000_close_legacy_global_verification_path_test.sql` | C |
| `supabase/tests/20260922100000_harden_account_lifecycle_rpcs_test.sql` | C |
| `supabase/tests/20260923100000_harden_profile_privilege_trigger_test.sql` | C |
| `supabase/tests/20260924100000_harden_public_booking_configuration_test.sql` | C |
| `supabase/tests/20260925100000_add_public_active_tenant_resolver_test.sql` | C |
| `supabase/tests/20260926100000_add_tenant_scoped_operational_readers_test.sql` | C |
| `supabase/tests/20260927100000_add_tenant_scoped_staff_event_rpcs_test.sql` | C |
| `supabase/tests/20260927110000_add_tenant_scoped_lane_configuration_rpcs_test.sql` | C |
| `supabase/tests/20260927120000_add_tenant_scoped_admin_reports_test.sql` | C |
| `supabase/tests/20260927130000_add_tenant_scoped_admin_users_test.sql` | C |
| `supabase/tests/20260928100000_add_c3_owner_calendar_and_global_profile_contracts_test.sql` | C |
| `supabase/tests/20260929100000_close_global_role_helper_execute_test.sql` | C |
| `supabase/tests/20260930110000_tenant_aware_onboarding_cutover_test.sql` | C |
| `supabase/tests/20261001100000_retire_single_tenant_compatibility_test.sql` | C |
| `supabase/tests/20261003100000_remove_single_active_tenant_guard_test.sql` | C |
| `supabase/tests/20261004100000_add_public_tenant_directory_test.sql` | C |
| `supabase/tests/20261005100000_add_public_tenant_landing_test.sql` | C |
| `supabase/tests/20261006100000_add_tenant_public_settings_test.sql` | C |
| `supabase/tests/20261007100000_add_saas_feature_entitlements_test.sql` | C |
| `supabase/tests/20261008100000_harden_cancellation_tenant_authority_test.sql` | C |
| `supabase/tests/20261011100000_verified_tenant_domains_test.sql` | C |
| `PRODUCT_10F_RECOVERY_HARDENING_REPORT.md` | F |
| `app/_components/GlobalAccountHeader.tsx` | E |
| `app/auth/confirm/route.ts` | A |
| `app/auth/recovery/legacy/route.ts` | A |
| `app/auth/recovery/route.ts` | A |
| `auth-email-proposals/recovery.html` | G |
| `lib/server/recovery-context.test.mjs` | D |
| `lib/server/recovery-context.ts` | A |
| `lib/server/recovery-grant-mint.ts` | A |
| `lib/server/recovery-http.ts` | A |
| `lib/server/recovery-routes.test.mjs` | D |
| `playwright.account-header.config.ts` | E |
| `playwright.recovery.config.ts` | D |
| `scripts/recovery-grant-concurrency.mjs` | D |
| `scripts/recovery-grant-live-check.mjs` | D |
| `scripts/recovery-grant-local-replay.mjs` | D |
| `supabase/migrations/20261012100000_add_one_time_recovery_grants.sql` | B |
| `supabase/tests/20261012100000_one_time_recovery_grants_test.sql` | C |
| `tests/e2e/global-account-header.spec.ts` | E |
| `tests/e2e/recovery-hardening.spec.ts` | D |

The large count comes primarily from exact full-DB inventory assertions: 3 additional SECURITY DEFINER functions (104 -> 107), one closed global table, exact role ACL allowlists; two old fingerprint checks now normalize CRLF/CR. Historical migration bodies remain unchanged.

Account Header's two frozen files require the already-reviewed GlobalAccountHeader component and /account integration plus its test configuration. They are category E, not unrelated work. Source and fresh origin share the same base, so reviewed file blobs can be copied without reverting intervening code.

Excluded: email-template proposal (future Phase C/D, no template change here); outside-source recovery-race-audit.cjs, logs, existing CSK mixed repository, drafts, AGENTS.md modifications. Base-tracked files remain unchanged.

## Totals and extraction verification

Source: `C:/Users/Mpios/Desktop/APP Krutla/branding-clean-review`.
Clean candidate: `C:/Users/Mpios/Desktop/APP Krutla/recovery-clean-preflight`.
Fresh fetch before extraction AND final fetch: origin/main =
`541e195e45a2c2fb5b190506a820be1cafd3cab4`; candidate HEAD/base identical; divergence 0/0.

62 raw changed files, 61 included source files, 1 excluded source file. This
preflight report adds one F file: **62 final checkpoint files**.

- A required runtime: 8.
- B new migration: 1.
- C required SQL tests: 38 (37 existing regression files + 1 focused test).
- D required test files/config/scripts: 8.
- E approved Account Header and dependencies: 5.
- F reports: 2 including this report.
- G excluded source: 1 (`auth-email-proposals/recovery.html`).

All 61 copied blobs were hash-compared to their reviewed source; source and target
share the exact fresh origin base. No application implementation changed during
extraction. Existing public landing, CSK visual, canonical auth callback,
forgot-password and platform-domain files have zero diff against base. The only
middleware hunk is the legacy code interception before browser initialization.
No staged files. No commits, pushes, rebase, reset or deployment.

Frozen hashes preserved byte-for-byte:

- dashboard: `9AE5B1DAAFBABF68AED2863B888F6C18BE97B190D73D20904B2A344624C4C800`.
- Account Header test: `BB92288C7C6D80196C0BB1F83EE09EBF7D70C7BD6E388F53F2BA9342458E12EE`.

`.env.local`, node_modules junction and Supabase link metadata are ignored local
execution dependencies, NOT checkpoint files. Logs/temporary catalog SQL/JSON
live outside candidate and are excluded. No production credentials were copied
into tracked files or printed.

## Migration and live production preflight

Project: `yuyxfodozzpzrdzkmolu` / csk-booking, main PRODUCTION.
Migration: `20261012100000_add_one_time_recovery_grants.sql`.
SHA-256: `A3E02BE30BE5D9A2DD6E8C3864988DE078CB694324C6EDD16E6054E7B1C4F7A2`.

Live migration list: all **127** deployed versions match local through
**20261011100000**. Exactly one pending: **20261012100000**. No unexpected remote
version. Final `supabase db push --linked --dry-run` explicitly reports that
migrations will NOT be pushed and lists only the recovery migration.

Production catalog was read in BEGIN READ ONLY / ROLLBACK. Baseline SD **104**;
local target **107**. Existing 166 function signatures, normalized definitions,
owners, security modes, search_path and ACLs match the canonical local target.
All 28 existing public-table owner/RLS/ACL records match. Public function EXECUTE
grants = 0. Unexpected grants in this comparison = 0. No conflicts for the new
table/index/function names. Active production tenants = 1.

Auth schema assumptions verified live and identical to local:
auth.sessions.id/user_id UUID NOT NULL; not_after nullable timestamptz;
auth.users.id UUID, deleted_at/banned_until nullable timestamptz,
is_anonymous boolean NOT NULL. No auth rows/emails/tokens were queried.

DRIFT = 0 in migration history, existing function contracts and public table
ACL/RLS/ownership. This is not a claim to have compared every production data row
or every unrelated table index. Historical tracked migration diff = NONE.

Forward-only new table/functions/indexes only; no destructive alteration of
existing business data. New table RLS enabled, no policies; all direct table
privileges revoked from PUBLIC/anon/authenticated/service_role. Only hash,
user/session UUID and timestamps persist. FK ON DELETE CASCADE removes grants
when an auth user/session is deleted, never deletes the parent. Unique hash PK;
expiry index supports bounded retention cleanup; session index supports cascade.

Mint signature accepts session_id/hash, no user_id/TTL. DB resolves user and
checks existing nonexpired session plus nondeleted/nonbanned/nonanonymous user.
TTL exactly 600 seconds, DB-generated. Mint EXECUTE only service_role among app
roles; check/consume only authenticated. PUBLIC and anon deny on all three;
service_role denied check/consume. postgres owner has inherent owner privileges.
All 3 definers owned by postgres with empty fixed search_path and qualified
relations. Atomic conditional UPDATE permits exactly one consume before password
mutation. A mutation failure burns the grant; no fail-open retry.

## Service-role review

Runtime references inventoried:

1. `lib/server/recovery-grant-mint.ts`: explicit server-only import, private env,
   only immediate post-verification callers in confirm and legacy handlers.
2. `lib/server/event-reserve-promotion.ts`: existing explicit server-only module.
3. `lib/server/confirmation-email-delivery.ts`: existing server helper; no explicit
   server-only marker, but all runtime importers are three server API handlers.
4. `app/api/account/delete/route.ts`: existing server route, verified user before
   Auth admin deletion; not modified by this candidate.

Remaining textual references are local fixtures, tests and test-server config.
No NEXT_PUBLIC service-key variable, client prop serialization, response return
or key logging found. Candidate build **93 client chunks checked** against the
actual local key and private env identifier: **0 matches**. Service-role exposure
= **0** in reviewed code/bundle. Production secret values were not retrieved.
Before Phase A app rollout, confirm private Production env availability; never
rename it to NEXT_PUBLIC or print its value.

## Exact clean-candidate tests

| Gate | Result |
| --- | --- |
| Focused SQL | 39/39 PASS |
| Full DB historical replay | 2052/2052 PASS, 66 SQL files |
| DB concurrency | exactly 1 winner / 7 denied, deadlocks 0 |
| Real Auth + DB fault matrix | 3/3 PASS |
| Targeted Node | 16/16 PASS |
| Full Node | 859/859 PASS |
| Playwright recovery/auth | 5/5 PASS |
| Playwright Account Header | 2/2 PASS |
| TypeScript | PASS |
| Production Build (webpack) | PASS |
| ESLint all changed JS/TS scope | PASS, no diagnostics |
| Diff check | PASS |
| Replay/local schema equivalence | diff 0 after newline normalization |
| Post-test schema | diff 0 |
| Fixture cleanup | 0 recovery grants/users; scratch DB removed; E2E fixture cleanup passed |

Evidence outside checkpoint: `../recovery-clean-{db,node,targeted,fault,build,eslint,playwright,account-header}.log`,
`../recovery-clean-dryrun.log` and read-only catalog JSONs.

Legacy same-browser ConfirmationURL flow: PASS, exactly one server exchange,
no browser exchange. Separate-browser legacy link denies safely (PKCE limitation
intentionally remains until Phase C). TokenHash independent browser flow: PASS.
Refresh same logical session: PASS. Different user/session, expired, consumed,
direct reset, ordinary session, external next and forged Origin: DENY.
Captured-cookie replay: DENY, including a real valid Auth session with injected
signOut failure. Concurrent actual handler/DB attempts invoke mutation once.
Injected update failure burns grant and requires fresh link.

The tests prove compatibility with the **current template mechanism**, not an
already-deployed candidate. No physical phone or production email was used.

## Current production email — read-only UI evidence

Supabase Reset password editor showed `href="{{ .ConfirmationURL }}"`.
Subject: **Reset hasła do CSK Booking**. SMTP sender name: **CSK Booking**.
Both Save controls remained disabled; no template/settings write occurred.
TokenHash template is NOT active. New code supports it but automated email flow
remains on legacy until separately authorized Phase C.

## Deployment plan — NOT EXECUTED

**Phase A — DB + dual-flow app**

After separate approval: refetch/race-check origin, verify this exact manifest and
migration SHA, precise staging/commit/fast-forward only. Recheck remote head and
single pending migration. Apply recovery migration before exposing new app code.
Account for Git-triggered Vercel autodeploy: sequence/promotion must not expose
the app before DB contracts exist. Target only csk-booking-5nwh. Verify SD107,
ACLs, zero pending and no unexpected drift; verify private server env without
revealing key. Leave email template/sender unchanged. Run read-only smoke and
controlled authorized recovery checks. No DNS/tenant/domain changes.

**Phase B — live legacy smoke**

Use an explicitly approved account/device to request one email and follow it in
the same browser. Verify exactly one exchange, clean URL, password update,
logout and reuse denial. User performs real credential entry/change. STOP on
legacy regression; do not advance template.

**Phase C — recovery template**

Only after A/B PASS and separate approval, use TokenHash link to canonical
`https://strzelajtu.pl/auth/confirm` with type=recovery and fixed reset next.
Read back persisted template. Keep legacy handler for previously issued links.
No wildcard or custom-domain auth expansion.

**Phase D — sender/subject**

Separate approved branding update to StrzelajTu.pl. Preserve verified SMTP
delivery configuration; do not invent sender domain/DNS changes. Read back.

**Phase E — physical-device/live security checks**

Approved account: desktop->phone, phone->desktop, same-device, reused email
token/grant and normal refresh. Credential mutation requires user participation.
Do not introduce a production signOut-failure toggle; retain the deterministic
local Auth+DB fault evidence and verify documented partial-success behavior if
an actual production cleanup failure occurs. Check infrastructure URL logging
redaction/retention before TokenHash rollout. No unnecessary emails.

## Final gate

CSK IMPACT: NONE. HISTORICAL MIGRATION CHANGES: NONE.
PRODUCTION WRITE: NO. STAGING/COMMIT/PUSH/DEPLOY: NO.
CURRENT CONFIRMATIONURL AFTER CODE DEPLOY: compatibility PASS on exact local
candidate; actual production smoke is Phase B, not performed here.
READY FOR CHECKPOINT COMMIT: YES.
READY FOR PHASE A PRODUCTION DEPLOY: YES, subject to fresh gate and explicit authorization.
READY FOR TOKENHASH TEMPLATE CUTOVER: NO.

Open rollout items (not local test claims): infrastructure query-log handling,
private production env availability at rollout, live Phase B/E device checks,
separately approved template/sender changes. LEGAL/GDPR remains separate.
