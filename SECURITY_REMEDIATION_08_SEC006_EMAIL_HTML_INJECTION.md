# SECURITY REMEDIATION 08 — SEC-006 EMAIL HTML INJECTION

SEC-ID: SEC-006
Original severity: MEDIUM

## Before

The reservation confirmation, reservation cancellation, and event registration
confirmation routes escaped dynamic HTML values, but each route carried a local
copy of the escaping logic. The reserve-promotion and confirmed-place email
flows interpolated recipient names, event titles, locations, dates, times,
prices, and links directly into HTML. A value such as
`<img src=x onerror=alert(1)>` could therefore become email markup in those two
flows.

No email template intentionally accepts trusted business HTML.

## Affected email flows and inventory

| Flow | Dynamic source and fields | Control | Before | After |
|---|---|---|---|---|
| Reservation confirmation | reservation `customer_name`, date/time, price; admin lane name; configured/request origin and generated check-in token | Mixed user/admin/system | Escaped by a local helper; URL protocol not explicitly constrained | Central text escaping; link restricted to absolute HTTP(S) and attribute-escaped |
| Reservation cancellation | reservation/profile display name, date/time; admin lane name | Mixed user/admin | Escaped by a local helper | Central text escaping |
| Event registration confirmation | registration `customer_name`; admin event title, location, date/time, price; controlled status; configured/request origin | Mixed user/admin/system | Escaped by a local helper; URL protocol not explicitly constrained | Central text escaping; link restricted to absolute HTTP(S) and attribute-escaped |
| Event reserve promotion | registration `customer_name`; admin event title, location, date/time, price; configured/request origin and generated promotion token | Mixed user/admin/system | Dynamic values were interpolated without escaping | Every dynamic HTML value escaped; link restricted to absolute HTTP(S) and attribute-escaped |
| Confirmed reserve place | registration `customer_name`; admin event title, location, date/time, price; configured site URL | Mixed user/admin/system | Dynamic values were interpolated without escaping | Every dynamic HTML value escaped; link restricted to absolute HTTP(S) and attribute-escaped |

Recipient email addresses are passed to the provider as envelope data and are
not interpolated into HTML. Event descriptions, notes, postal addresses, and
other profile fields are not present in these templates. Subjects are static.

## Threat model results

| Input | Result after remediation |
|---|---|
| `<script>alert(1)</script>` | `&lt;script&gt;alert(1)&lt;/script&gt;` — DENIED as markup |
| `<img src=x onerror=alert(1)>` | `&lt;img src=x onerror=alert(1)&gt;` — DENIED as markup |
| `<b>Injected</b>` | `&lt;b&gt;Injected&lt;/b&gt;` — DENIED as markup |
| `<a href="javascript:alert(1)">link</a>` in a text field | Escaped as text — DENIED as markup |
| `javascript:`, `data:`, `mailto:`, malformed or relative href | Rejected — DENIED |
| `Jan & Anna` | `Jan &amp; Anna` |
| `"O'Connor"` | `&quot;O&#39;Connor&quot;` |

## Escaping strategy

`lib/server/email-html.ts` is the single implementation point:

- `escapeHtml()` encodes `&`, `<`, `>`, `"`, and `'` in dynamic text;
- `escapeEmailHref()` requires a valid absolute URL with `http:` or `https:`,
  then applies HTML attribute escaping;
- complete template HTML is never sanitized or escaped, so structural markup is
  preserved;
- plain-text bodies continue to interpolate ordinary text and URLs without HTML
  entities.

The URL inputs are application configuration, request origin, and
cryptographically generated application tokens. No arbitrary profile or event
text is accepted as an href.

## Files changed

- `lib/server/email-html.ts`
- `lib/server/email-html.test.mjs`
- `lib/server/event-reserve-promotion.ts`
- `lib/server/event-reserve-confirmation-email.ts`
- `app/api/send-event-registration-confirmation/route.ts`
- `app/api/send-reservation-confirmation/route.ts`
- `app/api/send-reservation-cancellation/route.ts`
- `SECURITY_REMEDIATION_08_SEC006_EMAIL_HTML_INJECTION.md`

No SQL, migration, database object, ACL, RLS policy, or email business content
was changed.

## Tests

- Focused SEC-006 and adjacent email tests: 38/38 PASS before the final report
  update; the SEC-006 suite itself contains four focused tests.
- The focused suite verifies all required character mappings, both injection
  payloads, single escaping, retained structural HTML, central-helper use in all
  five flows, safe href schemes, and unescaped plain-text bodies.
- All Node tests: 546/546 PASS.
- TypeScript (`npx.cmd tsc --noEmit`): PASS.
- Next.js production build: PASS.
- ESLint on changed implementation and test files: PASS, zero findings.
- Full ESLint: KNOWN ESLINT BASELINE — 14 errors / 6 warnings.
- NEW SECURITY REMEDIATION ESLINT REGRESSIONS: 0.
- `npm audit --omit=dev`: 0 vulnerabilities.
- `git diff --check`: PASS.
- Supabase DB tests: not run because remediation is application-only and does
  not change SQL or database behavior.

## Compatibility

| Combination | Result |
|---|---|
| OLD APP + OLD DB | Existing behavior; vulnerable email HTML flows remain until application deployment |
| NEW APP + OLD DB | Compatible and remediated; no database contract changed |
| NEW APP + NEW DB | Compatible and remediated; no database change is required |

## Deployment recommendation

APP-ONLY deployment. No migration, database rollout, or coordinated compatibility
window is required.

## Regression risk

LOW. Text output and business semantics are unchanged. The intentional
fail-closed difference is that a malformed or non-HTTP(S) configured email link
is rejected instead of being emitted into HTML.

## Verdict

**SEC-006 FULLY REMEDIATED**
