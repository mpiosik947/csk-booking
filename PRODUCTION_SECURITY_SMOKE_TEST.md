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

Date: 2026-09-03
Production commit under test: `4a1182f`
Run marker: `[TEST][SEC-006][d09778ff]`
Recipient: controlled, masked test mailbox

The run was stopped fail-closed after the second flow returned HTTP 500. Exactly one of the authorized five messages was sent; no further send was attempted after the failure.

| TEST | RESULT | EVIDENCE |
|---|---|---|
| Reservation confirmation | PASS | HTTP 200 and one message delivered to the controlled mailbox. |
| Reservation cancellation | FAIL | Production endpoint returned HTTP 500. No cancellation message was sent. |
| Event registration confirmation | NOT RUN | Stopped after the first failure. |
| Event reserve promotion | NOT RUN | Stopped after the first failure. |
| Confirmed reserve place | NOT RUN | Stopped after the first failure. |
| HTML payloads in delivered message | PASS | `<script>`, `<img ... onerror=...>` and `<b>Injected</b>` were displayed literally as text; the message body contained zero injected script nodes, zero injected `src=x` images and zero injected bold nodes. |
| Special characters | PASS | `&`, `<`, `>`, double quote and apostrophe rendered as their intended text values. |
| Double escaping | PASS | The mailbox displayed literal payload text, not visible HTML entities such as `&lt;script&gt;`. |
| URL safety in delivered message | PARTIAL | Two expected HTTPS template links were present and no `javascript:` or `data:` href existed. The dedicated unsafe-URL event fixture was not delivered because the run stopped. |
| Plain-text MIME part | NOT VERIFIED | The run stopped before all five flows could be inspected; no claim of complete production plain-text coverage is made. |
| Template structure | PASS | The legitimate heading, paragraphs, labels and HTTPS action links rendered normally. |
| Secret/error exposure | PASS FOR DELIVERED MESSAGE | No JWT, service-role key, raw database error or provider error was visible. Functional scoped link values are intentionally omitted from this report. |

## Failure and stop condition

```text
reservation_confirmation: HTTP 200
reservation_cancellation: HTTP 500
messages sent: 1/5
additional sends after failure: 0
PRODUCTION ERRORS: FOUND
```

No application fix, retry, migration, configuration change or additional remediation was attempted.

## Cleanup

Before rate-limit cleanup, a read-only query identified exactly one paired user/IP timestamp for this run:

```text
user rate-limit timestamps: 1
IP rate-limit timestamps: 1
timestamps attributable to this run: 1
```

The cleanup removed the single synthetic user rate-limit row and exactly the single test timestamp from the paired IP row. Because that IP row contained no other timestamp, its now-empty row was deleted. No earlier or later real timestamp was changed.

The failed harness left one marked synthetic Auth user/profile pair and one marked synthetic lane. Each was independently identified by the exact run marker; dependency checks returned zero before their deletion. The Auth profile was removed through the existing user-delete cascade.

Independent post-cleanup queries returned:

```text
synthetic auth users: 0
synthetic profiles: 0
synthetic reservations: 0
synthetic events: 0
synthetic event registrations: 0
synthetic audit logs: 0
synthetic email deliveries: 0
synthetic lanes: 0
synthetic pricing rows: 0
synthetic rate-limit timestamps: 0
remaining synthetic fixture: 0
```

Cleanup was limited to `[TEST][SEC-006][d09778ff]`. No real customer data or unrelated rate-limit timestamp was modified.

```text
SEC-006 PRODUCTION SMOKE: FAIL

SEC-006 STATUS:
PARTIALLY REMEDIATED
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
