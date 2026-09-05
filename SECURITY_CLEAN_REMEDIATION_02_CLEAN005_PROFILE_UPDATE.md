# SECURITY CLEAN-ROOM REMEDIATION 02 — CLEAN-005

## Status

- Finding: `CLEAN-005 — admin direct profile modification hardening`
- Original severity: MEDIUM
- Date: 2026-09-05
- Scope: local application, migration and tests only
- Production database/deployment: not changed

## Before

`public.profiles` is owned by `postgres`, has RLS enabled and contains:

- identity/technical: `id`, `user_id`, `first_name`, `last_name`, `full_name`, `email`, `created_at`, `updated_at`;
- contact/address: `phone`, `postal_code`, `city`, `street`, `house_number`, `apartment_number`;
- legacy qualifications: `weapon_permit_number`, `weapon_permit_type`, `weapon_permit_issuer`, `has_range_officer`, `range_officer_number`, `has_instructor`, `instructor_number`;
- declarations: six `permission_*` and four `qualification_*` booleans;
- authorization/verification: `role`, `verification_status`, `verification_note`, `verified_at`, `verified_by`, `unverified_at`, `unverified_by`, `permissions_verified`, `permissions_verified_at`, `permissions_verified_by`, `permissions_verification_note`;
- administration: `admin_note`.

Before remediation, `authenticated` had `INSERT`, `SELECT` and `UPDATE` table
ACL. Two UPDATE policies existed: owner self-update and unrestricted row access
for an authenticated administrator. The trigger protected direct role, admin
note and identity changes, but deliberately returned early for an administrator
after those special cases. Consequently, an administrator could directly
change another profile's `user_id`, verification fields, email, phone, address,
declarations, qualifications, `created_at`, `updated_at` and other internal or
legacy fields without the controlled RPC and its audit.

### Current operation inventory before remediation

| Operation | Role | Current method | Direct update? | Controlled RPC | Audit |
|---|---|---|---|---|---|
| Own contact/address and declarations | signed-in owner | `/account` table update | yes | no | no |
| Change role | admin | `admin_set_user_role_v1` | trigger blocks direct role change | yes | yes |
| Verification | admin/employee | `update_profile_verification` | admin could bypass for arbitrary fields | yes | yes |
| Admin note | admin | `admin_set_user_note_v1` | trigger blocks direct note change | yes | yes |
| Identity correction | admin | `update_profile_identity` | trigger blocks direct identity change | yes | yes |
| Contact correction | admin/employee | `update_profile_contact_details` | admin also had broad direct path | yes | yes |
| Account anonymization | owner | `anonymize_my_account_v1` | SECURITY DEFINER lifecycle | yes | one pseudonymous lifecycle audit |

### Pre-remediation admin field tampering matrix

| Field/category | Direct admin result before |
|---|---|
| `role` | DENY by RPC-context trigger |
| `admin_note` | DENY by RPC-context trigger |
| `first_name`, `last_name`, `full_name` | DENY by identity RPC-context trigger |
| `user_id`, `id`, `created_at`, `updated_at` | ALLOW |
| verification fields | ALLOW |
| `email`, `phone`, address | ALLOW |
| declarations and qualifications | ALLOW |
| legacy/internal profile fields | ALLOW |

## Broad profile update path removed

Migration `20260905100000_harden_profile_direct_updates.sql`:

1. fails closed unless the expected table, ACL, two UPDATE policies and all
   controlled writers exist;
2. creates one narrow owner writer, `update_my_profile_v1(...)`;
3. drops both direct UPDATE policies;
4. revokes table `UPDATE` from `authenticated`;
5. verifies the final ACL, RLS policy set and RPC security properties.

After migration, direct UPDATE is denied at SQL ACL level for ordinary users,
instructors, employees and administrators. `anon` and `PUBLIC` retain no profile
ACL. `authenticated` retains only `SELECT` and the existing registration-time
`INSERT`; `service_role` retains its managed baseline.

## Controlled writers after

The existing specialized writers were not duplicated or redefined:

- `admin_set_user_role_v1(uuid,text)` — admin-only role allowlist, last-admin
  protection, idempotency and audit;
- `admin_set_user_note_v1(uuid,text)` — admin-only note with length bound,
  idempotency and audit;
- `update_profile_verification(uuid,text,text)` — admin/employee verification
  state machine and audit;
- `update_profile_identity(uuid,text,text)` — admin-only identity correction
  and audit;
- `update_profile_contact_details(uuid,text,text,text,text,text,text)` — bounded
  admin/employee contact correction and audit;
- `anonymize_my_account_v1()` — owner-scoped lifecycle writer.

All derive actor identity from `auth.uid()` and role from `public.profiles`.
Clients cannot provide audit actor identity. Their existing SECURITY DEFINER,
owner, search path, EXECUTE ACL and business behavior remain unchanged.

## Self-profile contract

`update_my_profile_v1(...)` is `VOLATILE SECURITY DEFINER`, owned by `postgres`,
uses `search_path = pg_catalog, public, pg_temp`, and is executable only by
`authenticated`. It derives the target exclusively from `auth.uid()`.

Its signature allows only:

- phone and five address fields;
- six declaration booleans;
- four qualification booleans.

It cannot accept or update a target user ID, role, identity, email,
verification/admin fields, timestamps, legacy document data or internal fields.
It preserves the existing re-verification behavior when declarations change
and returns an idempotent `no_change` result without a write.

`/account` now calls this RPC and no longer contains a table UPDATE call-site.
Its Auth metadata update and existing user messages remain intact.

## Admin operations and audit

Admin role, verification and note operations continue through their dedicated
RPCs. Focused SQL tests prove that each changes only its intended state and
creates exactly one audit with actor from `auth.uid()`. Repeated no-change note
submission creates no second audit. No direct `audit_logs` insert was added.

## Tests

- Focused frontend/profile tests: PASS, 13/13.
- Focused CLEAN-005 SQL: PASS, 30/30, one `BEGIN`, one final `ROLLBACK`, zero
  persistent fixture.
- Direct UPDATE DENY: admin (`role`, verification, email, phone, `user_id`,
  `created_at`), employee, instructor, anon, cross-user and owner self-direct.
- Positive paths: owner RPC, admin role RPC, admin verification RPC, admin note
  RPC, idempotency and trusted audit: PASS.
- SEC-009 anonymization regression: PASS.
- Full Supabase DB suite: PASS — 14 files, 269 tests.
- All Node tests: PASS — 614/614.
- TypeScript `tsc --noEmit`: PASS.
- Next.js production build: PASS.
- `npm audit --omit=dev`: PASS — 0 vulnerabilities.
- Full ESLint: known baseline exactly 14 errors / 6 warnings.
- New CLEAN-005 ESLint regressions: 0.
- `git diff --check`: PASS (line-ending warnings only).
- Secret scan of changed implementation/test files: no credential, key, token
  or connection-string finding.

## Compatibility

| Combination | Result | Reason |
|---|---|---|
| Old app + old DB | SAFE (existing risk) | Existing `/account` direct update works, but CLEAN-005 remains open. |
| Old app + new DB | UNSAFE | `/account` still calls direct table UPDATE, which the new DB correctly denies. |
| New app + old DB | UNSAFE | `/account` calls `update_my_profile_v1`, which does not yet exist. |
| New app + new DB | SAFE | Self-service uses the narrow RPC and all admin operations use dedicated RPCs. |

## Deployment recommendation

**COORDINATED deployment** is required. Neither DB-first nor app-first has a
fully compatible intermediate state. Deploy during a short controlled window,
apply the migration and application release together, then smoke-test
`/account` save plus admin role, verification and note operations. Do not roll
the application back after the migration without a compatibility release that
knows the new RPC contract.

## Verdict

```text
CLEAN-005 FULLY REMEDIATED
```

The implementation and verification are complete locally. No production
migration, deployment, commit or push was performed.
