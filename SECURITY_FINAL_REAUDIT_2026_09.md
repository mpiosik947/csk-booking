# CSK Booking — Final Security Re-audit 2026-09

## Executive summary

This report is a fresh, read-only assessment of the current repository at:

```text
HEAD: c9749b5 docs: record SEC-016 production smoke pass
Date: 2026-09-04
Deployment model: current single-tenant CSK
```

The review covered the original audit, all remediation and verification reports,
the consolidated production smoke report, current application code, migrations,
RLS and ACL contracts, SECURITY DEFINER functions, API routes, middleware, Auth,
PII lifecycle, e-mail delivery, rate limiting, audit integrity, headers,
dependencies and legal surfaces.

No current Critical vulnerability was found. The former application-controlled
High findings (dependencies, PostgreSQL ACL and public GET mutation) are closed.
The remaining High is SEC-004, an explicitly deferred architecture constraint:
the schema has no tenant boundary. It does not represent cross-tenant exposure in
the current one-organization deployment, but it is a hard blocker before adding
a second tenant.

The current single-tenant application is ready with accepted/deferred residuals.
It is not ready for SaaS. No new `SEC-FINAL-*` finding is supported by the
evidence gathered in this re-audit.

## Current counts

Counts below describe unresolved or accepted residual risk, not historical
findings that have been closed.

| Severity | Count | Items |
|---|---:|---|
| CRITICAL | 0 | None |
| HIGH | 1 | SEC-004 — tenant isolation, deferred architecture blocker before SaaS |
| MEDIUM | 1 | SEC-008 — global instructor access to event-registration PII, deferred pending an authoritative assignment model |
| LOW | 4 | SEC-009 10B retention, SEC-010 leaked-password protection, SEC-014 lane-block reason, managed Supabase ACL residual |
| INFO | 1 | SEC-016 owner/legal identity and privacy-contact data |

The documented `unsafe-inline` CSP limitation and Next.js middleware deprecation
are tracked implementation limitations, not separate security findings: no
current bypass or exploit path was demonstrated.

## Full security inventory

### Dependencies

The production dependency tree contains:

```text
next 16.3.4
postcss 8.5.23
nanoid 3.3.18
sharp 0.35.4
```

`npm audit --omit=dev` reports zero vulnerabilities. No vulnerable duplicate of
the four production packages was found in `npm ls --all --omit=dev`.

### Auth, sessions and passwords

- Server API routes that call `auth.getUser()` use the shared classifier in
  `lib/server/auth-user-verification.ts`: missing/invalid sessions map to 401,
  Auth 5xx and retryable/network failures to 503, and unknown Auth failures fail
  closed as 500 rather than false 401.
- Browser/server Supabase clients use the supported cookie/session model. No
  application-managed access/refresh token storage in localStorage or custom
  client cookies was found.
- The prior clean-session production review passed login, refresh, logout and
  reload. The stale refresh-token observation was not reproducible as a current
  regression.
- Registration, reset and account password changes share the 12–72 character
  policy. Production boundary tests passed. Existing login is not incorrectly
  subjected to new-password validation.
- Leaked-password protection remains unavailable on the current plan and is an
  accepted LOW residual. MFA for privileged roles remains future hardening, not
  a reopened SEC-010 claim.

### RLS, ACL and database functions

- Application-controlled default TABLE/SEQUENCE privileges for `postgres` are
  fail-closed. Client roles have explicit minimum table grants; no client
  TRUNCATE, REFERENCES, TRIGGER or MAINTAIN privilege is retained.
- Function EXECUTE is explicit. Sensitive SECURITY DEFINER RPCs revoke PUBLIC,
  anon and service_role where their contracts require an authenticated caller.
- Current DB tests validate function ownership, search paths, ACLs, table RLS,
  direct-DML denial, audit integrity and cross-writer invariants.
- `event_registrations` is SELECT-only for `authenticated`; mutations are through
  controlled RPCs. `audit_logs` client writes/updates/deletes are denied.
- SECURITY DEFINER writers use trusted `auth.uid()` and database roles, qualified
  tables and bounded response contracts. No unrestricted current client writer
  was found.
- The managed `supabase_admin` default-ACL residual is limited to future objects
  owned by that managed role. Current application objects owned through this
  path were previously verified as zero; the guard test remains active.

### service_role usage

Runtime references are confined to server-only delivery/lifecycle modules:
account Auth deletion after database anonymization, atomic e-mail delivery
completion/rate-limit operations, and reserve-promotion delivery. The public or
user-facing action is first authenticated/authorized through anon/JWT contracts.
No service-role key is referenced by Client Components or returned/logged.

### API and admin-route authorization

- `/admin/:path*` is protected server-side. Known routes use an explicit role
  matrix; an unknown admin path defaults to admin-only rather than allow.
- API routes retain their own authentication and role checks; they do not rely
  solely on middleware.
- SEC-003 confirmation mutation is authenticated POST. The token GET page is
  read-only. Ownership is derived from `auth.uid()`, with no service-role bypass.
- Known business conditions use stable codes/statuses; raw provider, Auth and
  PostgreSQL details are not forwarded to clients.

### Event registrations and check-in

- Direct event-registration DML is denied to application roles and payment
  changes use the audited admin/employee RPC. SEC-018 production tests passed.
- Public check-in exposes only a neutral allowlisted DTO and enforces the window
  from 24 hours before start through two hours after calculated end. Cancelled
  reservations are invalid, and attendance mutation is idempotent.
- SEC-008 remains open by deliberate architecture decision: the SELECT policy
  `Admins and staff can view all event registrations` calls
  `is_admin_or_staff()`, which includes `instruktor`. The admin Events UI also
  performs `select("*")` and explicitly lets instructors view participant lists.
  Rows include `customer_name`, `customer_email`, `customer_phone` and technical
  promotion fields. There is no authoritative event-to-instructor assignment in
  the current model, so a safe scoped RLS rule cannot yet be expressed.

### E-mail delivery, rate limiting and tokens

- Dynamic HTML is escaped centrally; link attributes accept only absolute HTTP
  or HTTPS URLs. Plain-text bodies remain plain text.
- Confirmation and cancellation delivery use atomic prepare/complete claims,
  controlled replay results and rate limits. Recipient identity and content are
  read from trusted server/database data, not caller-controlled fields.
- HMAC IP scope prevents raw IP storage in the tested rate limiter. Application
  responses/logging do not expose JWTs, service-role material, delivery-provider
  bodies or bearer tokens.
- Production smokes verified e-mail injection protection, cancellation delivery
  idempotency, reserve confirmation and check-in token behavior with synthetic
  fixtures and zero residue.

### Audit logs

Application roles cannot directly insert, update, delete or truncate audit logs.
Trusted business functions create database-timestamped audit records with the
actor derived from `auth.uid()`. Idempotent/no-change operations do not produce
duplicate audits. The audit payload checks reject secrets and active bearer
tokens.

### PII and account lifecycle

- Owner export is parameterless and allowlisted; it excludes admin notes,
  technical tokens, credentials, rate-limit internals and other users' data.
- Self-deletion accepts no arbitrary user ID. Database anonymization occurs
  before the server-only Auth Admin deletion. Failure after anonymization is
  retryable without restoring PII or duplicating the audit.
- Production testing confirmed direct PII removal, preservation of required
  non-identifying operational history, Auth deletion and cross-user isolation.
- Category-specific time retention (SEC-009 10B) remains deferred pending
  approved legal/business periods.

### Headers, cache and errors

- The global CSP has no wildcard source and no production `unsafe-eval`;
  `connect-src` is restricted to self and the exact Supabase HTTP/WS origin.
  Framing, objects and inline event-handler attributes are blocked.
- `nosniff`, Referrer-Policy, DENY framing, Permissions-Policy and COOP are
  applied centrally. Token routes use `no-referrer`.
- API, authenticated/admin and token paths use private/no-store controls; public
  static pages remain normally cacheable.
- `unsafe-inline` for script/style remains an acknowledged Next.js compatibility
  residual. Removing it requires a separate nonce/hash rollout.
- Client errors use stable messages and bounded diagnostic codes. Current code
  searches found no logging of Authorization headers, JWTs, service keys, full
  tokens, request bodies, e-mail/phone data or raw error objects.

### Legal and configuration surfaces

`/privacy` and `/terms` reflect the current account, reservation, event,
check-in, delivery, audit, rate-limit, export/anonymization and provider flows.
Only the approved legal owner/form/address/privacy-contact block remains
deferred. No unrelated TODO or `example.com` placeholder remains.

No tracked `.env` or credential file and no repository secret pattern was found.
Production values are not inferred from local `config.toml`; production claims
in this report come from documented production smoke evidence.

## High and Critical recheck

| ID | Area | Current status | Evidence and attack path |
|---|---|---|---|
| SEC-001 | Vulnerable production dependencies | CLOSED | Patched versions installed; current production dependency audit has 0 vulnerabilities. |
| SEC-002 | PostgreSQL ACL | CLOSED for application-controlled scope | Explicit function/table/sequence grants, hardened defaults and passing ownership/ACL tests. Managed-owner future-object residual remains LOW. |
| SEC-003 | Public GET mutation | CLOSED | GET is read-only; authenticated owner POST is required; production 401/403/success/replay tests passed. |
| SEC-004 | Tenant isolation | DEFERRED BY ARCHITECTURE | No `tenant_id`, tenant membership or tenant-scoped RLS exists. Once a second organization shares the system, global staff roles/readers can cross tenant boundaries. Hard blocker before SaaS, not a cross-tenant exploit in a one-tenant deployment. |

No new Critical or High finding was identified. No service-role exposure,
unrestricted client DML or insecure new lifecycle RPC was found.

## Medium recheck

| ID | Current status | Current severity | Production verified? | Residual | Blocks current single-tenant? | Blocks SaaS? |
|---|---|---:|---|---|---|---|
| SEC-005 | REMEDIATED | NONE | Yes | URL-bearer paths can exist in infrastructure logs; app suppresses referrers/logging | No | No, subject to platform log policy |
| SEC-006 | REMEDIATED | NONE | Yes, all five mail flows | None established | No | No |
| SEC-007 | REMEDIATED | NONE | Yes | None established | No | No |
| SEC-008 | DEFERRED / BLOCKED BY DATA MODEL | MEDIUM | Existing global behavior confirmed; no remediation smoke applicable | Instructor can read global registration PII without assignment | Accepted for current trusted single-tenant operations, but should be minimized | Yes |
| SEC-009 | CORE REMEDIATED; 10B DEFERRED | LOW residual | Yes for export/delete/anonymization | No approved time-based retention periods | No | Requires policy decision before scaled SaaS operation |
| SEC-010 | REMEDIATED WITH ACCEPTED RESIDUAL | LOW residual | Yes | Leaked-password protection OFF due plan | No | Reassess with plan/security tier |
| SEC-011 | REMEDIATED | NONE | Yes | Next.js middleware naming deprecation only | No | No, provided behavior is preserved during proxy migration |
| SEC-018 | REMEDIATED | NONE | Yes, 31/31 rollback smoke | None established | No | No |

## Low and Info recheck

| ID | Current status | Current severity | Evidence |
|---|---|---:|---|
| SEC-012 | REMEDIATED | NONE | Header/CSP/cache tests and production browser/HTTP smoke passed. `unsafe-inline` is documented, not claimed as full XSS prevention. |
| SEC-013 | REMEDIATED | NONE | Safe client/API error mapping and production invalid/auth/not-found checks passed. |
| SEC-014 | PARTIAL / DEFERRED BEFORE SAAS | LOW | Booking uses the minimal availability RPC, but authenticated table SELECT plus `Anyone can view active lane blocks` still allows direct retrieval of free-text `reason`. |
| SEC-015 | REMEDIATED | NONE | Atomic cancellation claim, authorization, idempotency and rate-limit production smoke passed. |
| SEC-016 | PARTIALLY REMEDIATED | INFO | Current data-flow content is deployed and verified; legal owner/form/address/privacy contact await the business-entity decision. |
| SEC-017 | OBSOLETE | NONE | No Storage use, bucket or object surface in the application/current verified inventory. Reopen only when Storage is introduced. |

## New findings

```text
NONE
```

The re-audit specifically inspected the new account lifecycle, delivery state,
rate limiting, CSP/header builder, route-permission helper, safe error helper,
pseudonymized audit path and shared password policy. No evidence justified a new
`SEC-FINAL-*` issue.

## Closed findings

Fully closed/remediated for the current system:

```text
SEC-001, SEC-002 (application-controlled scope), SEC-003,
SEC-005, SEC-006, SEC-007, SEC-011, SEC-012, SEC-013,
SEC-015, SEC-017, SEC-018
```

SEC-009 core lifecycle and SEC-010 application/password-length consistency are
also remediated; their explicitly named residuals remain below.

## Partially remediated and deferred findings

- SEC-008: no safe remediation without an event-instructor assignment model.
- SEC-009 10B: time-based retention periods are not approved/implemented.
- SEC-014: UI minimization is complete, direct authenticated reason access is not.
- SEC-016: privacy content is current, final controller identity/contact is not.
- SEC-004: tenant isolation is intentionally deferred but mandatory before SaaS.

## Production verification summary

| Item | Local evidence | Production evidence | Documented |
|---|---|---|---|
| SEC-001 dependencies | PASS, audit 0 | Patched app deployment documented; no dedicated runtime package endpoint | Yes |
| SEC-002 ACL | PASS | Production migration/ACL postflight verified | Yes |
| SEC-003 GET/POST confirmation | PASS | PASS | Yes |
| SEC-005 check-in token | PASS | PASS | Yes |
| SEC-006 e-mail HTML | PASS | PASS, five flows | Yes |
| SEC-007 audit integrity | PASS | PASS | Yes |
| SEC-008 instructor scoping | Analysis only; blocked | Current global access behavior remains | Yes |
| SEC-009 core lifecycle | PASS | PASS | Yes |
| SEC-010 password policy | PASS | PASS; accepted leaked-password residual | Yes |
| SEC-011 admin fail-closed | PASS | PASS | Yes |
| SEC-018 event registration DML | PASS | PASS, 31/31 with rollback | Yes |
| SEC-012 headers | PASS | PASS | Yes |
| SEC-013 safe errors | PASS | PASS | Yes |
| SEC-014 lane-block reason | Partial minimization tests | No closing smoke; residual intentionally remains | Yes |
| SEC-015 cancellation delivery | PASS | PASS | Yes |
| SEC-016 privacy/terms | PASS | PASS, partial legal residual | Yes |

Synthetic production tests documented zero remaining fixture/rate-limit residue.
No new production action was required or performed for this re-audit.

## Test results

| Check | Result |
|---|---|
| All Node tests | PASS — 611/611 |
| All local Supabase DB tests | PASS — 12 files, 215 tests |
| TypeScript `npx.cmd tsc --noEmit` | PASS |
| Next.js production build | PASS — Next.js 16.3.4, 37/37 pages |
| `npm audit --omit=dev` | PASS — 0 Critical, 0 High, 0 Medium, 0 Low |
| `git diff --check` before report | PASS |
| Full ESLint | KNOWN BASELINE — 14 errors, 6 warnings |
| New re-audit ESLint regressions | 0 (report-only change) |

The build still reports the known Next.js warning that `middleware.ts` is
deprecated in favor of the proxy convention. Current SEC-011 behavior is tested
and production-verified; migration should preserve the same fail-closed matrix.

## Residual risk register

| Item | Status | Severity | Accepted/deferred | Trigger to reopen |
|---|---|---:|---|---|
| SEC-004 tenant isolation | Open architecture constraint | HIGH before SaaS | Deferred | Before onboarding/configuring a second organization or shared staff/data boundary |
| SEC-008 instructor event access | Open | MEDIUM | Deferred pending model | Approval/implementation of event-instructor assignment; before SaaS or broader instructor population |
| SEC-009 10B retention | Open residual | LOW | Deferred pending periods | Legal/business approval of category retention periods; before scaled operations |
| SEC-010 leaked-password protection | Accepted residual | LOW | Accepted plan limitation | Supabase plan upgrade or provider capability becomes available |
| SEC-014 lane-block reason | Partially remediated | LOW | Deferred before SaaS | Before a second tenant, untrusted staff-note content, or customer-facing direct table access changes |
| SEC-016 owner data | Partial legal content | INFO | Deferred pending entity decision | Before formal service launch or once legal entity/contact is approved |
| Managed Supabase ACL | Accepted platform residual | LOW | Accepted with guard | Any public object becomes owned by `supabase_admin`, or platform/default grants change |
| CSP `unsafe-inline` | Documented limitation | INFO | Deferred hardening | Nonce/hash architecture work or evidence of an injection primitive |
| Middleware convention | Maintenance item | INFO | Deferred | Next.js proxy migration or framework removal of middleware support |

## Final priorities

### P0 — immediate blocker

None for the current single-tenant CSK deployment.

### P1 — before more feature development

None required by a new regression. Keep security tests and production smoke gates
mandatory for changes to Auth, RLS/ACL, lifecycle, e-mail and admin routes.

### P2 — before SaaS

1. Implement authoritative tenant ownership/membership and tenant-scoped RLS,
   RPCs, audits, jobs and operational reads (SEC-004).
2. Add the approved event-instructor assignment and scoped participant DTO, then
   remove instructor global registration access (SEC-008).
3. Replace broad lane-block table access with a minimal customer availability
   contract and a staff-only reason reader (SEC-014).
4. Approve and implement time-based retention periods (SEC-009 10B).
5. Revalidate managed-owner ACL, role matrices and storage policy before the
   second tenant.

### P3 — accepted/deferred

- Enable leaked-password protection after plan support becomes available.
- Complete legal owner/contact data when the business entity is finalized.
- Stage nonce/hash CSP hardening and migrate middleware to the proxy convention.

## Final recommendation

The current single-tenant service may continue feature work and operation with
the documented residual acceptance. Security-sensitive changes should continue
to use the existing fail-closed DB/API tests and synthetic production smokes.

Do not onboard a second tenant until SEC-004, SEC-008 and SEC-014 have explicit
tenant/assignment-aware models and tests. Treat that boundary as a release gate,
not optional hardening.

```text
FINAL SECURITY RE-AUDIT:
PASS WITH ACCEPTED RESIDUALS

CURRENT SINGLE-TENANT:
READY WITH ACCEPTED RESIDUALS

SAAS / SECOND TENANT:
NOT READY

BLOCKERS BEFORE FURTHER FEATURE WORK:
NONE for ordinary single-tenant work; preserve current security regression gates.

BLOCKERS BEFORE SAAS:
SEC-004 tenant isolation;
SEC-008 authoritative instructor assignment and scoped registration access;
SEC-014 lane-block reason minimization;
SEC-009 10B retention policy and implementation before scaled multi-tenant operation.
```

This re-audit changed only this report. It performed no code, SQL, migration,
RLS/ACL, configuration, production database, deployment, commit or push action.
