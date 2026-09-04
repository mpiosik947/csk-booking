# CSK Booking — Clean-Room Remediation 01

## CLEAN-004 — Admin direct hard-delete of reservations

**Date:** 4 September 2026

**Branch:** `main`

**Base HEAD:** `11002b7 docs: add clean-room security audit v2`

**Scope:** PostgreSQL ACL/RLS hardening and contract tests only

## Before

`public.reservations` was owned by `postgres` and had RLS enabled, but the table ACL granted `authenticated` both `SELECT` and `DELETE`.

| Grantee | Effective table ACL before |
|---|---|
| PUBLIC | none |
| anon | none |
| authenticated | SELECT, DELETE |
| service_role | SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN |

The active policies were:

| Policy | Command | Role | Expression |
|---|---|---|---|
| Admins and staff can view all reservations | SELECT | authenticated | `is_admin_or_employee()` |
| Users can view own reservations | SELECT | authenticated | `user_id = auth.uid()` |
| Admins can delete reservations | DELETE | authenticated | `is_admin()` |

Therefore all authenticated users inherited the SQL DELETE privilege, while RLS made the real direct-delete matrix:

| Role | Direct DELETE before | Controlled RPC | Audit | Business rules |
|---|---|---|---|---|
| anon | DENY | unavailable | no mutation | n/a |
| user | DENY by RLS | own reservation via `cancel_reservation` | yes when changed | ownership, confirmed/planned state, at least 12 hours |
| instructor | DENY by RLS | DENY | no mutation | role denied |
| employee / `pracownik` | DENY by RLS | global cancellation via `cancel_reservation` | yes when changed | row lock and operational state |
| admin | **ALLOW hard-delete** | global cancellation via `cancel_reservation` | only controlled cancellation was audited | direct DELETE bypassed all lifecycle checks |

## Direct delete path

No active runtime `.from("reservations").delete(...)` call was found. User, admin and check-in/reservation screens call `cancel_reservation(uuid)`. Read paths use SELECT only.

The vulnerable path was therefore a direct authenticated PostgREST table DELETE using an administrator JWT. It did not require or pass through application UI.

`public.reservations` has no DELETE trigger and no foreign key from another table that blocks deletion. Audit targets and e-mail-delivery `record_id` values are loose identifiers, not reservation FKs. Consequently the old path could physically delete a confirmed, paid, checked-in, completed or historical record; any older audit rows could remain detached, while reports and calendars would silently lose the reservation.

## Why hard-delete was unnecessary

The application has no documented reservation maintenance or cleanup flow requiring physical DELETE. The intended model preserves operational history:

1. `cancel_reservation(uuid)` locks the row.
2. Identity, role and user ownership are derived from `auth.uid()` and `public.profiles`.
3. It validates status, attendance state and the user cancellation window.
4. It changes status to `cancelled_by_user` or `cancelled_by_admin`.
5. It records `reservation_cancelled_by_user` or `reservation_cancelled_by_staff` in `audit_logs`.
6. A repeated cancellation is a no-change result and creates no duplicate audit.

SEC-009 account deletion also does not require reservation DELETE. `anonymize_my_account_v1()` updates reservation PII and ownership fields, invalidates the check-in token and retains the operational record.

## RLS / ACL changes

Migration: `20260904200000_harden_reservation_direct_delete.sql`

The migration is fail-closed. Its preflight verifies:

- table existence, owner `postgres` and RLS enabled;
- the exact two SELECT policies and one admin DELETE policy;
- the exact current client ACL shape;
- no anon/PUBLIC table grants;
- the complete existing `service_role` baseline;
- presence of `cancel_reservation(uuid)` and `anonymize_my_account_v1()`.

The mutation is deliberately minimal:

```sql
drop policy "Admins can delete reservations" on public.reservations;
revoke delete on table public.reservations from authenticated;
```

Postflight requires exactly two unchanged SELECT policies, no INSERT/UPDATE/DELETE/ALL policies, authenticated SELECT-only access, no anon/PUBLIC grants and unchanged full `service_role` access.

After migration:

| Role | Direct DELETE | Direct TRUNCATE |
|---|---|---|
| anon | DENY | DENY |
| user | DENY | DENY |
| instructor | DENY | DENY |
| employee / `pracownik` | DENY | DENY |
| admin | DENY | DENY |
| service_role | preserved baseline | preserved baseline |

No RPC, function definition, application code or other table policy was changed.

## Business flows preserved

Focused SQL execution confirmed:

- user can cancel an owned future reservation through `cancel_reservation`;
- admin can cancel a paid reservation through the controlled RPC without deleting it;
- employee can cancel through the same controlled RPC;
- cancelled rows remain present;
- repeated cancellation returns no-change and adds no second audit;
- paid and checked-in history cannot be hard-deleted by an administrator;
- SEC-009 anonymization still succeeds and leaves the anonymized reservation row present;
- all five synthetic reservation-history rows remained present before the test rollback.

The unchanged Node suite covers the application reservation, check-in, reports and calendar call sites. No application call site depended on direct DELETE.

## Audit integrity

Successful controlled cancellations continue to create exactly one audit with the actor derived from `auth.uid()`. The focused test verified both user and staff audit actions. No-change cancellation creates no duplicate. Since application roles no longer have table DELETE, they cannot erase a reservation while bypassing the lifecycle audit.

The migration does not add direct `audit_logs` writes or change SEC-007 protections.

## Tests

### Focused CLEAN-004

`supabase/tests/20260904200000_harden_reservation_direct_delete_test.sql`

- **24/24 PASS**
- `ON_ERROR_STOP` enabled
- exit code 0
- one transaction with final `ROLLBACK`
- synthetic UUIDs/e-mails unique per run
- direct DELETE DENY verified for anon, user, instructor, employee and admin
- application-role TRUNCATE DENY verified
- positive cancellation and SEC-009 lifecycle checks passed

### Full regression

| Check | Result |
|---|---|
| Full Supabase DB tests | PASS — 13 files, 239 tests |
| All Node tests | PASS — 611/611 |
| `npx.cmd tsc --noEmit` | PASS |
| `npm.cmd run build` | PASS — Next.js 16.3.4, 37 routes/pages |
| `npm.cmd audit --omit=dev` | PASS — 0 vulnerabilities |
| `npx.cmd eslint .` | KNOWN BASELINE — 14 errors, 6 warnings; new remediation regressions: 0 |
| `git diff --check` | PASS |

The existing SEC-002B ACL contract was updated to the new cumulative baseline: reservations are SELECT-only for authenticated, and its negative DELETE test now requires SQLSTATE `42501` rather than a silent zero-row RLS result.

## Compatibility

| Combination | Functional compatibility | Security state | Reason |
|---|---|---|---|
| OLD APP + OLD DB | SAFE functionally | vulnerable | Existing application uses cancellation RPC, but admin direct hard-delete remains possible. |
| OLD APP + NEW DB | **SAFE** | remediated | No old runtime call site performs direct reservation DELETE; all cancellations use RPC. |
| NEW APP + OLD DB | SAFE functionally | not remediated | No application code changed, but the old database still grants the vulnerable path. |
| NEW APP + NEW DB | **SAFE** | remediated | Controlled flows work and all application-role direct DELETE is denied. |

## Deployment recommendation

**DB FIRST is safe.** This is a database-only remediation. A production rollout should first verify that only migration `20260904200000` is pending, apply that migration, then confirm the exact ACL/policy postflight and smoke-test controlled user/admin/employee cancellation with synthetic data. No coordinated application deployment is required.

Rollback should be treated as security-sensitive: restoring authenticated DELETE and the admin policy would reopen CLEAN-004. Prefer forward remediation of any unexpected compatibility issue rather than silently restoring the bypass.

## Changed files

- `supabase/migrations/20260904200000_harden_reservation_direct_delete.sql`
- `supabase/tests/20260904200000_harden_reservation_direct_delete_test.sql`
- `supabase/tests/20260902120000_harden_public_table_sequence_acl_test.sql`
- `SECURITY_CLEAN_REMEDIATION_01_CLEAN004_RESERVATION_DELETE.md`

No application code, CLEAN-005 logic, tenant model, instructor model, retention policy or production resource was changed.

## Verdict

**CLEAN-004 FULLY REMEDIATED**

The local migration removes the only application-role hard-delete policy and DELETE grant from `public.reservations`, preserves controlled lifecycle RPCs and service-role baseline, and passes focused plus full regression testing. Production remains unchanged until an explicitly authorized deployment.
