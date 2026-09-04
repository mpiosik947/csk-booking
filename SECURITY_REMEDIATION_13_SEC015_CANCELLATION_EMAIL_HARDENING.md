# SECURITY REMEDIATION 13 — SEC-015

## Scope

- SEC-ID: `SEC-015`
- Original severity: `LOW`
- Component: `POST /api/send-reservation-cancellation`
- Baseline: `e10e377 — docs: record SEC-012 production smoke pass`
- Production changes performed: none

## Before

The cancellation itself was already a controlled database mutation. The user,
admin, or employee called the existing cancellation RPC, and that RPC changed
the reservation state and wrote the trusted `reservation_cancelled_by_user` or
`reservation_cancelled_by_staff` audit. Only after that mutation did the client
call `POST /api/send-reservation-cancellation`.

The email endpoint correctly required a verified user, accepted only a
`reservationId`, checked owner or `admin`/`pracownik`, required a cancelled
reservation, derived the recipient and content from trusted reservation/profile
reads, and escaped dynamic HTML. It nevertheless called Resend directly. It had
no delivery claim, no persistent sent marker, no provider idempotency key, no
attempt bound, and no user/IP rate limit.

| Step | Component | Authorization | Idempotent | Rate-limited | Trusted |
|---|---|---|---|---|---|
| Cancel reservation | controlled cancellation RPC | caller JWT; owner or permitted staff | business mutation is controlled | not an email operation | yes; DB role and ownership |
| Write cancellation audit | cancellation RPC | inherited trusted RPC context | one audit for the state change | not applicable | yes; DB actor/time |
| Request cancellation email | cancellation API route | verified caller JWT; owner or admin/employee | no | no | recipient and content were trusted |
| Send provider message | Resend call | server API key | no provider idempotency key | no | server-only, but repeatable |
| Complete delivery | absent | absent | no sent state | no | absent |

## Confirmed abuse path

An authenticated owner could repeatedly call the email endpoint with the UUID
of their already-cancelled reservation. Each request passed the unchanged state
check and reached Resend again. Parallel requests could also all send because
there was no atomic lease. The same was possible through the existing staff
path. This could generate duplicate messages and consume provider quota. It did
not permit choosing an arbitrary recipient or exposing another user's data, but
it was a confirmed bounded-abuse and availability/cost issue.

## After

The existing confirmation-email delivery system now accepts the closed message
type `reservation_cancellation`. The existing endpoint uses the same user/IP
limiter and the same prepare/send/complete orchestration as reservation and
event-registration confirmations.

The browser contract remains exactly one UUID field. Business reads still use
the caller's JWT. A service-role client exists only server-side and is used only
for the already-hardened rate-limit and completion RPCs; it is never used to
read reservations, profiles, or lane data.

## Claim model

1. `prepare_confirmation_email('reservation_cancellation', reservation_id)`
   locks and validates the reservation and caller.
2. The first valid request receives a five-minute opaque claim and a stable
   provider idempotency key based on the technical delivery UUID.
3. A concurrent request receives `in_progress` and does not call the provider.
4. Provider success is completed through `complete_confirmation_email` and
   stores the bounded provider message id.
5. A repeat after success receives `already_sent` and does not call the
   provider.
6. Provider failure clears the lease through the existing safe completion path;
   at most three attempts are allowed in the 24-hour attempt window.
7. Completion uncertainty does not trigger an automatic resend loop. Resend's
   stable idempotency key also protects a later deliberate retry from duplicating
   a provider-accepted message.

`email_deliveries` stores only technical state (`record_id`, user UUID, claim,
timestamps, bounded error code, provider id). It does not store recipient email,
HTML, plain text, JWT, or tokens.

## Rate-limit model

The endpoint reuses `check_confirmation_email_rate_limit`:

- 10 requests per authenticated user per sliding 10 minutes;
- 30 requests per HMAC-SHA256 IP scope per sliding 10 minutes;
- raw IP is never stored;
- a rate-limit response is `429` with a bounded `Retry-After` and
  `Cache-Control: no-store`;
- missing secret, invalid production IP, RPC error, thrown error, or malformed
  limiter response fails closed as a stable `internal_error`;
- no limiter credential or raw error is returned to the client.

## Authorization

- Missing or invalid authentication is denied.
- The reservation owner may prepare cancellation delivery for their own
  cancelled reservation.
- Existing staff access is preserved for exactly `admin` and `pracownik`.
- An ordinary user or instructor cannot claim a foreign reservation; the RPC
  returns the non-disclosing `not_found` result.
- Anonymous users have no `EXECUTE` on prepare.
- Ownership and staff role come from `auth.uid()` and `public.profiles`, not
  request fields.
- Existing `SECURITY DEFINER`, owner `postgres`, volatility, return type,
  search path, and function ACL are retained.

## Recipient integrity and SEC-006

The request accepts neither email, customer name, subject, HTML, nor text.
Recipient and message data continue to come from the authorized reservation,
the reservation-scoped customer-profile reader, or the owner's authenticated
profile/session fallback. Staff never become the recipient merely because they
triggered the notification. All dynamic HTML remains passed through
`escapeHtml`; the plain-text body remains plain text. The cancellation template
contains no dynamic link.

## Audit and side effects

The trusted cancellation RPC remains the sole creator of the business audit.
The email route does not insert into `audit_logs`. `ready`, `in_progress`,
provider failure, `already_sent`, and retry/no-change states therefore do not
create false cancellation audits. SEC-007 semantics are unchanged.

## Tests

| Check | Result |
|---|---|
| Focused cancellation/delivery/rate-limit/HTML Node tests | PASS — 66/66 |
| Focused SEC-015 DB contract | PASS — 24/24, transaction rollback |
| All Supabase DB tests | PASS — 215/215 across 12 files |
| All Node tests | PASS — 596/596 |
| TypeScript `tsc --noEmit` | PASS |
| Next.js production build | PASS |
| `npm audit --omit=dev` | PASS — 0 vulnerabilities |
| ESLint on changed application/test files | PASS — 0 findings |
| Full ESLint | KNOWN ESLINT BASELINE — 14 errors, 6 warnings |
| New SEC-015 ESLint regressions | 0 |
| `git diff --check` | PASS |

The focused tests cover authenticated owner success, foreign user denial,
instructor denial, anonymous ACL denial, employee/admin access, trusted
recipient identity, first claim, concurrent `in_progress`, completion,
`already_sent`, provider failure, three-attempt limit, `429` and `Retry-After`,
HMAC IP handling, malformed contracts, stable safe responses, HTML escaping,
plain text, and absence of email/token/content columns in delivery state.

## Compatibility

| Combination | Result | Reason |
|---|---|---|
| Old application + old database | SAFE | Existing behavior, with the original SEC-015 residual. |
| Old application + new database | SAFE | Migration is additive for the old app; existing confirmation types and route behavior remain valid. |
| New application + old database | UNSAFE FOR DELIVERY / FAIL-CLOSED | Old prepare RPC rejects `reservation_cancellation`; cancellation itself remains complete, but the email returns a controlled error and is not sent. |
| New application + new database | SAFE | Limiter, claim, provider idempotency, and completion contracts align. |

## Deployment recommendation

Use **DB FIRST**:

1. Verify migration history and take the normal pre-deployment database safety
   checks.
2. Apply only
   `20260904180000_harden_reservation_cancellation_email_delivery.sql`.
3. Verify the new message-type constraint, prepare definition/properties/ACL,
   and an empty/no-unexpected cancellation delivery baseline.
4. Deploy the application.
5. Smoke-test one synthetic owner cancellation, one repeat (`already_sent`),
   one unauthorized request, and the limiter; clean up only synthetic data.

If the database migration succeeds but the application deploy fails, the old
application remains operational. If the new application is deployed before the
migration, cancellation state changes remain valid but cancellation emails fail
closed, which is why APP FIRST is not recommended.

## Files changed

- `app/api/send-reservation-cancellation/route.ts`
- `app/api/send-reservation-cancellation/route.test.mjs`
- `lib/server/confirmation-email-delivery.test.mjs`
- `lib/server/confirmation-email-rate-limit.test.mjs`
- `supabase/migrations/20260904180000_harden_reservation_cancellation_email_delivery.sql`
- `supabase/tests/20260904180000_harden_reservation_cancellation_email_delivery_test.sql`
- `SECURITY_REMEDIATION_13_SEC015_CANCELLATION_EMAIL_HARDENING.md`

No SEC-013, SEC-014, SEC-016, SEC-008, SEC-009 10B, tenant model, or unrelated
business logic was changed. No production database operation, deployment,
commit, or push was performed.

## Verdict

`SEC-015 FULLY REMEDIATED`
