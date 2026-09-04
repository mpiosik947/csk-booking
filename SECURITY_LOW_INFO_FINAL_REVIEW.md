# CSK Booking — Security LOW / INFO Final Review

## Scope and verification basis

This is a read-only triage of the six findings originally classified as LOW or
INFO in `SECURITY_AUDIT_FINAL.md`. It was performed on 2026-09-04 at:

```text
HEAD: c5ca976 docs: record SEC-011 production smoke pass
Initial working tree: clean
```

The review used the current application code, migrations, security remediation
and verification reports, and the production smoke report. It did not change
application code, SQL, migrations, RLS, ACL, configuration, or production data.
The only repository change made by this review is this report.

The already closed HIGH/MEDIUM findings were not reopened. The known deferred
SEC-008 instructor model and SEC-009 time-based retention work are recorded only
as existing security debt, not recast as new LOW findings.

## Inventory and current conclusions

| SEC-ID | Original title | Original severity | Original evidence | Current affected component | Current status | Current severity | Decision |
|---|---|---:|---|---|---|---:|---|
| SEC-012 | Brak aplikacyjnych security headers | LOW | Empty `next.config.ts`; no CSP, frame protection, Referrer-Policy, or Permissions-Policy | Global Next.js response configuration and production HTTP headers | CONFIRMED | LOW | FIX NOW |
| SEC-013 | Surowe błędy w browser UI/console | LOW | Raw `error.message` and complete error objects in client UI/logging | Auth, account, user reservation, and selected admin Client Components | CONFIRMED | LOW | FIX NOW |
| SEC-014 | `reason` aktywnego lane block widoczny wszystkim userom | LOW | Authenticated global SELECT policy on active `lane_blocks`, including free-text `reason` | `public.lane_blocks` SELECT ACL/RLS; direct PostgREST access | PARTIALLY REMEDIATED | LOW | FIX BEFORE SAAS |
| SEC-015 | Cancellation e-mail bez claim/rate limit | LOW | Repeated request for a cancelled reservation can invoke the provider repeatedly | `POST /api/send-reservation-cancellation` | CONFIRMED | LOW | FIX NOW |
| SEC-016 | Placeholdery w informacji prywatności | INFO | Public page declares that controller/contact details are still to be completed | `app/privacy/page.tsx` | CONFIRMED | INFO | FIX NOW |
| SEC-017 | Storage poza zweryfikowanym zakresem | INFO | Repository did not use Storage, but the linked project inventory was not checked | Supabase Storage | OBSOLETE | NONE | CLOSE |

## SEC-012 — application security headers

### Current verification

`next.config.ts` still contains an empty `NextConfig`. The current repository has
no global CSP or `frame-ancestors`, X-Frame-Options, Referrer-Policy,
Permissions-Policy, or X-Content-Type-Options configuration.

A read-only production header check found HSTS supplied by the hosting layer,
but did not find the application headers listed above on the public root or the
anonymous `/admin` redirect. Hosting therefore mitigates transport downgrade,
but does not close the original finding.

### Practical exploitability

- **Attack path:** an external site can frame a sensitive page unless another
  platform control intervenes; the lack of CSP also removes a useful containment
  layer if an HTML/script injection is introduced later.
- **Required privileges:** none to frame a page; meaningful clickjacking impact
  requires an authenticated victim, usually staff/admin.
- **Impact:** UI redress/clickjacking and increased impact of a future injection;
  there is no evidence here of a current script injection primitive.
- **Likelihood:** low to medium.
- **Single-tenant CSK:** relevant now because privileged admin workflows exist.
- **Before SaaS:** more important as the number of privileged users and origins
  grows.

### Recommendation

**FIX NOW.** Add centrally tested response headers. Start with deterministic
frame protection, nosniff, Referrer-Policy and Permissions-Policy. Introduce CSP
against an explicit Supabase/Vercel/Resend-compatible allowlist, preferably via a
report-only observation stage before enforcement. Test actual production/preview
responses and authenticated navigation rather than only the config source.

## SEC-013 — raw browser errors

### Current verification

The issue remains visible in current code. Examples include raw
`error.message` rendered by login, register, forgot-password, account,
my-events, admin dashboard, admin reservations, and admin check-in screens.
Several Client Components also log complete Supabase error objects, including
admin users, events, my-reservations, and check-in flows. Newer routes often log
only an error code, but this improvement is not consistently applied.

No credential or secret was found in the reviewed statements. The remaining
risk is disclosure of provider diagnostics, table/constraint names, hints, or
request context in the DOM or browser console.

### Practical exploitability

- **Attack path:** deliberately trigger a failed Auth/PostgREST/RPC request and
  inspect UI text or DevTools.
- **Required privileges:** none for public Auth screens; an account with the
  relevant role for admin-only screens.
- **Impact:** reconnaissance and internal schema/diagnostic disclosure, not
  direct data modification.
- **Likelihood:** medium; triggering errors is straightforward, while useful
  sensitive detail depends on the upstream error.
- **Single-tenant CSK:** low but real diagnostic leakage.
- **Before SaaS:** more important because tenant/resource identifiers and more
  varied database errors can appear.

### Recommendation

**FIX NOW.** Use stable user-facing error codes/messages and a small redacted
client logger. Preserve the existing intentional mappings such as invalid login
and password validation. Add tests proving that injected SQL details, hints,
table names, JWTs, and tokens do not reach DOM text or console arguments.

## SEC-014 — lane-block reason exposure

### Current verification

The normal Booking UI now obtains only typed busy ranges from
`get_lane_booking_busy_ranges_v3`; its public shape is `start_time`, `end_time`,
and `busy_type`, so Booking no longer needs or displays `lane_blocks.reason`.
This is a material minimization of the original UI path.

The database path remains open to every authenticated user:

- `authenticated` retains table SELECT on `public.lane_blocks`;
- `Anyone can view active lane blocks` allows every authenticated user to read
  every active row;
- RLS filters rows, not columns, so direct PostgREST SELECT can still request
  the free-text `reason` column.

Staff Calendar/management code legitimately consumes the reason. No production
row containing actual PII was identified, so the original potential-data claim
is not promoted beyond LOW.

### Practical exploitability

- **Attack path:** any signed-in user directly selects active lane blocks through
  PostgREST and requests `reason`.
- **Required privileges:** an ordinary authenticated account.
- **Impact:** exposure of operational notes and accidental PII if staff entered
  such content.
- **Likelihood:** low; the access is deterministic, but sensitive content in the
  free-text field is unconfirmed.
- **Single-tenant CSK:** limited to one organization's operational notes.
- **Before SaaS:** materially more important; global/mis-scoped notes must not
  cross tenant or customer boundaries.

### Recommendation

**FIX BEFORE SAAS.** Keep a minimal availability DTO for customer flows and move
staff reason access behind a staff-scoped reader/view/RPC before removing broad
direct table visibility. Add column-contract and direct PostgREST negative tests.
Document that `reason` must not contain customer PII in the interim.

## SEC-015 — cancellation e-mail replay

### Current verification

The cancellation endpoint now has proper Bearer authentication, ownership/staff
authorization, a cancelled-status check, controlled error responses, and SEC-006
HTML escaping. It still calls the e-mail provider directly on every accepted
request. There is no cancellation delivery claim, unique delivery record,
idempotency key, or route-specific rate limit. Existing `email_deliveries`
semantics cover confirmation flows, not cancellation delivery.

The original finding therefore remains confirmed. Authentication reduces its
scope but does not prevent replay.

### Practical exploitability

- **Attack path:** replay the authenticated cancellation-email request for a
  reservation that remains cancelled.
- **Required privileges:** the reservation owner; admin/employee authorization
  broadens the operational scope if such a session is abused.
- **Impact:** repeated e-mail, provider cost, nuisance/spam, and possible sender
  reputation damage; no additional database mutation was established.
- **Likelihood:** medium because replay is simple.
- **Single-tenant CSK:** relevant now due to operational cost and recipient harm.
- **Before SaaS:** risk grows with volume and tenants.

### Recommendation

**FIX NOW.** Add an atomic, purpose-specific delivery claim/idempotency contract
and a bounded retry/rate-limit policy. A second successful request must not send
a second message. Cover concurrent requests, provider failure/retry, claim
expiry, and a no-second-send assertion. Do not treat a generic catch-all 429 as
a substitute for idempotency.

## SEC-016 — privacy notice placeholders

### Current verification

The production-facing source still states that controller contact data will be
completed before production and renders `Do uzupełnienia` plus blank entity,
address, e-mail, and phone fields. This is no longer merely a pre-launch note:
the system and production security smokes are live.

### Practical exploitability

- **Attack path:** none in the technical intrusion sense; any visitor can observe
  incomplete controller/contact information.
- **Required privileges:** none.
- **Impact:** transparency/compliance and incident-contact weakness.
- **Likelihood:** certain visibility when the privacy page is opened.
- **Single-tenant CSK:** relevant now.
- **Before SaaS:** the controller/processor and tenant responsibilities will need
  a broader legal review, not just placeholder replacement.

### Recommendation

**FIX NOW.** Obtain approved controller identity and contact details from the
business/legal owner, replace every placeholder, review the whole notice against
actual processing, and add a content test that rejects placeholder markers.

## SEC-017 — Supabase Storage

### Current verification

The repository still has no Storage client use, bucket configuration, upload
flow, signed-URL flow, or Storage policy migration. A read-only inventory of the
linked Supabase Storage project returned no paths/buckets/objects. There is no
current application Storage attack surface to assess.

### Practical exploitability

- **Attack path:** none in the current product.
- **Required privileges:** not applicable.
- **Impact and likelihood:** none for the current deployment.
- **Single-tenant CSK:** no effect.
- **Before SaaS:** re-open only if Storage is introduced.

### Recommendation

**CLOSE.** Record Storage policy/ACL tests as an entry criterion for any future
feature that creates a bucket or uploads an object.

## Regression and security-hygiene review

### Security headers and framing

Concrete gap remains and is fully represented by SEC-012. Production supplies
HSTS, but application-defined CSP/frame/referrer/permissions/nosniff controls
are absent. No separate duplicate finding is created.

### Cookie and session configuration

Auth uses `@supabase/ssr` browser/server clients and middleware cookie bridging.
No application token storage in `localStorage`, `sessionStorage`, or manually
constructed `document.cookie` was found. The prior production refresh review
classified the stale refresh-token symptom as LOW impact with no required fix.
There is no concrete evidence in this review of a new cookie/session regression.

### Debug output and raw errors

No tracked `.env`, debug log, backup, or temporary file was found. Raw client
errors remain and are accounted for by SEC-013. API routes reviewed during the
remediations generally expose stable responses and log bounded error codes.

### Source maps

`productionBrowserSourceMaps` is not enabled and no custom production source-map
publication was found. The Next.js default therefore remains in force. No
finding is supported by current evidence.

### Cache control

Sensitive account export/delete and admin calendar-feed routes explicitly use
`no-store`/`private, no-store`; confirmation responses also use `no-store` where
needed. Public static content may be cached. No response containing private data
was demonstrated to be publicly cacheable, so no new finding is created.

### Service-role use

Runtime references are confined to server-only delivery/lifecycle modules:
confirmation delivery, reserve promotion, and account deletion. Security tests
and completed remediations enforce normal anon/JWT contracts for public/user
flows. No new unnecessary browser/public service-role use was found.

### Environment hygiene

`.env*` is ignored and no environment file is tracked. No credential, token,
connection string, or production fixture was found in the reviewed working-tree
inventory. This review did not print secret values.

### Deprecated middleware and Next.js warnings

The project still uses `middleware.ts`; Next.js 16 reports the convention as
deprecated in favor of the proxy convention. SEC-011 tests and its production
smoke demonstrate fail-closed route authorization in the current version. The
warning is a maintenance/migration item, not current evidence of an authorization
bypass, and is not promoted to a security finding.

### Managed platform and framework observations

The broad `Access-Control-Allow-Origin: *` observed on a public static page is
not evidence of credentialed private-data exposure by itself. No current API
leak was demonstrated. Likewise, no new security-relevant Next.js warning was
identified beyond the middleware deprecation already noted.

## Known accepted / deferred security debt

| Item | Current severity | Status | Required future action |
|---|---:|---|---|
| SEC-004 multi-tenant isolation | HIGH before SaaS | DEFERRED TO SAAS ARCHITECTURE | Add authoritative tenant ownership, tenant-scoped RLS/RPC/storage/background jobs before serving multiple organizations. This is not claimed as remediated. |
| SEC-008 instructor event-registration access | MEDIUM | DEFERRED / BLOCKED BY DATA MODEL | Approve and implement `event ↔ instructor` assignment plus minimal participant DTO, then remove instructor global table access. |
| SEC-009 10B time-based retention | LOW | DEFERRED pending retention-period decisions | Approve legal/business periods for tokens, delivery/rate-limit metadata, cancelled records, audits, and financial history before scheduling deletion/anonymization. Core export/self-delete lifecycle is already remediated. |
| SEC-010 leaked-password protection | LOW | ACCEPTED RESIDUAL — PLAN LIMITATION | Production minimum 12 and application consistency passed; enable breached-password protection after a supporting plan upgrade. |
| Managed `supabase_admin` default ACL | LOW | ACCEPTED PLATFORM RISK | Current application objects owned by this role: zero. Keep ownership/default-ACL detection fail-closed and review any future managed-owner object before release. |

These are existing decisions. They are not new LOW findings and their severity is
not escalated by this review.

## Final action plan

### P1 — must fix before final re-audit

1. **SEC-012:** add and verify application security headers.
2. **SEC-013:** replace raw client errors with stable messages/redacted logging.
3. **SEC-015:** make reservation-cancellation e-mail delivery atomic/idempotent
   and bounded against replay.
4. **SEC-016:** replace the public privacy placeholders with approved content.

These four are concrete findings that the current HEAD still reproduces. A final
re-audit performed now would be expected to report them again.

### P2 — worth fixing before SaaS

1. **SEC-014:** remove direct authenticated access to lane-block reason after a
   staff-scoped replacement reader is available.
2. **SEC-008:** implement the approved instructor-assignment model and scoped DTO.
3. **SEC-009 10B:** decide and implement retention periods.
4. Migrate `middleware.ts` to the supported Next.js proxy convention with the
   existing SEC-011 fail-closed matrix preserved.

SEC-004 tenant isolation is a separate **hard prerequisite** for SaaS, not a P2
cosmetic hardening item.

### P3 — accepted, deferred, or closed

- **SEC-017:** CLOSE while Storage remains unused and empty.
- **SEC-010 breached-password check:** accepted until plan support is available.
- **Managed `supabase_admin` ACL residual:** accept with the existing ownership
  detector and release gate.

## Final verdict

```text
LOW/INFO READY FOR FINAL RE-AUDIT:
NO

BLOCKERS BEFORE FINAL RE-AUDIT:
SEC-012, SEC-013, SEC-015, SEC-016

BLOCKERS BEFORE SAAS:
SEC-004 tenant isolation;
SEC-008 authoritative instructor assignment and scoped participant access;
SEC-014 lane-block reason minimization;
SEC-009 10B retention decisions and implementation.
```

No application code, migration, RLS/ACL, configuration, production data, commit,
push, or deployment was performed.
