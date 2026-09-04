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
