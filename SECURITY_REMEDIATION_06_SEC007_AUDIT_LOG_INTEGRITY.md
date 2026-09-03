# SECURITY REMEDIATION 06 — SEC-007 Audit Log Integrity

## Status

- SEC-ID: SEC-007
- Original severity: MEDIUM
- Scope: PostgreSQL ACL/RLS and database contract tests
- Environment used for validation: local Supabase only (`127.0.0.1`)
- Production changes: none

## Before

`public.audit_logs` was owned by `postgres` and had RLS enabled, but the client
role `authenticated` had direct `INSERT`. The policy `Admins can insert audit
logs` used `is_admin_or_staff()`, so an authenticated `admin`, `pracownik`, or
`instruktor` could submit caller-controlled values including `actor_user_id`,
`actor_name`, `actor_role`, `action`, `target_*`, and `details`.

Direct `UPDATE`, `DELETE`, and `TRUNCATE` were already unavailable to client
roles. That did not protect integrity because a forged row could still be
appended and appear indistinguishable from a trusted audit entry.

### Previous access matrix

| Role | SELECT | INSERT | UPDATE | DELETE | TRUNCATE |
|---|---:|---:|---:|---:|---:|
| PUBLIC | deny | deny | deny | deny | deny |
| anon | deny | deny | deny | deny | deny |
| user | own policy does not apply; no rows | deny by RLS | deny | deny | deny |
| instruktor | deny by SELECT RLS | allow | deny | deny | deny |
| pracownik | deny by SELECT RLS | allow | deny | deny | deny |
| admin | allow | allow | deny | deny | deny |
| service_role | privileged baseline | privileged baseline | privileged baseline | privileged baseline | privileged baseline |

## After

Migration `20260903100000_harden_audit_log_integrity.sql`:

1. Fails closed unless the expected table owner, RLS state, two-policy
   inventory, and pre-remediation ACL are present.
2. Drops only the client mutation policy `Admins can insert audit logs`.
3. Revokes all table privileges from `PUBLIC`, `anon`, and `authenticated`.
4. Restores only `SELECT` to `authenticated`; the existing admin-only SELECT
   policy remains unchanged.
5. Verifies after the change that no client mutation policy or mutation
   privilege remains.
6. Leaves the existing `service_role` and owner privileges unchanged.

### Current access matrix

| Role | SELECT | INSERT | UPDATE | DELETE | TRUNCATE |
|---|---:|---:|---:|---:|---:|
| PUBLIC | deny | deny | deny | deny | deny |
| anon | deny | deny | deny | deny | deny |
| user | deny by RLS | deny | deny | deny | deny |
| instruktor | deny by RLS | deny | deny | deny | deny |
| pracownik | deny by RLS | deny | deny | deny | deny |
| admin | allow | deny | deny | deny | deny |
| service_role | privileged baseline | privileged baseline | privileged baseline | privileged baseline | privileged baseline |

From the application perspective the log is append-only through trusted
database operations. `service_role` and the `postgres` owner remain privileged
administrative trust boundaries, not end-user roles.

## Trusted write paths

No browser/server application code performs a direct `.insert()` into
`audit_logs`. The current database contains 15 functions whose definitions
insert audit rows:

- `admin_create_lane_booking_family_v1`
- `admin_set_lane_booking_family_configuration_v2`
- `admin_set_user_note_v1`
- `admin_set_user_role_v1`
- `approve_event_registration`
- `cancel_event_registration`
- `cancel_reservation`
- `create_reservation`
- `create_reservation_v2`
- `update_profile_contact_details`
- `update_profile_identity`
- `update_profile_verification`
- `update_reservation_admin_note`
- `update_reservation_attendance`
- `update_reservation_payment`

All 15 are `SECURITY DEFINER`, owned by `postgres`, have an explicit
`search_path`, and use `auth.uid()` in their authorization/actor flow. The
remediation introduces no generic audit logger and changes none of these
business functions.

## Audit data sensitivity

The table contains operational identity data: actor and target UUIDs, display
names, role, action, target type/name, timestamp, and structured details. It can
therefore contain personal or staff-operational information. Read access remains
admin-only through the unchanged RLS policy. The focused test additionally
asserts that a representative trusted flow does not store the note body,
credentials, authorization data, cookies, or technical tokens in `details`.

## Tests

### Focused SEC-007 contract

`20260903100000_harden_audit_log_integrity_test.sql` runs in one transaction
with a final `ROLLBACK` and contains 18 fail-closed checks:

- exact owner/RLS/policy/ACL state;
- direct forged `INSERT` denied for user, pracownik, instruktor, admin, and anon;
- no forged actor row created;
- direct `UPDATE` and `DELETE` denied for admin and pracownik;
- direct `TRUNCATE` denied for authenticated admin and pracownik;
- trusted `admin_set_user_note_v1` flow creates exactly one audit;
- idempotent repeat returns `no_change` and creates no second audit;
- actor/action/target/timestamp and safe `details` are verified;
- all 15 current audit writers satisfy the trusted-function contract;
- fixture is transaction-scoped.

Result: **18/18 PASS**, final `ROLLBACK` completed.

### Existing ACL contract

The global table/sequence ACL test was updated to expect `authenticated` to
have only `SELECT` on `audit_logs`. Its former direct-admin-insert assertion now
requires denial, and its idempotency section no longer re-grants the removed
privilege.

Result: **29/29 PASS**, final `ROLLBACK` completed.

### Full regression

- Local `supabase db reset`: PASS
- All Supabase DB tests: PASS — 9 files, 136 tests
- All Node tests: PASS — 541/541
- TypeScript (`tsc --noEmit`): PASS
- Next.js production build: PASS
- `npm audit --omit=dev`: PASS — 0 vulnerabilities
- Full ESLint: known baseline, 14 errors / 6 warnings
- New security-remediation ESLint regressions: 0 (SQL/docs only)
- `git diff --check`: PASS
- Synthetic fixture remaining after rollback: 0

## Compatibility matrix

| Application | Database before | Database after |
|---|---|---|
| Current application | compatible | compatible; all audit writes use trusted functions |
| Future application using trusted functions | compatible | compatible |
| Any client attempting direct audit INSERT | previously role-dependent | intentionally denied |

Existing audit rows and the table schema are unchanged. Rolling the application
back does not require restoring direct client INSERT because the audited runtime
contains no such call site. A database rollback, if ever required, would need to
recreate the removed policy and grant, but doing so would deliberately reopen
SEC-007.

## Regression risk

LOW–MEDIUM. The mutation surface is reduced without changing business RPCs,
table shape, audit history, or admin read behavior. The main compatibility risk
would be an untracked external client that directly inserts audit rows; this is
intentionally unsupported and now fails closed.

## Verdict

**SEC-007 FULLY REMEDIATED**

No commit, push, deployment, or production database operation was performed.
