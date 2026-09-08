# SAAS-9B-1 — Dormant Tenant Foundation Implementation Report

Data: 7 września 2026 r.
Repozytorium: `C:\Users\Mpios\Desktop\APP Krutla\APP Krutla\csk-booking`
Bazowy HEAD: `8195c3cb1f3b49ad5f0ec471b6cec39bc2511da3`

## 1. Executive summary

Dodano wyłącznie addytywny, dormant fundament tenantów. Baza posiada teraz rejestr tenantów, przyszłe tenant-scoped membership oraz jeden bootstrap tenant CSK. Runtime aplikacji, role, RLS tabel biznesowych i RPC pozostają bez zmian.

Drugi tenant może istnieć wyłącznie w stanie niedziałającym. Partial UNIQUE guard na poziomie PostgreSQL pozwala na maksymalnie jeden rekord `active`, więc drugiego działającego tenanta nie da się uruchomić przez `INSERT` ani `UPDATE`.

Nowe tabele są fail-closed: RLS jest włączone, nie mają żadnej polityki allow ani ACL dla `PUBLIC`, `anon`, `authenticated` i `service_role`. Provisioning jest obecnie możliwy wyłącznie przez kontrolowaną migrację/owner DB. Nie dodano żadnego `SECURITY DEFINER` ani panelu zarządzania tenantami.

## 2. Files changed

- `supabase/migrations/20260907100000_add_dormant_tenant_foundation.sql`
- `supabase/tests/20260907100000_add_dormant_tenant_foundation_test.sql`
- `supabase/tests/20260902120000_harden_public_table_sequence_acl_test.sql`
- `SAAS_9B_1_DORMANT_TENANT_FOUNDATION_IMPLEMENTATION_REPORT.md`

Pre-existing, untracked input from completed SAAS-9A remains separate:

- `SAAS_9A_MULTI_TENANT_ARCHITECTURE_MIGRATION_AUDIT.md`

No application/TypeScript file was changed.

## 3. Migrations added

`20260907100000_add_dormant_tenant_foundation.sql`

The migration is additive and contains:

1. strict preflight against pre-existing foundation objects;
2. `tenants` table;
3. one-active-tenant guard;
4. `tenant_memberships` table;
5. FKs, CHECKs and indexes;
6. shared `updated_at` triggers;
7. fail-closed RLS/ACL;
8. deterministic CSK bootstrap;
9. schema/security postflight.

It does not drop or alter any existing business column, policy, RPC or permission.

## 4. `tenants` schema

| Column | Contract |
|---|---|
| `id` | UUID PK, `gen_random_uuid()` default |
| `name` | trimmed, non-empty, max 120 |
| `slug` | NOT NULL, globally UNIQUE, lowercase, 2–63 chars, alphanumeric hyphenated segments |
| `status` | NOT NULL; `dormant`, `active`, `suspended`, `disabled` |
| `created_at` | DB timestamp |
| `updated_at` | DB timestamp maintained by existing shared trigger |

No branding, billing, plan, subscription, custom domain, facility or expanded settings were introduced.

## 5. `tenant_memberships` schema

| Column | Contract |
|---|---|
| `tenant_id` | FK to `public.tenants(id)`, cascade on tenant deletion |
| `user_id` | FK to global `auth.users(id)`, cascade on Auth user deletion |
| `role` | `admin`, `employee`, `user` |
| `status` | `active`, `pending`, `suspended` |
| `created_at` | DB timestamp |
| `updated_at` | DB timestamp maintained by trigger |

Composite PK `(tenant_id,user_id)` guarantees exactly one relationship for one global user and tenant. Indexes support future user membership lookup and tenant role/status administration.

## 6. Tenant role/status model

Tenant lifecycle is intentionally minimal. `active` means the sole currently working tenant; `dormant` prepares a future tenant without enabling runtime; `suspended` and `disabled` reserve explicit fail-closed lifecycle states.

Membership roles use normalized future values `admin`, `employee`, `user`. No instructor, owner or platform superadmin was added. Membership statuses are only `active`, `pending`, `suspended`. Verification/KYC/requirements/terms were intentionally deferred.

## 7. CSK tenant bootstrap

The migration creates exactly one row:

```text
id:     c5c00000-0000-4000-8000-000000000001
name:   CSK
slug:   csk
status: active
```

The deterministic UUID makes later business ownership backfill reproducible without changing any existing business UUID.

## 8. Second-tenant technical guard

`tenants_single_active_runtime_guard` is a partial UNIQUE index on a constant for rows where `status='active'`.

Effects:

- a second `active` tenant INSERT fails with unique violation;
- changing a dormant/suspended/disabled second tenant to `active` also fails;
- dormant preparation remains possible;
- removal in the final tenant-aware cutover is explicit and small: drop the named guard only after SEC-004 closure gates pass.

This protection does not depend on UI or documentation.

## 9. RLS/ACL applied to new objects

- owner: `postgres`;
- RLS: enabled on both tables;
- policies: zero;
- `PUBLIC`: no privileges;
- `anon`: no privileges;
- `authenticated`: no privileges;
- `service_role`: no privileges;
- sequences: none (UUID identifiers);
- new SECURITY DEFINER functions: none.

The existing SEC-002 table inventory test now explicitly includes all 16 public tables and the exact empty ACL of the two dormant objects.

## 10. Existing user handling

No memberships were generated for current users. This is intentional: current global `profiles.role` does not prove the future tenant relationship/consent model, and an automatic copy could prematurely turn global roles into tenant facts.

Membership backfill belongs to SAAS-9B-2/9B-3 after the membership creation and profile-sharing decisions are approved. The migration postflight asserts an empty membership table.

## 11. Existing `profiles.role` status

```text
profiles.role = LEGACY GLOBAL AUTH SOURCE — still active
tenant_memberships.role = DORMANT FUTURE AUTH SOURCE — not active yet
```

`get_my_role()` and `is_admin*()` remain profile-based. Middleware, RLS and all current RPC are unchanged. There are not two parallel active authorization sources.

## 12. Runtime behavior verification

- Booking/create reservation contracts unchanged.
- Events/scalable read contracts unchanged.
- Reports contracts unchanged.
- Calendar and Check-in contracts unchanged.
- Lane family creation/configuration unchanged.
- No app query references `tenants` or `tenant_memberships`.
- No `tenant_id` was added to business tables.
- No route, tenant resolver or selector was added.

## 13. Tests executed

- focused SQL SAAS-9B-1 contract;
- existing SEC-002 ACL inventory test;
- all Supabase DB tests on local Supabase;
- all Node tests;
- `npx.cmd tsc --noEmit`;
- `npm.cmd run build`;
- `npm.cmd audit --omit=dev`;
- full ESLint;
- Playwright lane-family suite;
- Playwright events responsive suite;
- `git diff --check`.

All DB commands targeted `postgresql://postgres@127.0.0.1:54322/postgres`. No linked/remote command or production operation was executed.

## 14. Test results

| Test | Result |
|---|---|
| SAAS-9B-1 focused SQL | PASS — 30/30, final ROLLBACK |
| SEC-002 exact ACL inventory | PASS — 29/29, final ROLLBACK |
| Full Supabase DB suite | PASS — 19 files, 408 tests |
| Node | PASS — 727/727 |
| TypeScript | PASS |
| Build | PASS — Next.js 16.3.4 |
| npm audit production | PASS — 0 vulnerabilities |
| Playwright lane-family | PASS — 5/5 |
| Playwright events | PASS — 8/8 |
| Full ESLint | existing baseline: 10 errors, 5 warnings |
| `git diff --check` | PASS (line-ending warning only) |

Focused test verifies schema, lifecycle/role CHECKs, both FKs, uniqueness, trigger presence, exact ACL/RLS, self-escalation denial, no tenant RPC, legacy authorization and the one-active-tenant guard on INSERT and UPDATE.

## 15. Regression results

Full DB suite initially exposed stale local Playwright lane fixtures and the expected old 14-table ACL inventory. The inventory was correctly extended to 16. Six stale `[TEST]` resources were removed from local PostgreSQL only, with exact-count fail-closed cleanup. After cleanup the complete DB suite, including REPORTS-6A, passed.

The lane-family E2E suite created five new local synthetic resources and passed. Those five records and their configuration/audit dependencies were then removed with another exact-count local cleanup. Remaining E2E synthetic Auth/profile records: zero.

The Supabase CLI local reset could not start because its bundled runtime returned `EUNKNOWN: uv_spawn`; no remote fallback was attempted. The new migration itself was successfully executed directly from its file against `127.0.0.1:54322`, and the complete DB suite subsequently passed on that schema.

## 16. Security notes

- New objects default to no access, including `service_role`.
- No public discovery API exists yet.
- No caller-controlled role or tenant provisioning exists.
- FK to `auth.users` follows the existing global account model.
- Unique active guard is a deployment safety control, not tenant isolation.
- SEC-004 remains open because business tables, RLS, RPC and application context remain global.
- Existing managed Supabase ACL residual is unchanged.

## 17. Rollback plan

Before any production deployment, capture schema/ACL and verify both tables do not pre-exist. Because no runtime references the foundation, rollback is structurally simple while the tables contain only the CSK bootstrap and no memberships:

1. verify zero memberships and no non-CSK tenant data;
2. drop membership trigger/table;
3. drop tenant trigger/table (the guard index drops with it);
4. verify all original tables/functions/policies and current V1 flows.

Do not perform destructive rollback after later phases begin storing real membership or ownership data. At that point rollback should retain the data and roll back only the application contract.

## 18. Known limitations

- Local migration history was already inconsistent before this change: schema contained 5 September contracts while CLI history listed those files as unapplied. No migration repair was performed.
- Full ESLint has an unrelated current baseline of 10 errors / 5 warnings. No changed runtime file adds an ESLint regression.
- No generated Supabase TypeScript database type file exists in the repository; none was manually introduced.
- There is no tenant public reader or management writer by design.

## 19. Deferred work

- tenant IDs and backfill for business roots;
- tenant-aware composite constraints and indexes;
- tenant-scoped RLS and SECURITY DEFINER RPC;
- membership provisioning/backfill;
- tenant-specific profile/verification/terms;
- routing and tenant resolution;
- tenant admin/platform admin;
- audit tenant ownership;
- public discovery/configuration;
- second tenant activation;
- SEC-004 closure.

## 20. Recommended SAAS-9B-2 scope

Keep the next stage preparatory and bounded:

1. resolve the production/local migration-history drift before deployment planning;
2. capture production schema, trigger, ACL/RLS and RPC fingerprints read-only;
3. define approved membership provisioning/backfill semantics;
4. introduce nullable tenant ownership only on agreed business roots (`shooting_lanes`, `reservations`, `events`, `event_registrations`, and selected operational history) with CSK backfill plan;
5. add validation queries and same-tenant constraint design, but do not activate tenant B;
6. retain the one-active-tenant guard and legacy runtime authorization.

Do not combine ownership backfill with the tenant-aware RLS/RPC cutover in one unreviewable migration.

## 21. GO / NO-GO

### A. SAAS-9B-1 implementation

**PASS**

### B. Readiness for SAAS-9B-2

**GO**, subject to resolving migration-history drift and approving membership/backfill semantics.

### C. Readiness for second tenant

**NO-GO**

### D. SEC-004

**OPEN**
