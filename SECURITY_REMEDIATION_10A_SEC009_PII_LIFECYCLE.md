# SECURITY REMEDIATION 10A — SEC-009 PII lifecycle

## Status

- SEC-ID: SEC-009
- Scope: self-service export, account deletion, business-data anonymization and audit pseudonymization
- Environment used for database verification: local Supabase only (`127.0.0.1`)
- Production changes: none

## Implemented

### Self-service export

- `GET /api/account/export` requires a valid Bearer session.
- The caller is derived from the verified JWT and `auth.uid()`; the endpoint and RPC accept no user identifier.
- `export_my_data_v1()` returns `export_version: 1`, `generated_at`, the caller's account/profile, reservations and event registrations.
- The response is a JSON attachment with `Cache-Control: no-store` and `X-Content-Type-Options: nosniff`.
- The allowlist excludes admin/verification notes, audit internals, password/security metadata, rate-limit state and all confirmation/check-in/promotion tokens.

### Self-service deletion

- `/account` exposes an explicit destructive action and requires the exact phrase `USUŃ KONTO`.
- `POST /api/account/delete` is the only deletion method. It accepts no target user ID.
- The route verifies the caller, executes `anonymize_my_account_v1()` with the caller JWT, and only after DB success calls Supabase Auth Admin `deleteUser()` server-side.
- The service-role key is confined to the Route Handler and is used only for the final Auth deletion.
- Loading/disabled states prevent duplicate UI submission. Success signs out and redirects to `/`.

### Deterministic anonymization

- Profile: removed completely after dependent business records are anonymized.
- Reservations: operational/history fields remain; owner link becomes `NULL`; contact snapshots become a deterministic collision-safe pseudonym; notes and `check_in_token` become `NULL`; `pii_anonymized_at` records DB time.
- Event registrations: operational relationship, statuses and required timestamps remain; owner/contact snapshots are anonymized; promotion tokens, claims and error state are cleared; `pii_anonymized_at` records DB time.
- Email delivery rows for the user and the user's rate-limit row are removed.
- The pseudonym is derived from the subject UUID and a domain separator. No reverse mapping is stored.

### Audit integrity

- Client ACL for `audit_logs` remains read-only according to SEC-007; no direct client audit insert/update/delete was added.
- The trusted SECURITY DEFINER lifecycle RPC pseudonymizes matching historical actor/target names, actor/profile UUID identifiers and direct PII inside nested JSON details.
- Safe operational audit facts remain.
- Exactly one pseudonymous `account_anonymized` audit is written by the database.
- A repeated call returns `already_anonymized` and writes no second audit.

## PII before/after

| Area | Before | After account deletion |
|---|---|---|
| Auth user | Login identity and Auth contact data | Deleted by server-side Auth Admin after DB success |
| Profile | Identity, contact/address, declarations, verification/admin notes | Profile row deleted |
| Reservation | Owner UUID, contact snapshots, notes, check-in token, operational history | Owner/contact PII/notes/token removed; operational history retained |
| Event registration | Owner UUID, contact snapshots, promotion token/claim state, operational history | Owner/contact PII/token/claim state removed; operational history retained |
| Audit | Actor/target identifiers and potentially direct PII in details | Deterministic pseudonym and redacted direct PII; history retained |
| Email/rate-limit state | User-linked technical metadata | User-linked records removed |

## Export contract

Top-level JSON keys are exact:

```text
export_version
generated_at
account
profile
reservations
event_registrations
```

The server validates this shape and recursively rejects known forbidden keys before returning the download. Invalid or malformed RPC output fails closed with a stable server error.

## Deletion contract and recovery

1. Valid authenticated caller and exact confirmation phrase are required.
2. DB anonymization executes atomically in one PostgreSQL transaction and is serialized per subject with an advisory transaction lock.
3. A DB error rolls back all anonymization and prevents Auth deletion.
4. DB success followed by Auth deletion failure returns HTTP 503 `auth_deletion_pending`; anonymized business PII is not restored.
5. A retry reuses the deterministic audit marker, returns `already_anonymized`, and retries only the Auth deletion.
6. An already absent Auth user is treated as idempotent success.

The DB and Auth Admin API cannot share one transaction. If an Auth deletion outage outlives the user's still-valid session, an operator-assisted retry may be required; the business database remains anonymized throughout.

## Authorization

- Anonymous export/delete: denied.
- User A export/delete: scoped only to `auth.uid()` User A.
- Supplying User B's ID: rejected by exact request-shape checks; neither RPC accepts a user ID.
- Admin/employee using the self-service endpoints: can act only on their own authenticated account.
- Anonymous and service-role clients have no EXECUTE on the lifecycle RPCs.

## Tests

- Focused Node/API contract tests: 12/12 PASS.
- Focused SEC-009 SQL contract: 28/28 PASS, explicit final `ROLLBACK`.
- All Node tests: 569/569 PASS.
- All Supabase DB tests: 11 files / 191 tests PASS.
- Local `supabase db reset --local --no-seed`: PASS; all migrations including `20260904120000` applied.
- TypeScript `tsc --noEmit`: PASS.
- Next.js 16.3.4 production build: PASS; both account routes are dynamic Route Handlers.
- Full ESLint: known baseline reproduced exactly — 14 errors / 6 warnings.
- New SEC-009 ESLint regressions: 0. New route/helper/test files pass focused lint; the only focused error is the pre-existing `loadUser` ordering finding in `app/account/page.tsx`.
- `git diff --check`: PASS for tracked changes; independent `--no-index --check` produced no findings for new files.
- Secret/credential scan of the SEC-009 implementation: no embedded token, connection string, Supabase URL, password or credential value found.
- `npm audit --omit=dev`: the live registry endpoint timed out; the immediate offline audit against the available advisory cache reported `found 0 vulnerabilities`. No dependency files were changed by this remediation.

## Compatibility matrix

| Application | Database | Result | Reason |
|---|---|---|---|
| Old | Old | SAFE | Existing behavior unchanged. |
| Old | New | SAFE | Migration is additive/relaxing for retained history; existing RPC ACL and application flows are unchanged. |
| New | Old | UNSAFE for new lifecycle actions | New export/anonymization RPCs do not exist, so the new endpoints fail closed. |
| New | New | SAFE | Full lifecycle contract is available. |

Deployment recommendation: **DB FIRST**, verify migration/RPC ACL and then deploy the application. Do not deploy the new application first.

## SECURITY REMEDIATION 10B — future retention

No cron, schedule or unapproved time period is implemented in 10A. A separate business/legal decision is still required for:

- expired tokens,
- email delivery metadata,
- rate-limit metadata,
- cancelled records,
- audit retention,
- financial retention.

## Verdict

**SEC-009 CORE LIFECYCLE FULLY REMEDIATED LOCALLY**

The core behavior, security boundaries, DB rollback, idempotency and application build are verified locally. The live npm advisory endpoint timeout is recorded as an external verification limitation; the cached offline audit is clean and SEC-009 changes no dependencies.
