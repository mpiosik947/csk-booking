# PRODUCT-10G-B — Booking emails local review

## CURRENT — CLEAN CONTINUITY SECURITY REVIEW (2026-09-27)

This section supersedes historical counts/status below. Candidate: `p10gb-continuity-clean`, branch `review/10gb-continuity-clean`, base/origin `4baacfc57899e1e537d72c46d16c902f245c4363`. Nothing staged or committed. No production mutation or real email send.

### Exact scope reconciliation

Source worktree has 51 changed/untracked files, not the earlier 46. Clean candidate contains 47 files: A=1 booking runtime, B=1 cancellation-continuity runtime, C=1 new migration, D=36 SQL tests/test runner (34 existing regression files + one focused SQL + runner), E=6 Node tests, F=1 continuity UI integration, G=1 report. H=0 unrelated. Four category-I generated previews excluded:
- `docs/previews/10g-b/csk-confirmation.html`
- `docs/previews/10g-b/csk-cancellation.html`
- `docs/previews/10g-b/tenant-b-confirmation.html`
- `docs/previews/10g-b/tenant-b-cancellation.html`

No diagnostics, AGENTS, drafts, CSK visual work, recovery or unrelated files copied. Ignored dependency junction, local environment and linked-project cache are test infrastructure only, not checkpoint files.

The current tracked diff is 42 files, +217/-302, identically +217/-302 with --ignore-space-at-eol. The earlier +6141/-5873 is not reproducible from this current source; without the old diff artifact its cause cannot honestly be attributed to line endings. New/untracked files are not included in git diff --stat. The large file count now comes chiefly from exact SQL inventory regression expectations: 33 SECURITY DEFINER count updates and one exact ACL inventory file (some count files also carry the approved prepare fingerprint). No historical migration edit; migration status is exclusively:
`?? supabase/migrations/20261014100000_add_reservation_cancellation_email_continuity.sql`.

| Category | Exact included path |
|---|---|
| E | `app/api/send-reservation-cancellation/route.test.mjs` |
| B | `app/api/send-reservation-cancellation/route.ts` |
| A | `app/api/send-reservation-confirmation/route.ts` |
| E | `app/c3-phase3-cutover.test.mjs` |
| F | `app/continuity/ContinuityPanel.tsx` |
| G | `docs/PRODUCT_10G_B_BOOKING_EMAILS_REPORT.md` |
| E | `lib/server/booking-email.test.mjs` |
| E | `lib/server/confirmation-email-delivery.test.mjs` |
| E | `lib/server/confirmation-email-rate-limit.test.mjs` |
| E | `lib/server/operational-email.test.mjs` |
| D | `scripts/booking-email-continuity-local-review.mjs` |
| C | `supabase/migrations/20261014100000_add_reservation_cancellation_email_continuity.sql` |
| D | `supabase/tests/20260816143000_harden_public_function_execute_acl_test.sql` |
| D | `supabase/tests/20260913100000_harden_event_management_rpcs_test.sql` |
| D | `supabase/tests/20260913150000_harden_public_event_readers_test.sql` |
| D | `supabase/tests/20260914100000_harden_shared_confirmation_email_rpcs_test.sql` |
| D | `supabase/tests/20260914150000_harden_event_reserve_promotion_rpcs_test.sql` |
| D | `supabase/tests/20260915100000_harden_lane_block_rpcs_test.sql` |
| D | `supabase/tests/20260916100000_harden_lane_family_creation_readers_test.sql` |
| D | `supabase/tests/20260917100000_harden_lane_family_writer_helpers_test.sql` |
| D | `supabase/tests/20260918100000_harden_admin_reservation_reports_test.sql` |
| D | `supabase/tests/20260919100000_add_tenant_user_admin_notes_test.sql` |
| D | `supabase/tests/20260919150000_harden_tenant_user_role_identity_contact_test.sql` |
| D | `supabase/tests/20260920100000_add_tenant_user_verification_foundation_test.sql` |
| D | `supabase/tests/20260920150000_cutover_tenant_user_verification_test.sql` |
| D | `supabase/tests/20260921100000_close_legacy_global_verification_path_test.sql` |
| D | `supabase/tests/20260922100000_harden_account_lifecycle_rpcs_test.sql` |
| D | `supabase/tests/20260923100000_harden_profile_privilege_trigger_test.sql` |
| D | `supabase/tests/20260924100000_harden_public_booking_configuration_test.sql` |
| D | `supabase/tests/20260925100000_add_public_active_tenant_resolver_test.sql` |
| D | `supabase/tests/20260926100000_add_tenant_scoped_operational_readers_test.sql` |
| D | `supabase/tests/20260927100000_add_tenant_scoped_staff_event_rpcs_test.sql` |
| D | `supabase/tests/20260927110000_add_tenant_scoped_lane_configuration_rpcs_test.sql` |
| D | `supabase/tests/20260927120000_add_tenant_scoped_admin_reports_test.sql` |
| D | `supabase/tests/20260927130000_add_tenant_scoped_admin_users_test.sql` |
| D | `supabase/tests/20260928100000_add_c3_owner_calendar_and_global_profile_contracts_test.sql` |
| D | `supabase/tests/20260929100000_close_global_role_helper_execute_test.sql` |
| D | `supabase/tests/20260930110000_tenant_aware_onboarding_cutover_test.sql` |
| D | `supabase/tests/20261001100000_retire_single_tenant_compatibility_test.sql` |
| D | `supabase/tests/20261003100000_remove_single_active_tenant_guard_test.sql` |
| D | `supabase/tests/20261004100000_add_public_tenant_directory_test.sql` |
| D | `supabase/tests/20261005100000_add_public_tenant_landing_test.sql` |
| D | `supabase/tests/20261006100000_add_tenant_public_settings_test.sql` |
| D | `supabase/tests/20261007100000_add_saas_feature_entitlements_test.sql` |
| D | `supabase/tests/20261008100000_harden_cancellation_tenant_authority_test.sql` |
| D | `supabase/tests/20261011100000_verified_tenant_domains_test.sql` |
| D | `supabase/tests/20261014100000_reservation_cancellation_email_continuity_test.sql` |

### Fresh security evidence

- Focused SQL **91/91**, full DB **2162/2162**, 68 SQL files. Added explicit tenant A versus B provider-key noncollision and admin/employee A -> cancelled reservation B DENY assertions. Migration content/SHA unchanged.
- Targeted Node **115/115**; full Node **920/920** (831 ordinary + 89 server-condition), no skips.
- TypeScript **PASS**; Webpack production build **PASS**; changed-file ESLint **PASS / 0 errors**; git diff --check **PASS**.
- Fresh history-preserving scratch replay through deployed 10G-A then proposed 10G-B. SECURITY DEFINER 108 -> 109; exact function ACL test passes, including no unexpected PUBLIC/browser/service grants.
- Local pre/post migration snapshot: policies, table ACL/RLS flags and every non-target function unchanged. Post-test schema diff 0. Scratch database removed; remaining fixtures 0. Main local app DB unchanged.
- Existing build warnings: middleware convention deprecation, dependency Edge Runtime process.cwd warning and module-type warning. No build failure.

The new authenticated-only reader accepts only reservation UUID. It derives actor from JWT, tenant/owner from reservation, and allows owner or active same-tenant admin/employee only for active/suspended tenant AND already-cancelled reservation. Missing/noncancelled/foreign/no-identity cases fail closed before PII or tenant resolver. Closed internal helper has no application-role EXECUTE. No general RLS widening/direct table grants; fixed search_path; no profile/platform-role authority. Dormant remains DENY, not a new continuity lifecycle.

Actual preserved endpoint sequence is: verify JWT -> strict request -> existing abuse limiter -> authorized cancelled-only DTO -> resource-derived tenant context -> prepare (authority/state recheck + claim) -> provider using stable key -> sent marker. The limiter is intentionally earlier than prepare, as in the existing implementation; no generic active-tenant helper remains in cancellation authorization. Confirmation remains active-only.

Business cancellation commits first in /continuity. Only changed reservations attempt email; inner email catch preserves success and shows cancellation-succeeded/email-failed warning. Event registration continuity does not initiate new promotion/email business.

Idempotency is BEST-EFFORT with stable message-type/delivery-UUID provider key, five-minute lease, sent marker and bounded attempts. A/B keys cannot collide. Provider-sent + marker-write failure remains **DEFERRED DUPLICATE RISK**, not exactly-once. The patch adds no queue.

### Exact PII/content inventory

Cancellation DTO has seven fields: recipient_email, customer_name, reservation_date, start_time, end_time, lane_name, cancelled_by. Provider recipient comes from reservation customer_email, then owner profile email, then owner-only auth email fallback. Body includes customer greeting (possibly email fallback), own date/time/lane, cancelled status, user-versus-staff wording, public tenant display name, global platform brand and canonical own-history CTA. No admin notes, verification data, other participants, tenant/user UUID, secrets or Auth tokens. cancelled_by retains caller-owner versus staff wording, not a new persisted-canceller attribution.

Subject: `StrzelajTu.pl / {tenantDisplayName} — Rezerwacja anulowana`.
CTA: `https://strzelajtu.pl/t/{technicalSlug}/my-reservations`.
Tenant B rendering has no CSK fallback. Existing confirmation check-in capability remains unchanged and sensitive; never logged.

Existing service-role resolver/completion/limiter remain server-only, called after appropriate actor checks; no service key in NEXT_PUBLIC, client props, API response or logs. New continuity reader itself uses caller JWT, not service-role business reads.

### Read-only production preflight

Project `yuyxfodozzpzrdzkmolu`; 129/129 deployed migration versions match through `20261013100000`. Exactly one pending migration:
`20261014100000_add_reservation_cancellation_email_continuity.sql`.
SHA-256: `884C1B442693DAEC107EDD93E654B07BDC62640F61893CEA4D9B5BAAD231A5F2`.
Dry-run from the exact clean candidate lists only that migration.

Live production has 170 public functions / 108 SECURITY DEFINER. All 170 normalized bodies, signatures, owner/security/search_path attributes and ACLs match the canonical deployed baseline; PUBLIC EXECUTE count 0. Both historical technical tables retain service_role ACL {}. Input prepare fingerprint matches. No production SQL write, migration repair, email send, commit, push or deployment.

Fresh linked public-schema diff completed successfully. Raw diff is intentionally NOT empty: 127 function replacements (known line-ending differences plus the planned prepare change), reverse-direction drops for the two pending functions, and six service-role REFERENCES/TRIGGER/TRUNCATE revokes on the two technical tables caused by shadow initialization. The live catalog confirms those production grants are already absent, consistent with historical replay. After classifying those known artifacts and planned changes, no other schema statements remain: **0 unexpected semantic drift**. Generated SQL was not applied.

SECURITY REVIEW: PASS. CLEAN PREFLIGHT: PASS.
READY FOR CHECKPOINT COMMIT: YES, exact 47-file candidate only.
READY FOR 10G-B PRODUCTION DEPLOY: YES, requires separate authorization.
READY FOR 10G-C: NO until production PASS.
Original mixed source worktree is preserved. The three added SQL assertions and this current report exist in the clean candidate; use that candidate as the next checkpoint source, not a blind recopy from the older source.



## CURRENT — SUSPENDED CONTINUITY REMEDIATION LOCAL PASS (2026-09-27)

This section supersedes the historical blocker and pre-remediation results below. Ready for a new security review, NOT production deployment.

Migration: `20261014100000_add_reservation_cancellation_email_continuity.sql`
SHA-256: `884C1B442693DAEC107EDD93E654B07BDC62640F61893CEA4D9B5BAAD231A5F2`

### Narrow architecture

- New authenticated-only SECURITY DEFINER `get_reservation_cancellation_email_v1(uuid)` accepts only the reservation ID. It rejects missing, non-cancelled and non-authorized resources uniformly. PUBLIC/anon/service_role have no EXECUTE. Postgres owner; `search_path=pg_catalog,public,pg_temp`.
- Closed SECURITY INVOKER `can_authorize_reservation_cancellation_email_core_v1(uuid)` derives tenant and owner from the reservation. Tenant must be active/suspended. Owner identity alone is sufficient as explicitly approved; staff must have an active admin/employee membership for that exact tenant. Profile roles and platform roles confer no authority. All application roles are denied direct helper execution.
- The reader returns exactly seven fields: recipient_email, customer_name, reservation_date, start_time, end_time, lane_name, cancelled_by. Recipient precedence retains reservation customer email, owner profile email, then auth email only for the owner. No tenant/user UUID, notes or other participants are returned. The lane join is tenant-bound.
- Existing prepare_confirmation_email uses the same closed authorization helper ONLY in its cancellation branch and preserves the cancelled-state check. Confirmation branches remain active-only. Owner-only absence of membership is intentionally allowed for existing cancellation continuity; it is NOT permitted for new business/confirmation.
- Migration enforces exact prior normalized prepare fingerprint `17d8b973c9e3df0839f692fd8d9efbde` plus a single exact replacement anchor. New prepare fingerprint is `6e042eecfac75e9a5cc4f669e36a374f`. No historical migration edit.
- No RLS policy, table ACL, general role helper, public reader, lifecycle function, complete_confirmation_email or rate limiter changed. No new table/queue/retry architecture.

### Application integration

Cancellation endpoint now calls the dedicated reader under caller JWT instead of active-only reservation/profile reads. It validates the minimal DTO, then invokes the existing resource-derived 10G-A resolver. Delivery still rechecks authorization/state via prepare before provider send. Exact-only request schema rejects tenant/recipient fields.

The existing /continuity panel previously had no email call. It now attempts the existing cancellation-email endpoint ONLY after a changed reservation cancellation RPC succeeds, with only reservationId. A nested email failure handler preserves the completed cancellation and displays the existing warning. Event-registration continuity does not send/promote and remains untouched. No tenant authority moves to client props.

Cancellation subjects and canonical history CTA remain as specified in the previews. Raw reservation dates/times, recipient derivation and price semantics remain unchanged. New reader is not a general suspended-reservation reader.

### Security and regression evidence

- Focused SQL: **88/88 PASS**. Active/suspended owner/admin/employee real cancellation -> reader -> claim -> retry stable key -> completion -> sent replay; confirmed-record reader denied; cross-tenant admin/employee/user/instructor reader and claim denied; pending/suspended membership denied; missing/no-identity/no-membership denied; dormant read/claim denied; active confirmation preserved; suspended confirmation/new reservation/new event denied; limiter works; ACL/search_path checks.
- Full DB: **2159/2159 PASS**, 68 files, on fresh history-preserving isolated replay through 10G-A then the new migration.
- Targeted Node: **115/115 PASS**. Actual endpoint handler tests with mocked DB/provider exercise DB DENY propagation before resolver/render/send, forged selector/recipient rejection and authorized owner/admin/employee rendering. The SQL suite independently tests real DB authority. No live provider send.
- Full Node: **920/920 PASS** (831 ordinary + 89 server-condition), no skips.
- TypeScript: PASS. Webpack build: PASS. ESLint changed files: PASS. Diff check: PASS.
- Schema check: all public policies, table ACL/RLS flags and existing function bodies/ACL remain identical except the explicit prepare branch change. Target SECURITY DEFINER **109**, total public functions **172**. Post-test schema diff 0; scratch database cleanup 0.
- SQL regression updates are limited to 108 -> 109 definer counts (33 files), exact two-function inventory/one authenticated grant addition and two prepare fingerprint expectations. No assertions removed or broad allowlists substituted.
- Initial test runs exposed fixture overlap/ambiguous column issues and stale exact inventory/source assertions; these were corrected and final full runs passed. Existing MODULE_TYPELESS_PACKAGE_JSON and middleware deprecation warnings remain.

Main local app database was not migrated/reset. Every replay used a newly named scratch DB and dropped it in finally. Production was not queried or changed in this remediation. No real email, DNS, staging, commit, push or deploy.

Idempotency remains BEST-EFFORT with stable key, five-minute lease, persistent sent marker, bounded attempts and provider deduplication. Provider-sent/marker-fail remains deferred hardening; no exactly-once claim. Inactive/dormant lifecycle is not expanded (schema's dormant state explicitly denied).

READY FOR SECURITY REVIEW: YES
READY FOR PRODUCTION: NO

## HISTORICAL SECURITY REVIEW — BLOCKED (superseded by remediation above)

The prior LOCAL PASS / suspended-continuity claim below is superseded. The 19 resolver assertions did not test the complete cancellation email authorization/read/claim path. Fresh review reproduced a functional continuity blocker on local canonical history through 20261012100000 plus the deployed 10G-A migration applied inside one rolled-back transaction.

Evidence: active tenant owner prepare_confirmation_email(reservation_cancellation, id) returns ready. After suspension, the same owner's authenticated reservations SELECT returns 0 rows and prepare returns not_found. get_my_tenant_role_v1 returns NULL for both active admin and employee memberships on a suspended tenant. The context resolver itself still succeeds, and new business remains denied. The endpoint therefore cannot reach successful delivery for those existing obligations.

Root cause: active-only RLS/read and authority helpers remain before the resolver; prepare_confirmation_email also uses active-only is_tenant_member_v1/has_tenant_role_v1. PRODUCT-10E's continuity cancellation RPC deliberately does not initiate email. This is not a demonstrated cross-tenant leak or production drift; it is an unhandled lifecycle requirement. Severity: MEDIUM functional blocker, security-sensitive remediation.

Required next step: separately approve a minimal forward-only, resource-bound cancellation-mail continuity DB contract and its endpoint integration. Do not broaden generic RLS, change general active-only helpers, use service-role business reads, or enable new business for suspended tenants. Preserve owner/active own-tenant admin/employee checks before PII read/render/send and preserve delivery claim/recipient binding. No implementation or migration added during this review.

Fresh origin/main = HEAD = 4baacfc57899e1e537d72c46d16c902f245c4363; divergence 0/0. Clean candidate creation is deferred because the user requires PASS before extraction. Current worktree is detached; no new branch, staging, commit, push or deployment.

Exact initial scope (9 files):
- A runtime: app/api/send-reservation-confirmation/route.ts
- B runtime: app/api/send-reservation-cancellation/route.ts
- C tests: app/api/send-reservation-cancellation/route.test.mjs; lib/server/booking-email.test.mjs
- D documentation: docs/PRODUCT_10G_B_BOOKING_EMAILS_REPORT.md
- D generated previews, EXCLUDE from checkpoint: docs/previews/10g-b/csk-confirmation.html; csk-cancellation.html; tenant-b-confirmation.html; tenant-b-cancellation.html
- E unrelated: none in this worktree's 9 changed/untracked files.

Proposed clean scope is 5 files, not yet a validated clean candidate. No CSK visual/auth/recovery or DB/migration changes in diff.

PII inventory: recipient email in provider to; customer name (confirmation) or customer_name/profile full/first/last-name with existing customer_email fallback (cancellation); own booking date/time/lane/status/price in confirmation. Existing confirmation check-in capability UUID/link is retained: not an Auth access/refresh token, but a sensitive link that must not be logged or treated as public sample data. No admin notes, verification metadata, other participants, tenant UUID, service keys or auth tokens added.

Idempotency classification: BEST-EFFORT overall, with bounded deduplication. Existing stable key uses message_type + persistent delivery UUID; record uniqueness and tenant/recipient binding avoid attribute-based cross-tenant collisions. Claim lease 5 minutes, sent_at guard, 3 attempts/24h and rate limiter remain. Provider sent + marker failure is DUPLICATE RISK / DEFERRED HARDENING: Resend retains keys for 24h and requires identical payload; after that a retry may send again. Within that window a changed payload may produce 409. No exactly-once or at-least-once delivery guarantee. Source: https://resend.com/changelog/idempotency-keys and https://resend.com/blog/engineering-idempotency-keys .

Fresh review checks: origin fetch PASS; diff check PASS; local rollback diagnostic confirms blocker; resolver checks 19/19 still PASS; cleanup verification 0 synthetic tenants, 0 synthetic users and diagnostic function rolled back. Initial diagnostic had a SQL assembly error and exited with transaction rollback; corrected invocation completed explicit ROLLBACK. No production queries/writes and no email send.

Full Node/DB, TypeScript, build and ESLint counts below belong to the preceding local implementation run and were NOT rerun after the blocker was confirmed. Cross-tenant admin/employee full endpoint negative tests and fresh migration pending verification remain incomplete in this review. They are not reported as a fresh PASS.

READY FOR CHECKPOINT COMMIT: NO
READY FOR 10G-B PRODUCTION DEPLOY: NO
READY FOR 10G-C: NO

---

Base: 4baacfc57899e1e537d72c46d16c902f245c4363
Workspace: p10ga-clean-review. Local only; no staging, commit, push, deployment or production access in this task.

## Scope

Two runtime endpoints only: reservation confirmation and reservation cancellation. Added explicit authoritative tenant display name, existing status wording and canonical scoped reservation-history CTA. Cancellation subject now uses the required exact label Rezerwacja anulowana. Existing check-in link, customer greeting, dates/times/lane/price and recipient selection are unchanged. No reservation ID or additional PII introduced.

Test changes: cancellation href assertion now verifies the escaped new CTA; booking-email.test.mjs renders actual endpoint templates for A/B confirmation, owner cancellation and staff cancellation (six cases), escaping/fail-closed and endpoint contract assertions. Four synthetic HTML previews accompany this report.

No event-email changes, UI, DB, migrations, auth, sender credentials, DNS or new business logic.

## Authority / continuity / failure model

Both request schemas accept exactly reservationId; tenant_id/tenantSlug/publicSlug extras are rejected. JWT reads and owner or resource-derived tenant staff checks precede the service-only reservation resolver. Missing reservation returns before resolver. Invalid/unknown tenant context fails closed in the unchanged resolver. Staff recipient profile uses the existing resource-bound RPC; no additional PII source.

Existing scoped /t/[slug]/my-reservations is dispatched by app/t/[slug]/[...path]/page.tsx. CTA uses operationalEmailHistoryUrl and PLATFORM_BASE_URL, never request host/custom domain. Existing check-in capability remains unchanged.

Owner cancellation, admin reservations cancellation and employee/admin check-in cancellation commit their RPC before separate email fetch. BookingForm commits creation before separate confirmation fetch. Email errors leave business state intact and report the existing warning. No compensating reservation update/rollback is performed by either mail endpoint.

Suspended existing obligations remain resolvable; new business remains denied. Verified by isolated SQL, not production mutations. Relevant full-suite coverage includes cancellation-email delivery (24), shared confirmation authorization/lease (44), tenant booking RLS (60), cancellation authority (46), onboarding/continuity (86), resolver (19).

No existing reschedule/change email sender or caller was found in app/lib runtime inventory. No new notification flow added.

## Idempotency audit

Both endpoints already use prepare_confirmation_email -> Resend with stable idempotencyKey -> complete_confirmation_email. Persistent sent_at prevents resend after completed success; five-minute claim lease prevents concurrent sends; bounded attempts (3 in 24h) and separate confirmation rate limiter remain unchanged. Provider key is confirmation/{message_type}/{delivery UUID}. Failure codes remain controlled.

Residual: provider success followed by missing/failed completion can leave delivery ambiguous; a later retry relies on provider deduplication, not an atomic transaction spanning provider and DB. Payload can also change between attempts. No unconditional exactly-once claim. Reconciliation/retry hardening deferred to 10G-C/10G-E; no new durable state or provider configuration introduced here.

## Verification

- Targeted Node: 92/92 PASS.
- Full Node: 913/913 PASS (824 ordinary-runtime + 89 server-condition tests), zero skipped/failures.
- Focused SQL: 19/19 PASS.
- Full isolated SQL: 2071/2071 PASS, 67 files; history-preserving replay then existing 10G-A migration, SD 108.
- Local replay schema equivalence: PASS; post-test schema difference 0.
- Scratch database cleanup: 0 remaining.
- TypeScript: PASS.
- Webpack production build: PASS.
- ESLint changed code/tests: PASS.
- git diff --check: PASS.
- No real email send; no live provider delivery test; no browser email-client compatibility claim.

Tests combine actual template renders, static endpoint guard/order checks, existing delivery unit tests and actual SQL RLS/RPC tests. They are not a live HTTP-to-Resend end-to-end test.

## Synthetic previews

All values below are fixtures, not production personal data. Check-in token in confirmation preview is synthetic.

### csk-confirmation

Subject: StrzelajTu.pl / CSK — Centrum Szkolenia Krutla — Potwierdzenie rezerwacji

CTA: https://strzelajtu.pl/t/csk/my-reservations

HTML: previews/10g-b/csk-confirmation.html

Plain-text body:

```text
StrzelajTu.pl
CSK — Centrum Szkolenia Krutla

Cześć Osobo testowa,

Twoja rezerwacja została przyjęta.

Obiekt: CSK — Centrum Szkolenia Krutla
Status: Potwierdzona
Data: 15 października 2026
Godzina: 10:00 - 11:00
Oś: Oś testowa
Płatność: 100.00 zł, płatność na miejscu

Moje rezerwacje: https://strzelajtu.pl/t/csk/my-reservations

Szybki check-in:
Pokaż ten link lub kod QR obsłudze podczas wizyty. Obsługa potwierdzi obecność w systemie.
https://strzelajtu.pl/check-in/11111111-1111-4111-8111-111111111111

Przyjedź kilka minut wcześniej, aby spokojnie przejść formalności przed wizytą.
W przypadku pierwszej wizyty pracownik może poprosić o okazanie wymaganych uprawnień do wglądu.

CSK — Centrum Szkolenia Krutla
StrzelajTu.pl
```

### csk-cancellation

Subject: StrzelajTu.pl / CSK — Centrum Szkolenia Krutla — Rezerwacja anulowana

CTA: https://strzelajtu.pl/t/csk/my-reservations

HTML: previews/10g-b/csk-cancellation.html

Plain-text body:

```text
StrzelajTu.pl
CSK — Centrum Szkolenia Krutla

Cześć Osobo testowa,

Twoja rezerwacja została anulowana.

Obiekt: CSK — Centrum Szkolenia Krutla
Status: Anulowana
Data: 15 października 2026
Godzina: 10:00 - 11:00
Oś: Oś testowa

Moje rezerwacje: https://strzelajtu.pl/t/csk/my-reservations

W przypadku pytań skontaktuj się z obsługą obiektu.

CSK — Centrum Szkolenia Krutla
StrzelajTu.pl
```

### tenant-b-confirmation

Subject: StrzelajTu.pl / Synthetic Range B — Potwierdzenie rezerwacji

CTA: https://strzelajtu.pl/t/synthetic-b/my-reservations

HTML: previews/10g-b/tenant-b-confirmation.html

Plain-text body:

```text
StrzelajTu.pl
Synthetic Range B

Cześć Osobo testowa,

Twoja rezerwacja została przyjęta.

Obiekt: Synthetic Range B
Status: Potwierdzona
Data: 15 października 2026
Godzina: 10:00 - 11:00
Oś: Oś testowa
Płatność: 100.00 zł, płatność na miejscu

Moje rezerwacje: https://strzelajtu.pl/t/synthetic-b/my-reservations

Szybki check-in:
Pokaż ten link lub kod QR obsłudze podczas wizyty. Obsługa potwierdzi obecność w systemie.
https://strzelajtu.pl/check-in/11111111-1111-4111-8111-111111111111

Przyjedź kilka minut wcześniej, aby spokojnie przejść formalności przed wizytą.
W przypadku pierwszej wizyty pracownik może poprosić o okazanie wymaganych uprawnień do wglądu.

Synthetic Range B
StrzelajTu.pl
```

### tenant-b-cancellation

Subject: StrzelajTu.pl / Synthetic Range B — Rezerwacja anulowana

CTA: https://strzelajtu.pl/t/synthetic-b/my-reservations

HTML: previews/10g-b/tenant-b-cancellation.html

Plain-text body:

```text
StrzelajTu.pl
Synthetic Range B

Cześć Osobo testowa,

Twoja rezerwacja została anulowana.

Obiekt: Synthetic Range B
Status: Anulowana
Data: 15 października 2026
Godzina: 10:00 - 11:00
Oś: Oś testowa

Moje rezerwacje: https://strzelajtu.pl/t/synthetic-b/my-reservations

W przypadku pytań skontaktuj się z obsługą obiektu.

Synthetic Range B
StrzelajTu.pl
```

## Gate

LOCAL RESULT: PASS
READY FOR SECURITY REVIEW: YES
READY FOR PRODUCTION: NO — requires separate review/preflight/authorization.
RESEND CONFIG: UNCHANGED
DB CHANGE: NO
MIGRATION: NONE
REAL EMAIL SEND: NOT RUN
SECOND PRODUCTION TENANT: NOT ACTIVATED
