# SAAS-9H — FINAL SECURITY AUDIT / SEC-004 CLOSURE

Date: 2026-09-23 (Europe/Warsaw)

## Scope

This audit is the final security and second-tenant readiness gate after the
SAAS-9F module cutover and SAAS-9G two-active-tenant local E2E. It covers the
application routes, 18 RLS-enabled public tables, tenant memberships, tenant
ownership/integrity constraints, all public RPCs, ACLs, PII boundaries,
account-wide lifecycle contracts, audit binding and current deployment
invariants.

No second production tenant was created or activated during the audit.

## Final module result

The module-by-module inventory in `SAAS_9F_FINAL_MODULE_CUTOVER_AUDIT.md`
remains authoritative. The 9H review found no remaining operational caller
that uses an implicit CSK tenant, an exact-single-tenant bridge, a compatibility
default, `profiles.role` as tenant authority, app-side filtering as security,
or a caller-controlled tenant identifier without server/resource validation.

| Security boundary | Evidence | Result |
|---|---|---|
| Tenant routing | canonical `/t/{slug}` server resolution; invalid/inactive slugs fail closed | PASS |
| Public readers | active tenant UUID resolved server-side; PII-free bounded DTOs | PASS |
| Owner readers/writers | authenticated owner plus explicit tenant/resource binding | PASS |
| Staff/admin readers/writers | active membership role/status plus persisted resource tenant | PASS |
| Cross-tenant PII | report/user/note/check-in/event DTO and RLS/RPC matrices | 0 leaks |
| Tenant-owned writes | all core ownership columns NOT NULL; resource/tenant FK consistency | PASS |
| Account lifecycle | global export/anonymization/delete remain distinct from tenant relationships | PASS |
| Audit | tenant-owned mutations retain tenant binding; global lifecycle audit may remain NULL | PASS |
| Browser authority | no service-role key and no browser-trusted tenant authority | PASS |
| Legacy bridges/defaults | bridge definitions 0; compatibility defaults 0 | PASS |

## Final readiness change

The only real 9H readiness blocker was the rollout-only partial unique index
`tenants_single_active_runtime_guard`. The application and database had already
completed tenant-aware cutover, but that index still made a second active tenant
structurally impossible.

Migration `20261003100000_remove_single_active_tenant_guard.sql` removes only
that index. Its fail-closed preflight requires:

- the guard to exist before deployment;
- exactly one currently active production tenant;
- no orphan membership;
- zero compatibility defaults;
- SECURITY DEFINER count 74;
- zero function body dependency on the old exact-single bridge or canonical
  CSK UUID.

Its postflight requires the guard to be absent, the production tenant state to
remain unchanged and the SECURITY DEFINER inventory to remain 74. The migration
does not create or activate a tenant and does not modify business data.

## RLS, ACL and function inventory

- RLS-enabled public tables: **18**
- SECURITY DEFINER functions: **74**
- SECURITY DEFINER functions executable by generic PUBLIC: **0**
- compatibility defaults: **0**
- bridge definitions: **0**
- tenant ownership NULL/orphan/resource mismatches: **0**
- orphan memberships/tenant-state rows: **0**

The 74 definers are partitioned into reviewed families:

- tenant context/membership: `get_my_active_tenants_v1`,
  `resolve_active_tenant_by_slug_v1`, `is_active_public_tenant_v1`,
  `is_tenant_member_v1`, `has_tenant_role_v1`, `get_my_tenant_role_v1`,
  `self_onboard_tenant_v1`;
- public booking/events/check-in readers: tenant-scoped booking, busy-range,
  event list/availability and public check-in contracts;
- owner reservation/event/account contracts: owner reads, cancellations, ICS,
  profile update, export and anonymization;
- staff reservation/check-in/reporting contracts: reservation reports/export,
  customer profile reads, notes, payment, attendance and verification;
- events/registrations/promotion contracts: tenant-scoped event management,
  registration status/payment and promotion/confirmation paths;
- lane/block/configuration contracts: tenant-scoped block and lane-family
  readers/writers plus protected integrity triggers;
- tenant user administration: role, identity, contact, verification and admin
  note contracts;
- trusted email/rate-limit and platform triggers.

Six retained functions use an older but fixed search path that does not start
with `pg_catalog`: `check_confirmation_email_rate_limit`, `handle_new_user`,
`get_my_role`, `is_admin`, `is_admin_or_employee`, and `is_admin_or_staff`.
The four legacy role helpers are postgres-only, have no active application
caller and cannot authorize tenant operations. The email limiter is
service-only and `handle_new_user` is trigger-only. None has generic PUBLIC
EXECUTE. This is a LOW hardening residual, not a cross-tenant authority path.

Textual references to `profiles.role` remain in closed historical/internal
function bodies, but active application callers, public/client ACL and tenant
authorization paths do not use them. The authoritative role source for tenant
operations is active `tenant_memberships` state.

## Two-tenant and regression evidence

- focused 9H SQL: **10/10 PASS**, transaction rolled back;
- full DB: **56 files, 1618/1618 PASS**;
- Node: **789/789 PASS**;
- TypeScript: **PASS**;
- production build: **PASS**;
- Playwright: **39/39 PASS**, including two active local tenants;
- two-tenant local selector/public/admin isolation: **PASS**;
- concurrency suites from 9G: **PASS**, deadlocks 0, cross-tenant effects 0;
- fixture cleanup: tenants 0, memberships 0, users/profiles 0;
- local final state: one active CSK tenant, guard absent, SECURITY DEFINER 74,
  defaults 0;
- `git diff --check`: **PASS** (Windows EOL notices only).

Full ESLint retains the existing baseline of four errors and five warnings in
unrelated application files. No changed 9H file introduces an ESLint error.
`npm audit --omit=dev` reports one existing moderate
`baseline-browser-mapping` denial-of-service advisory and no HIGH/CRITICAL
dependency finding.

## Findings and residuals

| ID | Severity | Finding | Decision |
|---|---|---|---|
| 9H-001 | LOW | Six closed/service/trigger functions retain older fixed search-path ordering | Accepted hardening backlog; no PUBLIC ACL or tenant authority |
| 9H-002 | MODERATE dependency advisory | `baseline-browser-mapping` can terminate on invalid input | Dependency maintenance; not introduced by SaaS cutover, no HIGH/CRITICAL |
| 9H-003 | Operational | Non-authoritative duplicate Vercel project previously failed while authoritative `csk-booking-5nwh` passed | Track outside SEC-004; authoritative production project remains source of truth |
| 9H-004 | Legal/privacy | Final business identity/contact and complete GDPR public-launch review remain incomplete | Public-launch gate, not technical tenant-isolation blocker |

New CRITICAL: **0**

New HIGH: **0**

## Production deployment and verification

- deployment-input SHA-256:
  `BCCB00461D8379E15862F150013ED1947EBE6BCEA1B30C92F9D08B1B6D27F0C2`;
- canonical checkpoint SHA-256 after removing one terminal blank line:
  `D145E3F19920DF07E9487EE45E251D8EC9CFDAFC854B51BCAF0AA2376A2911D9`;
  executable SQL and normalized migration content are unchanged;
- preflight migration history: LOCAL=REMOTE through `20261002100000`;
- preflight pending set: exactly
  `20261003100000_remove_single_active_tenant_guard.sql`;
- preflight dry-run: exactly that one migration;
- deployment: PASS; the migration's transactional preflight and postflight
  both completed;
- post-deploy migration history: LOCAL=REMOTE through `20261003100000`;
- final dry-run: `Remote database is up to date`;
- migration changed no function, ACL, RLS policy, application code or business
  row; SECURITY DEFINER remains 74 and the active tenant count remains one by
  migration postcondition;
- authoritative Vercel GET smoke: 200 for `/`, `/t/csk/booking`,
  `/t/csk/events`, `/login`, `/account`, `/dashboard`; unauthenticated admin
  routes returned the expected controlled 307 and no route returned 5xx.

No production fixture was created. No second production tenant was created or
activated.

## SEC-004 decision

The technical tenant-isolation blocker is closed. The application and database
now support explicit, concurrent tenant contexts; local two-active-tenant E2E
and cross-tenant security matrices pass; production no longer contains the
rollout-only structural guard. Activating a real second production tenant is a
separate controlled onboarding/business action, not part of this audit.

- SAAS-9H: **PASS**
- SEC-004: **CLOSED**
- SECOND TENANT READINESS: **READY**
- TECHNICAL SAAS READINESS: **YES**
- SECOND PRODUCTION TENANT ACTIVATION: **NOT PERFORMED**
- LEGAL/GDPR PUBLIC-LAUNCH GATE: **INCOMPLETE**
