# PRODUCT-10G-A — TENANT EMAIL FOUNDATION HANDOFF

Base HEAD: `74813eb6d420f259380ad26e18993c85637b7457`.
Local implementation and security-review candidate only. No staging, commit, push, deployment, production DB/config write or real email delivery.

## Exact scope

Runtime:
- `app/api/send-reservation-confirmation/route.ts`
- `app/api/send-reservation-cancellation/route.ts`
- `app/api/send-event-registration-confirmation/route.ts`
- `lib/server/event-reserve-promotion.ts`
- `lib/server/event-reserve-confirmation-email.ts`
- `lib/server/confirmation-email-delivery.ts`
- `lib/server/operational-email.ts` (new server-only adapter)
- `lib/server/operational-email-core.ts` (pure types/rendering/URL helpers; no env or secret accessor)
- `lib/server/operational-email-config.ts` (server-only existing sender configuration)

Tests:
- `lib/server/operational-email.test.mjs` (new)
- `lib/server/email-html.test.mjs`
- `app/api/send-reservation-cancellation/route.test.mjs`
- `supabase/tests/20261013100000_operational_email_context_test.sql` (new)

Migration:
- `supabase/migrations/20261013100000_add_operational_email_tenant_context.sql` (new)

Documentation: this report. Previous audit report and `docs/auth-email-cutover-prewrite.md` were present before implementation and were not edited. No CSK UI, auth/recovery, historical migration or unrelated file changed.

## RPC / authority

`resolve_operational_email_tenant_context_v1(text,uuid)` accepts only `p_resource_type` and `p_resource_id`. Types: reservation, event, event_registration. Waitlist/promotion registrations use event_registration; promotion batches use their authorized event.

Projection: exactly tenant_id, tenant_slug, public_slug, display_name. Reservation binds lane tenant; registration binds event tenant. Invalid/missing resource or profile fails closed. No default tenant, host lookup, tenant id input, user/profile authority or platform preview bypass.

SECURITY DEFINER, owner postgres, fixed search_path `pg_catalog,public,pg_temp`. EXECUTE: service_role only among application roles; PUBLIC/anon/authenticated denied. Database owner retains operator privileges as expected. No direct table grants, no business mutations. Existing owner/membership/operation checks remain before server resolver invocation. The RPC is an internal projection, NOT a standalone authorization to send an email.

Existing suspended/private resource context is readable. This does not authorize creation, publication, promotion or email continuity. Existing business/delivery gates remain unchanged. Local test proves the suspended new-business trigger still denies insertion while context lookup works.

## DTO / URLs / display

Typed DTO: tenantId, tenantSlug, publicSlug, displayName, canonicalPublicUrl. tenantSlug is needed because the established authenticated routes use technical slug, not public slug.

Canonical source: tenant_public_profiles.display_name/public_slug joined to resource tenant; technical slug from tenants.slug. Stored name is used exactly after trimming, without renaming CSK to a hardcoded alias. If current CSK metadata says `CSK — Centrum Szkolenia Krutla`, that remains the subject name; fixtures exercise `CSK Krutla` and `Strzelnica Alfa`. Missing/invalid display name fails closed.

Canonical host: PLATFORM_BASE_URL. Public URL: `/{publicSlug}`. Event history: `/t/{tenantSlug}/my-events`; reservation history helper supports `/t/{tenantSlug}/my-reservations`. Existing check-in and promotion capability routes retained, token shape checked, canonical host enforced. No new route, custom domain, env site URL, forwarded host, arbitrary next URL or legacy `/my-events` link.

One subject builder: `StrzelajTu.pl / {displayName} — {notificationLabel}`. CR/LF/control characters rejected. Common header/footer escape HTML; text versions remain plain. Typed `OperationalEmailInput<Operation>` pairs tenant and operation for future template extraction. Five existing templates retain operational content and now use shared branding fragments; no redesign of business flows.

HARDCODED OPERATIONAL CSK: BEFORE 38 occurrences in five send/template files; AFTER 0 in those files. Public CSK content, legacy compatibility routes and intentional test fixtures untouched.

## Sender / delivery boundaries

Single config accessor reads existing RESEND_API_KEY and RESERVATION_EMAIL_FROM. From value is preserved; no Sender Display Name cutover. No reply-to was previously configured by these sends and none is introduced. Target future display name remains StrzelajTu.pl, subject to separate production config authorization.

Idempotency foundation only: existing shared `deliverConfirmationEmail.send(idempotencyKey)` passes the existing key into Resend. Future 10G-C can adopt this seam for invitation/accepted-promotion flows. No queue, reminder, new retry state, dedupe schema or outbox is added. Known audit findings about invitation duplicate risk and silent accepted-receipt failures remain deferred.

Business mutation still completes before the separate email attempt. New context failure follows the existing controlled error/warning path; it cannot rollback a successful booking/event transaction. Service key is confined to server-only adapter and never exposed through a public environment variable or log.

## Original implementation evidence (superseded by remediation below)

- Focused SQL: **17/17 PASS**, actual local PostgreSQL in `supabase_db_csk-booking` mapped to 54322. New migration and synthetic A/B fixtures executed in one transaction followed by ROLLBACK.
- SQL covers reservation A, event B, waitlist B, exact four-field DTO, suspended lookup, suspended new business denial, anon/authenticated execution denial, PUBLIC/service_role ACL, unchanged closed table SELECT, forged resource type/id, unknown/null/deleted resource and missing profile.
- Targeted Node: **106/106 PASS**, seven email/auth/delivery test files including new foundation tests.
- Full Node: **899/899 PASS** (`*.test.mjs` under app/lib/tests), no failures or skips.
- TypeScript: **PASS**, `npx tsc --noEmit`.
- Production Webpack Build: **PASS**, `npx next build --webpack`.
- ESLint changed TS/MJS files: **PASS**, no errors/warnings emitted.
- `git diff --check`: **PASS**. Git CRLF informational warnings only.
- Existing Node MODULE_TYPELESS_PACKAGE_JSON / Next middleware-deprecation warnings remain; no unrelated package or middleware changes.
- Target SECURITY DEFINER in transaction: **108**. After rollback new RPC absent (`MIGRATION_PERSISTED=false`), fixture count **0**. Running local DB not permanently migrated.

No full SQL suite, production preflight, real provider delivery or live A/B email E2E was executed. Node tests cover context/templates/URLs and preserve existing auth/delivery assertions; focused SQL covers actual resolver/ACL. This is evidence for security review, not production deployment approval. A later deployment must install the migration before app rollout.

## Migration identity

`20261013100000_add_operational_email_tenant_context.sql`

SHA-256: `43B4F71F2C4F0570CBD4644A90F2C6BA06F328825C0249704AA96D9017877459`

One forward-only migration after repository head 20261012100000. No historical migration edits or migration repair.

## Final gate

TENANT EMAIL DTO: IMPLEMENTED

TENANT AUTHORITY: RESOURCE-DERIVED

SUBJECT BUILDER / COMMON HEADER: IMPLEMENTED

EVENT LINKS: FIXED (resource-derived technical slug, canonical platform)

FIRST-ACTIVE FALLBACK: NONE

FORGED TENANT: DENY (extra selector fields rejected before RPC)

MISSING TENANT: FAIL-CLOSED

TENANT A/B ISOLATION: PASS within focused SQL and Node scope

RESEND CONFIG: UNCHANGED

IDEMPOTENCY: FOUNDATION ONLY

FAILURE MODEL: PRESERVED

DB CHANGE: YES — one explicitly approved local migration candidate, tested rollback-only

PRODUCTION WRITE: NO

READY FOR SECURITY REVIEW: YES

READY FOR PRODUCT-10G-B: NO — until review

NO COMMIT / NO PUSH / NO DEPLOY

## Blocker remediation and clean candidate — 2026-09-26

This section supersedes the original test counts and security-review gate above.

Clean candidate: `C:/Users/Mpios/Desktop/APP Krutla/p10ga-clean-review`, detached at freshly fetched origin/main `74813eb6d420f259380ad26e18993c85637b7457`. No staging, commit or push. Candidate scope is 51 files: 9 runtime files, 3 Node tests, 35 existing SQL regression files, 1 focused SQL test, 1 migration, 1 local replay script and this report. Excluded: prior audit/security-review documents, auth-email-cutover document, CSK UI, AGENTS.md, drafts, historical migrations and auth/recovery changes.

Existing SQL regression diffs are only the approved inventory delta: SECURITY DEFINER 107 to 108, one exact service-only function entry (170 total public functions, seven service-executable contracts), and its explicit tenant-function allowlist entry. No permission assertion was weakened. The replay script creates and destroys a fresh local scratch database; it never resets the app DB or connects to production.

### Revised security contract

- Reservation confirmation/cancellation use the reservation wrapper; registration confirmation and accepted promotion use the registration wrapper; promotion batches use the event wrapper. Each wrapper sets a literal resource type in guarded server code. Request schemas do not expose resource type.
- The same UUID in reservation A and event B resolves to A via reservation and B via event. This is intentional typed identity, not a collision failure. Unknown types, missing resources and invalid DTOs fail closed; RPC has explicit CASE branches, no dynamic SQL or first-active fallback.
- Pure core has no env, API-key accessor or client creation. Adapter and config import `server-only`; actual imports outside the server condition are tested to fail. No secrets are returned in API payloads or props. Browser static build contains no Resend/service-role identifiers, resolver or config accessor.
- BUSINESS PRESERVED + EMAIL FAIL-CLOSED is the explicitly accepted failure model. Sender configuration remains unchanged; no real email was sent. Existing authorization remains before resolver invocation. Suspended resource lookup succeeds while existing lifecycle guards deny new business.

### Fresh exact-candidate evidence

- Focused SQL: 19/19 PASS, including typed UUID collision, A/B binding, strict DTO, ACL, missing/deleted/unknown resources and suspended continuity.
- Full DB: 2071/2071 PASS across 67 SQL files, on fresh replay of all 128 deployed migrations plus the candidate migration.
- SECURITY DEFINER: baseline 107; local target 108. Unexpected grants: 0. PUBLIC/anon/authenticated EXECUTE denied; service_role allowed. Direct table grants unchanged.
- Full Node: 904/904 PASS (831 ordinary-runtime tests plus 73 server-condition tests). React rendering tests correctly use ordinary Node; guarded adapter tests use `--conditions=react-server`.
- Targeted Node: 83/83 PASS (foundation, delivery, HTML and cancellation suites).
- TypeScript PASS; production Webpack Build PASS; ESLint changed TS/MJS PASS; diff check PASS.
- Existing warnings: middleware deprecation, Webpack cache size and framework Edge process.cwd import via linked dependencies. No application build failure.
- Schema: replay baseline equals current local public schema; post-test schema unchanged. Scratch DB cleanup: 0 remaining; fixture transactions rolled back.

### Live read-only migration preflight

Project `yuyxfodozzpzrdzkmolu`: 128/128 deployed migration versions match through `20261012100000`; mismatches 0. Exactly one pending migration: `20261013100000_add_operational_email_tenant_context.sql`. Linked dry-run lists exactly that migration and explicitly performs no push. Historical migration Git blobs unchanged. SHA remains `43B4F71F2C4F0570CBD4644A90F2C6BA06F328825C0249704AA96D9017877459`.

Migration-history drift: 0. Production schema drift verification is recorded separately below; matching migration versions alone is not a full schema drift proof.

### Final preflight blocker: schema provenance

`supabase db diff --linked --schema public` completed successfully as a read-only comparison, but did NOT produce an expected-only diff. Its local shadow replay reports REVOKE REFERENCES/TRIGGER/TRUNCATE for service_role on confirmation_email_rate_limits and lane_booking_family_configuration_versions, plus replacements of existing public functions. The drop of the new resolver in the shadow-to-remote diff is expected because the candidate migration is not deployed. The other output has not been established as semantic production drift; shadow initialization/default-ACL and function-body formatting differences must be distinguished from real drift before approval.

The history-preserving local replay has zero service_role ACL on those two tables and equals the current local public schema. That is not evidence that the CLI-created shadow has the same initialization. No generated diff SQL was executed. No grants, historical migrations or production objects were changed to suppress the discrepancy.

LOCAL REMEDIATION: PASS. CLEAN PRODUCTION PREFLIGHT: BLOCKED pending read-only normalized catalog/ACL comparison against the historical baseline (excluding the one pending RPC). Production schema drift: NOT CONFIRMED; zero drift not proven. READY FOR CHECKPOINT COMMIT: NO. READY FOR PRODUCTION DEPLOY: NO. This is a verification blocker, not a confirmed vulnerability. Recommended next action: compare owner/security/search_path/normalized function bodies/ACL and both technical-table ACLs using the same history-preserving replay as the full SQL suite, not unqualified CLI shadow defaults.

No production DB/config write, staging, commit, push, deployment or real email delivery. PRODUCT-10G-B remains NO-GO until production PASS.

## Schema forensics closure / deployment authorization — 2026-09-27

The earlier schema-provenance blocker is resolved. Direct read-only production/local/actual CLI-shadow catalogs prove: 169 existing functions match in normalized bodies, attributes, owner, search_path and EXECUTE ACL; production SECURITY DEFINER is 107. All 126 functions emitted by raw diff match after CRLF/LF normalization only. Both technical tables are owner-only in production and history-preserving local replay; CLI shadow alone has additional service_role TRUNCATE/REFERENCES/TRIGGER/MAINTAIN. These artifacts occur on the pre-10G-A baseline as well. Baseline raw diff equals candidate raw diff after removing the one expected pending-RPC difference. Semantic production drift for all reported objects: 0. No generated diff SQL was applied.

Forensics evidence is stored outside the checkpoint in `10ga-drift-evidence`; its helper scripts are excluded. The local SQL replay runner in this checkpoint is part of the approved test suite, not a production/runtime helper. User authorized exact-candidate commit, deployment of only 20261013100000, DB post-deploy verification, and only after DB PASS fast-forward app push and Vercel autodeploy. No real email sends, DNS or Resend configuration changes are authorized.
