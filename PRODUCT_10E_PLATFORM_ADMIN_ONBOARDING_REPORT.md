# PRODUCT-10E — Platform Admin and Tenant Onboarding

## Clean checkpoint remediation — 2026-09-25: LOCAL PASS

This section supersedes the blocked build gate below. No staging, commit, push,
deployment or production write was performed.

Root cause: commit 94d8bd0 (PRODUCT-10C) already exported a Next.js page with
a required custom tenantSlug prop. This was a historical component-boundary
defect, not a new PRODUCT-10E authority requirement. The scoped route reused that
page as a component. The fix keeps the global page a zero-prop, fail-closed
notFound entrypoint and moves the reusable UI into TenantAdminSettings.tsx.
The authenticated scoped route retains its existing server-side tenant checks.
No type checking was disabled.

The mixed worktree component preserves its existing TCM content unchanged.
The clean candidate component contains only the pre-TCM public-settings reader
and writer. TenantOnboardingSettings remains independent of TCM. The settings
source-contract tests now read the component; three new boundary tests prevent
regression. Playwright additionally checks assigned-admin scoped settings after
activation.

Account ESLint classification: A / unrelated baseline. HEAD and the clean
candidate produce the same five no-html-link-for-pages errors for the existing
anchors. PRODUCT-10E adds no such errors; these anchors were not modified.
Other changed PRODUCT-10E lint targets: zero errors, one existing admin-page
useEffect dependency warning. This is not an all-files zero-error ESLint claim.

Clean candidate: C:/Users/Mpios/Desktop/APP Krutla/product10e-checkpoint-candidate.
Source HEAD: 80341fe4c9512e5fcd719963aa636777098cf705.
Exactly five PRODUCT-10E migrations retain their approved hashes; historical
migration bytes are preserved. No TCM migration, public subpages or CSK visual
changes are included. The isolated replay ends at 20261009140000, with 124
migrations, SECURITY DEFINER=97, TCM objects absent and both technical-table
service_role ACL baselines empty.

Fresh clean-candidate evidence:
- Focused SQL: 86/86 PASS.
- Full pre-TCM DB: 1890/1890 PASS across 62 files.
- Concurrency: 6/6 PASS; deadlocks=0.
- Node: 817/817 PASS.
- TypeScript: PASS; production webpack build including generated route types: PASS.
- Isolated no-TCM Playwright: 2/2 PASS, including draft setup and scoped settings.
- Schema diff after SQL and E2E: 0.
- E2E/concurrency fixtures: 0; temporary Auth/REST containers removed: 2;
  scratch database remaining: 0.

Tenant membership authority and separate platform authority are preserved;
profiles.role and client tenantSlug are not authorization sources.
TCM remains FROZEN. Production preflight may be retried separately.

## Production preflight — 2026-09-25: BLOCKED (deployment scope)

Fresh read-only evidence: HEAD/main and GitHub origin/main both equal
`80341fe4c9512e5fcd719963aa636777098cf705`. Index is empty. Historical
migration files have no tracked diff; `git diff --check` passes. All five
PRODUCT-10E migration SHA-256 values match the identities recorded below.

Windows `npx.cmd --no-install supabase migration list --linked` succeeded.
Applied local/remote versions match through `20261008110000`; no remote-only
version was shown. There are SIX local pending migrations: the five ordered
PRODUCT-10E migrations 20261009100000 through 20261009140000, followed by
`20261010100000_add_tenant_public_content.sql` (frozen TCM).

Fresh `npx.cmd --no-install supabase db push --linked --dry-run` explicitly
reported all SIX files under "Would push these migrations". It also explicitly
reported "DRY RUN: migrations will *not* be pushed to the database." Thus the
required exact-five deployment scope gate FAILS in the current repository.
CLI exit 0 is not a scope PASS. No actual db push was performed.

The optional JSON-format wrapper failed parsing CLI output; its zero/null
summary is invalid and is not evidence. A subsequent complete migration-list
read succeeded and is the source for the migration history statement above.

Preflight stopped at this scope gate. No fresh full test suite, production
bootstrap catalog audit, complete hunk reconciliation or schema/function drift
comparison was completed in this preflight. Earlier LOCAL PASS results remain
historical evidence only and are not relabelled as fresh preflight results.

Recommended next action: prepare a separate, hash-verified deployment/preflight
workspace containing the full applied history plus exactly the five 10E
migrations, without moving/editing source migrations or including TCM; rerun
the exact-five dry-run and remaining gates there. Do not run a production push
from the current mixed migration directory. This isolation was not performed
automatically after the failed gate.

PRODUCTION WRITE: NO. STAGING/COMMIT/PUSH/DEPLOYMENT: NONE.
TCM: FROZEN, unchanged. AGENTS.md and unrelated changes: untouched.
PREFLIGHT RESULT: BLOCKED.
READY FOR CHECKPOINT COMMIT/PUSH: NO.
READY FOR PRODUCTION DEPLOYMENT: NO.

## Latest gate — history-preserving isolated replay (2026-09-25)

**PRODUCT-10E LOCAL: PASS. READY FOR PRODUCTION PREFLIGHT: YES.**
This supersedes the earlier ACL/replay and independent-E2E blockers below. It is
not authorization for deployment and no production preflight was started.

HEAD: `80341fe4c9512e5fcd719963aa636777098cf705` (unchanged).

### Exact remediation scope

- `scripts/product10e-isolated-schema-check.mjs`: removed current public default
  ACL pre-seeding; historical migrations install their own defaults in order;
  added explicit zero service-role grant gate and optional isolated E2E runner.
- `supabase/tests/20260902120000_harden_public_table_sequence_acl_test.sql`:
  changed only the two approved service-role expected arrays to `{}` in this
  task. Other PRODUCT-10E/TCM inventory hunks pre-existed and remain mixed scope.
- `scripts/product10e-isolated-e2e.mjs`: new local-only Auth/REST/proxy and app-copy
  harness connected to the same scratch database used by SQL tests.
- `scripts/product10e-local-concurrency.mjs`: optional validated scratch database
  selector; concurrency assertions unchanged.
- `tests/e2e/platform-onboarding.spec.ts`: optional validated scratch database
  selector and no-TCM/head/97-DEFINER preconditions; existing workflow assertions
  unchanged.
- This report: final evidence. No application component or migration was edited.

The disposable application workspace is outside the repository at
`C:/Users/Mpios/Desktop/APP Krutla/product10e-isolated-review`. Its `.env.local`
contains only a comment; test credentials are passed in process environment and
never printed. It contains mechanically copied application/test files, build and
Playwright artifacts; none is checkpoint scope. Existing application services
were not switched to a different database.

### ACL provenance result

| Object | Fresh replay service_role grants | Production read-only audit 2026-09-24 | Updated test |
|---|---|---|---|
| confirmation_email_rate_limits | `{}` | `{}` | `{}` |
| lane_booking_family_configuration_versions | `{}` | `{}` | `{}` |

The production column refers to the recorded fresh catalog audit in
`PRODUCT_10E_ACL_PROVENANCE_REPORT.md`; no new production connection/write was
required for this local gate. No grants were added and no historical migration
was changed.

### Independent no-TCM environment

The final run used `node scripts/product10e-isolated-schema-check.mjs --with-e2e`.
It replayed all **124** unchanged migrations through
`20261009140000_preserve_onboarding_account_lifecycle.sql` into a new empty
scratch database. SECURITY DEFINER = **97**. TCM pricing table and all three
TCM RPCs = **absent**. The TCM migration was never applied.

Focused/full DB tests, concurrency tests and browser tests used that same
database. Dedicated Auth and REST containers reused the installed local images
and local credentials with only their database target changed to the validated
scratch name. Only the Auth migration ledger, not user/business data, was copied
to bootstrap the managed Auth service. Local HTTP bindings were loopback-only:
15498 proxy, 15499 Auth, 15500 REST; app copy used 3001.

The existing in-memory removal of TCM-only inventory expectations remains
explicit: full DB here means the complete **pre-TCM** SQL suite (62 files), not
the later TCM test file. No authorization assertions were weakened. The two ACL
expectation corrections above are the only source assertion edits in this task.

### Final results

| Check | Result |
|---|---|
| Focused PRODUCT-10E SQL | **86/86 PASS**, ROLLBACK and cleanup 0 |
| Full pre-TCM DB suite | **1890/1890 PASS**, 62 files including two undated contracts |
| Isolated concurrency | **6/6 PASS**, deadlocks 0, fixture cleanup 0 |
| Node, full current workspace | **829/829 PASS**; includes pre-existing static TCM/UI tests |
| Playwright PRODUCT-10E, isolated Auth/REST/no-TCM DB | **2/2 PASS**, Chromium |
| TypeScript | PASS |
| Normal repository production build | PASS, Turbopack |
| Disposable application build | PASS, Webpack (junction-compatible local harness) |
| ESLint changed JS/TS tooling/tests | PASS |
| git diff --check | PASS |
| Public schema before/after SQL tests | identical |
| Public schema after concurrency/E2E | identical |
| E2E temporary users/platform admins/audit/tenants | 0 |
| Disposable Auth/REST containers | removed, 2/2 |
| Scratch database remaining | 0 |

SQL evidence verifies platform authority separate from tenant authority;
profiles.role cannot grant platform/tenant privileges; draft/private creation
without automatic plan; explicit plan and initial-admin assignment; readiness;
private preview; activation/publication; suspension history/cancellation;
audited external settlement notation; downgrade continuity; no automatic
platform operational access; cross-tenant denial; tenant-admin denial for
platform lifecycle/plan changes. No hard-delete endpoint was added.

Browser evidence verifies actual login, platform draft creation, plan/admin
assignment, dedicated `TenantOnboardingSettings` rendering and saving using
pre-TCM settings RPCs, denied tenant-admin platform access, continuity screen,
private preview, activation/publication/suspension, anonymous protection, and
responsive platform UI at 320/375/430/768/1440.

Earlier harness attempts are not hidden: managed Auth ledger restore needed the
local managed-schema administrator (no GRANT); inheriting Linux PATH into the
Windows Docker launcher was corrected; Turbopack rejected the copied workspace's
dependency junction so only its build uses supported `--webpack`; the first
isolated browser attempt was 1/2 because the new local proxy omitted PostgREST
`accept-profile`/`content-profile` CORS headers. The proxy-only correction led to
the final 2/2 run. No application/security contract was changed to force PASS.

### Boundaries and next step

TCM remains **FROZEN**. Its migration SHA is unchanged:
`FE899CBD76D8F0E1BAB24A14374CF9E29A96DAFD34B969714E699415A71CD10B`.
The working tree remains mixed; this local PASS is not approval to stage whole
shared files. AGENTS.md, drafts, unrelated UI and historical migrations remain
outside this task's edits.

PRODUCTION WRITE / STAGING / COMMIT / PUSH / DEPLOYMENT: **NO**.
Second production tenant: not activated by this task. DNS/custom domain: untouched.
Next action: separately requested production preflight with precise scope/hunk
reconciliation. No production readiness claim is made by this local-only gate.

## Historical gate — tenant setup decoupling (2026-09-24, superseded)

**PRODUCT-10E LOCAL: BLOCKED / PARTIAL. READY FOR PRODUCTION PREFLIGHT: NO.** This gate supersedes earlier LOCAL PASS for the current mixed working tree.

The draft route now imports dedicated `app/tenant-setup/TenantOnboardingSettings.tsx`, not the TCM-enhanced AdminSettingsPage. The component is based on the committed pre-TCM settings form and calls only `admin_get_tenant_public_settings_v1(text)` and `admin_update_tenant_public_settings_v1(text,jsonb,timestamptz)`. It retains optimistic concurrency, visibility/feature flags and existing tenant-admin authorization. No platform-role bypass is added: Platform Admin can perform platform onboarding/preview, but platform authority alone still cannot edit tenant settings. No TCM schema, content RPC, pricing CRUD or expanded content DTO is required by this route.

### Isolation and evidence

`scripts/product10e-isolated-schema-check.mjs` creates a uniquely named EMPTY scratch database inside local `supabase_db_csk-booking` (port 54322), restores managed non-application schema dependencies, rebuilds public schema, and applies all 124 repository migrations transactionally through `20261009140000`. Each applied version is recorded only after successful local execution. This is not migration repair. No production connection, existing DB reset or modification of historical migration files occurs. The new scratch database is removed in finally, including failure paths.

Fresh replay target: SECURITY DEFINER **97**, all three TCM RPCs and TCM pricing table absent. Focused unchanged SQL matrix **86/86 PASS**, ending ROLLBACK and exact fixture cleanup 0. This verifies platform/tenant authority separation, own/cross-tenant settings, draft/private creation, explicit plan/admin assignment, readiness, preview, activation/publication, suspension, external settlement, account preservation and no automatic platform operational access.

Full DB tests use an explicit in-memory projection of later TCM-only inventory expectations back to the PRODUCT-10E baseline (97 DEFINER, 157 functions, 26 tables, old audit fingerprint). Source SQL test files and TCM files remain untouched. Authorization assertions are not relaxed.

**Full replay suite FAIL:** `20260902120000_harden_public_table_sequence_acl_test.sql`, check 6, `service_role table ACL unchanged`. On both `confirmation_email_rate_limits` and `lane_booking_family_configuration_versions`, expected privileges are `{MAINTAIN,REFERENCES,TRIGGER,TRUNCATE}`; replay produces `{DELETE,INSERT,MAINTAIN,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE}`. The 28 other assertions in that file pass. Before it, 49 assertions in three files pass. This is a reproducibility/security-baseline blocker, not established production drift or a demonstrated tenant data leak. No grant/revoke correction or test weakening was performed to force PASS.

An earlier schema-reconstruction-only diagnostic (not full migration replay) passed 1875 assertions in 60 dated SQL files. It omitted two undated tests and is explicitly NOT the final full DB gate; the subsequent complete-chain replay failure above is authoritative.

| Check | Result |
|---|---|
| Focused SQL on complete replay, no TCM | 86/86 PASS |
| Full DB on complete replay | FAIL: service_role ACL mismatch on two tables |
| Full Node on current workspace | 829/829 PASS (includes existing unrelated/TCM tests) |
| TypeScript | PASS |
| Production build locally | PASS |
| ESLint new/changed code | PASS |
| git diff --check | PASS |
| Playwright onboarding smoke | 2/2 PASS on dedicated local app port 3001; existing API/database includes TCM, so NOT independent E2E evidence |
| Initial reused-dev Playwright attempt | 1/2; stopped at login; retry used separate production-mode server |
| Isolated API/Auth/browser full E2E | NOT COMPLETED |
| Final schema parity gate | BLOCKED by replay ACL discrepancy |
| Cleanup | Focused fixture 0; each scratch DB removed; local browser synthetic users/tenants query 0/0 |

### Current-turn scope / classification

PRODUCT-10E only: dedicated TenantOnboardingSettings component (new); tenant-setup/[slug]/page.tsx import/render change; tenant-onboarding-settings.test.mjs (new, 3 tests); product10e-isolated-schema-check.mjs (new tooling); this report and reconciliation report evidence update. No new shared application hunk introduced. The pre-existing shared-file inventory remains documented separately and is not approved for whole-file staging.

TCM remains FROZEN. Its migration SHA remains `FE899CBD76D8F0E1BAB24A14374CF9E29A96DAFD34B969714E699415A71CD10B`. None of the five PRODUCT-10E migration timestamps/content was edited. AGENTS.md, drafts and unrelated UI remain untouched by this decoupling task.

Next required work: reconcile provider/baseline service_role ACL provenance against the migration chain without changing historical migrations or broadening authority; obtain clean independent DB replay and full suite; attach isolated Auth/REST/browser tests to that same baseline. Do not infer production readiness from the mixed-stack browser smoke.

PRODUCTION WRITE / STAGING / COMMIT / PUSH / DEPLOYMENT: NO. SECOND PRODUCTION TENANT: not activated. DNS/custom domains: untouched.

Date: 2026-09-24
Status: PRODUCT-10E LOCAL PASS (2026-09-24). Cancellation security patch remains PROD PASS. The implementation below is LOCAL ONLY and supersedes the historical implementation-blocked status. Production preflight has NOT been started.

## PRODUCT-10E resumed local implementation — authoritative handoff

### Source of truth and scope

HEAD `80341fe4c9512e5fcd719963aa636777098cf705`, branch `main`; existing origin/main tracking reference matches, divergence 0/0. No network fetch, staging, commit, push, deployment or production SQL was performed in this local implementation task. The working tree contains real implementation changes, not only a report. Five existing unrelated entries remain excluded: AGENTS.md, SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md, SAAS_FINAL_MIGRATION_MASTER_REPORT.md, FINAL_SAAS_SECURITY_AUDIT_2026_09.md and supabase/drafts/*.

The PRODUCT-10D docs checkpoint audit below remains valid: 90c5895 was report-only; lib/tenant-features.ts belonged to the preceding implementation checkpoint.

### Platform authority and bootstrap

New closed table `platform_admins` stores an explicit active/suspended platform role. Authority is never inferred from profiles.role, auth metadata, tenant membership, a slug or an arbitrary client tenant ID. Server routes authenticate with auth.getUser and independently call is_platform_admin_v1; every privileged RPC repeats platform authorization.

Platform Admin can manage metadata/lifecycle/plan/initial onboarding, but gets NO automatic tenant operational membership or customer-data access. Initial-admin assignment is draft-only, requires a verified existing account, refuses an existing active admin/membership, and cannot be used to grant platform staff access to an already active tenant.

PRODUCTION PLATFORM ADMIN BOOTSTRAP REQUIRED = YES. Before production deployment, the owner must explicitly identify the existing verified account to provision and authorize a separate controlled bootstrap. No real UUID/email is embedded in migrations; no account is selected automatically. Provisioning and revocation are deliberately not exposed as a self-service RPC/UI.

### Lifecycle, creation, identity and readiness

Creation is atomic: tenant dormant (the existing draft-equivalent status), a minimal private public-profile row, all optional public sections off, no plan assignment. No CSK data is copied.

Technical/public slugs are distinct, stable, lowercase 2–63-character selectors, validated against the reserved namespace including platform-admin/continuity/tenant-setup. Existing cross-table uniqueness/namespace triggers are preserved, with the same advisory namespace lock. Both tables additionally use the canonical closed validator in CHECK constraints. No rename API or hard-delete API exists.

Lifecycle: dormant -> active; active -> suspended; suspended -> active. Active -> draft is rejected. Activation and publication are separate, authorized actions. Readiness requires valid identity/slugs, public settings/name/city, an active plan, and a verified active tenant admin. Suspension unpublishes without deleting resources or memberships. Reactivation checks readiness and does not silently republish.

Plan assignment is explicit, accepts an existing active plan, locks the tenant, updates one assignment and records platform audit. Repeated identical assignments are idempotent. Tenant admins/employee/instructor/user/anon cannot assign plans. Downgrade preserves rows/history/cancellation while the existing entitlement engine blocks new unavailable module use.

### Initial administrator, setup and private preview

Exact-email lookup is platform-only, bounded to a single verified non-deleted account, returns only account ID/email needed for assignment, rejects ambiguous matches, and is not a user directory or invitation/auth-user creation flow.

Draft tenant admins configure their own public settings through /tenant-setup/[slug]. Existing settings RPCs accept dormant or active tenants, still require active admin membership, and use a closed draft-aware presentation feature helper. General operational tenant-role/RLS/entitlement helpers remain active-only.

Private /platform-admin/tenants/[id]/preview uses an independently authorized RPC and the existing strict public-landing DTO parser. It neither publishes nor makes anonymous draft readers succeed. Booking/event navigation in preview is disabled; privacy visibility masking and entitlement AND visibility remain intact.

### Suspension and external settlement continuity

/continuity is authenticated and linked from /account. The owner sees only their own existing reservation/event history; active tenant admin/employee may select only their authorized tenant. Reads are 25 resources/page with stable ordering. Platform role alone cannot read staff history, cancel a resource or record a settlement.

A closed resource-derived continuity role helper accepts active memberships in active/suspended tenants. Only the four existing cancellation wrappers/cores use it; canonical reservation 12-hour and event 72-hour rules/status restrictions remain unchanged. General tenant authority remains active-only. Continuity cancellation never initiates waitlist promotion or new email delivery.

The external settlement RPC derives tenant from the locked reservation/registration resource, permits active tenant admin/employee only, validates positive decimal amount/currency/reference, binds idempotency to exact payload and tenant, and writes tenant-bound audit. It records an externally performed refund/reconciliation; it does not move money, create payment links/charges, change payment_status, or interpret unpaid as refunded. Owner history displays minimal settlement metadata, not staff identity or reference.

Database triggers on reservations/events/event_registrations serialize resource writes with lifecycle transitions via tenant row locks. Suspended new obligations, registrations, events, extensions and promotion writes are denied. Only exact cancellation/redaction shapes are allowed. The existing local-postgres fixture switch is retained; normal application sessions cannot use it to gain authority.

Account-wide anonymization remains separate from leave-tenant: new actor references are pseudonymized, operational references redacted and own platform authority removed. Existing account authorization/last-admin semantics remain intact. No new leave-tenant or global account export contract is introduced.

### Security inventory / ACL

Local target: 157 public functions; SECURITY DEFINER 85 -> 97; 26 public tables. All 16 new functions are owned by postgres and pin search_path to pg_catalog, public, pg_temp. New tables have RLS and zero permissive policies; PUBLIC/anon/authenticated/service_role direct table privileges are revoked.

| New functions | Mode / reason | Client EXECUTE |
| --- | --- | --- |
| is_platform_admin_v1 | DEFINER: read closed platform authority | authenticated only |
| platform_list_tenants_v1, platform_lookup_initial_admin_v1 | DEFINER: minimal authorized metadata/account lookup | authenticated only, platform check |
| platform_create_tenant_v1, platform_set_tenant_plan_v1, platform_assign_initial_admin_v1, platform_set_tenant_state_v1 | DEFINER: atomic authorized writes to closed tables | authenticated only, platform check |
| platform_preview_tenant_v1 | DEFINER: private allowlisted preview | authenticated only, platform check |
| get_my_continuity_v1, record_external_settlement_v1, cancel_continuity_resource_v1 | DEFINER: owner/resource-bound continuity on closed resources | authenticated only, independent owner/membership checks |
| enforce_suspended_obligations_v1 | DEFINER trigger: authoritative lifecycle lock/check | no direct client EXECUTE |
| platform_slug_valid_v1, platform_tenant_readiness_core_v1, get_my_continuity_role_core_v1, tenant_setup_has_feature_core_v1 | closed INVOKER helpers | no direct client EXECUTE |

PUBLIC/anon/service_role EXECUTE on all new functions is denied. No service key enters app code. Existing public directory/landing contracts and allowlisted DTOs are unchanged. Public API contains no platform audit, readiness, plan assignment, membership or customer PII. Privileged platform lookup intentionally returns the exact selected administrator email; this is not a public DTO.

### Migrations and identity

These are five NEW, uncommitted, undeployed forward-only migrations. Existing deployed migration files are unchanged. Their timestamps follow the repository's established future-dated sequence after 20261008110000; no historical rename/repair was performed.

| Migration | SHA-256 |
| --- | --- |
| 20261009100000_add_platform_tenant_onboarding.sql | 01BE8C0C5E7469C03F9364C295EB673ADFB34CA409C86B3847E84A1A6DB9912C |
| 20261009110000_add_tenant_continuity.sql | A24B6AA56821033AF2269D29F476522B72BC911D2949E47D110527A3F5320042 |
| 20261009120000_add_private_tenant_setup.sql | 73737BB5D7C90D7F48BAC27DCC1038430CA7A2A066FC05E780F682A52F3D733C |
| 20261009130000_guard_suspended_obligations.sql | F05CA543C9D100C85E6E776FEAC4B67A79D273CF0B9508016E12B62AD01ED483 |
| 20261009140000_preserve_onboarding_account_lifecycle.sql | 243E355C920BFB0EFD527C638CE2830A2BCB04B6336C4868302252FF90E25BB8 |

Existing function replacements use normalized CRLF/CR -> LF fingerprint guards; the account-redaction change also checks a unique replacement anchor. Local schema replay validates the complete chain. Production input fingerprint/slug/inventory/volume preflight remains a separate required step; LOCAL PASS is not production readiness approval.

### Local tests and evidence

All DB/test actions targeted Windows Docker container supabase_db_csk-booking, local port 54322. No linked commands, production SQL, reset, Docker cleanup or CLI update.

| Gate | Final result |
| --- | --- |
| Focused onboarding / privacy / continuity SQL | 86/86 PASS; BEGIN/ROLLBACK; final exact fixture cleanup 0 |
| Full DB | 1890/1890 PASS, 62 files |
| Concurrency | 6/6 PASS; deadlocks 0; cleanup 0 |
| Node | 811/811 PASS |
| Playwright | 51/51 PASS, Chromium |
| TypeScript | PASS |
| Production build | PASS, 41 generated pages |
| Changed-files ESLint | PASS, 0 errors; 1 existing app/admin/page.tsx hook-dependency warning |
| git diff --check | PASS |
| Local schema diff / full migration replay | PASS: No schema changes found |
| Independent cleanup query | synthetic tenants 0, auth users 0, memberships 0, platform admins 0, platform audit 0, external settlements 0 |
| SECURITY DEFINER local inventory | 97 |

Concurrency covers duplicate technical/public slugs, concurrent plan writes, initial-admin assignment, activation racing incomplete setup, and suspension racing new events. Browser evidence includes platform-only route protection; private draft creation; explicit booking-only plan; exact-account assignment; separate tenant-admin draft settings; preview; activate/publish/suspend; 320/375/430/768/1440 no-overflow checks; and existing two-tenant/operational regressions.

Focused SQL additionally checks no automatic plan, no global profiles.role platform authority, tenant-role negative cases, private preview, resource cancellation, settlement idempotency and audit, suspended membership denial, downgrade preserving data/owner history/cancellation eligibility, global anonymization, and closed table ACLs. Existing cancellation/security suites preserve cutoff and cross-tenant regressions.

An initial Playwright run was 50/51: legacy dashboard quick links still pointed to entitlement-disabled Check-in/events despite correct module tiles. The minimal correction applies the same existing feature flags to those links. Full rerun 51/51. A DB run overlapped browser fixtures and failed the pre-existing baseline-membership assertion; isolated final DB run passed without weakening that assertion. Neither event is evidence of production failure.

### Exact local scope (58 files)

The 37 existing SQL regression files change expected inventory/counts/allowlists and the explicitly changed account/cancellation helper fingerprints/contracts only. Historical migration files are NOT edited. No unrelated checkpoint files are included.

- `app/_components/PublicTenantLanding.tsx`
- `app/account/page.tsx`
- `app/admin/page.tsx`
- `app/continuity/ContinuityPanel.tsx`
- `app/continuity/page.tsx`
- `app/platform-admin/page.tsx`
- `app/platform-admin/PlatformTenants.tsx`
- `app/platform-admin/tenants/[id]/preview/page.tsx`
- `app/tenant-setup/[slug]/page.tsx`
- `lib/platform-onboarding.test.mjs`
- `lib/server/platform-admin.ts`
- `lib/server/public-tenant-directory.ts`
- `PRODUCT_10E_PLATFORM_ADMIN_ONBOARDING_REPORT.md`
- `scripts/product10e-local-concurrency.mjs`
- `supabase/migrations/20261009100000_add_platform_tenant_onboarding.sql`
- `supabase/migrations/20261009110000_add_tenant_continuity.sql`
- `supabase/migrations/20261009120000_add_private_tenant_setup.sql`
- `supabase/migrations/20261009130000_guard_suspended_obligations.sql`
- `supabase/migrations/20261009140000_preserve_onboarding_account_lifecycle.sql`
- `supabase/tests/20260816143000_harden_public_function_execute_acl_test.sql`
- `supabase/tests/20260902120000_harden_public_table_sequence_acl_test.sql`
- `supabase/tests/20260903100000_harden_audit_log_integrity_test.sql`
- `supabase/tests/20260907100000_add_dormant_tenant_foundation_test.sql`
- `supabase/tests/20260910120000_tenant_aware_booking_rls_test.sql`
- `supabase/tests/20260913100000_harden_event_management_rpcs_test.sql`
- `supabase/tests/20260913150000_harden_public_event_readers_test.sql`
- `supabase/tests/20260914100000_harden_shared_confirmation_email_rpcs_test.sql`
- `supabase/tests/20260914150000_harden_event_reserve_promotion_rpcs_test.sql`
- `supabase/tests/20260915100000_harden_lane_block_rpcs_test.sql`
- `supabase/tests/20260916100000_harden_lane_family_creation_readers_test.sql`
- `supabase/tests/20260917100000_harden_lane_family_writer_helpers_test.sql`
- `supabase/tests/20260918100000_harden_admin_reservation_reports_test.sql`
- `supabase/tests/20260919100000_add_tenant_user_admin_notes_test.sql`
- `supabase/tests/20260919150000_harden_tenant_user_role_identity_contact_test.sql`
- `supabase/tests/20260920100000_add_tenant_user_verification_foundation_test.sql`
- `supabase/tests/20260920150000_cutover_tenant_user_verification_test.sql`
- `supabase/tests/20260921100000_close_legacy_global_verification_path_test.sql`
- `supabase/tests/20260922100000_harden_account_lifecycle_rpcs_test.sql`
- `supabase/tests/20260923100000_harden_profile_privilege_trigger_test.sql`
- `supabase/tests/20260924100000_harden_public_booking_configuration_test.sql`
- `supabase/tests/20260925100000_add_public_active_tenant_resolver_test.sql`
- `supabase/tests/20260926100000_add_tenant_scoped_operational_readers_test.sql`
- `supabase/tests/20260927100000_add_tenant_scoped_staff_event_rpcs_test.sql`
- `supabase/tests/20260927110000_add_tenant_scoped_lane_configuration_rpcs_test.sql`
- `supabase/tests/20260927120000_add_tenant_scoped_admin_reports_test.sql`
- `supabase/tests/20260927130000_add_tenant_scoped_admin_users_test.sql`
- `supabase/tests/20260928100000_add_c3_owner_calendar_and_global_profile_contracts_test.sql`
- `supabase/tests/20260929100000_close_global_role_helper_execute_test.sql`
- `supabase/tests/20260930110000_tenant_aware_onboarding_cutover_test.sql`
- `supabase/tests/20261001100000_retire_single_tenant_compatibility_test.sql`
- `supabase/tests/20261003100000_remove_single_active_tenant_guard_test.sql`
- `supabase/tests/20261004100000_add_public_tenant_directory_test.sql`
- `supabase/tests/20261005100000_add_public_tenant_landing_test.sql`
- `supabase/tests/20261006100000_add_tenant_public_settings_test.sql`
- `supabase/tests/20261007100000_add_saas_feature_entitlements_test.sql`
- `supabase/tests/20261008100000_harden_cancellation_tenant_authority_test.sql`
- `supabase/tests/20261009100000_platform_tenant_onboarding_test.sql`
- `tests/e2e/platform-onboarding.spec.ts`

### Deferred scope / pre-production gates

- Explicit production Platform Admin identity and separately authorized bootstrap are required. No automatic CSK-admin grant.
- Separate production preflight must verify migration history, all five SHAs, normalized inputs, reserved-slug compatibility, ACL/inventory, and lock risk before any deployment decision.
- DNS/custom domains, actual payments/refunds/billing, invites, storage upload lifecycle, transactional email branding, and final legal/GDPR documents remain deferred as specified.
- Legal/account-export review must include new external-settlement/platform-audit retention and lawful access requirements; this task preserves existing account export and extends anonymization, not a final legal completeness claim.
- Second production tenant was not activated; production, DNS and custom domains were not accessed or changed.

### Final local gate

PRODUCT-10E LOCAL: PASS.
PLATFORM AUTHORITY SEPARATION: PASS.
TENANT ISOLATION / PII: PASS.
SUSPENSION / EXTERNAL-ONLY CONTINUITY: PASS.
PRODUCTION PLATFORM ADMIN BOOTSTRAP REQUIRED: YES.
READY FOR SEPARATE PRODUCTION PREFLIGHT: YES.
READY FOR PRODUCTION WRITE: NO.
STAGING / COMMIT / PUSH / DEPLOYMENT: NONE.

---

## Historical security-patch and blocker evidence

The following sections retain the earlier chronology and production cancellation-patch evidence; earlier onboarding-blocked wording does not override the authoritative local handoff above.


## Checkpoint verification

- HEAD: `90c5895ef48352f09d3df5ca7e5e2943dc06a39d`, branch `main`.
- Local HEAD matches the existing `origin/main` tracking reference, divergence 0/0. No remote fetch or production access was required for this initial local audit.
- `git show --stat 90c5895ef48352f09d3df5ca7e5e2943dc06a39d` confirms exactly one changed file: `PRODUCT_10D_SAAS_ENTITLEMENTS_REPORT.md` (19 insertions, 1 deletion). It is docs-only.
- `lib/tenant-features.ts` belongs to the preceding PRODUCT-10D checkpoint `3877970ac8a010eac70d89981c4bfa760a052137`, not the docs commit. No reversal is needed.
- The working tree was not clean: the five previously excluded SaaS/AGENTS/drafts entries remain. This task did not change them.

## Existing authority and lifecycle inventory

Initial repository search found no explicit platform-admin/superadmin authority contract. Local schema has no platform-admin table. Tenant authority remains `tenant_memberships`, with active membership and active tenant checks. No account is selected for platform authority.

The current tenant status constraint allows `dormant`, `active`, `suspended`, and `disabled`; `dormant` can represent draft without adding a duplicate lifecycle field. Publication already exists independently as `tenant_public_profiles.is_public`.

Technical/public slug uniqueness and cross-table collisions already have a database trigger and advisory transaction lock. The existing reserved-root list will need to include the new `platform-admin` route in a forward-only migration.

Local SECURITY DEFINER baseline: 85.

## Blocking finding: suspension versus existing obligations

Severity: HIGH operational continuity risk if suspension management is introduced without a defined exception contract. This is not evidence of cross-tenant leakage or a production incident.

Evidence was obtained from current local PostgreSQL definitions, not only historical migration text:

| Current contract | Observed behavior |
| --- | --- |
| `get_my_tenant_role_v1(uuid)` | Returns a role only when membership and tenant are both active. |
| `is_tenant_member_v1(uuid)` | Returns false for a suspended tenant, even with active membership. |
| `get_my_reservations_v2()` | Filters owner reservations through an active-tenant join. Suspended tenant reservations disappear from this result. |
| `cancel_reservation(uuid)` | Uses `get_my_tenant_role_v1`; null role is denied before cancellation business rules. |
| `cancel_event_registration(uuid)` | Uses the same active-tenant role prerequisite and denies cancellation when it returns null. |
| `get_my_reservation_calendar_v1(uuid)` | Requires an active tenant and tenant membership helper. |
| `resolve_active_tenant_by_slug_v1(text)` | Resolves active tenants only, so tenant routes also require continuity-specific consideration. |
| `admin_get_tenant_public_settings_v1` / `admin_update_tenant_public_settings_v1` | Require an active tenant; draft configuration cannot simply reuse these routes without an explicitly scoped extension. |

PRODUCT-10D entitlement downgrade continuity does not establish tenant suspension continuity: downgrading the plan keeps the tenant active. Reusing the existing suspended status unmodified would therefore block self-service cancellation/history for existing obligations.

The PRODUCT-10E specification explicitly requires STOP/HANDOFF when suspension semantics need a business decision. No general membership helper, RLS policy, owner RPC, or lifecycle writer has been changed.

## Approved suspension decision

The owner approved the following policy after the initial audit: SUSPENDED means no new business, while existing obligations may be safely completed. Owners retain history and cancellation under existing cutoffs. Active tenant admin/employee members may cancel, refund, reconcile existing payments, and finish transactions initiated before suspension. New bookings (including manual staff bookings), events, registrations, payment links, charges, and increases/extensions of obligations are prohibited. This resolves the original suspension-policy blocker.

The following technical recommendations implement that policy without broadening general tenant authority:

Approve a narrowly scoped continuity contract for suspended tenants:

1. Public acquisition, new booking/event registration, promotion into new obligations, and normal operational module use remain denied.
2. Owners retain access to their own existing reservation/event history and cancellation under unchanged canonical cutoff/status rules. Global account operations remain available.
3. Active tenant admin/employee memberships retain only cancellation, refund, reconciliation and completion of pre-existing transactions. They do not receive unrestricted access to all modules.
4. Platform Admin does not acquire access to operational customer records by virtue of platform authority.
5. General `get_my_tenant_role_v1` / `is_tenant_member_v1` semantics remain fail-closed. Any continuity exception must be resource-bound and tested separately, rather than globally treating suspended tenants as active.
6. Re-activation rechecks plan/admin/settings readiness. Publication remains a separate explicit action; suspension hides the tenant publicly without deleting business data or memberships.

## Current financial capability gap

Follow-up repository and local schema inspection confirmed:

- `reservations` stores `price`, `total_price`, and `payment_status`; event registrations store `payment_status`.
- There is no payment/refund/transaction ledger, provider transaction identifier, payment-start timestamp, charge/capture contract, payment-link contract, or refund contract in the current application/schema inventory.
- `update_reservation_payment(uuid,text)` changes a payment status; `mark_event_registration_paid` / its scoped caller mark an existing registration as paid. They do not transfer or refund funds.
- Canonical UI statuses are `pay_on_site`, `paid`, `paid_on_site`, `unpaid`, `free`, and `voucher`. None represents a completed refund. Treating `unpaid` or `free` as a refund would lose meaning and could misrepresent customer money.

The approved policy therefore cannot be represented fully by merely allowing the existing payment-status RPCs while suspended. PRODUCT-10E expressly excludes payment processing/billing integration. No existing transaction model can prove that a payment transaction began before suspension.

Approved implementation boundary: PRODUCT-10E handles operational recording only. Add a minimal tenant/resource-bound, audited record of an externally completed refund/reconciliation with idempotency and historical visibility; do not initiate movement of funds, capture, payment links, or charges. Record this honestly in the UI as an external settlement, not an executed refund. Real payment execution and provider transaction completion remain deferred until a separately designed payment integration exists. The owner explicitly approved this scope; no further approval of this same boundary is required for local implementation.

Suspension must not permit new obligations or increases to existing obligations. Continuity authorization must derive from the existing resource and active tenant staff membership, not platform authority, a caller-supplied tenant identifier, or global profiles.role. Idempotency must reject reuse of a key for a different settlement payload. Existing cancellation cutoffs remain unchanged.

Do not infer payment initiation from reservation creation time or a mutable `payment_status`.

## Proposed architecture after decision

- Separate closed `platform_admins` authority with an active status; no profiles.role, tenant-role, signup, or self-grant inference.
- Synthetic local platform administrator only. Production bootstrap requires a separately identified existing auth account and an explicitly approved provisioning operation.
- Metadata-only management RPCs, private preview, explicit plan assignment, first-admin assignment, atomic readiness/activation, and separate minimal platform audit.
- No platform operational-data bypass, hard delete, billing, custom-domain provisioning, or email branding.
- Exact-email existing-account lookup with a minimal private DTO; no global user directory.
- Tenant creation atomically creates dormant/private metadata and conservative settings with no default plan.
- Draft Tenant Settings access will require a narrowly scoped admin-only setup contract; active unpublished settings already fit the existing status model.

## Work and verification performed

- Read the complete PRODUCT-10E specification and repository instructions.
- Verified checkpoint scope, HEAD, branch, tracking divergence, and dirty-tree exclusions.
- Inspected current lifecycle constraints, settings contracts, public-slug namespace protection, owner/cancellation RPC definitions, and membership helper definitions.
- Performed only local read-only database queries. No fixtures were created.
- No migration, application implementation, staging, commit, push, deployment, production SQL, or tenant activation was performed.
- Test suites were not rerun because implementation was stopped before code or schema changes.

## Deferred scope and bootstrap

Legal/GDPR entity/privacy/processing metadata needs a future legal gate. Existing tenant identity/public profile can support later integrations without inventing legal-role flags. Logo/hero storage lifecycle, custom domains/DNS, billing, transactional email branding, destructive tenant deletion, and platform-role provisioning UI remain deferred.

PRODUCTION PLATFORM ADMIN BOOTSTRAP REQUIRED: YES — no verified explicit model/account is available from this audit. A production account must be designated; no UUID/email will be guessed or embedded in the migration.

## Initial audit gate (historical; superseded by remediation below)

PRODUCT-10E LOCAL: BLOCKED — business decisions resolved; a separate existing cancellation authority bypass was reproduced locally before implementation. This is not a LOCAL PASS.

READY FOR PRODUCTION PREFLIGHT: NO.

MIGRATIONS: NONE.

FILES CHANGED BY THIS TASK: this report only.

PRODUCTION WRITE: NO.

## Cancellation authority remediation — final local evidence (authoritative latest result)

### Identity and scope

HEAD remains `90c5895ef48352f09d3df5ca7e5e2943dc06a39d`. No staging, commit, push or deployment occurred. No historical migration was edited.

Two new forward-only migrations split the confirmed cutoff bypass from the additional active helper findings:

| Migration | SHA-256 |
| --- | --- |
| `20261008100000_harden_cancellation_tenant_authority.sql` | `1591FCB5895C51E502A1EB1429DC8900DBD7A53FEBDED5F6A358AB76ECAE3E38` |
| `20261008110000_harden_resource_helper_role_authority.sql` | `4620BA7EAE7648FDA3604EF263F0473D324E84D92203605A125A83C0B1055A5A` |

Both migrations validate normalized input-definition fingerprints (CRLF/CR → LF) and require exactly one expected role-assignment anchor per function. Their chronological identifiers follow the current repository chain. They modify only role derivation in existing closed INVOKER cores and harden their search_path/ACL; signatures, wrappers, policies, tables and application code are unchanged.

The migrations were applied transactionally to the local `supabase_db_csk-booking` database using `psql -1`, not a linked connection. The complete filesystem migration chain was independently replayed by local Supabase schema diff in its shadow database. No migration-history repair was used. This is schema/test evidence, not a claim of production or linked migration-history verification.

### Confirmed finding and severity

Severity remains **HIGH**. Prerequisite: an authenticated account owns the target registration/reservation, holds an active ordinary membership in its resource tenant, but has legacy global `profiles.role=admin` (or a corresponding legacy staff role). The client does not need, and was not shown to have, the ability to edit its own global role. The confirmed event exploit selected the staff cancellation branch inside the 72-hour cutoff. A corresponding reservation pattern existed in the 12-hour cancellation core. This finding does not establish arbitrary foreign-user access or a cross-tenant PII leak.

After remediation, only the resource tenant's active membership decides staff override. `employee`/`instructor` are mapped to the pre-existing legacy labels solely for existing result/audit compatibility. Global profile fields can still supply the existing display name; they no longer determine these cancellation privileges. Existing 12-hour and 72-hour cutoff calculations, inclusive boundaries, status transitions, lock order and return signatures are preserved.

### Affected functions and resource binding

All fifteen functions below remain **SECURITY INVOKER**, owned by **postgres**, `search_path=pg_catalog, public, pg_temp`, with direct EXECUTE denied to PUBLIC/anon/authenticated/service_role. Existing authenticated SECURITY DEFINER entry wrappers remain in place and retain their own resource/role checks. SECURITY DEFINER count stays **85**; no extra grants or service-role/browser surface were introduced.

| Function (existing signature unchanged) | Authoritative tenant resource |
| --- | --- |
| `cancel_reservation__saas9d1_core(uuid)` | reservation ID |
| `cancel_event_registration__saas9d2a_core(uuid)` | event registration ID |
| `admin_create_lane_block__saas9d3a_core(uuid,date,time,time,text)` | lane ID |
| `admin_set_lane_block_active__saas9d3a_core(uuid,boolean)` | existing block ID |
| `admin_update_lane_block__saas9d3a_core(uuid,uuid,date,time,time,text,boolean)` | existing block ID; outer wrapper retains destination-lane consistency validation |
| `admin_set_event_active_v2__saas9d2b1_core(uuid,boolean)` | event ID |
| `admin_update_event_v2__saas9d2b1_core(uuid,text,text,date,time,time,text,numeric,integer,uuid[])` | event ID |
| `approve_event_registration__saas9d2a_core(uuid)` | event registration ID |
| `mark_event_registration_paid__saas9d2a_core(uuid)` | event registration ID |
| `update_reservation_admin_note__saas9d1_core(uuid,text)` | reservation ID |
| `update_reservation_payment__saas9d1_core(uuid,text)` | reservation ID |
| `update_reservation_attendance__saas9d1_core(uuid,text)` | reservation ID |
| `create_reservation_v2__saas9d1_core(uuid,date,time,integer,integer,uuid,text)` | lane ID |
| `get_check_in_reservation_v1__saas9d1_core(uuid)` | reservation matched by check-in token |
| `admin_list_event_registrations_v1__saas9d2a_core(uuid,text,text,integer,integer)` | event ID |

The additional thirteen helpers were classified **AUTHORITY RISK** before remediation: even with tenant-scoped outer wrappers, their global-role checks could wrongly reject legitimate tenant staff, require obsolete global privileges, or misclassify the actor. They are the same local role-source defect and were corrected under the authorized targeted-global-role search scope. No unrelated business-policy redesign was undertaken.

### Remaining runtime global-role search classification

Searches inspected actual local runtime definitions, EXECUTE grants, function callers and RLS policy expressions, not just historical migration text.

| Hits | Classification and reason |
| --- | --- |
| `create_reservation`, `admin_get_reservation_report_v1`, `admin_set_lane_booking_configuration`, `get_reservation_customer_profiles_v1__saas9d1_core` | SAFE / NON-ACTIVE legacy authority bodies: owner-only EXECUTE, no active SQL callers found. No application activation or ACL expansion. |
| `is_admin`, `is_admin_or_employee`, `is_admin_or_staff` | SAFE / CLOSED: no anon/authenticated/service_role EXECUTE, no active function caller and zero public RLS policy dependencies. |
| `get_my_role` | SAFE / NON-AUTHORITY self/global-profile reader; not used as authority by the remediated tenant mutations. |
| `admin_set_lane_booking_family_configuration_v2__saas9d3c_core` | SAFE / NON-AUTHORITY legacy profile role used for audit label; actual authorization explicitly uses tenant membership. |
| `admin_create_lane_booking_family_v2__saas9ec2b_core`, `admin_get_tenant_public_settings_v1`, `admin_update_tenant_public_settings_v1`, `admin_list_users_v2`, `admin_set_user_role_v2`, `admin_set_user_note_v2`, `get_reservation_customer_profiles_v1`, `update_tenant_profile_identity_v2`, `update_tenant_profile_contact_details_v2` | SAFE / NON-AUTHORITY search hits: tenant membership authorization; profile data, result roles or audit fields are not global role authority. |
| `legacy_profile_role_to_tenant_role_v1`, `tenant_role_to_legacy_profile_role_v1` | SAFE / NON-AUTHORITY explicit string translation; no caller-authority inference. |
| `handle_new_user`, `update_my_profile_v2`, `export_my_data_v1`, `anonymize_my_account_v1`, `set_audit_log_tenant_id` | SAFE / NON-AUTHORITY account lifecycle, profile data, self-service, or audit classification; not global tenant-staff authorization. |
| Corrected cancellation/reservation cores still matching broad `profiles` + `role` searches | SAFE / NON-AUTHORITY remaining profile access supplies names/contact data; role assignment is now resource-bound membership. |

No known active global-role authority hit remains in the audited cancellation/helper graph. This is a local targeted audit, not a new blanket certification of every platform surface or of deployed production.

### Suspension boundary

No suspension continuity expansion is included in these prerequisite migrations. The general active-tenant role resolver remains fail-closed. Tests explicitly verify that global admin role does not unlock a suspended tenant. PRODUCT-10E must implement its already approved narrow history/cancellation/external-settlement continuity separately, using resource-bound membership rather than relaxing general RLS/role helpers. No payment execution/refund processor was added.

### Verification

The focused matrix covers both reservation and event paths: user/global-user cutoff DENY; user/global-admin cutoff DENY; tenant admin/global-user ALLOW; employee/global-user ALLOW; admin in another tenant DENY; pending/suspended/no membership DENY; anon DENY; eligible owner outside cutoff ALLOW; foreign ownership DENY; suspended tenant not unlocked by global role. Additional behavioral probes cover payment, note, attendance, event approval and event deactivation with inverted global/tenant roles. All thirteen extra helpers also have definition/resource-binding/ACL/search_path assertions.

| Check | Final result |
| --- | --- |
| Focused SQL including exact-ID rollback cleanup | 46/46 PASS |
| Full DB suite, all 61 SQL files | 1804/1804 PASS |
| Existing reservation/event/ACL regression suites | Included in full DB, PASS |
| Node | 803/803 PASS |
| Playwright | 49/49 PASS after both migrations |
| TypeScript | PASS |
| Production build (local execution) | PASS |
| Changed-files ESLint | NOT APPLICABLE: only SQL/Markdown changed; no JS/TS application changes |
| Tracked diff check plus untracked-file whitespace checks | PASS |
| Local schema diff, complete shadow migration replay | PASS — No schema changes found |
| Fixture cleanup | 0 |

The initial sandboxed Playwright attempt could not access Docker. Its two synthetic `test-9d4b1a-...@example.invalid` accounts were identified by exact UUID/email and removed locally; no unrelated account was removed. Playwright was then rerun successfully with local Docker access. Full DB was run sequentially afterward to avoid concurrent fixture effects. An intermediate old ACL test expected a global-role-derived `invalid_input` response for a NULL block: it now checks a real synthetic block for staff ALLOW and explicitly requires missing-resource DENY, preserving the security assertion instead of restoring global authority. No full-suite failures remain.

Existing build warnings about middleware convention and Node module type were not addressed in this security-only task. Error-state browser tests intentionally log controlled read failures; their assertions pass.

### Exact task file scope

1. `supabase/migrations/20261008100000_harden_cancellation_tenant_authority.sql` — new.
2. `supabase/migrations/20261008110000_harden_resource_helper_role_authority.sql` — new.
3. `supabase/tests/20261008100000_harden_cancellation_tenant_authority_test.sql` — new focused matrix and cleanup.
4. `supabase/tests/20260816143000_harden_public_function_execute_acl_test.sql` — resource-based fixture/assertion update only; no historic migration edit.
5. This report — updated evidence.

`AGENTS.md`, prior SaaS reports/plan, `FINAL_SAAS_SECURITY_AUDIT_2026_09.md`, and `supabase/drafts/*` remain unrelated and excluded. The staging area is empty. The external diagnostic script remains outside the repository and is not checkpoint scope.

### Remediation handoff

EVENT and RESERVATION required matrices: PASS.

PROFILES.ROLE AUTHORITY REMOVED: YES — audited active cancellation/helper paths.

TENANT_MEMBERSHIP AUTHORITY: PASS.

RESOURCE TENANT BINDING: PASS.

OTHER GLOBAL-ROLE AUTHORITY HITS: 13 active helpers corrected; remaining hits classified above.

BLOCKER STATUS: RESOLVED LOCALLY / NOT DEPLOYED.

PRODUCT-10E READY TO RESUME: YES — local onboarding implementation only; this does not declare PRODUCT-10E LOCAL PASS.

PRODUCTION WRITE / STAGING / COMMIT / PUSH / DEPLOYMENT: NO.

SECOND PROD TENANT: NOT ACTIVATED BY THIS TASK.

DNS/CUSTOM DOMAIN: UNTOUCHED.

## Security patch production preflight — 2026-09-24

Repeat requested preflight completed with unchanged HEAD and migration SHA values: live origin/main unchanged, 117 matching deployed versions, exactly two pending migrations, dry-run exactly those two, production input fingerprints 15/15, unexpected function/ACL drift 0. Repeated SQL 46/46 and full DB 1804/1804, Node 803/803, Playwright 49/49, TypeScript/build/schema diff PASS. No implementation expansion or production/Git write.

Result: **PASS** for the two security migrations only. PRODUCT-10E onboarding was not resumed. This is deployment readiness, not a claim that the production vulnerability is already fixed.

### Repository and deployment identity

- HEAD / live remote main: `90c5895ef48352f09d3df5ca7e5e2943dc06a39d`; branch `main`; divergence `0/0`. Remote HEAD was checked with `git ls-remote`, without fetch/staging/commit/push.
- Linked production project reference: `yuyxfodozzpzrdzkmolu`.
- Production migration history: **117 deployed migrations match the local filesystem history through `20261007100000`**; no remote-only or mismatched versions.
- Exactly two pending migrations: `20261008100000` and `20261008110000`.
- `supabase db push --linked --dry-run`: PASS, lists exactly those two files and explicitly does not apply them. No actual push was run.
- SHA-256 rechecked: cancellation `1591FCB5895C51E502A1EB1429DC8900DBD7A53FEBDED5F6A358AB76ECAE3E38`; helpers `4620BA7EAE7648FDA3604EF263F0473D324E84D92203605A125A83C0B1055A5A`.
- Historical migration tracked diff: empty. No migration repair, destructive DDL, table/data changes, or new grants in either patch. They replace guarded function role assignments and retain closed INVOKER helpers.

### Read-only production inventory comparison

- Normalized production input fingerprints: **15/15 match** the migration guards.
- Public function inventory: production **141**, local target **141**.
- SECURITY DEFINER: production **85**, local target **85**.
- Signatures, owners, security modes and ACLs match between production and the local target. All fifteen helpers are INVOKER and owner-only EXECUTE; PUBLIC/anon/authenticated/service_role do not gain direct access. Existing entry wrappers remain unchanged.
- The 126 functions outside the patch have matching normalized definitions. Unexpected function drift: **0**.
- Exactly two planned search-path changes: `cancel_event_registration__saas9d2a_core` and `approve_event_registration__saas9d2a_core`, from `public, pg_temp` to `pg_catalog, public, pg_temp`. The initial strict metadata comparator flagged these; inspection confirmed the explicit migration ALTER statements and matching input fingerprints. These are target changes, not unexpected drift. No gate or migration was changed to accommodate them.
- Production tenant count: **1**, active tenant count: **1**. No second tenant was activated.

### Repeated tests and scope of evidence

Authorization behavior was tested on the local target, not by mutating production. Ordinary owners with global user/admin roles cannot override cutoffs; resource-tenant active admin/employee memberships retain the existing override; foreign-tenant admin, pending/suspended/no membership, anonymous and foreign ownership paths deny. Eligible owner self-cancellation remains functional. Reservation 12-hour and event 72-hour business rules are unchanged.

| Check rerun during preflight | Result |
| --- | --- |
| Targeted SQL, including post-Playwright rerun | 46/46 PASS |
| Full DB suite | 61 files, 1804/1804 PASS |
| Node | 803/803 PASS |
| Playwright | 49/49 PASS |
| TypeScript | PASS |
| Local production build | PASS |
| Local schema diff / complete shadow replay | PASS, No schema changes found |
| Git diff check | PASS |
| Focused transaction fixture cleanup | 0 |
| E2E test-user / temporary-tenant / test-lane cleanup counts | 0 / 0 / 0 |

Playwright/build logs include existing warnings, controlled error-state diagnostics, and a destination-stream-close diagnostic; all assertions pass. This report does not claim an entirely empty console log. No application code was changed.

Exact proposed checkpoint scope remains the five files listed above: two migrations, focused SQL test, existing ACL regression test, and this report. Excluded: `AGENTS.md`, `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md`, `SAAS_FINAL_MIGRATION_MASTER_REPORT.md`, `FINAL_SAAS_SECURITY_AUDIT_2026_09.md`, and `supabase/drafts/*`. Staging remains empty.

**READY FOR CHECKPOINT COMMIT/PUSH: YES.**
**READY FOR PRODUCTION DEPLOYMENT: YES — readiness only; separate deployment authorization required.**
**PRODUCTION WRITE / STAGING / COMMIT / PUSH / DEPLOYMENT: NO.**

## Security patch production deployment — 2026-09-24 (latest authoritative result)

**SECURITY PATCH PROD: PASS. PRODUCT-10E READY TO RESUME: YES, local implementation only after review; no onboarding continuation was performed.**

### Checkpoint and deployment

- Security checkpoint: `666eddfca92ddb8f7d7d9b68fe063fee97b80ba4`, message `PRODUCT-10E security patch tenant cancellation authority`.
- Exactly the approved five files were staged and committed. Cached diff check passed. No AGENTS, drafts or unrelated SaaS document entered the checkpoint.
- Push to origin/main was fast-forward from `90c5895ef48352f09d3df5ca7e5e2943dc06a39d`; live remote matched the checkpoint, divergence 0/0.
- Final production gate rechecked project `yuyxfodozzpzrdzkmolu`, both authorized SHA-256 values, exactly two pending versions, 15/15 input fingerprints and SECURITY DEFINER=85.
- `supabase db push --linked --yes` applied only `20261008100000_harden_cancellation_tenant_authority.sql` and `20261008110000_harden_resource_helper_role_authority.sql`.
- Each version occurs exactly once in production migration history. LOCAL=REMOTE for all 119 versions; pending=0. Final dry-run: `Remote database is up to date`.
- Both migration file SHA-256 values remain identical to the authorized preflight values above.
- No separate application deployment was needed or invoked: the checkpoint changes SQL/tests/report only. Any automatic Git-integrated build does not change application source.

### Target and production security matrix

All 141 public function normalized fingerprints, signatures, owners, ACLs, security modes and search paths match the tested local target. Unexpected drift=0; unexpected grants=0; SECURITY DEFINER=85. All fifteen patched internal helpers remain closed INVOKER functions, with no PUBLIC/anon/authenticated/service_role direct EXECUTE.

The focused test was executed through the production Management API as postgres in a single BEGIN/ROLLBACK transaction. Only psql transport directives were adapted in memory: `\\set` was removed, generated fixture UUIDs were bound explicitly, and `\\gset` cleanup references were replaced by the same exact UUIDs. No test expectation or authorization logic changed; no fixture script or migration was edited. Transaction-local lock/statement timeouts were added. No COMMIT was issued.

Each of the 45 in-transaction assertions raises on mismatch. The API returned the final post-ROLLBACK result: `ok 46 - rollback cleanup across all fixture tables = 0`, with successful execution and no error. Thus **46/46 PASS**. Temporary synthetic active tenants were transaction-private and rolled back; no second tenant was durably activated or made visible to concurrent clients.

- user membership + global user/admin: cutoff override DENY for both cancellation paths.
- active resource-tenant admin/employee + global user: override ALLOW under existing scope.
- pending/suspended/no resource membership, admin only in the other tenant, anonymous and foreign ownership: DENY.
- eligible owner self-cancellation: PASS; reservation 12h and event 72h semantics unchanged.
- Additional helper behavioral probes and all thirteen resource-authority/ACL/search-path assertions: PASS.

Run fixture identifiers: tenant `58cf3bd7-3b76-4a17-84a3-a80817e1e589`, other tenant `55335993-4dfe-4751-9cbe-ffa4b7e770dd`, actor `30ec02a0-0fa7-429c-886b-2d3f5d5e312f`. The test's exact-ID cleanup covered users, profiles, memberships, plans, events, registrations, lanes, pricing, reservations and audit. An independent read-only query confirmed fixture tenants/users/audit=0; production tenants=1 and active tenants=1.

### Regression and limitations of evidence

Post-deploy production HTTP smoke: all 17 requested/relevant routes completed with HTTP 200 after expected redirects, 5xx=0: `/`, `/csk-krutla`, `/csk`, `/t/csk`, `/t/csk/booking`, `/t/csk/events`, `/booking`, `/events`, `/account`, `/dashboard`, `/login`, `/admin`, `/admin/settings`, `/t/csk/admin`, `/t/csk/admin/reservations`, `/t/csk/admin/users`, `/t/csk/admin/reports`. Public aliases canonicalize correctly; unauthenticated protected routes redirect to login.

Full regression evidence comes from the immediately preceding repeated preflight on the identical target: DB 1804/1804, Node 803/803, Playwright 49/49, TypeScript/build/schema diff PASS. Production target parity plus the production 46-control matrix establishes the DB patch result. This is not a claim of a new authenticated production browser session or rerunning the full fixture-heavy DB suite on production. PRODUCT-10A/B/C/D and auth/account automated regression remain green; no application code changed.

Final git diff check: PASS. No migration repair, force push, rebase/reset, DNS/custom-domain change, customer-record mutation or persistent synthetic fixture. The five pre-existing unrelated entries remain excluded. The evidence update is a separate report-only checkpoint, not mixed into the security implementation commit.

## Archived pre-remediation reproduction (2026-09-24)

The following evidence records the original blocker before the two local migrations. Its stop verdict and proposed correction are superseded by the authoritative remediation result above; it is retained to preserve the security finding rather than erase it.

Severity: HIGH — legacy global role affects a tenant-owned cancellation privilege. The confirmed impact is bypass of the 72-hour self-service cutoff for the actor's own registration; this diagnostic does not establish access to another user's registration or a cross-tenant PII leak.

Current local database definitions and active callers show this chain:

`app/api/cancel-event-registration/route.ts` → `cancel_event_registration_v2(uuid,uuid)` → `cancel_event_registration(uuid)` → `cancel_event_registration__saas9d2a_core(uuid)`.

The scoped wrapper requires tenant membership and resource consistency. The next wrapper permits the owner. However, the core reads `profiles.role`, derives `is_self_service_actor` from that global role, and only applies the 72-hour cutoff to the self-service branch. A tenant member with role `user` and a legacy global role `admin` therefore reaches the staff branch for their own registration.

### Reproduction

Executed twice against **local** Docker container `supabase_db_csk-booking`, never production. Synthetic active tenant, explicit full-plan assignment, synthetic auth user/profile, active membership with role `user`, own registered event registration, event beginning in approximately one hour. Enabled the existing PRODUCT-10D test enforcement switch so entitlement checks were not skipped. Actual RPC execution used `SET LOCAL ROLE authenticated` and that synthetic user's JWT claims.

| Tenant membership | Legacy global role | Observed result |
| --- | --- | --- |
| active / user | user | DENY, SQLSTATE `55000`, 72-hour cutoff message |
| active / user, unchanged | admin | ALLOW, `changed=true`, `new_status=cancelled`, `operator_role=admin` |

The test explicitly asserted that membership remained `user` after the global profile-role change. The global role was changed only by the local diagnostic as database owner; this is **not** evidence that a client can edit its own global role.

Both runs ended with `ROLLBACK`. The final run checked the exact generated identifiers across `auth.users`, `profiles`, `tenants`, `tenant_memberships`, `tenant_plan_assignments`, `events`, `event_registrations`, and `audit_logs`: **fixture_remaining=0**.

Local reproducer (outside the repository and excluded from any checkpoint):
`C:/Users/Mpios/Desktop/APP Krutla/product10e-cancellation-authority-diagnostic.sql`.

### Related surface and required correction

`cancel_reservation__saas9d1_core(uuid)` also reads `profiles.role` to select the staff branch and whether the 12-hour cutoff applies; the active `cancel_reservation(uuid)` wrapper calls it. This second surface is a definition-level finding, not yet a behavioral reproduction.

Before extending cancellation to suspended tenants, implement a narrowly scoped **forward-only** correction: derive staff authority from the resource tenant's active admin/employee membership; treat ordinary owners as self-service regardless of their global profile role; preserve canonical 12-hour / 72-hour boundary rules, statuses, audit binding and resource ownership checks. Test both reservation and event paths, including mismatched legacy/global roles, active/suspended tenant continuity, foreign resources and pending/suspended memberships. Do not relax the general tenant-role helper or RLS.

No historical migration, cancellation function, application code or production state was modified. No new PRODUCT-10E migration was created, and no Git staging/commit/push was performed. Full implementation suites were not run; the result here is a targeted security reproduction, not PRODUCT-10E acceptance evidence.

READY FOR PRODUCTION PREFLIGHT: NO.

PRODUCTION WRITE: NO.
