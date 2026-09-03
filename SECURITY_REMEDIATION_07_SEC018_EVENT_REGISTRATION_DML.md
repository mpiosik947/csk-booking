# SECURITY REMEDIATION 07 — SEC-018

SEC-ID: SEC-018
Original severity: MEDIUM

## Before

`public.event_registrations` has RLS enabled and is owned by `postgres`. It has 18 columns, including customer contact data, status and payment fields, promotion token/claim state, attempt counters and timestamps.

Before this remediation, `authenticated` had table-level `SELECT`, `INSERT` and `DELETE`. Three policies allowed `admin` and `pracownik` to insert and delete complete rows and also exposed an UPDATE policy. The earlier ACL hardening had already removed table-level UPDATE (including the former column-level payment grant), so the update policy was ineffective, but the browser payment action still attempted that now-broken direct UPDATE.

The two existing SELECT policies are intentionally unchanged:

- staff read: `is_admin_or_staff()`;
- own read: `user_id = auth.uid()`.

This remediation does not change the SEC-008 instructor read model.

## Direct DML inventory

| Operation | Role | Method before | Direct DML | Controlled RPC before |
|---|---|---|---:|---:|
| Register for event | user | `register_for_event(uuid, boolean)` | no | yes |
| Approve registration | admin / employee | `approve_event_registration(uuid)` | no | yes |
| Cancel registration | owner / instructor-owner / admin / employee | application endpoint and `cancel_event_registration(uuid)` | no | yes |
| Prepare/complete reserve promotion | service workflow | dedicated prepare/complete RPCs | no | yes |
| Confirm reserve promotion | authenticated owner | `confirm_event_reserve_promotion(text)` | no | yes |
| Mark event payment paid on site | admin / employee | browser `.update({ payment_status })` | yes | no |
| Insert arbitrary registration | admin / employee | unused by current application | possible | not a supported UI operation |
| Delete registration | admin / employee | unused by current application | possible | not a supported UI operation |

The application contains no active direct INSERT, DELETE or UPSERT call site for `event_registrations`. Server-side occurrences outside the admin page are reads used by controlled confirmation and delivery workflows.

## Threat model

Before the change, admin/employee direct INSERT could forge every supplied field: `user_id`, `event_id`, customer PII, `registration_status`, `payment_status`, promotion token/claim fields, attempt state, timestamps and `created_at` — **CONFIRMED**. Direct DELETE of any row visible through the staff policy was also **CONFIRMED**. Direct UPDATE of those fields was **DENIED** by the already-hardened SQL ACL even though a stale UPDATE policy remained. `anon` and ordinary users could not obtain staff-policy access.

## Controlled RPC after

The payment action now uses:

`public.mark_event_registration_paid(p_registration_id uuid) returns jsonb`

Properties:

- `LANGUAGE plpgsql`, `VOLATILE`, `SECURITY DEFINER`;
- owner `postgres`;
- `search_path = pg_catalog, public, pg_temp`;
- `EXECUTE` only for `authenticated` among application roles;
- role derived from `auth.uid()` and `public.profiles`;
- only `admin` and `pracownik` are allowed;
- locks the event before the registration, matching the established lock order;
- accepts only `registration_id` and sets the fixed target value `paid_on_site`;
- updates only `payment_status`;
- returns a controlled JSON result and supports idempotent `no_change`.

The browser has no direct-table fallback. It validates the RPC response, registration/event identity, result code, changed flag and fixed resulting payment status before updating local UI state. Raw database messages are not shown to users.

## RLS/ACL after

- `authenticated`: SELECT only;
- `anon`: no table privileges;
- `PUBLIC`: no table privileges;
- `service_role`: existing full table ACL unchanged;
- no INSERT, UPDATE, DELETE or ALL policy remains;
- both existing SELECT policies remain unchanged;
- client roles have no TRUNCATE, REFERENCES, TRIGGER or MAINTAIN.

## Field integrity

The payment RPC exposes no parameters for `user_id`, `event_id`, statuses other than the fixed payment transition, promotion state, tokens, PII or timestamps. Direct field-tampering UPDATE and arbitrary INSERT are denied by SQL ACL before RLS can grant access.

Existing status, ownership, capacity and reserve-token rules remain in their dedicated RPCs. No generic status writer or hard-delete RPC was introduced.

## Authorization

Authorization is fail-closed and based on the authenticated database context. Browser-supplied role, actor ID or admin flags are not accepted. Admin and employee can execute the payment operation; ordinary user and instructor receive controlled `not_allowed`; anon has no EXECUTE privilege.

## Audit integration

A successful payment mutation inserts exactly one trusted `event_registration_payment_marked_by_staff` audit from the SECURITY DEFINER function. Actor ID comes from `auth.uid()`, the role comes from the database, and the timestamp comes from `transaction_timestamp()`.

Audit details contain only registration ID, event ID, previous/new payment status, operator role and change time. They contain no customer PII or token. `no_change` returns before the INSERT and creates no duplicate audit. SEC-007 direct audit mutation restrictions remain unchanged.

## Tests

- Focused SEC-018 SQL: 27/27 PASS, transaction ended with ROLLBACK.
- Full Supabase DB suite: 10 files, 163 tests, PASS.
- Focused admin Events Node tests: PASS.
- All Node tests: 542/542 PASS.
- TypeScript `tsc --noEmit`: PASS.
- Next.js production build (16.3.4): PASS.
- `npm audit --omit=dev`: 0 vulnerabilities.
- Full ESLint: known baseline 14 errors / 6 warnings; new SEC-018 ESLint regressions: 0.
- `git diff --check`: PASS.

Focused SQL coverage includes exact ACL/RLS/RPC construction, direct INSERT/UPDATE/DELETE denial for ordinary user, employee and admin, anon denial, minimal one-argument RPC shape, admin/employee success, user/instructor denial, idempotency, audit integrity and regression of the established approve/cancel RPCs.

## Compatibility matrix

| Application | Database | Result | Reason |
|---|---|---|---|
| OLD | OLD | UNSAFE for payment action | The old browser uses direct UPDATE, already blocked by the prior SEC-002 table ACL. Other established RPC flows continue to work. |
| OLD | NEW | UNSAFE for payment action, no new runtime break for used flows | The old payment action remains blocked; current code has no runtime direct INSERT/DELETE call site. |
| NEW | OLD | UNSAFE | The new browser requires `mark_event_registration_paid`, which is absent. |
| NEW | NEW | SAFE | Payment and all status operations use controlled RPCs; direct DML is denied. |

## Deployment recommendation

**DB FIRST**, followed immediately by the application deployment.

The new application cannot precede the database because the new RPC would be missing. Applying the database first adds the RPC and removes direct INSERT/DELETE paths that the current application does not use. The old payment action is already nonfunctional under the current production-style ACL, so this ordering does not introduce that incompatibility, but the interval should still be kept short and payment UI smoke-tested after application deployment.

## Regression risk

MEDIUM. The migration changes table ACL/RLS policy inventory and adds an audited writer, while the frontend change is narrowly limited to the existing payment action. The risk is bounded by fail-closed preflight/postflight checks and full local SQL/application regression.

## Verdict

**SEC-018 FULLY REMEDIATED**

No production database operation, deployment, commit or push was performed.
