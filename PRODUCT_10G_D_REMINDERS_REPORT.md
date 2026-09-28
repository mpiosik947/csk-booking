# PRODUCT-10G-D — local implementation / security handoff

Current result: DEADLINE REMEDIATION / CLEAN PREFLIGHT PASS. The earlier lock-wait blocker and its evidence are retained below as historical findings; the final remediation section supersedes them.
Base HEAD: `5d9082d1f1831b55dd9373e94ee3b22217968f54`.
No staging, commit, push, deployment, production write, real email send or production scheduler activation.

## Migration and identity

Migration: `20261017100000_add_reminder_occurrences.sql`.
Current SHA-256: `F9B62C113C0ECDD2CFB4A72FA377F61F47CE8018B029042313727F627093D158`.
Obsolete pre-remediation SHA-256: `4B5E1ABD8469CEC2EAF478D053CB0FA30A00B84C3EB8195590DDF9C5F8B9076B`.
SECURITY DEFINER baseline 111; target 117. Seven new functions, six definers; four service-only executable contracts. Internal projection, trigger and purge are owner-only. Both new tables have RLS and no PUBLIC/anon/authenticated/service_role direct grants. Full exact ACL inventory passes.

`reminder_schedules`: UUID, reservation/event FK (exactly one), current generation, authoritative start instant, changed timestamp.
`reminder_occurrences`: UUID, message type, schedule FK, reservation/registration FK (exactly one), generation, start instant, creation timestamp. Resource type is represented by message type and constrained typed FK, not caller input.
No recipient/body/token/private tenant metadata is stored in either registry.

Both booking and event schedule changes are tracked DB-side. Booking currently has no supported reschedule UI contract, but is not assumed immutable at DB level. Event rescheduling is supported. A→B→A advances generations and creates A2; A1 cannot be reactivated. Final send checks compare generation and start with the current business resource.

Legacy `UNIQUE(message_type,record_id)` is preserved. Only reminder types use occurrence UUID as record_id. Existing prepare/confirmation/cancellation RPCs are not rewritten. The existing delivery binding trigger is extended narrowly for the two reminder types. Its legacy branches remain unchanged. Legacy prepare function definition hash matches replay/local DB: `6e042eecfac75e9a5cc4f669e36a374f`.

## Eligibility and authority

Types: `booking_reminder_24h`, `event_reminder_24h`.
Window: T−24h inclusive, strictly before T−1h; no new sends/retries at or after T−1h. Resource created less than 24h before start is excluded.
Europe/Warsaw timestamps are converted to absolute instants; 23/25-hour DST days are tested.
Booking must be confirmed; participation must be registered and event active. Cancelled/reserve/past/anonymized/missing resources fail closed.
Existing active/suspended obligations are eligible; dormant is denied. `inactive` is not a valid current tenant status, so no new status contract was invented.
Tenant/user/recipient/schedule are derived from authoritative reservation or registration→event. No caller-selected tenant, recipient, slug or schedule authority. Existing suspended new-business gates remain unchanged and full historical tests pass.

## Delivery and scheduler

Discovery inserts occurrence and delivery atomically, bounded to 100; concurrent discovery has one logical occurrence. Claims use row locks/SKIP LOCKED, max25, 5-minute lease, maximum3 attempts. Exhausted expired leases become terminal failed.
Final check revalidates eligibility immediately before provider call. Stable provider key: `{message_type}/{occurrence_uuid}`. Provider success followed by marker failure is reported UNCERTAIN, not exactly-once. Cancellation after final DB check but before external send remains an unavoidable external-send race.
Terminal delivery retention is 90days. Occurrence tombstones survive purge and anonymization. Resource deletion cascades their deletion. Purged logical delivery is not recreated.

`POST /api/internal/reminders` is server-only and requires dedicated `REMINDER_CRON_SECRET`; no body/query selectors. Secret is not the service-role key and is not NEXT_PUBLIC. Missing/invalid secret fails before DB/provider initialization. No secret values or recipient/provider payloads are logged. Existing operational sender configuration is reused.

## Local evidence

| Gate | Result |
|---|---|
| Focused SQL | 48/48 assertions, rollback-only |
| Full DB | 71/71 SQL files; 2259 pgTAP `ok` lines, plus custom-assertion suites including focused48 |
| Concurrent discovery / claim | PASS / PASS; one occurrence, one claimant |
| Targeted Node | 11/11 |
| Full Node | 992/992 (913 standard +79 server-condition tests) |
| Playwright HTTP | 4/4; missing/forged credentials401, GET405; no send |
| TypeScript | PASS |
| Webpack production build | PASS |
| ESLint changed JS/TS | PASS, 0 errors |
| Diff check | PASS |
| Fresh schema replay | PASS, exact public schema equality |
| Fixture / scratch cleanup | 0 / 0 |

The full DB inventory tests were updated precisely: 111→117 definers, 179→186 functions, 29→31 tables, two extra message types, four extra service-only RPCs, one additional trigger function. No privilege denial was relaxed and no deployed migration was edited.
The initial local app DB was behind the repository. Missing historical migrations were applied locally without editing their bytes (CRLF normalized only in psql input where historical dynamic SQL requires it). Fresh scratch replay records its own migration history in order. This is not migration repair or a production history claim. No live LOCAL=REMOTE/preflight claim is made here.
Playwright initially expected an exact cache header; Next adds stricter private/no-cache directives. The final test checks the `no-store` directive. Local process teardown required execution outside the process sandbox; the final run exited0.

Evidence: `test-results/reminders/` and `test-results/reminder-http/` (generated, not checkpoint scope).
Four synthetic HTML/plain-text previews are generated by `node scripts/reminder-previews.mjs`: Tenant A/B × booking/event. No provider call. Tenant B output contains no CSK fallback.

## D5 rollout boundary

Production scheduler: NOT ACTIVATED. No Vault/env/pg_cron/pg_net writes were made.
No tracked Vercel cron configuration was found in this candidate. This does NOT establish absence of manually configured jobs.
Live pg_cron/pg_net/Vercel scheduler inventory was not performed in this local gate; it remains mandatory read-only evidence before a production proposal.
After separate clean preflight/authorization: verify live inventory, deploy reviewed migration/app, provision dedicated secret safely in server env/Vault, then separately authorize a 15-minute job and controlled synthetic live test. Do not print secrets or activate cron as part of D1–D4.

READY FOR CLEAN PREFLIGHT: YES.
READY FOR D5 PRODUCTION CRON: NO.

## Historical CLEAN PREFLIGHT — BLOCKED before deadline remediation

Fresh origin/base: 5d9082d1f1831b55dd9373e94ee3b22217968f54; divergence 0/0.
Isolated candidate: C:/Users/Mpios/Desktop/APP Krutla/p10gd-clean-preflight, detached HEAD at origin/main.
44 files, no staged files. Excluded: three evidence scripts and generated artifacts.
All 36 existing SQL changes are approved inventory changes; OTHER=0. No security assertion removed or DENY changed to ALLOW for an existing contract.

### New mandatory deadline-lock failure

Local synthetic test: event starts at clock_timestamp()+1 hour 5 seconds. Discover/claim while eligible, hold its delivery row lock for eight seconds, invoke final_check_reminder_v1 while waiting on that lock.
Observed result: {"after_deadline":true,"payload_present":true}.
This violates strict no-send/retry at/after T−1h. The source eligibility uses statement_timestamp(), fixed before the lock wait. This is a DB deadline revalidation defect, not the acknowledged external provider race.
NO provider call occurred. Approved migration remains unchanged at SHA 4B5E1ABD8469CEC2EAF478D053CB0FA30A00B84C3EB8195590DDF9C5F8B9076B.
Remediation recommendation (NOT implemented): revalidate the wall-clock deadline after acquiring locks, at claim/final-check, with a permanent regression test. Changing the migration requires a new reviewed SHA and renewed preflight.

Initial synthetic cleanup transaction rolled back on a tenant plan FK; no partial delete committed. Follow-up cleanup verified exact synthetic tenant/user identity and fixture counts, removed the plan assignment in dependency order, then committed locally. Remaining deadline fixtures=0. Production unchanged.

### Fresh clean-candidate evidence

- Focused SQL 48/48 PASS; full DB 71/71 files PASS, 2259 pgTAP ok lines plus custom assertions.
- Targeted Node 11/11; full Node 992/992.
- Playwright HTTP secret denial 4/4; TypeScript PASS after Next generated its ignored declarations.
- Webpack build PASS; ESLint PASS; diff check PASS.
- Fresh target schema replay PASS, exact public schema equality, SECURITY DEFINER117; scratch cleanup0.
- Concurrent discovery/occurrence/claim PASS; concurrent schedule updates generation3 PASS.
- Reschedule/cancellation committed before final-check DENY PASS.
- NEW lock-wait retry-deadline case FAIL, so the aggregate preflight is BLOCKED.
- DST: 2027-03-27 12:00→2027-03-28 12:00 Europe/Warsaw =23h; 2027-10-30 12:00→2027-10-31 12:00 =25h; expected=actual.
- All fixture/scratch cleanup completed; real email send0.

### Production read-only evidence

Project yuyxfodozzpzrdzkmolu:
- Remote migration head20261016100000; all132 deployed versions match candidate history; unexpected remote versions0.
- Pending exactly1:20261017100000. CLI db push --linked --dry-run listed only this migration; no apply.
- Production SECURITY DEFINER111; PUBLIC EXECUTE0.
- pg_cron NOT INSTALLED; pg_net NOT INSTALLED; cron.job absent; pg_cron job count0.
- Vault secret names=[]; secret values never selected.
- Vercel csk-booking-5nwh Cron Jobs shows enabled feature with empty Get Started state, no configured jobs. No tracked Vercel cron definition found.
- Reminder job NONE; observed scheduler conflicts NONE. Unknown external schedulers outside these surfaces are not claimed absent.
- Infrastructure logging NOT VERIFIED.
- Schema-only production dump compared to pre-reminder historical replay:844 objects compared;4 text-only differences in TCM length/trim checks from associative AND parentheses, no semantic change in those4.
- Expanded default-ACL/views/sequences/enums comparison did not complete (diagnostic query requires explicit char→text cast). Thus full extended production semantic drift gate remains INCOMPLETE; no overall drift0/PASS claim.
- No production settings, schema/data, cron/Vault or SMTP changes.

### New functions and authorization

All six new SECURITY DEFINER functions are postgres-owned; fixed search_path=pg_catalog,public,pg_temp.
PUBLIC/anon/authenticated EXECUTE=DENY for each.

| Function | Purpose / input | service_role | Tenant/recipient authority |
|---|---|---|---|
| track_reminder_schedule_v1() | Trigger on authoritative resource; no caller arguments | DENY | Resource row; no recipient input |
| discover_reminders_v1() | Bounded discovery; no arguments | ALLOW | Reservation or registration→event |
| claim_reminders_v1() | Bounded lease/claim; no arguments | ALLOW | Delivery→occurrence→resource |
| final_check_reminder_v1(uuid) | Live claim revalidation / payload | ALLOW | Claim-bound resource; no tenant/user/email input |
| complete_reminder_v1(uuid,boolean,text) | Claim result / provider ID | ALLOW | Existing live claim; cannot select tenant/recipient |
| purge_reminder_deliveries_v1() | Terminal90day purge; no arguments | DENY, operator-only | Two reminder types, no recipient selection |

Other new function: reminder_source_v1(text,uuid), SECURITY INVOKER, owner-only.
New tables: reminder_schedules,reminder_occurrences; RLS enabled, no client/service direct grants.
New triggers: track_booking_reminder_schedule,track_event_reminder_schedule.
New partial unique indexes: reminder_booking_occurrence(reservation_id,generation) WHERE reservation_id IS NOT NULL; reminder_event_occurrence(registration_id,generation) WHERE registration_id IS NOT NULL.
Schedule PK UUID and unique reservation_id/event_id remain DB-controlled; occurrence PK UUID.
Modified objects: email delivery message/state checks plus reminder state check; set_email_delivery_tenant_id trigger function extended only for reminder binding. Legacy UNIQUE(message_type,record_id) and old prepare RPC semantics preserved.

### Per-file classification (36/36)

| SQL file | Classification |
|---|---|
| supabase/tests/20260816143000_harden_public_function_execute_acl_test.sql | Function inventory/count + ACL expected update |
| supabase/tests/20260902120000_harden_public_table_sequence_acl_test.sql | Table inventory/count + ACL expected update |
| supabase/tests/20260904180000_harden_reservation_cancellation_email_delivery_test.sql | Message type update |
| supabase/tests/20260913100000_harden_event_management_rpcs_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20260913150000_harden_public_event_readers_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20260914100000_harden_shared_confirmation_email_rpcs_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20260914150000_harden_event_reserve_promotion_rpcs_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20260915100000_harden_lane_block_rpcs_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20260916100000_harden_lane_family_creation_readers_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20260917100000_harden_lane_family_writer_helpers_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20260918100000_harden_admin_reservation_reports_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20260919100000_add_tenant_user_admin_notes_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20260919150000_harden_tenant_user_role_identity_contact_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20260920100000_add_tenant_user_verification_foundation_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20260920150000_cutover_tenant_user_verification_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20260921100000_close_legacy_global_verification_path_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20260922100000_harden_account_lifecycle_rpcs_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20260923100000_harden_profile_privilege_trigger_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20260924100000_harden_public_booking_configuration_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20260925100000_add_public_active_tenant_resolver_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20260926100000_add_tenant_scoped_operational_readers_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20260927100000_add_tenant_scoped_staff_event_rpcs_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20260927110000_add_tenant_scoped_lane_configuration_rpcs_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20260927120000_add_tenant_scoped_admin_reports_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20260927130000_add_tenant_scoped_admin_users_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20260928100000_add_c3_owner_calendar_and_global_profile_contracts_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20260929100000_close_global_role_helper_execute_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20260930110000_tenant_aware_onboarding_cutover_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20261001100000_retire_single_tenant_compatibility_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20261003100000_remove_single_active_tenant_guard_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20261004100000_add_public_tenant_directory_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20261005100000_add_public_tenant_landing_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20261006100000_add_tenant_public_settings_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20261007100000_add_saas_feature_entitlements_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20261008100000_harden_cancellation_tenant_authority_test.sql | SECURITY DEFINER expected update (111 → 117) |
| supabase/tests/20261011100000_verified_tenant_domains_test.sql | SECURITY DEFINER expected update (111 → 117) |

### D5 proposal only

After remediation, new reviewed SHA and clean preflight:
A deploy approved DB+D1–D4 app; B smoke with scheduler disabled; C provision dedicated REMINDER_CRON_SECRET securely; D configure approved pg_cron/pg_net/Vault; E controlled dry/mock run without mail; F explicitly approved synthetic live fixture; G verify email/idempotency; H cleanup; I separately enable15-minute recurring job.
Canonical endpoint: https://strzelajtu.pl/api/internal/reminders, POST, Authorization: Bearer <dedicated secret>, empty body/query. No preview/tenant/krutla host.
None of A–I executed.

READY FOR CHECKPOINT COMMIT: NO.
READY FOR D1–D4 PRODUCTION DEPLOY: NO.
READY FOR D5 CRON ACTIVATION: NO.

## DEADLINE REMEDIATION / CLEAN PREFLIGHT — current result: PASS

Authoritative candidate: `p10gd-clean-preflight`, base `5d9082d1f1831b55dd9373e94ee3b22217968f54`.
Scope is now 45 files: the approved 44 plus the explicitly requested permanent two-session regression `tests/db/reminder-lock-wait.mjs`. The 36 SQL inventory adjustments retain the classifications above; 33 were mechanically rechecked as exclusively 111-to-117 expected definer updates. No historical migration edits, weakened assertions, staged files, evidence scripts or generated artifacts in scope. The older source worktree still has the obsolete migration; do not deploy from it.

### Timestamp classification and minimal change

- Business schedule instants, generation and creation-age eligibility are unchanged. Discovery and the internal stable source projection retain `statement_timestamp()` for their deterministic scan window. Discovery is not permission to send.
- Claim decision time is refreshed with `clock_timestamp()` for each acquired delivery row; current cutoff is checked in addition to generation/resource binding. Claim scans use `FOR UPDATE SKIP LOCKED` and never wait for another claimant's delivery lock.
- Final check acquires the delivery lock, validates lease, rereads authoritative resource/status/generation/lifecycle and tenant branding, then checks current `clock_timestamp()` against both T−1h and lease expiry immediately before returning a payload. No stale statement time can authorize a late send.
- Completion explicitly locks the delivery before checking lease expiry; its subsequent UPDATE also checks wallclock expiry. A blocked completion cannot mark sent after the lease expired.
- Existing terminal-record 90-day retention wallclock semantics are unchanged. No global timestamp replacement, new authority or scheduler activation.

### Permanent two-session test and negative control

Command: `node tests/db/reminder-lock-wait.mjs` (local Docker only, port 54322 guard; no provider calls).
Negative control against the old local functions: `--deadline-only` failed for BOTH booking and event, each with `started_before=true`, `ended_after=true`, `allowed=true`; exit 1, cleanup 0. This is a real timing regression, not a source-text assertion.
After fresh canonical replay and local function replacement: 20/20 cases PASS, covering both types:

- Lock crossing T−1h: DENY; short lock released before deadline: ALLOW.
- Final-send lease expiry and completion lease expiry while blocked: DENY.
- Cancellation, reschedule and A→B→A generation change committed by lock holder: DENY.
- Lifecycle changed to dormant/disabled while blocked: DENY.
- Lifecycle changed to suspended: ALLOW for the existing eligible obligation, preserving approved continuity (not new-business permission).
- Every test fixture, schedule, occurrence, delivery and synthetic account removed; cleanup 0.

### Fresh gates after remediation

| Gate | Result |
| --- | --- |
| Focused SQL | 48/48 PASS, including ACL, DST, bounded retry, retention and no-PII registry checks |
| Full DB | 71/71 files PASS; 2259 pgTAP assertions plus custom SQL assertions |
| Deadline / lock / lifecycle matrix | 20/20 PASS; old implementation failed both deadline cases |
| Concurrent discovery / claim | Exactly one occurrence / claimant, PASS |
| Concurrent occurrence updates | Serialized generation=3, PASS |
| Targeted Node | 11/11 PASS |
| Full Node | 913 + 79 server-condition tests = 992/992 PASS |
| Playwright / scheduler auth | 4/4 PASS; missing/forged credential 401, GET 405; no send |
| TypeScript | PASS |
| Webpack production build | PASS |
| ESLint changed executable files | PASS, zero errors |
| Diff check | PASS; untracked candidate files also checked for trailing whitespace |
| Fresh replay / app public schema equivalence | Exact normalized schema equality PASS; legacy prepare hash unchanged |
| Fixture / temporary DB cleanup | 0 |

Evidence is excluded from checkpoint scope under `test-results/reminders/remediation-*`; the permanent regression is included under `tests/db/`.

### Completed production read-only preflight and semantic drift

Fresh CLI history: 132 deployed versions match through `20261016100000`. Exactly one pending migration: `20261017100000_add_reminder_occurrences.sql`. Fresh `db push --linked --dry-run` lists only that file; no apply performed.
Fresh schema-only production dump was restored into a disposable local DB and compared with canonical historical replay through 16. Extended inventory completed successfully: 847 entries spanning function definitions/ACL/owners, tables/RLS/ACL, columns, constraints, indexes, triggers, policies, views, sequence definitions (excluding live last_value), default ACL and enums.
Exactly four differences remain, all known equivalent associative AND grouping in TCM checks: `tenant_public_profiles_about_offer_check`, `tenant_public_profiles_about_audience_check`, `tenant_public_pricing_items_unit_check`, `tenant_public_pricing_items_title_check`. Each is `(A AND B) AND C` versus `A AND B AND C`, with identical operands/null handling. No normalization hid other differences.
Unexpected semantic production drift: 0. Production remains pre-reminders (111 definers); fresh local target 117. Exact ACL inventories PASS; unexpected grants 0. This public-schema comparison does not claim equivalence of unmanaged platform schemas or external scheduler services.
Previously recorded read-only scheduler inventory remains unchanged by this work; no cron/Vault/Vercel configuration was written.

READY FOR CHECKPOINT COMMIT: YES (requires separate authorization).
READY FOR D1–D4 PRODUCTION DEPLOY: YES (requires separate authorization using the NEW SHA).
READY FOR D5 CRON ACTIVATION: NO.
Production write / real email / staging / commit / push / deployment / cron activation: NONE.
