# CSK Booking — Security Remediation 12

## SEC-012 — Application Security Headers

**Original severity:** LOW  
**Implementation base:** `fc7e8b5 docs: review remaining low security findings`  
**Date:** 2026-09-04

## Before

`next.config.ts` contained no response-header configuration. A read-only check of
the current production deployment at `https://csk-booking-5nwh.vercel.app`
produced the following inventory before implementation:

| Route | HTTP | Application security headers | Cache-Control | Platform header |
|---|---:|---|---|---|
| `/` | 200 | none of the SEC-012 baseline | `public, max-age=0, must-revalidate` | Vercel HSTS |
| `/login` | 200 | none | `public, max-age=0, must-revalidate` | Vercel HSTS |
| `/account` | 200 | none | `public, max-age=0, must-revalidate` | Vercel HSTS |
| `/admin` (anonymous) | 307 | none | `public, max-age=0, must-revalidate` | Vercel HSTS |
| `/api/account/export` (anonymous) | 401 | route-level `nosniff` only | `no-store` | Vercel HSTS |
| `/check-in/[synthetic-invalid-token]` | 200 | metadata-level referrer protection only | `private, no-cache, no-store, max-age=0, must-revalidate` | Vercel HSTS |
| `/events/confirm/[synthetic-invalid-token]` | 200 | no global baseline | `private, no-cache, no-store, max-age=0, must-revalidate` | Vercel HSTS |

No request mutated data. The two token values were deliberately invalid probes.

Vercel supplies:

```text
Strict-Transport-Security: max-age=63072000; includeSubDomains; preload
```

The application did not supply Content-Security-Policy,
X-Content-Type-Options, Referrer-Policy, X-Frame-Options,
Permissions-Policy, Cross-Origin-Opener-Policy, or
Cross-Origin-Resource-Policy globally. HSTS is therefore kept as a hosting-layer
control rather than duplicated in application configuration.

## Threat model

| Missing control | Practical impact in this application |
|---|---|
| Frame protection | A malicious origin could attempt to frame login/admin UI and perform clickjacking against an authenticated victim. |
| MIME nosniff | A browser could interpret a response more permissively than its declared content type. |
| Referrer policy | Full paths, including token-bearing paths, could be sent as referrers unless a page-specific override intervened. |
| CSP | The browser had no application allowlist or containment for future injection. No current XSS primitive was established. |
| Permissions policy | Unused camera, microphone, location, sensor, payment, and USB capabilities were not explicitly disabled. |
| Private cache policy | Dynamic token pages and selected APIs were already protected, but authenticated/admin shells were not covered by an explicit central policy. |

The finding remains LOW: this remediation does not claim evidence of an active
XSS or cache leak.

## Headers added or changed

`next.config.ts` now applies one central baseline to all application paths:

```text
Content-Security-Policy: <policy documented below>
X-Content-Type-Options: nosniff
Referrer-Policy: strict-origin-when-cross-origin
X-Frame-Options: DENY
Permissions-Policy: accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()
Cross-Origin-Opener-Policy: same-origin
```

`frame-ancestors 'none'` is the authoritative modern frame restriction;
X-Frame-Options DENY is retained as a compatible legacy defense. The application
has no current iframe, OAuth-popup, or cross-origin opener workflow requiring a
weaker policy.

Cross-Origin-Resource-Policy was reviewed but not added globally. Applying it to
every document and asset without a demonstrated cross-origin resource threat
would add compatibility risk without closing a concrete part of SEC-012.

## CSP

The production CSP is:

```text
default-src 'self';
base-uri 'self';
form-action 'self';
frame-ancestors 'none';
object-src 'none';
script-src 'self' 'unsafe-inline';
script-src-attr 'none';
style-src 'self' 'unsafe-inline';
img-src 'self' data: blob:;
font-src 'self' data:;
connect-src 'self' <exact Supabase HTTP(S) origin> <exact Supabase WS(S) origin>;
frame-src 'none';
manifest-src 'self';
worker-src 'self' blob:
```

The Supabase origins are derived from the validated
`NEXT_PUBLIC_SUPABASE_URL`; only `http:` or `https:` inputs are accepted. An
invalid or missing URL fails closed to `connect-src 'self'`. No broad `*` source
is used. Resend is server-side and requires no browser CSP exception. Current
images and fonts are same-origin/local.

Production does not allow `unsafe-eval`. Development adds `unsafe-eval` only for
the Next.js development runtime. The production build and browser smoke confirm
that the production policy supports current hydration, images, Auth UI, token
pages, and API calls.

### Residual CSP limitation

Next.js currently emits inline bootstrap scripts and the UI uses inline-capable
styling, so `unsafe-inline` remains in `script-src` and `style-src`. Removing it
safely requires a nonce/hash design and dynamic response plumbing beyond this
minimal LOW-severity remediation. The CSP still provides material protection via
exact origins, `default-src`, `object-src 'none'`, `base-uri`, `form-action`, and
`frame-ancestors`.

A future staged hardening may introduce report-only telemetry, nonces/hashes,
and then removal of `unsafe-inline`. This residual is not represented as complete
script-injection prevention. Inline event-handler attributes remain blocked by
`script-src-attr 'none'`.

## Private cache behavior

Caching was not disabled globally. Public pages remain eligible for normal Next
static caching.

The following paths now receive an explicit central policy:

```text
Cache-Control: private, no-store, max-age=0, must-revalidate
```

- all `/api/*` responses;
- `/account`;
- `/dashboard`;
- `/my-events`;
- `/my-reservations`;
- `/reset-password`;
- all `/admin/*` responses and redirects;
- `/check-in/*`;
- `/events/confirm/*`.

The two bearer-token paths additionally receive:

```text
Referrer-Policy: no-referrer
```

Route-specific existing `no-store` behavior is preserved and aligned with the
central policy. Local production-mode response checks confirmed that Next.js did
not overwrite the targeted private cache headers.

## Tests

### Focused SEC-012

```text
node --test lib/server/security-headers.test.mjs
PASS — 5/5
```

The tests cover:

- the full global baseline;
- production CSP directives;
- exact HTTP(S)/WS(S) Supabase origins;
- absence of production `unsafe-eval` and broad wildcard sources;
- development-only eval support;
- fail-closed invalid Supabase URL handling;
- public, private, admin, API, and token route rules;
- no-store and token-specific no-referrer behavior.

### Runtime response and browser smoke

A local `next start` production build returned the configured headers for:

```text
/
/login
/account
/admin
/api/account/export
/check-in/[synthetic-invalid-token]
/events/confirm/[synthetic-invalid-token]
```

Observed results:

- public/login responses: 200;
- account response: 200 with private no-store;
- anonymous admin navigation: redirect to login with private no-store;
- anonymous account export: 401 with private no-store;
- both invalid token pages: controlled 200 with private no-store and
  no-referrer;
- headless Chromium navigation across the same page set: zero console or page
  errors;
- Next hydration and local assets loaded under the CSP.

### Full regression

```text
All Node tests: PASS — 580/580
TypeScript: PASS — npx.cmd tsc --noEmit
Build: PASS — Next.js 16.3.4, 37/37 pages generated
npm audit --omit=dev: PASS — 0 vulnerabilities
Focused ESLint (changed implementation/test): PASS
git diff --check: PASS
```

Full ESLint reproduced exactly the known baseline:

```text
KNOWN ESLINT BASELINE: 14 errors / 6 warnings
NEW SECURITY REMEDIATION ESLINT REGRESSIONS: 0
```

The existing Next.js warning that `middleware.ts` is deprecated in favor of the
proxy convention is unchanged and outside SEC-012. No SQL changed, so database
tests were not required.

## Deployment

```text
APP ONLY
```

No database migration, RLS/ACL change, environment-variable addition, or Vercel
configuration change is required. The existing production Supabase URL is read
at build time to create exact CSP connect origins.

Required post-deployment production smoke:

1. verify the new commit is the active Vercel production deployment;
2. repeat header checks for `/`, `/login`, `/account`, `/admin`, one safe API
   response, and both synthetic-invalid token paths;
3. verify exact production Supabase HTTPS and WSS origins in `connect-src`;
4. verify HSTS is still supplied once by Vercel;
5. open login, authenticated account/admin navigation, public Booking, and both
   token pages while checking browser CSP violations;
6. confirm API/Auth/Supabase calls and local images work;
7. confirm private routes and API responses remain `private, no-store`.

STOP deployment if the CSP contains a local origin, lacks the production
Supabase origin, emits `unsafe-eval`, or the browser reports blocked required
resources.

## Residual

- `unsafe-inline` remains for current Next.js script/style compatibility; nonce
  hardening is explicitly deferred as a separate, staged improvement.
- HSTS remains platform-provided and must be rechecked after deployment/domain
  changes.
- Production response validation is pending deployment of this app-only change.
- SEC-013, SEC-014, SEC-015, and SEC-016 were not modified.

## Verdict

```text
SEC-012 FULLY REMEDIATED
```

The missing baseline, framing, MIME, referrer, browser-permission, opener, and
private-cache protections are implemented and verified locally. The verdict is
for the code remediation; the prepared Vercel smoke remains the required
deployment confirmation.
