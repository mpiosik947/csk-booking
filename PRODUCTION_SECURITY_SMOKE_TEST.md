# CSK Booking — Production Security Smoke Test

Date: 2026-09-02

Production application: `https://csk-booking-5nwh.vercel.app`

Supabase project ref: `yuyxfodozzpzrdzkmolu`

Test run marker: `SECURITY-SMOKE-20260902T193153257Z-9E4686`

The test used exactly two synthetic ordinary-user accounts and one isolated event/registration fixture. Administrative credentials were used only to create, inspect, and remove that fixture. All tested confirmation requests used normal production HTTP and ordinary Supabase Auth sessions.

## Summary

```text
PUBLIC BOOKING CONFIG: PASS
CONFIRM GET READ-ONLY: PASS
UNAUTHENTICATED POST: PASS
CROSS-USER POST: PASS
OWNER POST: PASS
REPEAT CONFIRMATION: PASS
RPC ACL: PASS
CLEAN SESSION LOGIN: PASS
SESSION REFRESH: PASS
LOGOUT: PASS
AUTH REFRESH ISSUE REPRODUCED: NO
PRODUCTION ERRORS: NONE OBSERVED IN TESTED FLOWS
TEST AUTH USERS REMAINING: 0
TEST FIXTURE REMAINING: 0

PRODUCTION SECURITY SMOKE:
PASS
```

---

# SEC-006 EMAIL HTML INJECTION PRODUCTION SMOKE

Retest date: 2026-09-04

Production commits under test:

```text
4a1182f — security: escape dynamic email html
8ae9509 — fix: repair reservation cancellation email flow
```

Run marker: `[TEST][SEC-006][a3db4385]`

Recipient: controlled, masked test mailbox

The full smoke test was repeated from the beginning against the current
production deployment. It created only uniquely marked synthetic fixture and
sent exactly five messages, one for each covered flow. Test requests used the
real production application/API contracts and authenticated caller sessions.
The service-role credential was limited to fixture setup, verification and
cleanup.

| FLOW | RESULT | HTTP | PROVIDER | HTML ESCAPING | CLEANUP |
|---|---|---:|---|---|---|
| Reservation confirmation | PASS | 200 | Reached; message delivered | PASS | PASS |
| Reservation cancellation | PASS | 200 | Reached; message delivered | PASS | PASS |
| Event registration confirmation | PASS | 200 | Reached; message delivered | PASS | PASS |
| Event reserve promotion | PASS | 200 | Reached; message delivered | PASS | PASS |
| Confirmed reserve place | PASS | 200 | Reached; message delivered | PASS | PASS |

## Message-content verification

All five delivered messages were located in the controlled mailbox using the
exact run marker and inspected independently.

- `<script>alert(1)</script>`, `<img src=x onerror=alert(1)>` and
  `<b>Injected</b>` were rendered literally as text. No injected `script`,
  `img src=x` or injected bold element existed in the rendered message DOM.
- `Jan & Anna`, `<`, `>`, double quotes and the apostrophe in `"O'Connor"`
  rendered as their intended text values.
- No double escaping was visible: recipients saw the literal test strings,
  not entity text such as `&lt;script&gt;`.
- Legitimate template headings, detail rows, paragraphs and action controls
  retained their expected HTML layout.
- The link-bearing flows generated HTTPS action links. The malicious
  `javascript:` and `data:` values supplied in dynamic fixture fields remained
  inert text and never appeared as `href` values. The allowlist continues to
  permit only absolute HTTP/HTTPS links.
- Each production send supplied a separate plain-text body alongside the HTML
  body. Dynamic values in that body remained ordinary text and were not
  HTML-entity encoded.
- No delivered content exposed a JWT, service-role key, raw database/provider
  error, or an additional technical token field. Functional scoped action
  links are intentionally omitted from this report.

## Cancellation regression verification

The previously failing cancellation flow completed with HTTP 200. The provider
was reached and the cancellation message was delivered. No SQLSTATE 42501,
HTTP 500 or raw database error occurred.

```text
reservation_confirmation: HTTP 200
reservation_cancellation: HTTP 200
event_registration_confirmation: HTTP 200
event_reserve_promotion: HTTP 200
confirmed_reserve_place: HTTP 200
messages sent: 5/5
messages delivered: 5/5
```

## Cleanup

Application fixture cleanup removed only records associated with
`[TEST][SEC-006][a3db4385]`. Independent control reads confirmed:

```text
synthetic auth users: 0
synthetic profiles: 0
synthetic reservations: 0
synthetic events: 0
synthetic event registrations: 0
synthetic audit logs: 0
synthetic email deliveries: 0
synthetic lanes: 0
remaining synthetic application fixture: 0
```

A separate read-only pre-cleanup query identified exactly two isolated `user`
rate-limit rows and one `ip` row containing only the two timestamps generated
by this smoke run. The transactional, fail-closed cleanup required all three
rows and their exact timestamp sets before deleting them. Its independent
post-check returned:

```text
remaining_synthetic_rate_limit_records: 0
cleanup_confirmed: true
remaining synthetic fixture: 0
```

No real customer data, unrelated rate-limit timestamp, application code,
schema, migration, RLS, ACL or production configuration was changed.

```text
SEC-006 PRODUCTION SMOKE: PASS

SEC-006 STATUS:
FULLY REMEDIATED
```

## SEC-018 EVENT REGISTRATION DML PRODUCTION SMOKE

Production deployment under test:

```text
commit: 66a0610 — security: harden event registration writes
migration: 20260903160000_harden_event_registration_direct_dml.sql
migration present on production: true
```

The production smoke test executed 31 security and regression checks using only
synthetic fixture. The test finished with its expected controlled exception:

```text
ERROR: P0001: SEC018_SMOKE_ALL_31_PASS_ROLLBACK
```

This exception rolled back the complete smoke-test statement, including Auth
users, profiles, events, event registrations, and audit logs created by the
fixture.

| TEST | RESULT | EVIDENCE |
|---|---|---|
| SEC-018 contract and regression checks | PASS | 31/31 checks completed before the controlled rollback exception. |
| Controlled rollback | PASS | Final result was `SEC018_SMOKE_ALL_31_PASS_ROLLBACK`. |
| Synthetic Auth users removed | PASS | Post-smoke read-only count: `0`. |
| Synthetic profiles removed | PASS | Post-smoke read-only count: `0`. |
| Synthetic events removed | PASS | Post-smoke read-only count: `0`. |
| Synthetic event registrations removed | PASS | Post-smoke read-only count: `0`. |
| Synthetic audit logs removed | PASS | Post-smoke read-only count: `0`. |
| Complete fixture cleanup | PASS | `remaining_synthetic_fixture = 0`. |

```text
SEC-018 PRODUCTION SMOKE: PASS

SEC-018 STATUS:
FULLY REMEDIATED
```

---

# SEC-007 AUDIT LOG INTEGRITY PRODUCTION SMOKE

Test date: 2026-09-03

Application commit: `1661abb — security: harden audit log integrity`

Migration: `20260903100000_harden_audit_log_integrity.sql`

The linked production migration history contains `20260903100000`. The smoke
test was executed through Supabase Management API as one PostgreSQL statement.
Fixture setup and control reads used the privileged Management API connection;
every tested application operation explicitly assumed `anon` or
`authenticated` and set the corresponding synthetic `auth.uid()`.

The statement deliberately ended with the sentinel exception
`SEC007_SMOKE_ALL_20_PASS_ROLLBACK`. PostgreSQL therefore rolled back the whole
statement, including four synthetic Auth users/profiles, the synthetic profile
change, and its trusted audit. A separate read-only post-check confirmed that
all fixture was absent.

| TEST | RESULT | EVIDENCE |
|---|---|---|
| Remote migration history | PASS | `20260903100000` exists remotely. |
| anon direct INSERT | PASS | Denied with `insufficient_privilege` / SQLSTATE 42501. |
| ordinary user direct INSERT | PASS | Denied with SQLSTATE 42501. |
| employee direct INSERT | PASS | Denied with SQLSTATE 42501. |
| admin direct INSERT | PASS | Denied with SQLSTATE 42501. |
| employee direct UPDATE | PASS | Denied with SQLSTATE 42501. |
| admin direct UPDATE | PASS | Denied with SQLSTATE 42501. |
| employee direct DELETE | PASS | Denied with SQLSTATE 42501. |
| admin direct DELETE | PASS | Denied with SQLSTATE 42501. |
| authenticated TRUNCATE | PASS | Admin and employee attempts denied with SQLSTATE 42501. |
| admin SELECT | PASS | Admin saw exactly the synthetic trusted audit through RLS. |
| employee SELECT | PASS | Employee saw zero audit rows through RLS. |
| trusted business flow | PASS | `admin_set_user_note_v1` returned `updated`. |
| trusted audit count | PASS | Exactly one `profile_admin_note_updated` audit was created. |
| actor integrity | PASS | `actor_user_id` matched the authenticated admin's `auth.uid()`. |
| action integrity | PASS | Action and target fields came from the trusted RPC contract. |
| timestamp integrity | PASS | `created_at` equalled PostgreSQL `transaction_timestamp()`. |
| idempotent repeat | PASS | Repeat returned `no_change`; audit count remained one. |
| secret/token minimization | PASS | `details` contained only note-presence booleans and `operator_role`; no token, JWT, key, credential, cookie, or note body. |
| fixture isolation | PASS | All four synthetic accounts/profiles and one audit existed only inside the rolled-back statement. |

## ACL and RLS post-check

```text
PUBLIC:        no audit_logs privileges
anon:          no audit_logs privileges
authenticated: SELECT only; no INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER/MAINTAIN
service_role:  existing privileged platform baseline preserved

RLS policies: exactly 1
Admins can view audit logs: SELECT, authenticated, USING is_admin()
Mutation policies: 0
```

All independent post-check booleans returned `true`:

```text
migration_present
auth_fixture_absent
profile_fixture_absent
audit_fixture_absent
rls_contract_intact
public_has_no_acl
anon_has_no_acl
authenticated_select_only
service_role_baseline_intact
```

No full token, production customer PII, credential, or service-role key was
printed or stored in this report. No real customer record was used.

```text
remaining synthetic fixture = 0

SEC-007 PRODUCTION SMOKE: PASS

SEC-007 STATUS:
FULLY REMEDIATED
```

---

## SEC-005 CHECK-IN TOKEN PRODUCTION SMOKE

Date: 2026-09-03

Application commit verified by deployed behavior: `d0e7ced — security: harden check-in token access`.

Migration history: LOCAL and REMOTE both contain `20260902160000_harden_check_in_token_access.sql`.

Controlled marker: `[TEST][SEC-005][20260903T174923784Z][8A2B7C]`.

The run created two synthetic Auth users, one isolated inactive lane, one pricing rule and four synthetic reservations. Service-role credentials were used only for fixture setup, control reads and cleanup. Public calls used the anon role. Staff and ordinary-user checks used real production password sessions and their own Bearer JWTs. No real customer data was read or changed.

| TEST | RESULT | EVIDENCE |
|---|---|---|
| 1. Public valid token | PASS | Anonymous `get_public_check_in_status_v1(uuid)` returned HTTP 200 and exactly `{ok:true, code:"ready"}`. Production `/check-in/[token]` returned HTTP 200 with the neutral ready UI, no fixture marker, e-mail, phone, profile, reservation detail or service-role content. The page includes `no-referrer` and `noindex, nofollow` metadata. |
| 2. Invalid token | PASS | A random unknown UUID returned HTTP 200 and exactly `{ok:false, code:"unavailable"}`; no PII and no 5xx. |
| 3. Too early | PASS | A reservation more than 24 hours in the future returned HTTP 200 and the same neutral `unavailable` result. |
| 4. Expired | PASS | A reservation whose end plus two hours was in the past returned HTTP 200 and the same neutral `unavailable` result. |
| 5. Cancelled | PASS | A cancelled reservation returned HTTP 200 / `unavailable`; the staff token reader returned no reservation row. |
| 6. Staff lookup | PASS | Authenticated admin received HTTP 200 and one allowlisted row. Authenticated ordinary user received 403, anon received 401, and service role received 403. The DTO contained no `check_in_token`, internal note or address fields. Authorization was exercised through a real JWT and the role stored in `profiles`. |
| 7. Check-in idempotency | PASS | First `update_reservation_attendance(...,'start')`: HTTP 200, `started`, `changed=true`. Repeat: HTTP 200, `already_started`, `changed=false`. Attendance remained `present`, `checked_in_at` did not change, and the total audit delta was exactly one. |
| 8. Token after check-in | PASS | Public reader returned HTTP 200 and exactly `{ok:true, code:"already_checked_in"}`. Staff lookup still returned one allowlisted row inside the window. No second attendance mutation occurred. |
| 9. ACL | PASS | Production schema dump: public reader has explicit PUBLIC revoke and anon grant only; staff reader has explicit PUBLIC revoke and authenticated grant only; private lifecycle helper has explicit PUBLIC revoke and no client grant. Runtime additionally confirmed authenticated/service-role denial on the public reader and anon/service-role denial on the staff reader. |
| 10. Log / secret review | PASS | Public RPC/DTO and staff DTO returned no token. Public response contained no PII or raw DB error. Tested calls produced no 5xx. Application source logs only a controlled RPC error code and never the token. No password, JWT, service key or full token is recorded in this report. |

### ACL matrix

| Function | PUBLIC | anon | authenticated | service_role |
|---|---:|---:|---:|---:|
| `get_public_check_in_status_v1(uuid)` | NO | EXECUTE | NO | NO |
| `get_check_in_reservation_v1(uuid)` | NO | NO | EXECUTE, with internal admin/pracownik check | NO |
| `is_reservation_check_in_token_usable_v1(...)` | NO | NO | NO | NO |

### Data-minimization and logging note

The RPC response never returns the bearer token as a data field. As expected for a dynamic Next.js route, the HTML/RSC router state mirrors the token-bearing URL that the requester already supplied; it does not add a second token field or expose it to another principal. `Referrer-Policy: no-referrer` is emitted as page metadata, and application logging does not log the route parameter. Infrastructure access logging of request paths remains an inherent residual risk of the approved URL-bearer design and should be handled by platform log-retention/redaction controls.

### Cleanup

The harness deleted only records identified by the generated marker and exact synthetic IDs. Final control reads returned:

```text
synthetic reservations remaining: 0
synthetic lanes remaining: 0
synthetic profiles remaining: 0
synthetic Auth users remaining: 0
remaining synthetic fixture: 0
```

No schema, migration, ACL, RLS, application configuration or production code was changed during the smoke test.

```text
SEC-005 PRODUCTION SMOKE: PASS

SEC-005 STATUS:
FULLY REMEDIATED
```

## Preflight

- Local and `origin/main`: `d04c17163b8eb4717bbcfa0d040163140a267b7e`.
- GitHub deployment status for commit `d04c171`: success for both Vercel contexts associated with the project.
- Production migration history contains matching LOCAL/REMOTE entries for `20260816130000`, `20260816143000`, and `20260902120000`.
- A read-only production schema dump confirmed the deployed SEC-003 function, table schema, constraints, and ACL.
- No migration, schema, RLS, ACL, deployment, commit, or push operation was executed.

## Public booking configuration

The anonymous production call to `get_public_booking_configuration_v1()` succeeded with the equivalent of HTTP 200 and returned 10 public resources:

- resource kinds: `lane`, `position`;
- hierarchy, availability flags, capacities, durations, currency, and pricing were present;
- customer data, profiles, Auth metadata, claims, promotion tokens, and other PII were absent.

```text
PUBLIC BOOKING CONFIG: PASS
```

## Controlled fixture

```text
event_id: e8906f00-414e-44dd-b4dc-d80b0d197e39
registration_id: d76b5e4d-bbe2-41f5-afb5-d93bf2c8d13f
owner_user_id: f3a160a0…e395
other_user_id: 77e4207f…7fe0
token identifier: SHA-256 257b758ba7eec5302f5b634c914bb454d3b30018b5f2c48c79a6771cd4810f9c
```

The full promotion token, passwords, JWTs, service credential, and synthetic account addresses are not included in this report.

Baseline before GET:

```text
registration_status: reserve
payment_status: pending
promotion_confirmed_at: null
claim: absent
promotion_attempt_count: 1
registration_count: 1
participants: 0/1
available_places: 1
```

## GET read-only

```text
GET /events/confirm/[controlled-token]
HTTP 200
```

The complete business snapshot before and after GET was identical. Registration status, promotion fields, token hash, participant count, capacity, and available places did not change.

```text
CONFIRM GET READ-ONLY: PASS
```

## Unauthenticated POST

Request without `Authorization`:

```text
POST /api/confirm-event-reserve-promotion
HTTP 401
code: unauthorized
```

The complete fixture snapshot remained unchanged.

```text
UNAUTHENTICATED POST: PASS
```

## Cross-user POST

User B signed in through normal `signInWithPassword()` and called the production endpoint using its own Bearer JWT with User A's controlled token.

```text
HTTP 403
code: forbidden
```

Registration status, promotion fields, participant count, and capacity remained unchanged.

```text
CROSS-USER POST: PASS
```

## Owner POST

User A signed in through normal `signInWithPassword()` and called the endpoint with its own Bearer JWT.

```text
HTTP 200
ok: true
code: confirmed
```

Exactly the expected state transition occurred:

```text
registration_status: reserve -> registered
promotion_confirmed_at: null -> set
registration_count: 1 -> 1
participants: 0/1 -> 1/1
available_places: 1 -> 0
owner: unchanged
token hash: unchanged
```

No additional registration was created.

```text
OWNER POST: PASS
```

## Replay / idempotency

The identical POST was repeated as User A with the same token.

```text
HTTP 409
ok: false
code: not_reserve
```

The complete state after the repeated request was identical to the state after the successful owner request. There was no second mutation, duplicate registration, or second capacity reduction.

```text
REPEAT CONFIRMATION: PASS
```

## Clean Auth sessions

Both synthetic accounts independently completed `signInWithPassword()`, `auth.getUser()`, explicit `refreshSession()`, and `signOut()`. All operations succeeded. `Invalid Refresh Token: Refresh Token Not Found` was not reproduced.

```text
CLEAN SESSION LOGIN: PASS
SESSION REFRESH: PASS
LOGOUT: PASS
AUTH REFRESH ISSUE REPRODUCED: NO
```

## Production RPC ACL

The read-only production schema dump confirmed:

```text
public.confirm_event_reserve_promotion(text) returns jsonb
LANGUAGE plpgsql
SECURITY DEFINER
search_path = public, pg_temp
owner = postgres

PUBLIC        = NO EXECUTE
anon          = NO EXECUTE
authenticated = EXECUTE
service_role  = NO EXECUTE
```

```text
RPC ACL: PASS
```

## Production errors

No HTTP 5xx, Auth failure, refresh error, malformed RPC response, or unexplained error was observed during the controlled run. The expected negative responses were HTTP 401, HTTP 403, and replay HTTP 409.

```text
PRODUCTION ERRORS: NONE OBSERVED IN TESTED FLOWS
```

## Cleanup

Before every deletion, the harness re-read the exact record and verified its unique marker and exact run IDs. Cleanup used only those IDs.

```text
registration marker verified: true
event marker verified: true
User A marker verified: true
User B marker verified: true
registration deleted: true
event deleted: true
User A deleted: true
User B deleted: true

TEST EVENTS REMAINING: 0
TEST REGISTRATIONS REMAINING: 0
TEST PROFILES REMAINING: 0
TEST AUTH USERS REMAINING: 0
```

No real customer record was read, modified, or deleted.

## Final verdict

```text
PRODUCTION SECURITY SMOKE:
PASS
```

---

# SEC-010 PASSWORD POLICY PRODUCTION SMOKE

**Date:** 2026-09-04

**Production application:** `ea51547 — security: strengthen password policy`

**Vercel status:** Production / Ready
**Synthetic run:** uniquely marked SEC-010 fixture; identifiers and passwords omitted

No Supabase Auth setting, application code, migration, or production schema was
changed during this smoke test.

## Provider policy

The production Auth contract was verified independently of the application UI:

| Boundary | HTTP | Provider result | Verdict |
|---|---:|---|---|
| 11 characters | 422 | `weak_password`, reason `length`; user not created | PASS |
| 12 simple lowercase characters | 200 | accepted; no required character class | PASS |
| 72 characters | 200 | accepted | PASS |
| 73 characters | 400 | controlled validation rejection | PASS |

This proves the effective production length range is 12–72. The accepted
12-character value deliberately contained no uppercase letter, digit, or
symbol, confirming the approved `No required characters` policy.

## Application contracts

### Registration

- production `/register` exposes `Minimum 12 znaków` and input bounds 12–72;
- 11 characters returned `Hasło musi mieć minimum 12 znaków.` locally;
- 12 characters passed application validation and reached the controlled
  registration-success state;
- the separate direct Auth boundary test confirmed that the provider itself
  also rejects 11 and accepts 12.

```text
REGISTER APPLICATION CONTRACT: PASS
```

### Reset password

The deployed reset page was exercised using only the authenticated synthetic
account; no reset message was sent to a real user:

- 11 characters were rejected with the shared minimum-12 message;
- 12 characters were accepted and produced the controlled success response;
- recovery-link exchange and reset-session code were not modified by SEC-010.

```text
RESET PASSWORD CONTRACT: PASS
```

### Account password change

On the confirmed synthetic account:

- 11 characters were rejected locally;
- 12 characters were accepted by the application and production Auth;
- the previous synthetic password subsequently returned
  `invalid_credentials`;
- the new 12-character synthetic password authenticated successfully with
  HTTP 200.

No password or session token is recorded in this report.

```text
ACCOUNT PASSWORD CHANGE: PASS
```

## Existing-user compatibility

No real user's password was read or changed. Supabase's documented contract
states that strengthening password requirements does not automatically remove,
rewrite, or invalidate existing passwords. Existing users can still sign in;
new users and future password changes must satisfy the strengthened policy,
and Auth can surface weak-password information for an older credential.

The synthetic account also remained usable across multiple successful password
changes until its deliberate cleanup.

```text
EXISTING USER COMPATIBILITY: PASS
```

Reference: [Supabase password security](https://supabase.com/docs/guides/auth/password-security)

## Leaked-password protection

Production inspection confirmed:

```text
Prevent use of leaked passwords: OFF
Project plan: Free
Availability: Pro plan and above
```

The setting was not changed or bypassed. This is recorded as an accepted
residual constrained by the current plan, not as an application regression.

```text
LEAKED PASSWORD PROTECTION:
ACCEPTED RESIDUAL — PLAN LIMITATION
```

## Cleanup

Exactly three synthetic Auth users were created: one 12-character boundary
user, one 72-character boundary user, and one confirmed account used for
password-change tests. The 11- and 73-character cases created no users.

Each deletion was fail-closed against the exact synthetic address. An
independent read-only SQL post-check returned:

```text
synthetic_auth_users: 0
synthetic_profiles: 0
remaining_synthetic_fixture: 0
```

No real account or profile was modified or deleted.

## SEC-010 final result

```text
SEC-010 PASSWORD LENGTH POLICY:
PROD PASS

SEC-010 APPLICATION CONSISTENCY:
PASS

LEAKED PASSWORD PROTECTION:
ACCEPTED RESIDUAL — PLAN LIMITATION

SEC-010 FINAL STATUS:
REMEDIATED WITH ACCEPTED RESIDUAL
```

---

# SEC-009 CORE LIFECYCLE PRODUCTION SMOKE

**Date:** 2026-09-04

**Production application:** `1288fd5 — security: add account pii lifecycle`

**Production migration:** `20260904120000_add_account_pii_lifecycle.sql`

The smoke test used two uniquely identified synthetic users and isolated
synthetic business records. User-facing operations were executed through the
production Auth and application API contracts. Privileged database access was
used only for fixture setup, read-only before/after verification, and the
confirmed, fail-closed cleanup. No real customer record was read, modified, or
deleted. No credential, bearer token, password, or technical token is recorded
in this report.

## Results

| Test | Result | Evidence |
|---|---|---|
| Migration and RPC presence | PASS | Remote migration history contains `20260904120000`; both lifecycle RPC signatures exist. |
| Anonymous export | PASS | `GET /api/account/export` returned HTTP 401. |
| Owner export | PASS | Synthetic User A received HTTP 200, JSON, `export_version = 1`, and a populated `generated_at`. |
| Export ownership isolation | PASS | The export contained exactly User A's synthetic reservation and event registration; User B identifiers and data were absent. A `user_id` query parameter was rejected with HTTP 400. |
| Export data minimization | PASS | No admin notes, check-in or promotion tokens, JWT, password hash, service-role material, rate-limit state, or audit-log payload was returned. |
| Anonymous deletion | PASS | `POST /api/account/delete` without a bearer session returned HTTP 401 and made no change. |
| Cross-user deletion input | PASS | A body containing an additional User B `user_id` was rejected with HTTP 400; the endpoint accepts only the exact confirmation field. |
| Owner self-delete | PASS | User A's authenticated request returned HTTP 200 with the controlled `deleted` result. Runtime behavior and route ordering confirmed database anonymization precedes Auth Admin deletion. |
| Profile and direct PII removal | PASS | User A's profile was absent; reservation and registration owner links, names, contact data, notes, and active technical tokens were removed or replaced with the approved pseudonymous values. |
| Operational-history retention | PASS | The synthetic reservation and event-registration records remained with their date/time, resource, status, payment, attendance, and other approved operational fields intact. |
| Audit integrity and idempotency | PASS | Exactly one pseudonymous `account_anonymized` audit existed. It contained only allowlisted lifecycle summary fields and no PII, token, or secret. Reuse of the old JWT returned HTTP 401 and did not create a second audit. |
| Auth deletion and old credentials | PASS | User A disappeared from Auth. A login attempt with the old synthetic credentials returned the controlled `invalid_credentials` result. |
| User B isolation | PASS | User B's Auth user, profile, reservation, registration, PII, notes, and tokens remained unchanged before cleanup. |
| RPC ACL | PASS | `authenticated` has EXECUTE on both lifecycle RPCs; `PUBLIC`, `anon`, and `service_role` do not. |
| Secret/error exposure | PASS | Tested API responses contained no JWT, service-role material, technical token, foreign-user data, or raw database error. |
| Retry after Auth-provider failure | PASS (contract) | No production outage was injected. The deployed orchestration and regression contract preserve anonymized DB state, return retryable `auth_deletion_pending`, and retry only Auth deletion after `already_anonymized`. |

## Cleanup

Before cleanup, a read-only inventory identified only the records belonging to
this run: one remaining synthetic Auth user and profile, two retained
reservations, two retained event registrations, one synthetic event, one lane,
one pricing rule, one delivery record, one user rate-limit record, and three
synthetic audit records.

The cleanup ran in one transaction with exact identity/count preconditions. An
independent read-only post-check returned zero for every component:

```text
synthetic_auth_users: 0
synthetic_auth_identities: 0
synthetic_profiles: 0
synthetic_lanes_and_pricing: 0
synthetic_events: 0
synthetic_reservations: 0
synthetic_event_registrations: 0
synthetic_email_deliveries: 0
synthetic_rate_limits: 0
synthetic_audit_logs: 0
remaining_synthetic_fixture: 0
```

## SEC-009 final result

```text
SEC-009 CORE LIFECYCLE PRODUCTION SMOKE:
PASS

SEC-009 CORE LIFECYCLE STATUS:
FULLY REMEDIATED / PROD PASS

SEC-009 TIME-BASED RETENTION 10B:
NOT IMPLEMENTED / DEFERRED
```

---

# SEC-011 ADMIN ROUTES FAIL-CLOSED PRODUCTION SMOKE

**Date:** 2026-09-04

**Production application:** `ea27ca8 — security: fail closed admin routes`

Vercel deployment metadata confirmed the production target is `READY`, the
deployed branch is `main`, and the exact deployed revision is
`ea27ca83102db7dabfe4d118eadca03cdc9a0ab5`.

The test used direct production URLs and existing accounts representing all
four authenticated roles. No account, role, application data, database object,
configuration, or deployment was changed. No credentials or personal data are
recorded below.

## Direct URL results

| Role | Route | Result | Evidence |
|---|---|---|---|
| Anon | `/admin` | PASS — DENY | HTTP 307 to `/login?redirectTo=%2Fadmin`. |
| Anon | `/admin/events` | PASS — DENY | HTTP 307 to login with the original route in `redirectTo`. |
| Anon | `/admin/users` | PASS — DENY | HTTP 307 to login with the original route in `redirectTo`. |
| Anon | `/admin/__future-test-route` | PASS — DENY | HTTP 307 to login; the missing page was not reached anonymously. |
| Ordinary user | every current `/admin/*` route tested | PASS — DENY | Direct requests for the admin root, Calendar, Events, Reservations, Users, Reports and Lane Configuration all ended on `/dashboard`. |
| Ordinary user | `/admin/__future-test-route` | PASS — DENY | Direct request ended on `/dashboard`. |
| Employee | `/admin`, Reservations, Calendar, Lane Blocks, Events, Check-in | PASS — ALLOW | The production dashboard identified the trusted role as `Pracownik`; each allowed direct URL remained on its requested admin page. |
| Employee | Reports, Users, Lane Configuration | PASS — DENY | Each direct URL redirected to `/admin`. |
| Employee | `/admin/__future-test-route` | PASS — DENY | Direct URL redirected to `/admin`, confirming the unknown-route admin-only default. |
| Instructor | `/admin`, Calendar, Events | PASS — ALLOW | The production dashboard identified the trusted role as `Instruktor`; both allowed module URLs remained accessible. |
| Instructor | Reservations, Lane Blocks, Check-in, Reports, Users, Lane Configuration | PASS — DENY | Each direct URL redirected to `/admin`. |
| Instructor | `/admin/__future-test-route` | PASS — DENY | Direct URL redirected to `/admin`. No SEC-008 access was expanded. |
| Admin | all known admin pages | PASS — ALLOW | Calendar, Events, Reservations, Users, Reports and Lane Configuration loaded directly; the dashboard exposed all 8/8 modules. |
| Admin | `/admin/__future-test-route` | PASS — AUTHORIZED, THEN 404 | The URL was not redirected to `/admin`; Next.js returned its 404 page because no physical route exists. This separates authorization success from route existence. |

## Authentication failure behavior

| Condition | Result | Evidence |
|---|---|---|
| Missing browser session | PASS — fail-closed | Direct requests without cookies returned HTTP 307 to login for all required `/admin` URLs. |
| Missing API bearer | PASS — fail-closed | `/api/admin/calendar-feed` returned HTTP 401 and the stable `unauthorized` response. |
| Invalid API bearer | PASS — fail-closed | The same endpoint returned HTTP 401 and did not expose internal Auth details. |
| Invalid or expired browser session | PASS — contract verified | In the exact deployed middleware, any `userError` or missing user redirects to login before profile or route authorization. It cannot reach the allow response. |
| Auth service/network failure | PASS — contract verified | A production Auth outage was not induced. A returned Auth error is handled by the same fail-closed branch; a thrown upstream failure cannot reach `NextResponse.next()`. No fail-open fallback exists. |

## Trusted role source

The exact deployed middleware first calls server-side `supabase.auth.getUser()`,
then reads `role` from `public.profiles` for the authenticated user, normalizes
that value, and finally applies `canRoleAccessAdminRoute()`. The authorization
decision does not read a role from query parameters, `localStorage`, browser
JSON, request body, or a client boolean.

The production behavior matched that contract: the dashboard independently
identified employee and instructor roles, and direct URL outcomes matched the
central server-side matrix rather than link visibility.

## Admin API

The only current `/api/admin/*` route is
`/api/admin/calendar-feed`. It has independent server-side authorization and
does not rely on the page middleware:

- requires a Bearer token;
- verifies the user server-side;
- obtains the role through `get_my_role`;
- returns 401 for missing/invalid authentication, 403 for a valid disallowed
  role, 503 for classified Auth unavailability, and a controlled 500 for other
  unexpected failures;
- does not use service role;
- preserves the instructor-safe Calendar data contract.

The endpoint returned controlled HTTP 401 responses for both missing and
invalid Bearer tokens. The instructor Calendar loaded its production data via
the authenticated feed, confirming the permitted API path remained operational.

## Regression check

- Calendar: loaded for Admin, Employee and Instructor according to the existing
  role matrix.
- Events: loaded for Admin, Employee and Instructor.
- Reservations: loaded for Admin and Employee; denied for Instructor and User.
- Users: loaded only for Admin; denied for Employee, Instructor and User.
- Reports: loaded only for Admin; denied for Employee, Instructor and User.
- Lane Configuration: loaded only for Admin; denied for Employee, Instructor
  and User.
- Unknown future admin route: Admin reached the application 404; every other
  authenticated role was denied before route resolution.

## SEC-011 final result

```text
SEC-011 PRODUCTION SMOKE:
PASS

SEC-011 STATUS:
FULLY REMEDIATED / PROD PASS
```

---

# SEC-012 APPLICATION SECURITY HEADERS PRODUCTION SMOKE

**Date:** 2026-09-04

**Production application:** the deployment contains the SEC-012 header baseline
from `0b6acf0 — security: add application security headers`.

The test used direct read-only HTTP requests plus an interactive browser session.
No application action that writes data was invoked. No code, Vercel setting,
database object, configuration, migration, or deployment was changed.

## Direct production response inventory

| Route | HTTP/result | CSP and browser headers | Cache result | Verdict |
|---|---|---|---|---|
| `/` | 200 | Complete SEC-012 baseline | Public page cache | PASS |
| `/login` | 200 | Complete SEC-012 baseline | Public page cache | PASS |
| `/account` | 200 | Complete SEC-012 baseline | `private, no-store, max-age=0, must-revalidate` | PASS |
| `/admin` without session | 307 to login | Complete SEC-012 baseline | `private, no-store, max-age=0, must-revalidate` | PASS |
| `/api/admin/calendar-feed` without Bearer JWT | controlled 401 | Complete SEC-012 baseline | `private, no-store` | PASS |
| `/check-in/[synthetic-invalid-token]` | controlled 200 | Complete baseline plus `Referrer-Policy: no-referrer` | `private, no-cache, no-store, max-age=0, must-revalidate` | PASS |
| `/events/confirm/[synthetic-invalid-token]` | controlled 200 | Complete baseline plus `Referrer-Policy: no-referrer` | `private, no-cache, no-store, max-age=0, must-revalidate` | PASS |

The anonymous account response contains only the static client shell; it is now
explicitly non-cacheable regardless. The admin redirect and API denial also
remain non-cacheable. Public `/` and `/login` contain no private response data
and retain normal public page caching.

## Header values

Every tested response contained:

```text
X-Content-Type-Options: nosniff
Referrer-Policy: strict-origin-when-cross-origin
X-Frame-Options: DENY
Permissions-Policy: accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()
Cross-Origin-Opener-Policy: same-origin
```

The two token routes correctly override the general referrer policy with:

```text
Referrer-Policy: no-referrer
```

Vercel continues to provide, without an application duplicate:

```text
Strict-Transport-Security: max-age=63072000; includeSubDomains; preload
```

## Production CSP verification

The exact deployed CSP directives were:

```text
default-src 'self';
base-uri 'self';
form-action 'self';
frame-ancestors 'none';
object-src 'none';
script-src 'self' 'unsafe-inline';
script-src-attr 'none';
style-src 'self' 'unsafe-inline';
img-src 'self' data: blob:;
font-src 'self' data:;
connect-src 'self' https://yuyxfodozzpzrdzkmolu.supabase.co wss://yuyxfodozzpzrdzkmolu.supabase.co;
frame-src 'none';
manifest-src 'self';
worker-src 'self' blob:
```

Verified properties:

- no broad wildcard source;
- no production `unsafe-eval`;
- Supabase HTTP and WebSocket connections are limited to the exact production
  project origin;
- `frame-ancestors 'none'` and X-Frame-Options DENY agree;
- inline event-handler attributes are blocked by `script-src-attr 'none'`;
- base URL changes, object embedding, cross-origin forms, and frames fail closed.

## Browser smoke

| Check | Result | Evidence |
|---|---|---|
| Public home and login | PASS | Both rendered with HTTP 200 under the deployed CSP. |
| Login and Supabase Auth | PASS | Interactive production login completed and the subsequent trusted server session identified the administrator. |
| Account | PASS | The authenticated account page loaded its profile contract under CSP; no write action was used. |
| Admin UI | PASS | `/admin` loaded the operational dashboard and all eight authorized module links for the administrator. |
| Admin Calendar API | PASS | `/admin/calendar` completed loading, enabled its controls, and rendered production lane configuration through the authenticated calendar feed. |
| Anonymous API behavior | PASS | Direct `/api/admin/calendar-feed` without a token returned controlled HTTP 401, not 5xx. |
| Token pages | PASS | Both synthetic-invalid token pages rendered controlled states without 5xx. |
| CSP compatibility | PASS | Automated anonymous Chromium navigation reported zero CSP violations and zero console/page errors; authenticated Account, Dashboard and Calendar completed their Supabase/API reads without a blocked-resource state. |
| Assets/layout | PASS | Branding and application layouts rendered normally on public, account, admin, calendar and token pages. |

The smoke did not create a reservation, event registration, check-in, or any
other fixture. No production cleanup was required.

## Residual

`unsafe-inline` remains in `script-src` and `style-src` as the documented,
intentional compatibility limitation of the current Next.js rendering setup.
Production does not allow `unsafe-eval`; inline event-handler attributes remain
blocked. Removing `unsafe-inline` requires the separately staged nonce/hash
hardening described in the remediation report and is not falsely claimed here.

## SEC-012 final result

```text
SEC-012 PRODUCTION SMOKE:
PASS

SEC-012 STATUS:
FULLY REMEDIATED / PROD PASS
```

---

# SEC-015 RESERVATION CANCELLATION EMAIL PRODUCTION SMOKE

**Date:** 2026-09-04

**Production application:** `b587010 — security: harden reservation cancellation email delivery`

**Production migration:** `20260904180000_harden_reservation_cancellation_email_delivery.sql`

The production smoke used only fixture marked with the unique run marker
`[TEST][SEC-015][2af86979ff]`. User-facing operations were executed through
`POST /api/send-reservation-cancellation` with anonymous or real synthetic-user
JWT contexts. The service role was limited to fixture setup, verification, and
cleanup. Exactly three messages were sent, all to the approved controlled
mailbox through unique plus-address aliases.

## Results

| Check | Result | Evidence |
|---|---|---|
| Migration | PASS | Remote migration history contains `20260904180000`. |
| Anonymous authorization | PASS | Missing Bearer JWT returned controlled HTTP 401 `unauthorized`. |
| Owner authorization | PASS | Owner request returned HTTP 200 `sent`. |
| Foreign user authorization | PASS | Foreign user received non-disclosing HTTP 404; no delivery was created. |
| Instructor authorization | PASS | Instructor received non-disclosing HTTP 404; no delivery was created. |
| Employee authorization | PASS | Employee request for the synthetic owner's cancelled reservation returned HTTP 200 `sent`. |
| Admin authorization | PASS | Two concurrent admin requests produced exactly one `sent` result and one controlled `already_sent` result. |
| Request-field integrity | PASS | A request containing extra recipient, user, customer-name, and content fields was rejected with controlled HTTP 400 `invalid_request`. |
| First delivery | PASS | First owner request completed one provider delivery and returned HTTP 200 `sent`. |
| Repeat after success | PASS | Repeat returned HTTP 200 `already_sent`; provider delivery count remained one for that reservation. |
| Parallel claim | PASS | Concurrent production endpoint calls produced one provider completion only; the other request returned the controlled no-send state. The deployed claim definition retains the five-minute lease and `in_progress` branch. |
| Delivery count and recipient | PASS | Exactly three provider-completed rows existed before cleanup, each with attempt count 1 and the synthetic reservation owner's UUID as recipient. |
| Attempt bound | PASS (contract verification) | The deployed prepare definition retains the maximum three attempts per 24-hour attempt window and returns `attempt_limit_reached`; failure injection was intentionally not performed against the production provider. |
| Provider failure | PASS (contract verification) | The deployed route uses the safe completion path, returns stable `delivery_failed`, does not expose the provider error, and performs no automatic resend. No production failure was induced. |
| User rate limit | PASS | Ten endpoint requests for one synthetic user reached the normal controlled 404 path; request 11 returned HTTP 429 `rate_limited` with `Retry-After: 592`. |
| HMAC IP rate limit | PASS | Thirty accepted endpoint requests populated only the HMAC IP scope; the next request returned HTTP 429 with `Retry-After: 568`. No raw IP appeared in the response or persisted rate-limit key. |
| Recipient integrity | PASS | The browser could not supply an email or content field. Provider completions all referenced the reservation owner, including staff-triggered delivery. |
| SEC-006 HTML escaping | PASS | Delivered HTML rendered `<script>`, `<img onerror>`, and `<b>` literally as text. Original MIME contained `&lt;`, `&gt;`, `&amp;`, `&quot;`, and `&#39;` exactly once; no executable injected element or double escaping was present. |
| Plain-text body | PASS | Original MIME contained a separate `text/plain` part with the dynamic values as ordinary text, without HTML-entity escaping. |
| Template regression | PASS | The legitimate structural HTML, heading, reservation details, and footer rendered normally in Gmail. |
| SEC-007 audit integrity | PASS | The delivery claim, concurrent/repeat result, and email send created zero synthetic email business audits; the cancellation audit contract remains owned by the cancellation RPC. |
| Safe response/error surface | PASS | Every tested response contained only the stable `ok` and `code` fields. No JWT, service-role key, provider secret, raw IP, technical token, or raw database/provider error was returned. Static route review confirms generic server logging without token, IP, recipient, or raw error content. |

The automated production run completed **36/36 assertions**. The three messages
were independently visible in the controlled mailbox. SPF, DKIM, and DMARC
were all reported as PASS by the recipient mailbox.

## Production RPC ACL

| RPC | PUBLIC | anon | authenticated | service_role | Result |
|---|---:|---:|---:|---:|---|
| `prepare_confirmation_email(text,uuid)` | no | no | yes | no | PASS |
| `complete_confirmation_email(uuid,boolean,text,text)` | no | no | no | yes | PASS |
| `check_confirmation_email_rate_limit(uuid,text)` | no | no | no | yes | PASS |

All three functions remain `SECURITY DEFINER`, owned by `postgres`, with the
expected `search_path = public, pg_temp`. The endpoint's authenticated client
performs the business authorization and prepare claim; the server-only client
is restricted to the limiter and completion contracts.

## Cleanup

Application fixture cleanup completed first and independently confirmed zero
remaining synthetic Auth users, profiles, reservations, delivery rows, audit
rows, lane rows, and pricing rows.

The rate-limit pre-check then identified exactly nine synthetic user-scope rows
with the expected per-user cardinalities and exactly one IP-scope row containing
only the 30 matching timestamps from this run. A fail-closed transaction removed
exactly those ten rows. It would have rolled back on any count, identity,
timestamp-window, or IP-content mismatch. The final independent result was:

```text
remaining synthetic fixture = 0
remaining synthetic rate-limit residue = 0
cleanup_confirmed = true
```

No real reservation, user, profile, audit, delivery, or rate-limit timestamp
was changed. No application code, configuration, schema, RLS, ACL, migration,
or deployment was changed during the smoke.

## SEC-015 final result

```text
SEC-015 PRODUCTION SMOKE:
PASS

SEC-015 STATUS:
FULLY REMEDIATED / PROD PASS
```

---

# SEC-013 SAFE ERROR HANDLING PRODUCTION SMOKE

**Date:** 2026-09-04

**Production application:** `524da7a — security: harden client error handling`

This smoke used only malformed requests, missing/invalid authentication and a
non-existing all-zero UUID. No fixture, valid business mutation, provider
delivery, database write or production configuration change was performed.

## Results

| Check | Result | Evidence |
|---|---|---|
| Invalid request | PASS | `GET /api/create-reservation` returned HTTP 405 with an empty body. No raw message, database detail, hint, stack trace, SQL object name or 5xx was returned. |
| Missing authentication | PASS | `POST /api/confirm-event-reserve-promotion` without a Bearer token returned HTTP 401 with only `unauthorized` and the controlled message `Musisz się zalogować.` |
| Invalid authentication | PASS | The same endpoint with an invalid synthetic Bearer value returned HTTP 401 with only `unauthorized` and the controlled message `Musisz zalogować się ponownie.` |
| Admin API authorization | PASS | Anonymous `GET /api/admin/calendar-feed` returned HTTP 401 with the stable `unauthorized` code and controlled Polish text. |
| Promotion API authorization | PASS | Anonymous `POST /api/send-event-reserve-promotion` returned controlled HTTP 401 `Unauthorized`; the request did not reach provider delivery. |
| Controlled not found | PASS | As an authenticated admin, submitting `/events/confirm/00000000-0000-4000-8000-000000000000` rendered only `Nie znaleziono aktywnego zaproszenia.` The deployed allowlisted contract maps `not_found` to HTTP 404 and ignores the RPC-provided message. No mutation or email occurred. |
| Invalid check-in token | PASS | `/check-in/00000000-0000-4000-8000-000000000000` returned HTTP 200 with the controlled neutral `Check-in niedostępny` state and no reservation data or technical error. |
| Provider/delivery failure contract | PASS (static contract verification) | Deliberate production-provider failure was not induced. Source at the production commit returns fixed response codes/messages, omits provider bodies and stack traces, and logs only an operation/stage plus bounded code/status. Focused tests cover unknown/provider failures. |
| Account and customer UI | PASS | Authenticated `/account`, `/my-reservations` and `/my-events` loaded successfully. `/booking` and `/events` loaded their normal public views. No raw-error markers or visible 500 state appeared. |
| Admin UI | PASS | Authenticated `/admin`, `/admin/check-in`, `/admin/reservations` and `/admin/users` loaded successfully. No raw-error markers or visible 500 state appeared. |
| Known business codes | PASS | The deployed mapping retains controlled handling for `not_allowed`, `not_found`, conflict codes, `rate_limited`, `already_sent` and the active reservation/event/configuration codes. The focused suite passed 17/17. |
| Client/API exposure | PASS | Observed API bodies and error UI contained no `details`, `hint`, stack, SQL table/function name, filesystem path, raw error object or provider response body. |
| Secret/PII logging contract | PASS | Runtime source at the deployed commit does not log Authorization headers, JWTs, service-role keys, check-in/confirmation/reserve tokens, request bodies, email/phone PII or complete error objects. Client diagnostics are limited to operation name and an optional bounded stable code. |
| Normal-flow 5xx regression | PASS | Direct GET checks returned 200 for `/`, `/login`, `/account`, `/booking`, `/events`, `/my-reservations` and `/my-events`; anonymous `/admin/*` returned the expected 307 authorization redirect. Authenticated admin/dashboard/check-in/reservations/users views loaded in the browser. No tested normal flow returned 5xx. |

The Vercel log viewer was not available in the smoke browser session (it
required a separate Vercel login), so no private cloud log contents were
copied. Logging safety was verified from the exact deployed source contract and
from the absence of technical data in the exercised production responses and
UI. No token, secret or customer data is included in this report.

## Cleanup and changes

No synthetic persistent fixture was created, therefore cleanup was not
required and remaining fixture is zero by construction. No application code,
configuration, database data, schema, migration, RLS, ACL or deployment was
changed during the smoke.

## SEC-013 final result

```text
SEC-013 PRODUCTION SMOKE:
PASS

SEC-013 STATUS:
FULLY REMEDIATED / PROD PASS
```

---

# SEC-016 PRIVACY POLICY PRODUCTION SMOKE

**Date:** 2026-09-04

**Production application:** `https://csk-booking-5nwh.vercel.app`

**Production commit:** `f7d685d — docs: update privacy policy and terms`

This was a read-only application smoke. It created no fixture and performed no
database, configuration, migration or deployment operation.

## Results

| Check | Result | Evidence |
|---|---|---|
| `/privacy` availability | PASS | Production GET returned HTTP 200, a Vercel response body of 32,679 bytes and no 5xx. |
| `/terms` availability | PASS | Production GET returned HTTP 200, a Vercel response body of 29,334 bytes and no 5xx. |
| General draft wording | PASS | Neither rendered page contains `wersja robocza` or an equivalent general draft marker. |
| Current data-flow coverage | PASS | The rendered privacy page describes account/profile data, reservations, event registrations, check-in, e-mail delivery, user data export, account deletion, anonymization, audit logs and abuse/rate-limit metadata. |
| Technical providers | PASS | The rendered notice names only the verified providers in scope: Supabase for database/authentication, Vercel for hosting and Resend for e-mail delivery. |
| Last-updated date | PASS | The page renders `Ostatnia aktualizacja: 4 września 2026 r.` |
| Approved owner-data residual | PASS | Visible owner placeholders are limited to legal name, legal form, address and privacy contact. The block is explicitly marked for completion before formal service launch. |
| Other placeholders | PASS | Rendered `/privacy` and `/terms` contain no `TODO`, `example.com`, dotted blank fields or unrelated placeholder data. |
| Terms consistency | PASS | `/terms` no longer presents itself as a draft, retains its personal-data section and links to the current `/privacy` page. |
| Browser/runtime | PASS | Fresh headless Chromium loads returned HTTP 200 with 0 console errors, 0 page errors and 0 failed resource requests for both pages. The interactive browser showed the expected headings, content, image and legal navigation without a Next.js error overlay. |

## Changes and residual

No application code, database data, schema, RLS, ACL, configuration, migration
or deployment was changed during this smoke. No synthetic fixture was required.

The remaining limitation is intentional and visible: legal identity and contact
details await the final business-entity decision. This prevents SEC-016 from
being classified as fully remediated but does not invalidate the verified
content update.

## SEC-016 final result

```text
SEC-016 PRODUCTION SMOKE:
PASS

SEC-016 STATUS:
PARTIALLY REMEDIATED — OWNER DATA DEFERRED

KNOWN RESIDUAL:
legal identity/contact details pending final business entity decision.
```

---

# CLEAN-004 DIRECT RESERVATION DELETE HARDENING PRODUCTION SMOKE

**Date:** 2026-09-04

**Production commit:** `7e0d05f — security: block direct reservation deletes`

**Production migration:** `20260904200000_harden_reservation_direct_delete.sql`

The smoke used a unique synthetic run marker and dynamically generated UUIDs.
All fixture and application-role checks ran in one transaction. Successful
completion deliberately raised
`CLEAN004_SMOKE_ALL_20_PASS_ROLLBACK`, forcing rollback of the complete test
fixture.

## Results

| Check | Result | Evidence |
|---|---|---|
| Migration | PASS | Production migration history contains `20260904200000` / `harden_reservation_direct_delete`. |
| Reservation RLS contract | PASS | RLS remains enabled; no direct reservation DELETE policy exists for admin, employee or another client role. |
| Reservation table ACL | PASS | `authenticated` retains SELECT without DELETE; `anon` and `PUBLIC` have no direct table privilege; the existing `service_role` privileged baseline is unchanged. |
| Anonymous direct DELETE | PASS | Direct DELETE was denied. |
| Ordinary-user direct DELETE | PASS | Direct DELETE was denied, including against the user's synthetic reservation. |
| Instructor direct DELETE | PASS | Direct DELETE was denied. |
| Employee direct DELETE | PASS | Direct DELETE was denied. |
| Admin direct DELETE | PASS | Direct DELETE was denied. |
| Client TRUNCATE | PASS | The application role could not truncate `reservations`. |
| Owner cancellation | PASS | The owner cancelled their own synthetic reservation through the controlled cancellation RPC. |
| Employee cancellation | PASS | Employee cancellation through the controlled application RPC succeeded. |
| Admin cancellation | PASS | Admin cancellation through the controlled application RPC succeeded. |
| Operational history | PASS | Each controlled cancellation retained the reservation row and changed only the expected cancellation state; the record remained available to operational/reporting history. |
| Cancellation audit | PASS | Successful controlled cancellation produced the expected audit entry; denied direct DELETE could not bypass the audit path. |
| Idempotency | PASS | Repeating the already-applied controlled cancellation produced the controlled no-change result and no duplicate audit. |
| SEC-009 anonymization | PASS | `anonymize_my_account_v1` completed for the synthetic lifecycle user without deleting the reservation. Direct PII was removed while the anonymized reservation history remained. |
| History count | PASS | Reservation row counts for the synthetic lifecycle case were preserved across anonymization. |
| Transaction safety | PASS | Exactly 20 smoke assertions passed before the deliberate terminal exception; no `COMMIT` was executed. |
| Controlled rollback | PASS | SQL Editor returned the expected `ERROR: P0001: CLEAN004_SMOKE_ALL_20_PASS_ROLLBACK`. |
| Independent cleanup check | PASS | Read-only post-check returned zero synthetic Auth users, profiles, lanes, pricing rules, reservations and audit logs; `remaining_synthetic_fixture = 0`. |

## Compatibility and security conclusion

The hardening blocks every tested client-side direct reservation deletion while
preserving the supported user, employee and admin cancellation workflows.
Cancellation keeps the reservation as operational history and remains audited.
The SEC-009 account-lifecycle flow continues to anonymize rather than delete
reservation history.

No application code, configuration, production schema, migration, RLS or ACL
was changed during this smoke. The only database writes were synthetic rows
inside the transaction that ended in the deliberate rollback exception. The
independent post-check was read-only and confirmed zero residue.

## CLEAN-004 final result

```text
CLEAN-004 PRODUCTION SMOKE:
PASS

CLEAN-004 STATUS:
FULLY REMEDIATED / PROD PASS
```

---

# CLEAN-005 PROFILE UPDATE HARDENING PRODUCTION SMOKE

**Date:** 2026-09-05

**Production commit:** `fe1783b — security: harden profile updates`

**Production migration:** `20260905100000_harden_profile_direct_updates.sql`

The database smoke used dynamically generated UUIDs, synthetic
`example.invalid` identities and the `[TEST][CLEAN-005]` marker. The primary
30-check matrix ran in one transaction and ended with `ROLLBACK`. A separate
employee positive-path transaction ended with the expected controlled
`CLEAN005_EMPLOYEE_CONTROLLED_RPC_PASS_ROLLBACK` exception. No real customer
record was read or changed.

## Results

| Check | Result | Evidence |
|---|---|---|
| Migration | PASS | Read-only production history check returned `migration_present = true` for `20260905100000`. |
| Profile RLS and owner | PASS | `profiles` remains PostgreSQL-owned with RLS enabled; no direct `UPDATE` policy remains. |
| Client table ACL | PASS | `authenticated` has profile `SELECT, INSERT` without `UPDATE`, `DELETE`, `TRUNCATE`, `REFERENCES`, `TRIGGER` or `MAINTAIN`; `anon` and `PUBLIC` have no profile table privilege. The managed `service_role` baseline is unchanged. |
| Anonymous direct update | PASS | Direct profile `UPDATE` was denied. |
| Ordinary-user cross-profile update | PASS | User A could not update User B. |
| Ordinary-user self direct update | PASS | Direct self-update was denied; self service must use the allowlisted RPC. |
| Instructor direct update | PASS | Direct arbitrary profile `UPDATE` was denied. |
| Employee direct update | PASS | Direct arbitrary profile `UPDATE` was denied. |
| Admin direct update | PASS | Direct changes to `role`, `verification_status`, `email`, `phone`, `user_id`, `created_at` and `admin_note` were denied. A complete before/after row comparison confirmed no field changed. |
| Self-service RPC | PASS | `update_my_profile_v1(...)` updated only the synthetic owner's allowlisted contact/address and declaration fields. Its signature exposes no target-user or privileged-field parameter. |
| Privileged-field integrity | PASS | Self-service left `role`, `verification_status` control, `admin_note`, `user_id`, identity key and internal timestamps outside the caller-controlled update contract. User A could not target User B. |
| Account application path | PASS | The deployed `/account` view loaded without a browser console error. The application save path calls `update_my_profile_v1` and contains no `.from("profiles").update(...)` fallback; the same RPC succeeded dynamically in the transactional smoke. No real account save was performed. |
| Admin controlled role RPC | PASS | `admin_set_user_role_v1` changed only the expected synthetic role and produced exactly one trusted audit entry. |
| Admin controlled verification RPC | PASS | `update_profile_verification` changed the expected synthetic verification state and produced exactly one trusted audit entry. |
| Admin controlled note RPC | PASS | `admin_set_user_note_v1` changed the expected synthetic note and produced exactly one trusted audit entry. |
| Employee controlled RPCs | PASS | As an authenticated `pracownik`, the synthetic operator successfully used `update_profile_contact_details` and `update_profile_verification`; each changed the intended fields and produced exactly one audit with the operator's `auth.uid()`. |
| Audit integrity and idempotency | PASS | Audits used the authenticated actor and database-side execution path. Repeating the same admin-note operation returned the controlled `no_change` result and did not create a duplicate audit. No direct client insertion into `audit_logs` was used. |
| Cross-user isolation | PASS | The denied User A statements left User B's complete profile row byte-for-byte equivalent at the JSON row level. |
| SEC-009 lifecycle regression | PASS | `anonymize_my_account_v1()` completed for the synthetic lifecycle user through its trusted SECURITY DEFINER path; it did not depend on client table `UPDATE`. |
| Secret/error review | PASS | The test and report contain no JWT, Authorization header, service-role key or real-user PII. Client-facing account behavior remained controlled; no raw database error was exposed through the application UI. |
| Primary transaction | PASS | The SQL Editor returned 30 result rows and the final assertion block raised no failure; all 30 checks passed before the explicit `ROLLBACK`. |
| Employee transaction | PASS | The terminal exception was exactly `CLEAN005_EMPLOYEE_CONTROLLED_RPC_PASS_ROLLBACK`, proving both employee positive paths and forcing rollback. |
| Independent cleanup | PASS | Final read-only check returned `synthetic_auth_users = 0`, `synthetic_profiles = 0`, `synthetic_audit_logs = 0` and `remaining_synthetic_fixture = 0`. |

## Security conclusion

All tested application roles are denied direct profile updates. Self-service,
admin and employee workflows remain available only through their controlled
RPC contracts, with field allowlisting, trusted actor attribution and
idempotent auditing. The account lifecycle remains compatible with SEC-009.

No application code, configuration, production schema, migration, RLS or ACL
was changed during this smoke. Production writes were limited to synthetic
rows inside transactions that were fully rolled back; all post-checks were
read-only.

## CLEAN-005 final result

```text
CLEAN-005 PRODUCTION SMOKE:
PASS

CLEAN-005 STATUS:
FULLY REMEDIATED / PROD PASS
```

---

# ADMIN CALENDAR SINGLE POSITION RESERVATIONS PRODUCTION SMOKE

**Date:** 2026-09-05

**Production commit:** `e60482a — fix: show position reservations in admin calendar`

The production smoke used one uniquely marked synthetic lane family, one
synthetic Auth/profile identity and three synthetic reservations. The family
contained a root lane, an active child position and an inactive historical
child position. All observations were made through the deployed admin Calendar
UI or its authenticated production feed. The fixture was removed with an
exact-ID, fail-closed cleanup followed by an independent zero-residue check.

## Results

| Check | Result | Evidence |
|---|---|---|
| Production deployment | PASS | The deployed Calendar exhibited the hierarchy-aware behavior introduced by `e60482a`: a parent filter returned its direct child reservation and a child filter remained exact. |
| Whole-lane reservation | PASS | Day view showed the synthetic root reservation at `10:00–11:00`. |
| Single-position reservation | PASS | Day view showed the child reservation exactly once at `11:00–12:00`, under the `Parent — Position 1` label. |
| Child UUID preservation | PASS | The authenticated feed returned exactly two entries with distinct lane IDs: the root UUID and the original child UUID. No projection to the parent or a sibling UUID occurred. |
| Day view | PASS | Parent scope rendered one root lane entry and one child-position entry, each exactly once. |
| Week view | PASS | The week of 31 August–6 September rendered the same two reservations on 5 September, without duplication. |
| Month view | PASS | 5 September reported exactly `Rezerwacje: 2` and 17% occupancy. The count comprises one root and one child reservation; the child was included once and was not double-counted. |
| Parent filter | PASS | Selecting the synthetic parent displayed the parent and its active child position, with both corresponding reservations. |
| Child filter | PASS | Selecting the child UUID displayed only `Parent — Position 1` and its single reservation. The root reservation and other children were absent. |
| Inactive child history | PASS | After enabling historical entries for 4 September, the inactive child appeared as `Zasób historyczny` and its completed reservation was visible once with the `Zakończona` status. |
| No sibling projection | PASS | Exact child scope returned one child lane and one entry; no root or sibling reservation was rendered. |
| Anonymous access | PASS | A direct unauthenticated request to `/api/admin/calendar-feed` returned HTTP 401. |
| Ordinary-user access | PASS | A real production request authenticated as the synthetic ordinary user returned HTTP 403. |
| Instructor restriction | PASS | A real production request authenticated as the synthetic instructor returned HTTP 200 with `entries=0` for a reservation-only query; lane metadata remained available but reservation data did not. |
| PII contract | PASS | The admin feed entry shape remained limited to calendar fields (`date`, times, ID, label, lane metadata, status/type and shooter count). No email, phone, address, token or profile field was added by the bugfix. |
| Cleanup | PASS | Fail-closed cleanup targeted only the run's exact UUIDs. Final post-check returned `remaining_synthetic_fixture = 0` and `cleanup_confirmed = true`. |

## Security and data conclusion

The production parent filter now includes direct child positions, while a
child filter remains exact. Reservations retain their source lane UUID and
hierarchy label, so neither sibling projection nor monthly double-counting was
observed. The established access boundary also remained intact: anonymous and
ordinary users cannot read the admin feed, and instructors receive no
reservation entries.

No application code, configuration, schema, migration or deployment was
changed during this smoke. Production writes were limited to the uniquely
marked synthetic fixture and its exact-ID cleanup. The final read-only
verification confirmed zero remaining synthetic fixture.

## Final result

```text
ADMIN CALENDAR SINGLE POSITION PRODUCTION SMOKE:
PASS

BUG STATUS:
FULLY FIXED / PROD PASS
```

---

# REPORTS-6A PRODUCTION SMOKE

**Date:** 2026-09-05

**Production commit:** `282edff — feat: add scalable admin reservation reports`

**Production migration:** `20260905150000_add_admin_reservation_reports_v1.sql`

The database portion used four uniquely generated synthetic Auth/profile
identities, a synthetic hierarchy, an inactive historical resource and
synthetic reservations on dates that cannot overlap current customer data.
All fixture changes ran inside one transaction. After 25 assertions passed,
the deliberate terminal exception
`REPORTS6A_PROD_SMOKE_ALL_25_PASS_ROLLBACK` forced rollback of the complete
fixture. A separate read-only query then confirmed zero residue.

## Results

| Test | Result | Evidence |
|---|---|---|
| Authorization | PASS | The deployed RPC allowed the synthetic admin. Employee, instructor and ordinary-user calls returned controlled `not_allowed`; `anon`, `PUBLIC` and `service_role` have no `EXECUTE`. `/admin/reports` is admin-only in the server-side route map and loaded successfully in a real authenticated admin session. No browser `service_role` use or REPORTS-6A RLS widening was found. |
| Operating hours / occupancy | PASS | Production returned `opening_start=08:00`, `opening_end=20:00` and exactly `opening_minutes_per_day=720`. The deployed UI independently displayed the same 12-hour capacity premise. The controlled mixed hierarchy produced 300 occupied minutes; a 960-minute denominator was not used. |
| Date range | PASS | One day returned 1 civil day, a month boundary and year boundary returned 2 days each, and both the spring and autumn DST dates remained one civil day. UI day, week, month and year modes loaded successfully; the year view returned 365 days without off-by-one behavior. |
| Whole-lane | PASS | A two-hour whole-lane reservation was counted once as a reservation and mapped to the two effective child units without creating an extra root unit. |
| Single position | PASS | The child reservation appeared exactly once with its child UUID, `resource_kind=position`, parent UUID and `Parent — Position` presentation. It was not projected onto its sibling. |
| Mixed hierarchy | PASS | Overlapping root `08:00–10:00` and child `09:00–11:00` ranges were unioned per effective unit. The result was 300 occupied minutes, not the double-counted alternative, and the synthetic family increased effective capacity by exactly two. |
| Cancellation | PASS | The synthetic owner cancelled a future reservation through the existing `cancel_reservation` RPC. The report changed from active occupancy to one cancellation, with zero occupied minutes for that date; the reservation row remained as operational history. |
| Revenue | PASS | On the controlled fixture, planned revenue was 150 PLN, paid revenue 100 PLN and outstanding/on-site revenue 50 PLN. Cancelled and no-show records did not inflate the canonical planned total. |
| PII reduction | PASS | Aggregate fields contained no identity/contact data. Detail rows were bounded to the exact existing admin-table DTO. No user ID, address, permit/declaration, admin note, check-in/confirmation/promotion token, JWT or service-role field was returned. |
| Pagination | PASS | With 55 synthetic detail rows, page 1 returned exactly 50 and page 2 exactly 5. IDs were unique across pages, ordering was stable, and aggregate summary data was identical on both pages. |
| Large range | PASS | Production RPC calls for 90 days and 365 days completed successfully. The frontend contains one aggregate RPC call with bounded limit/offset and no raw `reservations` table fetch or per-day/per-lane N+1 loop. |
| Inactive / historical resource | PASS | A reservation for an inactive resource remained visible through `lane_name_snapshot`. The contract explicitly reported `name_basis=reservation_snapshot`, `position_parent_name_basis=current_configuration` and `capacity_basis=current_configuration`. |
| Frontend | PASS | The deployed `/admin/reports` rendered range controls, KPI cards, hierarchy-aware details, empty-state behavior and pagination controls without a runtime or 5xx error. Day, week, month and year refreshes completed against `admin_get_reservation_report_v1()`. |
| Migration / function contract | PASS | Production history contains `20260905150000`. The exact RPC is `STABLE SECURITY DEFINER`, owned by `postgres`, with `search_path=pg_catalog, public, pg_temp`; the reporting index and default page size/offset match the migration. |
| Transaction rollback | PASS | The terminal result was the expected controlled exception `REPORTS6A_PROD_SMOKE_ALL_25_PASS_ROLLBACK`, proving all 25 checks passed before rollback. |
| Cleanup | PASS | Independent post-check: synthetic Auth users `0`, profiles `0`, lanes `0`, reservations `0`, audits `0`; `remaining_synthetic_fixture=0`, therefore `cleanup_confirmed=true`. |

## Scalability and security conclusion

The production page reads one canonical aggregate/paginated RPC and does not
bulk-fetch raw reservations in the browser. KPI values are independent of the
current detail page, pagination is bounded at 50 in the UI, and the tested
90-day/year ranges completed without timeout or memory errors. No production
schema, migration, application code, configuration or deployment was changed
during the smoke.

The documented historical limitation remains intentional: occupancy capacity
uses current resource configuration, and a position snapshot does not preserve
the historical parent name. The smoke confirmed this contract rather than
treating it as a REPORTS-6A failure.

## Final result

```text
REPORTS-6A PRODUCTION SMOKE:
PASS

REPORTS-6A STATUS:
FULLY IMPLEMENTED / PROD PASS

HISTORICAL SNAPSHOT RESIDUAL:
CONFIRMED
```

---

# PUBLIC EVENT AVAILABILITY PRODUCTION SMOKE

**Date:** 2026-09-05

**Production commit:** `fbddb5c — fix: use authoritative public event availability`

**Production migration:** `20260905120000_add_public_event_availability_v1.sql`

The production database smoke used a uniquely marked synthetic event, five
synthetic Auth/profile identities and synthetic event registrations. All data
changes ran in one transaction. The terminal exception was exactly
`PUBLIC_EVENT_AVAILABILITY_SMOKE_ALL_PASS_ROLLBACK`, deliberately forcing a
rollback after every assertion had passed. No real event, registration or user
record was used.

## Results

| Check | Result | Evidence |
|---|---|---|
| Migration | PASS | A read-only production history check returned `migration_present = true` for `20260905120000`. |
| Public RPC ACL | PASS | `anon` and `authenticated` have `EXECUTE`; `PUBLIC` and `service_role` do not. The ACL matches the deployed migration. |
| Function security | PASS | The deployed zero-argument RPC is `STABLE`, `SECURITY DEFINER`, owned by `postgres`, and has `search_path=pg_catalog, public, pg_temp`. |
| PII-free contract | PASS | The response contained only `event_id`, public event presentation fields, `max_participants`, `registered_count`, `reserve_count`, `available_spots` and `sold_out`. It contained no registration ID, user ID, customer identity/contact data, admin note or token field. |
| Authoritative count | PASS | With capacity 10 and three occupying registrations, both anonymous and authenticated calls returned `registered_count=3` and `available_spots=7`. |
| Owner-scoped RLS independence | PASS | The ordinary user could directly see only their own one registration, while the public RPC returned the complete aggregate of three. Anonymous and authenticated aggregate rows were identical. |
| Reserve semantics | PASS | One reserve registration produced `reserve_count=1` without reducing `available_spots`; occupying statuses remained exactly `registered` and `approved`. |
| Sold out | PASS | At ten occupying registrations the RPC returned `registered_count=10`, `available_spots=0` and `sold_out=true`; availability never became negative. |
| Controlled cancellation | PASS | Owner cancellation through `cancel_event_registration` reduced the occupying count from 3 to 2 and increased availability from 7 to 8. |
| Reserve promotion | PASS | Owner confirmation through `confirm_event_reserve_promotion` moved the test registration from reserve to registered: reserve count fell to 0, registered count rose to 3 and availability returned to 7. |
| Production `/events` | PASS | The deployed page loaded without a 5xx and rendered availability states/counts. Its deployed call site uses `get_public_event_availability_v1()` and contains no direct `event_registrations` query or client-side participant counting. The anonymous RPC contract returned the same authoritative aggregate as the authenticated call; the existing UI may still defer detailed count presentation until login. |
| No-overbooking regression | PASS | When the synthetic event was full, `register_for_event` did not create an eleventh occupying registration; it returned the controlled reserve outcome. The authoritative result remained `registered_count=10`, `available_spots=0`, with the new registration counted only in `reserve_count`. |
| Transaction rollback | PASS | The terminal result was the expected controlled exception `PUBLIC_EVENT_AVAILABILITY_SMOKE_ALL_PASS_ROLLBACK`; therefore the complete synthetic fixture was rolled back. |
| Independent cleanup | PASS | A separate read-only post-check returned zero synthetic Auth users, profiles, events, event registrations and audit rows, with `remaining_synthetic_fixture=0`. |

## Security and data conclusion

Public availability is computed from the complete registration set inside the
dedicated PII-free database contract and is independent of owner-scoped
`event_registrations` RLS. The public reader does not expose registration rows
or identity/contact data, and the atomic registration writer remains the
authoritative overbooking control.

No application code, configuration, schema, migration or deployment was
changed during this smoke. Production writes were limited to the uniquely
marked synthetic fixture inside a transaction that was fully rolled back; the
independent post-check confirmed zero residue.

## Final result

```text
PUBLIC EVENT AVAILABILITY PRODUCTION SMOKE:
PASS

BUG STATUS:
FULLY FIXED / PROD PASS
```

---

# REPORTS-6B PRODUCTION SMOKE

**Date:** 2026-09-05

**Production commit:** `b9b79d5 — feat: add report filters and safe csv export`

**Production migration:** `20260905170000_add_admin_reservation_report_filters_export.sql`

The smoke used one uniquely marked synthetic Auth/profile identity, one
synthetic parent family with two positions, one standalone lane and 72
synthetic reservations. Four of those reservations were isolated CSV formula
injection cases. No real customer, reservation or resource was read or
modified as fixture data.

## Results

| Test | Result | Evidence |
|---|---|---|
| Migration and RPC presence | PASS | Remote migration history contains `20260905170000`; the deployed report v2 and export v1 signatures both exist. |
| Authorization | PASS | The production role matrix returned data only for `admin`; `pracownik`, `instruktor` and ordinary `user` received `not_allowed`. An unauthenticated direct URL request returned `307` to `/login?redirectTo=%2Fadmin%2Freports`. |
| Function ACL | PASS | `authenticated` has EXECUTE on report v2 and export v1. `anon`, `PUBLIC` and `service_role` do not. The private shared helper is not a browser contract. |
| RLS / browser trust boundary | PASS | No REPORTS-6B table policy exists and no table RLS policy was widened. The deployed browser flow used the authenticated reporting RPC; no service-role client or raw reservations bulk fetch was introduced. |
| Date filters | PASS | Exact `from`, exact `to`, and the inclusive two-day `from+to` range returned respectively 7, 1 and 8 controlled fixture rows. KPI and details totals matched each range. |
| Parent filter | PASS | Selecting the synthetic parent returned its three root rows and the three rows belonging to its two children, excluded the standalone resource, retained effective capacity 2 and produced 600 non-double-counted occupied minutes. |
| Child filter | PASS | Selecting the exact child returned only its two rows, retained the child UUID and effective capacity 1, and returned neither the parent nor sibling. |
| Booking type | PASS | The controlled date returned 4 whole-lane and 3 single-position rows. Combining the child with `single_position` returned only the two exact child rows. |
| Reservation status | PASS | All supported canonical filters passed: `confirmed=3`, `completed=2`, grouped `cancelled=1`, and `no_show=1`. KPI and detail totals were consistent. |
| Payment status | PASS | All supported filters passed: `paid=2`, `paid_on_site=1`, `unpaid=1`, `pay_on_site=1`, `free=1`, and `voucher=1`. Canonical unfiltered revenue was planned 420 PLN, paid 280 PLN and outstanding/on-site 140 PLN. |
| Combined filters | PASS | Date + parent + whole-lane + confirmed + paid returned exactly one row, one active reservation and 100 PLN planned/paid revenue. The server filter echo exactly matched the request. |
| Pagination | PASS | A 60-row fixture returned 50 rows on page 1 and 10 on page 2, with no duplicate IDs, stable ordering and identical KPI summaries. Changing a filter on page 2 reset the UI to page 1. |
| URL state | PASS | Query parameters restored all six filters after reload. Browser back/forward restored the previous/next status and payment state. Reset returned both dates to today and removed lane/status/payment/type values. No PII appeared in the URL. |
| CSV filter scope | PASS | A combined child/status/payment/type export contained exactly the one matching row. A separate 60-row export contained all 60 filtered rows rather than only the current 50-row page. |
| CSV format | PASS | The actual production download used UTF-8 BOM, semicolon separators, CRLF records and quoted cells. Quotes, semicolons, embedded newline, Unicode and Polish text were preserved correctly. |
| CSV formula injection | PASS | Four actual downloaded cells beginning with `=`, `+`, `-` and `@` were each prefixed with an apostrophe before CSV quoting. The multiline `-` case remained one quoted logical CSV field. |
| PII minimization | PASS | CSV headers and rows contained no email, phone, address, permits, tokens, admin note, profile data, user ID or reservation ID. Aggregate KPI/filter contracts contained no identity/contact fields. |
| Export limit | PASS | The deployed definition enforces `v_total > 5000`, returns controlled `export_too_large` with `max_rows=5000`, and omits the rows payload above the limit. No 5,000-row production load test was performed. |
| Empty result | PASS | An empty date returned zero details, zero canonical revenue and a valid empty export array without runtime or 5xx error. |
| REPORTS-6A regression | PASS | The production matrix retained the 08:00–20:00 / 720-minute day, civil-day calculations across spring/autumn DST, whole-lane and position hierarchy semantics, effective-capacity accounting, interval-union occupancy without double counting, admin-only access and 50-row bounded details. |
| Frontend | PASS | `/admin/reports` rendered KPI, details, all filters, reset, pagination and export. Combined filters showed the expected one-row state; pagination showed 50/10; export success messages matched the result counts. No runtime or 5xx error occurred. |
| Cleanup | PASS | Fail-closed pre-check identified exactly 1 Auth user, 1 profile, 1 identity, 4 lanes, 4 booking rules, 4 pricing rules, 72 reservations and 0 audits. Cleanup removed only those exact UUIDs. |
| Independent cleanup confirmation | PASS | A separate read-only post-check returned synthetic Auth users `0`, profiles `0`, lanes `0`, reservations `0`, with `remaining_synthetic_fixture=0` and `cleanup_confirmed=true`. |

## Security and scalability conclusion

The production UI and database use one shared server-side filter contract for
aggregate KPI and details. KPI are independent of the 50-row page, while CSV
uses a separate PII-minimal full-result contract bounded at 5,000 rows. The
browser never receives raw unbounded reservation datasets and does not use a
service-role credential.

The known `REPORTS-HISTORY-SNAPSHOT` residual is unchanged: historical
capacity can use current resource configuration, and a child snapshot does not
contain the historical parent name. This is not a REPORTS-6B failure.

No code, schema, migration, configuration or deployment was changed during the
smoke. Production writes were restricted to the uniquely identified synthetic
fixture and its exact cleanup. The final independent check confirmed zero
residue.

## Final result

```text
REPORTS-6B PRODUCTION SMOKE:
PASS

REPORTS-6B STATUS:
FULLY IMPLEMENTED / PROD PASS

REPORTS-6A REGRESSION:
PASS

HISTORICAL SNAPSHOT RESIDUAL:
CONFIRMED
```

---

# REPORTS-6C PRODUCTION SMOKE

**Date:** 2026-09-05

**Production implementation:** `d8f6bab — feat: improve responsive reports ux`

This smoke was performed against the deployed Vercel application in a real
authenticated admin session. It used the existing read-only reporting
contracts and did not create fixture data or perform any production write.
The live phone-sized browser surface was 354 CSS px wide; the deployed
sub-640 px layout used there is the same layout used at 320, 375 and 430 px.
The exact 320/375/430 behavior was additionally checked against the deployed
responsive classes and the focused REPORTS-6C regression contract.

## Results

| Test | Result | Evidence |
|---|---|---|
| Mobile 320 | PASS | The deployed sub-640 px card layout has no page-level fixed minimum width; `min-w-0`, wrapping KPI values and full-width controls cover the 320 px case. The production phone rendering showed no document-level horizontal overflow. |
| Mobile 375 | PASS | The live 354 px production rendering exercises the same CSS breakpoint as 375 px. KPI, filters, reservation cards, pagination and export remained readable and usable without page-level horizontal overflow. |
| Mobile 430 | PASS | The deployed 430 px path remains in the same card-layout breakpoint. No clipping or unbreakable content was present; hierarchy labels and KPI values wrap inside bounded containers. |
| Mobile PII minimization | PASS | Production cards exposed only date, time, amount, resource label, booking type, reservation status and payment status. Customer name, email and phone were absent from the mobile-card DOM. |
| Tablet | PASS | Below the `xl` breakpoint, the responsive card layout remains active while filter and card grids progressively move to two columns. The layout contains no page-level fixed-width table or clipped controls. |
| Desktop | PASS | At the production desktop viewport the cards were hidden and the full table was visible. The table remained inside its dedicated horizontal-scroll container; KPI, filters, pagination and export rendered without regression. |
| Filter UX | PASS | Date, parent/child resource, reservation status, payment status and booking type controls were present and labelled. A combined parent + confirmed + pay-on-site + single-position filter returned exactly one matching row. Selecting the exact child also returned exactly that one row. |
| Filter URL and reset | PASS | All active filters were reflected in non-PII query parameters. Reset restored both dates to today, cleared resource/status/payment/type values and removed their query parameters. Filter changes retained page 1 behavior. |
| Loading | PASS | A fresh production navigation rendered the polite live-region state `Ładowanie raportu...` until the RPC response completed. |
| Empty state | PASS | The current-day empty result rendered the controlled empty message, explained how to broaden the scope, displayed the no-export-data hint and disabled CSV export. No raw backend error was shown. |
| Error and retry | PASS | An invalid production URL filter failed closed with `Nieprawidłowe filtry raportu w adresie strony.` and no DB/RPC details. The deployed retryable-error branch uses the generic report message and an accessible `Spróbuj ponownie` action that calls the same bounded loader; raw `message/details/hint` values are not rendered. |
| Pagination UX | PASS | The production control announced `Wyniki 1–10 z 10. Strona 1 z 1`; Previous/Next had explicit accessible names, were correctly disabled at the boundary and measured 44 px high. The detail request remains bounded to 50 rows. |
| Export UX | PASS | A real production export completed with the controlled status `Wyeksportowano 10 rekordów.` Empty results disabled the action. The existing 5,000-row controlled-limit message and REPORTS-6B CSV contract are unchanged. |
| Accessibility smoke | PASS | Inputs have associated labels; status, loading and error regions have explicit live/alert semantics; pagination buttons have descriptive names. Tested inputs/buttons measured 44–50 px high and deployed interactive controls retain visible focus-ring styles. No basic contrast or keyboard-control regression was observed. |
| Runtime / console | PASS | Normal report loading, combined filtering, reset, empty state and export produced no browser console errors or warnings and no 5xx response surfaced in the UI. |
| REPORTS-6A regression | PASS | The canonical aggregate RPC remains the source of KPI/details, the UI still states the 12-hour / 720-minute operating-day premise, hierarchy labels remain intact, and the single-position row was counted once without sibling projection. Admin-only access and bounded details are unchanged. |
| REPORTS-6B regression | PASS | Backend filters, shared KPI/detail scope, URL restoration, page size 50, dedicated full-result CSV export, formula-injection neutralization, PII minimization and admin-only export remain unchanged. The live combined-filter and export checks passed. |
| Historical snapshot residual | CONFIRMED | Historical capacity may use current resource configuration, and a child snapshot does not preserve the historical parent name. This accepted residual was not changed by REPORTS-6C. |

## Security and data conclusion

The responsive polish is present in production and preserves the REPORTS-6A
and REPORTS-6B backend contracts. Mobile cards intentionally omit customer
identity/contact fields, while the desktop-only table remains available to the
authorized administrator. No raw backend error was rendered and no service
role or direct table-read path was introduced.

No code, database data, schema, migration, configuration or deployment was
changed during this smoke. Only this report was updated locally.

## Final result

```text
REPORTS-6C PRODUCTION SMOKE:
PASS

REPORTS-6C STATUS:
FULLY IMPLEMENTED / PROD PASS

REPORTS-6A REGRESSION:
PASS

REPORTS-6B REGRESSION:
PASS

ETAP 6 REPORTS:
DONE

HISTORICAL SNAPSHOT RESIDUAL:
CONFIRMED
```

---

# EVENTS-8A PRODUCTION SMOKE

**Date:** 2026-09-05

**Production implementation:** `1e42f57 — fix: align event status and cancellation ux`

The smoke was executed against the deployed Vercel application and the linked
production database. All persistent records used by the test were synthetic
and carried the unique marker
`[TEST][EVENTS-8A][evt8a-mtouoga1-5ecc37f8]`. Database mutation checks were
performed inside explicit transactions ending in `ROLLBACK`. The persistent UI
fixture was removed by a fail-closed cleanup and followed by an independent
read-only zero-residue check.

## Results

| Test | Result | Evidence |
|---|---|---|
| Status consistency | PASS | Production `/my-events` rendered `registered` as `Zapisany`, `approved` as `Zatwierdzony`, `reserve` as `Lista rezerwowa`, and `cancelled` as `Zapis anulowany`. `/admin/events` rendered the same four business states with the matching participant/action model. `/events` used availability states rather than reinterpreting participant statuses. |
| Cancellation cutoff | PASS | A production transaction created three synthetic registrations at `>72h`, exactly `72h`, and `<72h` from the event start in `Europe/Warsaw`. The first two cancellations succeeded; the third returned the controlled backend denial and left the registration unchanged. The deployed frontend uses the same `Europe/Warsaw` instant calculation and exposes the CTA only when the remaining time is at least 72 hours. |
| Public availability | PASS | Both anon and authenticated production views returned the same authoritative values from `get_public_event_availability_v1()`: registered/approved `1 / 5`, cancelled `0 / 5`, sold-out `1 / 1` with reserve count 1, and the promotion case `1 / 2` with reserve count 1. Transactional cancellation changed `1/3` to `0/3`; reserve promotion changed registered/reserve/available from `1/1/1` to `2/0/0`. |
| Availability source | PASS | The deployed `/events` client calls only `get_public_event_availability_v1()` and contains no public `event_registrations` count. The production RPC returned exactly the approved aggregate keys and no registration rows or identity/contact/token fields. |
| Public event flow | PASS | Logged-out and logged-in `/events` loaded without 5xx. Available, sold-out, reserve-list, and closed states rendered controlled Polish UX. A user already registered for a synthetic event received no second registration CTA; the backend duplicate call was controlled and `changed=false`. |
| Registration / overbooking | PASS | A rollback-only production test registered a fresh synthetic user into an available event (`registered`) and into a full event (`reserve`). The full event remained at capacity with `available_spots=0`; reserve count increased without overbooking. |
| My Events | PASS | The synthetic user saw registered, approved, reserve, and cancelled states, payment labels, promotion-related reserve state, and cancellation eligibility. The UI displayed the 72-hour rule and did not offer an inconsistent action for a state outside its eligibility contract. |
| Admin Events | PASS | The synthetic administrator loaded all six events, authoritative participant/reserve/cancelled counts, payment states, and the expected approve/pay/cancel actions. The participant query exposed only the operational DTO: id, name, email, phone, registration status, payment status, and creation time. Address, permits, tokens, admin notes, and profile data were absent. |
| Payment and promotion | PASS | In rollback-only production calls, `mark_event_registration_paid(uuid)` set the expected payment state and `confirm_event_reserve_promotion(text)` atomically moved one record from reserve to registered. Both mutations were rolled back. |
| Security regression | PASS | An ordinary authenticated user was redirected from direct `/admin/events` access to `/dashboard`. Owner-scoped RLS exposed only the user's own registration in the mixed participant fixture. Availability remained complete despite that RLS scope. No service-role credential was used by the browser, no participant PII appeared on public `/events`, and the two existing registration SELECT policies remained unchanged. |
| Existing flows | PASS | Registration, duplicate registration, reserve placement, promotion, cancellation, payment marking, sold-out protection, and authoritative availability all passed against current production contracts. No email-delivery endpoint was invoked because all mutating contract checks were deliberately rollback-only. |
| Cleanup | PASS | Fail-closed cleanup required exactly 2 Auth users, 2 profiles, 2 identities, 6 events, and 8 registrations for the run before deletion. The independent post-check returned `remaining_synthetic_fixture = 0` and `cleanup_confirmed = true`, including Auth users, profiles, events, registrations, and matching audit records. |

## Data and safety conclusion

No application code, production schema, migration, RLS, ACL, configuration, or
deployment was changed. Transactional checks left no mutations. The only
persistent production writes were the explicitly synthetic smoke fixture and
its exact cleanup; no real customer record was read for test assertions or
modified.

## Final result

```text
EVENTS-8A PRODUCTION SMOKE:
PASS

EVENTS-8A STATUS:
FULLY IMPLEMENTED / PROD PASS

STATUS CONSISTENCY:
PASS

CANCELLATION TIME CONSISTENCY:
PASS

PUBLIC AVAILABILITY:
PASS

MINIMAL PARTICIPANT DTO:
PASS
```

---

# EVENTS-8B PRODUCTION SMOKE

**Date:** 2026-09-06

**Production implementation:** `963ca72 — feat: add scalable event read contracts`

**Production migration:** `20260905190000_add_scalable_event_read_contracts.sql`

The smoke was executed against the deployed Vercel application and production
Supabase project. Database contract checks used a unique
`[TEST][EVENTS-8B][RUN-ID]` marker, four synthetic Auth users, 60 synthetic
events, and 176 synthetic registrations. The complete fixture lived inside one
transaction that ended with the controlled exception
`EVENTS8B_SMOKE_ALL_30_PASS_ROLLBACK`.

## Results

| Test | Result | Evidence |
|---|---|---|
| Migration and RPCs | PASS | Production migration history contains `20260905190000`. All four exact functions exist: `get_public_event_list_v2(text,text,integer,integer)`, `admin_list_events_v1(text,text,text,integer,integer)`, `admin_list_event_registrations_v1(uuid,text,text,integer,integer)`, and `get_my_event_registrations_v1(text,text,integer,integer)`. All four are `STABLE SECURITY DEFINER`, owned by `postgres`, with `search_path=pg_catalog, public, pg_temp`. |
| Public direct contract | PASS | A real anonymous PostgREST request to `get_public_event_list_v2` returned HTTP 200, `contract_version`, filters, pagination and items, with `page_size=50`. No customer, user, registration, email, phone, token or note field was present. |
| Public list and authoritative availability | PASS | The transactional production fixture returned 58 active future events as bounded pages `20 / 20 / 18`; page 4 was empty. Repeated page 1 was byte-equivalent. For the controlled capacity-200 event, `registered + approved = 80`, `reserve = 20`, cancelled registrations consumed no capacity, and `available_spots = 120` without a negative value. Anon and ordinary authenticated users received identical public aggregates. |
| Public ACL | PASS | `anon` and `authenticated` have `EXECUTE`; generic `PUBLIC` and `service_role` do not. The deployed browser bundle contains no service-role credential. |
| Admin event list | PASS | Production `/admin/events` rendered successfully. Search, all/upcoming/past/inactive scope, nearest/latest ordering and URL restoration worked. The controlled DB fixture returned 60 total rows, exactly one past row and one inactive row, with a bounded 20-row first page. Ordinary users received `not_allowed`; the existing employee/instructor behavior remained unchanged. |
| Admin participants | PASS | Production participant UI rendered status and all supported payment filters plus page-independent registered/reserve/cancelled totals. The fixture returned 121 rows in stable pages of at most 50; page 2 contained 50 rows. Status and payment filters were backend-owned. Summary was independent of page: registered/approved 80, reserve 20, cancelled 21, and paid active registrations 40. |
| Minimal participant DTO | PASS | The participant RPC returned only `id`, customer name/email/phone, registration status, payment status and creation time—the fields required by the existing operational screen. It returned no profile, address, permits, tokens, admin note or delivery internals. |
| My Events read contract | PASS | Production `/my-events` rendered the current account's rows and supported upcoming/history and status filters. URL reload and back/forward restored state. The fixture returned only the caller's 55 rows: 46 upcoming and 9 cancelled history rows. The API accepts no caller-supplied user ID; anonymous execution was denied. |
| Pagination boundaries | PASS | Page 1, later pages and the empty page beyond the last were deterministic and duplicate-free. Page 0 and requested page size 51 returned controlled `invalid_input`. Browser values such as a non-numeric page or unknown filter were normalized safely without runtime errors. |
| URL state | PASS | `/events`, `/admin/events`, and `/my-events` preserved search/filter state through reload and browser back/forward. Changing filters reset pagination. Query strings contained only search, scope, sort, status and page values—no PII. |
| Performance contract | PASS | Each deployed list bundle references its single bounded RPC. The admin/my-events bundles contain no direct `event_registrations` read and no `service_role`. Public aggregation was verified against page-only output. The three production indexes exist: `events_active_date_time_id_idx`, `event_registrations_user_created_id_idx`, and `event_registrations_event_payment_created_id_idx`. No disruptive production load test was run. |
| Authorization | PASS | Admin list and participant contracts denied ordinary users and anonymous callers. My-events remained owner-derived from `auth.uid()`. Instructor behavior was preserved exactly as the current deferred model requires. No table RLS or table ACL was expanded. |
| Frontend | PASS | `/events`, `/admin/events`, and `/my-events` loaded without 5xx or visible runtime failure. Search, filters, empty states, participant details, URL restoration and controlled invalid parameters worked. Public `/events` used `get_public_event_list_v2`; admin and my-events used the three corresponding bounded RPCs. |
| EVENTS-8A regression | PASS | Canonical status labels and the Europe/Warsaw 72-hour cancellation contract remain in the deployed client. Public capacity semantics, minimal participant DTO, registration/reserve/promotion/cancellation/payment call-sites and backend overbooking authority are unchanged. The EVENTS-8B migration is additive and does not redefine any EVENTS-8A mutation RPC. |
| Cleanup | PASS | The final transaction produced `EVENTS8B_SMOKE_ALL_30_PASS_ROLLBACK`. Independent read-only verification returned Auth users 0, profiles 0, events 0, event registrations 0, audit logs 0, `remaining_synthetic_fixture=0`, and `cleanup_confirmed=true`. |

## Harness diagnostics

Two preliminary harness attempts were rolled back before the successful run:
one exposed an ambiguous test variable named `user_id`, and one used an
incorrect expected `paid_count`. The correct production contract counts paid
rows only when their registration status occupies capacity, making the fixture
value 40 rather than 60. Neither diagnostic represented a product failure, and
neither left persistent data.

## Safety conclusion

No application code, production schema, migration, RLS, ACL, configuration or
deployment was changed. No event-management mutation, registration mutation,
email flow or real customer record was modified. Only this report was changed
locally.

## Final result

```text
EVENTS-8B PRODUCTION SMOKE:
PASS

EVENTS-8B STATUS:
FULLY IMPLEMENTED / PROD PASS

PUBLIC READ CONTRACT:
PASS

ADMIN READ CONTRACT:
PASS

PARTICIPANT PAGINATION:
PASS

MY EVENTS READ CONTRACT:
PASS

AUTHORIZATION:
PASS

EVENTS-8A REGRESSION:
PASS
```
