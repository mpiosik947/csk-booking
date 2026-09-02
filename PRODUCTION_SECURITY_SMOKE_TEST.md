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
