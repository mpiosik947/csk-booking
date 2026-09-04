# SECURITY REMEDIATION 14 — SEC-013 SAFE ERROR HANDLING

## Status

- SEC-ID: SEC-013
- Original severity: LOW
- Scope: application-only error presentation and diagnostic logging
- Baseline: `152a0f2 — docs: record SEC-015 production smoke pass`
- Database, SQL, RLS, ACL and migrations: unchanged

## Before

The current-code inventory confirmed production-relevant instances in which:

- selected Auth, account and admin screens interpolated Supabase `error.message` directly into Polish UI messages;
- account and event screens could display an arbitrary `error` or `message` returned by an API response;
- the event reserve confirmation API forwarded the `message` supplied by its database RPC;
- several browser components logged complete Supabase errors or malformed response objects, including fields such as `details` and `hint`;
- the event reserve promotion server logger included internal event and registration identifiers.

The route-handler review did not find an active response that serialized a thrown error, stack trace, raw Postgres `details`/`hint`, provider response body, JWT, service-role key or request body. Existing API failures otherwise used controlled codes and fixed response text.

## Inventory classification

### A. Server log only

- API routes log fixed operation names and, where useful, a database error code.
- Confirmation delivery classifies provider errors internally but does not return or log the provider message.
- Event reserve promotion now logs only the stable stage plus a bounded technical code/status; event and registration IDs were removed.

### B. Client/UI response

Raw Supabase/Auth/API text was removed from login, registration, password recovery, password reset, account, customer event history, admin dashboard, reports, reservations and check-in surfaces. Unknown failures now produce fixed Polish messages.

### C. API response

The reserve-place confirmation route now maps its allowlisted RPC result code to application-owned text. It no longer returns the RPC-provided message. Existing route handlers continue to return stable codes such as `unauthorized`, `not_allowed`, `not_found`, `rate_limited` and `internal_error` with controlled text.

### D. Development only

Node's `MODULE_TYPELESS_PACKAGE_JSON` warnings and the Next.js middleware deprecation warning are build/tooling diagnostics. They do not include request data or secrets and are outside SEC-013.

### E. Production relevant

The remediated browser logs and UI/API response paths execute in production. All were changed to controlled presentation or minimal structured diagnostics.

## Affected routes and components

- `/login`, `/register`, `/forgot-password`, `/reset-password`, `/account`
- `/events`, `/events/confirm/[token]`, `/my-events`, `/my-reservations`
- `/admin`, `/admin/reports`, `/admin/reservations`, `/admin/check-in`, `/admin/users`
- `POST /api/confirm-event-reserve-promotion`
- reservation and event-registration client action helpers
- event reserve promotion server delivery helper

## Raw exposure removed

- No remediated UI interpolates Supabase `error.message`.
- Account export/deletion and event cancellation no longer display an arbitrary API `error`/`message` body.
- The confirmation form ignores response `message` and `error` fields and maps only a known `code`.
- The confirmation API ignores the RPC message and maps the validated RPC code itself.
- Browser logging no longer receives complete error/data objects, Postgres `details`/`hint`, payloads, tokens or PII.
- Server promotion logging no longer contains event or registration IDs.

No runtime logging of `check_in_token`, confirmation/reserve token values, access/refresh tokens, Authorization headers, JWTs, service-role keys, email addresses or phone numbers was found.

## Safe response model

- Known business/auth codes are mapped to controlled Polish messages.
- Unknown Auth, provider, RPC and API failures use a generic operation-specific message.
- HTTP authorization and business semantics are unchanged.
- Database/provider text is used only in two non-output classifiers where no structured discriminator exists: cancellation-window classification and retryable email-provider classification. The text is neither rendered nor logged.

## Logging changes

`reportClientError()` accepts an operation label and optionally emits only a code that matches a bounded alphanumeric/underscore allowlist. It never serializes the error object, message, details, hint, request body or token. Server-side promotion diagnostics retain only stage, bounded code/name and numeric HTTP status.

## Tests

Focused SEC-013 coverage verifies:

- raw Supabase/provider message, details, hint and token-like data never become UI text;
- unknown exceptions fall back to generic messages;
- known Auth and business codes keep controlled Polish diagnostics;
- client logging emits only an operation and safe bounded code;
- malformed or user-controlled codes are omitted;
- remediated components contain no direct raw-error rendering or raw-object console calls;
- event confirmation API maps RPC codes rather than forwarding RPC messages;
- event promotion client code does not forward an API error body.

Validation results:

- Focused SEC-013 and confirmation tests: 17/17 PASS
- All project Node tests: 606/606 PASS
- TypeScript `tsc --noEmit`: PASS
- Next.js production build: PASS
- `npm audit --omit=dev`: PASS, 0 vulnerabilities
- Full ESLint: KNOWN ESLINT BASELINE — 14 errors / 6 warnings
- NEW SECURITY REMEDIATION ESLINT REGRESSIONS: 0
- Database tests: not required; there are no SQL or database changes

## Production smoke plan

After an app-only deployment, use synthetic or invalid inputs and verify:

1. unauthenticated and invalid requests return their controlled 4xx contract without provider/DB text;
2. a controlled missing-resource case returns the known `not_found` presentation;
3. a safe synthetic provider-failure path returns a generic failure and logs only operation/stage plus safe code/status;
4. browser UI and console contain no raw message, details, hint, token, PII or stack trace;
5. normal login, registration, account, reservation, event and admin flows retain their current successful behavior.

Do not induce destructive failures and do not use real customer data.

## Residual

- A small number of server/client helpers inspect provider or database message text solely to classify a known condition when the upstream contract lacks a distinct code. The raw text is never returned, rendered or logged.
- Existing code-only server logs remain because they are minimal diagnostics and contain no secrets, PII or request payloads.
- The known ESLint baseline and Next.js middleware deprecation warning are unrelated to SEC-013.

## Deployment

APP ONLY. No migration or production database change is required.

## Verdict

**SEC-013 FULLY REMEDIATED**
