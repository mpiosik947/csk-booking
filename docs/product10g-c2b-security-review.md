# PRODUCT-10G-C2B — local security review

Base: `18abc945f3dd8564164768f48287d32e6a9178f4`.
Migration remains **DRAFT**. No staging, commit, push, deployment, production data write,
real email send, or scheduler action was performed.

## Approved dispatch boundary

Cancellation and each positive-email claim/admission lock the authoritative `events`
row with `FOR UPDATE`. Cancellation committed first denies a new admission.
Admission committed first permits only that existing leased attempt. No transaction
or row lock crosses the provider HTTP request. This is not a recall or exactly-once guarantee.

Before provider invocation, a service-only RPC validates the exact existing claim and
its DB-clock lease, not a permanent dispatch flag. Expired/replaced claims do not pass.
Every new positive claim rechecks event cancellation under the event lock. Therefore
crash, definitive failure, or uncertain outcome followed by cancellation cannot mint
a new positive send attempt. Provider idempotency identity remains unchanged.

## Positive email audit

| Flow | Admission | Final attempt validation |
|---|---|---|
| Registered confirmation | `prepare_confirmation_email` | Exact delivery claim/lease |
| Reserve/waitlist confirmation | Same confirmation contract | Exact delivery claim/lease |
| Reserve promotion/place offer | `prepare_event_reserve_promotions` | Exact promotion claim/lease |
| Accepted-place confirmation | `claim_event_reserve_acceptance_email_v1` | Exact delivery claim/lease |

Individual registration cancellation and event-wide cancellation are not positive
progression; they retain cancellation-receipt retry semantics. Booking flows are
unchanged. Reminder/scheduler implementation is outside this patch.

## Event cancellation

- Separate irreversible `cancelled_at` / `cancelled_by`; `is_active` stays visibility.
- Cancellation hides the event, preserves registration statuses, and atomically
  inserts resource-derived `event_cancellation` obligations.
- Admin/employee membership in the event tenant is required. Instructor/user and
  cross-tenant staff are denied. `profiles.role` is not authority.
- Recipients: registered, approved, reserve. Cancelled and participant excluded.
  Prior read-only production inventory found participant=0.
- Event/registration triggers deny reactivation and new participation advancement.
  Current check-in implementation concerns reservations, not event registrations.
- Explicit staff request processes at most five deliveries; no background worker.
- Stable key: `event-cancellation/{eventId}/{registrationId}`. Three attempts,
  five-minute lease, 23-hour retry window. Exhausted expired attempts become failed.
- Sent/failed delivery retention is 90 days; permanent event marker blocks fresh
  fan-out on repeated cancellation. No historical backfill.
- Reuses branded operational shell; no recipient address, body, token, or private
  metadata is stored in the new delivery identity.

## Migration / ACL

`20261019100000_add_event_wide_cancellation.sql`

SHA-256: `F54C0F198C593E3925C0F4461AD81153CADB9F40477EE367CFE514827FDFDB60`

LF only, final newline. No deployed migration was edited.
Public function inventory: 186 → 193. SECURITY DEFINER: 117 → 120.
Two tenant-authorized authenticated RPCs, two service-only RPCs, two non-callable
trigger functions, and one postgres-only retention function. PUBLIC EXECUTE stays
absent. No new direct table grants.

The local app DB had an earlier draft; evidence uses fresh isolated canonical replay,
not that mutable database. The harness removes its scratch database on completion.

## Test corrections and scope

Runtime scope (10 files):

- `app/admin/events/page.tsx`
- `app/api/cancel-event/route.ts`
- `app/api/send-event-registration-confirmation/route.ts`
- `lib/server/confirmation-email-delivery.ts`
- `lib/server/event-acceptance-delivery.ts`
- `lib/server/event-reserve-confirmation-email.ts`
- `lib/server/event-reserve-promotion.ts`
- `lib/server/event-positive-email.ts`
- `lib/server/event-wide-cancellation-core.ts`
- `lib/server/event-wide-cancellation.ts`

Tests: the 36 SQL inventory files classified below, the existing CSK visual test,
two new Node test files, one focused SQL suite, two local DB runners, one explicit
Node-only loader, and one HTTP Playwright suite. The one draft migration and this
report complete the proposed scope; nothing is staged.

The visual-only snapshot test excludes only the explicitly marked additive C2B
controller/button; existing UI behavior remains compared to HEAD. New tests cover
the confirmation modal/endpoint separately.
The explicit Node loader stubs `server-only` only in the Node test process; production
imports remain intact. It does not enable React's incompatible `react-server`
condition for ordinary SSR tests.

Historical SQL test changes below update exact inventories/fingerprints only. No
existing DENY was changed to ALLOW and no security test was removed.

## Verification evidence

Final local gate: **PASS**.

| Gate | Result |
|---|---|
| Focused SQL | PASS, including rollback, recipient eligibility, retry, terminal exhaustion, retention/no-recreation and sent-history preservation |
| Full DB | 72/72 files PASS on fresh canonical replay |
| Dispatch races | 15/15 PASS: 3 positive flows × 5 order/crash/failure scenarios |
| Targeted Node | 45/45 PASS |
| Full Node | 1026/1026 PASS, 0 skipped |
| HTTP Playwright | 5/5 PASS against local production build |
| TypeScript | PASS |
| Webpack production build | PASS |
| ESLint changed JS/TS files | PASS |
| Git diff check / new file whitespace | PASS |
| Public schema before/after SQL tests | 0 differences |
| Fixtures / scratch database cleanup | 0 remaining |
| Historical migration modifications | 0 |
| Remote history | Matches through 20261018100000; one local draft pending |
| Linked dry-run | Exactly 20261019100000_add_event_wide_cancellation.sql |

The original Playwright web-server wrapper stalled during Windows teardown; final
HTTP tests used the same running local production build via an ignored config without
server lifecycle management. The first new HTTP assertion expected only `no-store`;
it was corrected to the existing stronger global middleware cache header. No runtime
security header was weakened. The test server wrapper was interrupted after testing.

Race A/B/F are exercised by holding the first event lock in one session and starting
the competing transaction from another. C/D/E verify no new lease after cancellation
following crash, hard failure, or uncertainty. G/H are additionally covered by focused
SQL cancellation retry and cross-tenant denial. Provider calls are not made: HTTP-call
suppression/permission is validated by the server helper's Node tests, not live mail.

Ready for clean production preflight/review: YES. Ready for deployment: NOT APPROVED
in this task. Migration stays DRAFT. A full live schema-drift comparison and clean
candidate extraction are not represented as completed by the read-only history check.

Final results are recorded in the task handoff and ignored `test-results/c2b-*` logs.
The SQL suite checks schema stability and fixture counts before/after tests.
Race tests use isolated Docker Postgres sessions; no provider is called.
HTTP Playwright smoke covers anonymous denial, forged fields, GET safety, and the
existing individual cancellation endpoint; it does not send mail or test live delivery.

Read-only remote migration inventory: matches repository through `20261018100000`.
Dry-run reports exactly the C2B draft pending. This is history verification, not a
claim that a full production schema-drift comparison has been completed.

Excluded: existing D5-C operator/evidence scripts, reminder docs, email preview
generator, generated test results, AGENTS, and unrelated worktree files.

## Historical SQL test classification

- `supabase/tests/20260816143000_harden_public_function_execute_acl_test.sql`: function / ACL / trigger inventory update.
- `supabase/tests/20260904180000_harden_reservation_cancellation_email_delivery_test.sql`: message type inventory update.
- `supabase/tests/20260912100000_harden_event_registration_rpcs_test.sql`: exact intentional admission-function fingerprint update.
- `supabase/tests/20260913100000_harden_event_management_rpcs_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20260913150000_harden_public_event_readers_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20260914100000_harden_shared_confirmation_email_rpcs_test.sql`: SECURITY DEFINER count + exact admission-function fingerprint update.
- `supabase/tests/20260914150000_harden_event_reserve_promotion_rpcs_test.sql`: SECURITY DEFINER count + exact admission-function fingerprint update.
- `supabase/tests/20260915100000_harden_lane_block_rpcs_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20260916100000_harden_lane_family_creation_readers_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20260917100000_harden_lane_family_writer_helpers_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20260918100000_harden_admin_reservation_reports_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20260919100000_add_tenant_user_admin_notes_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20260919150000_harden_tenant_user_role_identity_contact_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20260920100000_add_tenant_user_verification_foundation_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20260920150000_cutover_tenant_user_verification_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20260921100000_close_legacy_global_verification_path_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20260922100000_harden_account_lifecycle_rpcs_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20260923100000_harden_profile_privilege_trigger_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20260924100000_harden_public_booking_configuration_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20260925100000_add_public_active_tenant_resolver_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20260926100000_add_tenant_scoped_operational_readers_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20260927100000_add_tenant_scoped_staff_event_rpcs_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20260927110000_add_tenant_scoped_lane_configuration_rpcs_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20260927120000_add_tenant_scoped_admin_reports_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20260927130000_add_tenant_scoped_admin_users_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20260928100000_add_c3_owner_calendar_and_global_profile_contracts_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20260929100000_close_global_role_helper_execute_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20260930110000_tenant_aware_onboarding_cutover_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20261001100000_retire_single_tenant_compatibility_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20261003100000_remove_single_active_tenant_guard_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20261004100000_add_public_tenant_directory_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20261005100000_add_public_tenant_landing_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20261006100000_add_tenant_public_settings_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20261007100000_add_saas_feature_entitlements_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20261008100000_harden_cancellation_tenant_authority_test.sql`: SECURITY DEFINER inventory/count update.
- `supabase/tests/20261011100000_verified_tenant_domains_test.sql`: SECURITY DEFINER inventory/count update.
