# CSK Booking — Independent Clean-Room Security Audit V2

**Audit date:** 4 September 2026

**Repository:** CSK Booking

**Branch:** `main`

**Audited HEAD:** `b741a05 docs: add final security re-audit`

**Method:** read-only source, configuration, migration, local reconstructed-schema and test review

## 1. Executive Summary

The current single-tenant application has no newly discovered critical or high-severity production vulnerability. Authentication, server-side authorization, public-token minimization, e-mail escaping, rate limiting, account anonymization, audit-log protection, dependency hygiene and application security headers are materially stronger than the original baseline.

The fresh review found nine items. Seven map to explicitly documented residuals. Two are newly classified medium risks even though their underlying grants were listed in an earlier ACL inventory:

- an authenticated administrator can directly hard-delete any reservation through PostgREST, bypassing the controlled cancellation/audit path;
- an authenticated administrator can directly insert profiles and update a broad set of profile fields outside the controlled administrative RPC/audit paths.

Both require a valid administrator identity, so neither is a public privilege escalation. They do, however, create avoidable alternate mutation paths around integrity and audit controls. Until they are removed or explicitly accepted, the current deployment is rated **NOT READY** for an unconditional security sign-off.

The product remains **NOT READY** for a second tenant: authorization, resources, operational records, audit and staff roles are global and have no tenant scope.

### Scope and clean-room limitation

The substantive findings below were derived and frozen from current code, migrations, configuration and the local reconstructed database before the historical reports were used for comparison. Because this audit was performed in the same long-running task that had previously handled security reports, strict epistemic isolation from all prior knowledge was impossible. To minimize that limitation, no previous SEC identifier was used to structure the fresh review; historical mapping appears only in section 17.

## 2. Architecture / Trust Boundaries

```text
Browser
  | cookies/JWT, user input, public bearer tokens
  v
Next.js (Vercel)
  | verified user JWT or narrowly scoped server credential
  +--> Supabase Auth
  |      \-- trusted user identity
  +--> PostgREST / PostgreSQL
  |      +-- RLS and table ACL
  |      +-- SECURITY DEFINER RPC with auth.uid()/role/ownership checks
  |      \-- audit, booking, event, configuration and lifecycle state
  \--> Resend
         \-- recipient and escaped HTML/plain-text e-mail content
```

Trust decisions are made server-side or in PostgreSQL. Browser state selects UX but is not authoritative for identity, role, ownership, price, reservation status or audit actor. JWTs cross the browser/Next.js/Supabase boundary; PII and public workflow tokens cross application/database boundaries; server-only delivery and Auth Admin operations use elevated credentials.

Principal roles are `anon`, ordinary authenticated `user`, `instruktor`, `pracownik`, `admin`, PostgreSQL owner `postgres`, and `service_role`. The current role model is installation-global.

## 3. Fresh Findings CLEAN-*

### CLEAN-001 — No tenant isolation model

- **Severity:** HIGH for a second tenant; architectural blocker rather than a current single-tenant exploit
- **Component:** all business tables, RLS helpers, role model, RPCs and audit
- **Evidence:** no `tenant_id`, organization membership or tenant-bound staff role was found; helpers such as `is_admin_or_staff()` are global; reservations, events, lanes, configuration and audit are not tenant-scoped.
- **Attack path:** after adding a second customer/organization without redesigning authorization, a staff role or global query/RPC can cross organization boundaries.
- **Prerequisites:** a second tenant is introduced under the current schema and authorization model.
- **Impact:** cross-tenant PII disclosure and cross-tenant operational mutations.
- **Exploitability:** not applicable to the present single-tenant installation; high once tenant data is colocated.
- **Single-tenant impact:** no demonstrated cross-customer boundary exists today.
- **SaaS impact:** release blocker.
- **Recommendation:** add an explicit tenant/membership model and propagate tenant checks through tables, RLS, RPCs, audit, rate limiting and server routes before onboarding a second tenant.

### CLEAN-002 — Instructor can read global event-registration PII

- **Severity:** MEDIUM
- **Component:** `public.event_registrations`, `public.is_admin_or_staff()`, `app/admin/events/page.tsx`
- **Evidence:** the staff SELECT policy uses `is_admin_or_staff()`, which includes `instruktor`; `loadRegistrations()` performs `.select("*")`. The table includes customer name, e-mail, phone and promotion/delivery fields.
- **Attack path:** any authenticated instructor opens the event participant UI or queries PostgREST and reads registrations for unrelated events.
- **Prerequisites:** valid instructor account.
- **Impact:** broad PII and workflow-metadata disclosure.
- **Exploitability:** medium.
- **Single-tenant impact:** real confidentiality exposure.
- **SaaS impact:** more severe because the global role would also cross tenants.
- **Recommendation:** first add an authoritative instructor-to-event assignment relation, then scope RLS and return an allowlisted operational DTO. Do not infer assignment from unrelated fields.

### CLEAN-003 — Active lane-block reasons are readable by every authenticated user

- **Severity:** LOW
- **Component:** `public.lane_blocks`
- **Evidence:** `Anyone can view active lane blocks` grants authenticated SELECT for every active row, while `reason` is staff-authored free text; user-facing booking needs only busy ranges/status, not the reason.
- **Attack path:** an ordinary user directly queries active lane blocks and reads operational notes that may contain incidental PII.
- **Prerequisites:** any authenticated account and staff entering sensitive text in `reason`.
- **Impact:** limited operational-information or incidental-PII disclosure.
- **Exploitability:** low.
- **Single-tenant impact:** limited but concrete.
- **SaaS impact:** requires tenant scoping and DTO minimization.
- **Recommendation:** remove ordinary-user direct table SELECT and expose only the required busy-range contract; retain reasons for authorized staff views.

### CLEAN-004 — Administrator direct hard-delete bypasses reservation lifecycle controls

- **Severity:** MEDIUM
- **Component:** `public.reservations` table ACL/RLS
- **Evidence:** migration `20260902120000_harden_public_table_sequence_acl.sql` grants authenticated `DELETE`; policy `Admins can delete reservations` permits any administrator to delete any row. No reservation DELETE audit trigger exists. Normal application behavior uses controlled reservation RPCs and contains no direct table DELETE call site.
- **Attack path:** a stolen or malicious admin JWT calls PostgREST `DELETE /rest/v1/reservations?...`, physically removes records and bypasses the cancellation, history and audit path.
- **Prerequisites:** valid administrator JWT.
- **Impact:** loss of operational/history records and incomplete audit evidence; potential integrity and dispute-handling impact.
- **Exploitability:** medium after admin compromise, otherwise low.
- **Single-tenant impact:** real integrity/audit risk.
- **SaaS impact:** amplifies across tenant data unless both mutation and tenant scope are fixed.
- **Recommendation:** verify no legitimate direct dependency, revoke authenticated DELETE, remove the direct-delete policy, preserve owner/admin cancellation through controlled RPCs, and add direct-DML denial plus RPC/audit tests.

### CLEAN-005 — Broad administrator profile mutations bypass controlled RPC/audit paths

- **Severity:** MEDIUM
- **Component:** `public.profiles` table ACL/RLS and `prevent_non_admin_profile_privilege_changes()`
- **Evidence:** authenticated receives profile INSERT/UPDATE; admin policies allow all-row INSERT/UPDATE. The trigger protects role, admin note and identity through RPC markers, but then returns immediately for an admin, allowing other contact, declarations, permit/qualification and verification fields to be updated directly. Administrative UI operations otherwise use controlled RPCs.
- **Attack path:** a stolen or malicious admin JWT directly updates profile verification/contact/declaration state with PostgREST, avoiding the intended administrative RPC validation and audit semantics; it can also insert arbitrary profile rows allowed by constraints.
- **Prerequisites:** valid administrator JWT.
- **Impact:** profile/verification integrity loss and incomplete audit trail.
- **Exploitability:** medium after admin compromise, otherwise low.
- **Single-tenant impact:** real integrity/audit risk.
- **SaaS impact:** broader blast radius under a global administrator model.
- **Recommendation:** inventory required self-service fields, remove unnecessary admin direct INSERT/UPDATE policies, route administrative changes through narrowly scoped RPCs, and enforce direct-DML denial with positive RPC/audit tests.

### CLEAN-006 — No deployed time-based retention policy

- **Severity:** LOW
- **Component:** PII snapshots, audit, e-mail delivery and rate-limit data
- **Evidence:** owner export and self-deletion/anonymization exist, but category-specific scheduled retention windows and deletion jobs are not implemented.
- **Attack path:** old PII or pseudonymous operational metadata remains available longer than needed and is exposed if another control fails.
- **Prerequisites:** elapsed retention time plus a later disclosure event or excessive internal access.
- **Impact:** increased historical data exposure and privacy burden.
- **Exploitability:** low as a direct attack.
- **Single-tenant impact:** privacy/compliance debt.
- **SaaS impact:** storage and cross-customer governance risk grows substantially.
- **Recommendation:** decide legal/business periods, then implement auditable category-specific retention without destroying required operational or security evidence.

### CLEAN-007 — Managed `supabase_admin` default privileges remain broad for future objects

- **Severity:** LOW
- **Component:** managed Supabase default ACL
- **Evidence:** current `postgres` defaults and existing application objects are hardened, but provider-managed `supabase_admin` defaults can grant broad privileges to client roles on future objects.
- **Attack path:** a future object created under the managed owner inherits broader rights than its author expects and becomes reachable through PostgREST/RPC.
- **Prerequisites:** creation of a future public-schema object under that managed owner without an explicit ACL migration/test.
- **Impact:** future accidental data or execution exposure.
- **Exploitability:** low today; configuration-dependent.
- **Single-tenant impact:** future-object risk only.
- **SaaS impact:** higher consequence because an accidental grant may expose multiple tenants.
- **Recommendation:** retain the catalog guard test and require explicit ACL review for every new public object; do not fight provider-managed defaults without supported platform guidance.

### CLEAN-008 — CSP still permits inline scripts and styles

- **Severity:** INFO
- **Component:** `next.config.ts`
- **Evidence:** production CSP blocks wildcard sources and `unsafe-eval`, limits connections, blocks inline event attributes and framing, but includes `'unsafe-inline'` in `script-src` and `style-src`.
- **Attack path:** a separate HTML-injection primitive would face weaker CSP containment for inline content.
- **Prerequisites:** an independent injection bug; none was found in React rendering or current e-mail/browser HTML paths.
- **Impact:** reduced defense in depth, not a standalone exploit.
- **Exploitability:** low.
- **Single-tenant impact:** informational residual.
- **SaaS impact:** same class, larger exposure surface.
- **Recommendation:** move to nonce/hash-based CSP only as a separately tested Next.js rollout.

### CLEAN-009 — Privacy/terms retain business-owner placeholders

- **Severity:** INFO
- **Component:** `/privacy`, `/terms`
- **Evidence:** documents describe current technical processing and providers, but final administrator legal name/form/address/privacy contact remain explicitly deferred.
- **Attack path:** no technical compromise; users lack final controller contact details.
- **Prerequisites:** public use before the business entity decision is completed.
- **Impact:** legal/operational completeness risk.
- **Exploitability:** not applicable.
- **Single-tenant impact:** transparency residual.
- **SaaS impact:** must be resolved before broader commercialization.
- **Recommendation:** fill the approved legal identity and contact fields once decided.

## 4. Severity Counts

Fresh inventory, including known residuals:

| Severity | Count |
|---|---:|
| Critical | 0 |
| High | 1 |
| Medium | 3 |
| Low | 3 |
| Info | 2 |

New relative to the historical finding register: **0 Critical, 0 High, 2 Medium, 0 Low**. CLEAN-004 and CLEAN-005 are new security classifications of privileges previously visible in an ACL inventory but not raised as findings.

## 5. Auth / Session Review

- Registration, reset and account password changes share a 12–72 character application policy. Production Auth policy evidence in the repository records the same minimum; leaked-password screening remains unavailable on the current plan.
- Callback redirects and login redirect targets use fixed/local allowlists; no open redirect was found.
- Browser and SSR clients use the Supabase-supported client factories; no custom localStorage token store or manual cookie parsing was found.
- Server routes verify JWTs through `auth.getUser()`. Shared classification distinguishes no/invalid session (401), insufficient role (403), Auth network/5xx outage (503) and unknown server failure (500) without exposing provider details.
- Forgot-password behavior is enumeration resistant. Reset tokens are exchanged through the Auth callback and query credentials are removed from the page URL.
- Middleware fails closed and guards direct admin URLs. API routes also enforce their own server-side authorization and do not rely solely on UI/middleware.
- No session fixation or client-controlled role path was found. A clean authentication outage may redirect protected pages rather than display a 503, but it does not grant access.

## 6. Authorization / IDOR Review

- No request body was found to authoritatively set role, audit actor, owner identity, price or operational status without a server/RPC check.
- Account export and deletion derive the subject from the verified session and accept no arbitrary target user ID.
- Reservation and event-registration user mutations use ownership-aware RPCs; reserve-promotion confirmation is authenticated POST and checks token ownership.
- Admin route authorization uses trusted profile role from the server/database. Unknown `/admin/*` routes fail closed.
- The confirmed authorization exceptions are CLEAN-002, CLEAN-004 and CLEAN-005. CLEAN-003 is data minimization rather than IDOR.

Role summary:

| Capability | anon | user | instructor | employee | admin |
|---|---|---|---|---|---|
| Public booking/config | constrained read | constrained read/create own | constrained read | operational | operational/config where allowed |
| Own reservations/registrations | no | yes | own plus instructor exception below | global operational read/RPC | global operational read/RPC |
| Global event registrations | no | no | **yes (CLEAN-002)** | yes | yes |
| Direct reservation delete | no | no | no | no | **yes (CLEAN-004)** |
| Direct broad profile mutation | no | self-service subset | self-service subset | controlled RPC for scoped work | **yes (CLEAN-005)** |

## 7. DB / RLS / ACL / RPC Review

- The reconstructed current public schema contains 14 tables; all 14 have RLS enabled and are owned by `postgres`.
- Existing table ACLs are substantially minimized. Client roles do not have `TRUNCATE`, `REFERENCES`, `TRIGGER` or `MAINTAIN`; ordinary access is principally SELECT plus the two direct mutation exceptions described above and self-profile updates.
- Public-schema `CREATE` is not granted to PUBLIC/client roles. The four older definer helpers with `search_path=public` qualify `public.profiles`; under the current schema ACL they are not presently exploitable, although the newer `pg_catalog, public, pg_temp` convention is preferable.
- There are 57 public SECURITY DEFINER functions. Only two are anon-executable: the intentionally public booking configuration reader and minimized public check-in lookup. No unexpected PUBLIC EXECUTE exposure was found.
- Definer writers generally derive identity from `auth.uid()`, query the role in `public.profiles`, validate arguments, use qualified relations and expose stable result codes.
- No runtime dynamic SQL or SQL-injection candidate was found.
- Current `postgres` default function/table/sequence ACL is hardened. The managed future-object residual is CLEAN-007.
- The key remaining table-level gaps are CLEAN-004 and CLEAN-005; instructor and lane-block SELECT scope are CLEAN-002 and CLEAN-003.

## 8. `service_role` Review

Active runtime use is server-only and limited to:

- completing account deletion through Supabase Auth Admin after database anonymization;
- e-mail delivery state/rate-limit coordination after caller authentication and ownership/role checks;
- reserve-promotion server processing.

No service-role key reference was found in browser code or public client construction. Routes do not accept an arbitrary role or recipient and then rely on service-role bypass. The elevated client remains capable of bypassing RLS by design, so the current narrow call sites and allowlisted payloads remain security-critical.

## 9. PII Lifecycle Review

- Owner export is parameterless and allowlisted; it excludes admin notes, tokens, credentials, rate-limit internals and foreign-user data.
- Self-deletion anonymizes database data before Auth Admin deletion. The retry case after database success/Auth deletion failure is idempotent and does not restore PII or duplicate the audit.
- Reservation/event history is retained in anonymized form for operational reporting; direct identifiers, contact snapshots, notes and active tokens are cleared/neutralized by the lifecycle contract.
- Audit actors/details are pseudonymized without permitting client audit mutation.
- No reversal path from the pseudonymized lifecycle identifiers was found in application code.
- Category-specific timed retention is still absent (CLEAN-006).

## 10. Token Flows

- Check-in tokens are random UUID bearer values, valid only from reservation start minus 24 hours through reservation end plus 2 hours, invalid after cancellation and idempotent after first check-in. Public lookup returns a minimized DTO; staff lookup is separately authorized.
- Event reserve-promotion GET is read-only. Mutation uses authenticated POST; the RPC derives ownership from `auth.uid()` and denies cross-user use.
- Token pages use no-referrer and private/no-store headers. Query tokens can still appear in browser history and infrastructure request metadata as an inherent bearer-link residual; no application logging of full tokens was found.
- Password reset continues through Supabase Auth's token exchange rather than a custom bearer implementation.

## 11. Email / Abuse Review

- Dynamic HTML is escaped centrally and link-bearing templates accept only absolute HTTP(S) URLs. Plain-text bodies remain plain text.
- Recipient addresses are resolved from trusted database/profile records; callers cannot submit arbitrary recipients to the hardened delivery paths.
- Confirmation and cancellation delivery use database-backed claim/lease and completion state. Success and in-progress/already-sent outcomes prevent duplicate delivery; provider errors are reduced to stable codes.
- User and HMAC-IP rate limits are enforced before delivery. Production requires a valid forwarded IP; the deployed Vercel boundary is relied upon to supply the authoritative forwarding header.
- No full token, raw IP, provider body, authorization header or service-role key logging was found.

## 12. Concurrency Review

- Reservation creation and lane conflict checks are transactionally serialized at resource-family level and use half-open interval conflict rules.
- Event registration/capacity, reserve promotion, payment/check-in transitions and configuration writers use row/advisory locking, no-change handling or optimistic versions appropriate to the flow.
- E-mail delivery claims prevent parallel sends; completion failure does not blindly resend.
- Account anonymization uses an advisory lock and idempotent audit semantics.
- Database invariant tests exercise the cross-writer cases. No new check-then-act race with a demonstrated security impact was found.

## 13. Frontend / CSP / Cache / Error Review

- React rendering does not use `dangerouslySetInnerHTML`, direct `innerHTML`, `eval` or dynamic script construction.
- User-visible errors are stable and generic; server diagnostics are limited to operation/stable codes. No raw SQL details, provider bodies or secret-bearing request objects were found in active logging.
- Global CSP has no wildcard source and no production `unsafe-eval`; `connect-src` is restricted to self and the configured Supabase HTTP/WebSocket origins. Objects, framing and inline event-handler attributes are blocked.
- `X-Content-Type-Options`, frame protection, Referrer-Policy, Permissions-Policy and COOP are applied centrally. Private/admin/API and token routes use private/no-store controls.
- CLEAN-008 records the remaining inline-script/style CSP compromise. No current DOM-XSS primitive was found that makes it independently exploitable.

## 14. Secrets / Dependencies Review

- No tracked `.env` or credential file, embedded service-role/Resend secret, bearer token, database password or production fixture was found in the reviewed tree.
- Environment-variable names appear where expected, but values are not committed or emitted by the application.
- No explicit browser production source-map publication was enabled.
- Production dependency versions at audit time: Next.js `16.3.4`, PostCSS `8.5.23`, NanoID `3.3.18`, Sharp `0.35.4`, `@supabase/ssr` `0.10.3`, `@supabase/supabase-js` `2.105.4`, React/React DOM `19.2.4`, Resend `6.12.4`, `react-qr-code` `2.2.0`.
- `npm audit --omit=dev` reported **0 vulnerabilities**.
- Build emits a Next.js deprecation warning for the `middleware` file convention. This is maintenance debt, not a current authorization bypass; the route-protection tests and build pass.

## 15. SaaS Readiness

### Current single-tenant

The global installation boundary is coherent, and no public cross-account critical/high vulnerability was found. The two new admin alternate-write paths remain unaccepted medium integrity/audit risks, so the current unconditional verdict is NOT READY pending remediation or explicit documented acceptance.

### Second tenant / SaaS

The current schema cannot safely represent or enforce tenant ownership. Adding a tenant only in UI or a few routes would leave global RLS helpers, staff roles, functions and operational tables. A tenant migration requires end-to-end data and authorization design, backfill, composite uniqueness decisions, scoped admin roles, tenant-aware RPC tests and a staged rollout.

## 16. Test Results

| Check | Result |
|---|---|
| `node --test` | PASS — 611 tests, 611 passed, 0 failed |
| `npx.cmd supabase test db --local` | PASS — 12 files, 215 tests |
| `npx.cmd tsc --noEmit` | PASS |
| `npm.cmd run build` | PASS — Next.js 16.3.4, 37 routes/pages generated; middleware deprecation warning only |
| `npm.cmd audit --omit=dev` | PASS — 0 vulnerabilities |
| `npx.cmd eslint .` | KNOWN BASELINE — 14 errors, 6 warnings; no files were changed before this run |
| `git diff --check` before report | PASS |

The Node suite prints non-failing module-type performance warnings for several `.js`/`.ts` ESM imports. They do not expose data or change execution semantics in the tested runtime.

## 17. Historical Comparison

Historical reports were opened only after the fresh finding set was frozen.

| Fresh ID | Historical disposition | Comparison |
|---|---|---|
| CLEAN-001 | KNOWN RESIDUAL | Matches the previously deferred multi-tenant/SaaS isolation gap (SEC-004). |
| CLEAN-002 | KNOWN RESIDUAL | Matches the deferred instructor-to-event authorization model (SEC-008); no trustworthy assignment relation yet exists. |
| CLEAN-003 | KNOWN RESIDUAL | Matches the accepted/deferred lane-block reason exposure (SEC-014). |
| CLEAN-004 | **NEW** | Earlier ACL documentation listed authenticated DELETE plus the admin RLS policy and called it an existing path to preserve/review, but did not classify hard-delete bypass of controlled reservation lifecycle/audit as a finding. |
| CLEAN-005 | **NEW** | Earlier reports described direct profile update as allowlisted/trigger-protected and listed broad admin DML for review, but did not identify the trigger's early admin return and remaining unaudited mutation surface as a finding. |
| CLEAN-006 | KNOWN RESIDUAL | Matches deferred category-specific time retention (SEC-009 phase 10B). |
| CLEAN-007 | KNOWN RESIDUAL | Matches the managed Supabase future-object default-ACL residual after SEC-002C. |
| CLEAN-008 | KNOWN RESIDUAL | Matches the acknowledged `unsafe-inline` CSP limitation after SEC-012. |
| CLEAN-009 | KNOWN RESIDUAL | Matches the deferred legal owner/contact fields after SEC-016. |

No finding was removed merely because it had already been reported. No remediation regression was confirmed. The two new items are longstanding ACL/design gaps newly recognized for their security consequence, not newly introduced regressions at this HEAD.

## 18. Known Residual Register

| Residual | Current severity | Current single-tenant impact | SaaS impact | Trigger to reopen |
|---|---|---|---|---|
| Instructor event assignment / CLEAN-002 | Medium | Global participant PII visible to instructors | Cross-tenant PII risk | Before instructor participant access expands or assignment model is added |
| Time-based retention / CLEAN-006 | Low | Privacy/compliance debt | Data-governance scale risk | When retention periods are approved; before SaaS |
| Leaked-password protection plan limitation | Low accepted residual | Reduced breached-password defense | Higher account population increases exposure | Plan/feature becomes available or credential attacks increase |
| Privacy owner/legal data / CLEAN-009 | Info | Transparency/completeness | Commercial/legal blocker | Business entity/contact decision is final |
| Managed Supabase ACL defaults / CLEAN-007 | Low | Future-object risk | Larger future blast radius | Any new managed-owner public object or platform behavior change |
| Tenant isolation / CLEAN-001 | High for SaaS | No present second boundary | Absolute second-tenant blocker | Before designing/onboarding tenant two |
| Lane-block reason exposure / CLEAN-003 | Low | Incidental operational/PII disclosure | Must become tenant- and role-scoped | Before entering sensitive reasons or SaaS |
| CSP `unsafe-inline` / CLEAN-008 | Info | Weaker XSS defense in depth | Same, across a larger surface | A compatible nonce/hash design or any HTML injection finding |

## 19. Priorities

### P0 — immediate production blocker

**NONE.** No unauthenticated critical/high exploit or active production compromise was found.

### P1 — fix before further feature development

- **CLEAN-004:** eliminate authenticated direct hard-delete of reservations and keep controlled lifecycle/audit paths only.
- **CLEAN-005:** eliminate broad direct admin profile mutations not covered by narrow RPC validation/audit.

### P2 — fix before SaaS

- **CLEAN-001:** complete tenant and membership isolation before a second tenant.
- **CLEAN-002:** implement an explicit instructor-event assignment model and scoped registration DTO/RLS.
- **CLEAN-003:** stop exposing lane-block free text to ordinary users.
- **CLEAN-006:** implement approved category-specific retention.
- Resolve CLEAN-004/CLEAN-005 tenant scope as part of their remediation, not as a later UI-only change.

### P3 — accepted/deferred

- CLEAN-007 managed default-ACL risk, guarded by tests/review.
- CLEAN-008 nonce/hash CSP hardening.
- CLEAN-009 final legal owner/contact details.
- Leaked-password screening pending plan capability.
- Next.js middleware-to-proxy migration and ESM package warnings as non-security maintenance.

## 20. Final Verdicts

### Current single-tenant CSK

**NOT READY.** There is no P0, but CLEAN-004 and CLEAN-005 are newly recognized, unaccepted medium integrity/audit gaps. The system can return to **READY WITH ACCEPTED RESIDUALS** after those paths are either remediated with regression tests or consciously accepted with a documented admin-compromise threat decision.

### SaaS / second tenant

**NOT READY.** Tenant isolation is absent by design and must be implemented before any second tenant is introduced.

```text
CLEAN-ROOM AUDIT:
PASS WITH FINDINGS

NEW CRITICAL:
0

NEW HIGH:
0

NEW MEDIUM:
2

NEW LOW:
0

CURRENT SINGLE-TENANT:
NOT READY

SAAS / SECOND TENANT:
NOT READY

P0:
NONE

P1:
CLEAN-004, CLEAN-005

P2:
CLEAN-001, CLEAN-002, CLEAN-003, CLEAN-006

P3:
CLEAN-007, CLEAN-008, CLEAN-009; leaked-password protection plan limitation; non-security maintenance warnings

BLOCKERS BEFORE FURTHER FEATURE WORK:
CLEAN-004 direct reservation hard-delete and CLEAN-005 broad direct admin profile mutation must be remediated or explicitly accepted with documented risk.

BLOCKERS BEFORE SECOND TENANT:
End-to-end tenant/membership isolation (CLEAN-001), scoped instructor event access (CLEAN-002), tenant-safe lane-block visibility (CLEAN-003), retention governance (CLEAN-006), and closure of CLEAN-004/CLEAN-005.
```
