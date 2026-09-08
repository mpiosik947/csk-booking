# SAAS-9B-1P — Production Deploy & Verification

Date: 2026-09-08
Scope: final production post-deploy verification of the dormant tenant foundation
Migration: `20260907100000_add_dormant_tenant_foundation.sql`

## 1. Deployment result

The migration is deployed on production. Its repository SHA-256 is `BF642DF8D4E3968B99A7C56BC055075FBBCA51324DEF3933A1CCEFF1DF979E69`.

No migration, schema/application change, migration repair, Git commit, or Git push was performed during this final verification.

## 2. Migration history verification

Operator-provided deployment evidence confirms LOCAL and REMOTE both contain `20260907100000`, with no other pending migration. The production catalog independently confirms this version is present.

Result: **PASS**.

## 3. Post-deploy dry-run

The completed WSL/Supabase CLI post-deploy dry-run returned `Remote database is up to date.`

Result: **PASS**. No `db push` was executed during this verification.

## 4. Tenants verification

| Check | Result |
|---|---:|
| all tenants | 1 |
| tenant `CSK` | 1 |
| slug `csk` | confirmed |
| CSK status | `active` |
| all active tenants | 1 |
| active CSK tenants | 1 |

There is no second active tenant. Result: **PASS**.

## 5. Tenant memberships verification

- `public.tenant_memberships` exists.
- Row count is `0`.
- No existing-user membership backfill occurred.
- Primary key is `(tenant_id, user_id)`.

Result: **PASS**.

## 6. Legacy authorization verification

- `public.profiles.role` still exists.
- Runtime role helpers continue to use the legacy profile-based authorization chain.
- `tenant_memberships.role` is not referenced by application runtime or authorization RPCs.
- The migration contains no authorization cutover.

Current production function fingerprints recorded as the post-deploy baseline:

| Function | Definition fingerprint |
|---|---|
| `is_admin()` | `89a221fa092af2a457db05a64b7e8d18` |
| `get_my_role()` | `dc8858eed7d2fd2d1ab47d22b0000b06` |
| `is_admin_or_staff()` | `6fe5644a9356a4d94959c5a6087be0b5` |
| `is_admin_or_employee()` | `15514f37a714f2592fb496820d2b8277` |
| `get_public_booking_configuration_v1()` | `2aee39e3d37d3d1a19f58c3626aa0365` |
| `create_reservation_v2(...)` | `601664ae4957ed0eef29f85ded57a191` |

Additional current fingerprints were captured for scalable public/admin event lists, my-events, and reservation reports. A strict historical hash comparison is unavailable because no trustworthy pre-deploy production hash set was retained. However, the migration contains zero `CREATE FUNCTION`, `ALTER FUNCTION`, or `DROP FUNCTION` statements, so it cannot modify an RPC definition. The local database is not used as a baseline because its documented schema drift produces different hashes for several pre-existing functions.

Result: **PASS**, with this evidence limitation recorded.

## 7. Business schema invariants

Production catalog inspection confirms SAAS-9B-1 added no `tenant_id` column to `reservations`, `shooting_lanes`, `lane_blocks`, `events`, `event_lanes`, `event_registrations`, `profiles`, or `audit_logs`.

The migration performs no DDL or DML against these tables. No reliable pre-deploy row-count snapshot was retained, so this report does not claim a count-based before/after proof. Static migration review and the current catalog prove that their schema was not altered by SAAS-9B-1.

Result: **PASS with documented baseline limitation**.

## 8. RLS / ACL verification

For both `public.tenants` and `public.tenant_memberships`:

- owner is `postgres`;
- RLS is enabled;
- FORCE RLS is off, matching the approved migration;
- policy count is exactly `0`;
- `PUBLIC` has no explicit privilege;
- `anon`, `authenticated`, and `service_role` have no `SELECT`, `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`, `REFERENCES`, `TRIGGER`, or `MAINTAIN` privilege;
- only the `postgres` owner ACL remains.

Result: **PASS**.

## 9. RPC / SECURITY DEFINER verification

- SAAS-9B-1 introduced zero tenant-named functions/RPCs.
- It introduced zero `SECURITY DEFINER` functions.
- The migration contains no function DDL.

Result: **PASS**.

## 10. Second-active-tenant guard implementation

The guard is the valid unique partial index:

```sql
create unique index tenants_single_active_runtime_guard
  on public.tenants ((true))
  where status = 'active';
```

Every active row indexes the same constant key, so PostgreSQL uniqueness prevents two active tenants. It applies to INSERT and UPDATE, is concurrency-safe at the database/index level, and is not a UI/RLS-only guard.

## 11. Second-active-tenant rollback test

A single production transaction used a unique synthetic marker and performed:

1. second active tenant INSERT — rejected with unique violation;
2. dormant synthetic tenant INSERT — accepted inside the transaction;
3. dormant-to-active UPDATE — rejected with unique violation;
4. explicit `ROLLBACK`.

| Post-check | Result |
|---|---:|
| active tenant count | 1 |
| remaining guard-test fixture | 0 |
| rollback clean | true |

Result: **PASS**.

## 12. Runtime smoke

| Flow | Result |
|---|---|
| Public Booking | PASS — page and resource form rendered, no 5xx |
| Login | PASS — login form rendered, no 5xx |
| Admin dashboard | PASS — authorized dashboard rendered |
| Reservations | PASS — admin reservations rendered |
| Calendar | PASS — occupancy calendar rendered |
| Reports | PASS — report view and KPIs rendered |
| Events | PASS — public/admin event views rendered |
| Check-in | PASS — admin check-in view rendered |

No multi-tenant behavior was exercised and no secret was exposed.

## 13. Known limitations

- This is a dormant foundation, not tenant isolation.
- `profiles.role` remains the active legacy authorization source.
- Memberships are empty and unused.
- Business tables remain global and have no `tenant_id`.
- Strict pre/post production function hashes and row counts were not captured before deployment; static migration scope is the available non-mutation proof.
- The managed Supabase ACL residual remains unchanged.

## 14. Security status

- **SECOND TENANT: NO-GO**
- **SEC-004: OPEN**

## 15. Git status and checkpoint state

At final verification, the repository was on `main` at `8195c3cb1f3b49ad5f0ec471b6cec39bc2511da3`.

The SAAS work remains uncommitted. No `git add`, commit, or push was performed.

## 16. Final verdict

**SAAS-9B-1 PRODUCTION DEPLOY: PASS**

**SAAS-9B-2: NO-GO until the mandatory SAAS-9A / SAAS-9B-1 / SAAS-9B-1P Git checkpoint is reviewed and explicitly approved.**

**SECOND TENANT: NO-GO**

**SEC-004: OPEN**
