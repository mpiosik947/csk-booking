# PRODUCT-10F operator runbook — not executed in production

## Trust boundary

The HTTP Host is a public selector, not proof of identity. Only exact active verified
DB bindings resolve. Ignore Forwarded and X-Forwarded-Host for tenancy and redirects.
Vercel's verified project-domain binding is the production ingress boundary; no alternate
origin server or wildcard domain should be exposed. Membership/resource authorization
continues independently on the platform. Custom hosts never receive an auth surface.

## Manual domain verification

1. An active Platform Admin adds the exact hostname and requests a challenge in the UI.
   This stores only a SHA-256 digest, requester, version, and 24-hour expiry.
2. The owner publishes `_strzelajtu-verification.<hostname>` TXT with the displayed value.
3. The operator sets `DOMAIN_HOST` and `DOMAIN_TXT_VALUE` in a private environment and
   runs `node scripts/check-domain-dns.mjs`. It performs DNS reads only and never prints
   the challenge. A stale version must be rejected even when an old TXT remains.
4. Separately inspect Vercel project **csk-booking-5nwh**, exact domain, verified ownership,
   valid TLS certificate and configured project deployment. Never attest from a tenant
   supplied screenshot. The DNS check does not establish provider readiness.
5. Only after both checks, the controlled postgres operator calls
   `operator_verify_tenant_domain_v1(domain_uuid, exact_version, observed_txt, 'csk-booking-5nwh', true)`.
   Supply values through a private parameterized operator connection; never log SQL with
   the TXT value. No browser, authenticated role, tenant admin or service_role can execute.
6. The Platform Admin may then activate and choose primary. There is no UI verify bypass.
   Verification and all state changes are audited without raw TXT. Tenant-row locking and
   unique hostname / unique tenant-primary constraints serialize competing changes.

## Canonical and cache strategy

Model B: platform public paths stay available; canonical points to the active primary
custom host, or the platform path if absent. Custom secondary hosts use the same primary
canonical. Host pages are force-dynamic/no-store; RPC requests use no-store and no cookies.
No CDN shared-page cache is permitted in V1. After disable, resolution immediately fails.

## Future production DNS/provider steps — separate authorization required

Add apex `strzelajtu.pl` and `www.strzelajtu.pl` to **csk-booking-5nwh** only.
Keep DNS at dhosting. Set apex A to the exact address recommended by that project's
Domain Settings, and www CNAME to its exact project-specific recommended target.
Do not guess legacy Vercel A/CNAME values, replace MX/TXT, or change nameservers.
Use the application www→apex 308; verify valid certificates for both.
For a tenant subdomain use its provider-recommended CNAME plus our TXT challenge;
for an apex use the provider-recommended A record and TXT. Vercel may require a separate
ownership TXT: retain both until verification is complete. No wildcard tenant binding.
References: https://vercel.com/docs/domains/working-with-domains/add-a-domain
and https://vercel.com/kb/guide/a-record-and-caa-with-vercel .

## Supabase Auth cutover — separate authorization required

Set Site URL to `https://strzelajtu.pl`. Exact allowed callbacks:
`https://strzelajtu.pl/auth/callback` and `https://strzelajtu.pl/reset-password`.
Update new signup/reset confirmations to the canonical config, and inspect hosted email
templates so RedirectTo is honored. Do not add tenant custom domains to Auth redirects.
Clean cutover: NO grace period, expiration timer or legacy callback completion.
After DB/app deployment and non-mutating smoke under the old Auth configuration,
change Site URL to canonical, add the two exact canonical redirects above, and remove
exactly the five currently configured legacy entries:

- `https://krutla.pl/auth/callback`
- `https://krutla.pl/reset-password`
- `https://www.krutla.pl/auth/callback`
- `https://www.krutla.pl/reset-password`
- `https://www.krutla.pl/**`

Actual app: register generates /auth/callback; forgot-password generates /reset-password.
Account updateUser changes metadata/password, not email. No OAuth initiation, magic-link
or email-change initiation is implemented, so no additional redirect is invented.
New initiation and completion belong to the canonical origin only.
Live read-only inventory on 2026-09-25: Site URL `https://www.krutla.pl`, four exact
Krutla completion URLs plus `https://www.krutla.pl/**`; no Vercel completion entries.
Remove the wildcard at the same cutover; target allowlist has two exact URLs only.
There are no existing Vercel redirect entries to remove. Legacy navigation redirects to canonical;
valid tenant-scoped login return paths survive, untrusted returns fail closed.
Krutla public marketing may remain separately hosted, but this application's legacy
host paths redirect to canonical. No tenant authority or cookie bridge is introduced.
Code denies legacy completion immediately and strips old callback tokens when redirecting
to a fresh platform login. Reset links on old hosts lead to canonical forgot-password.
There is no Domain cookie, token-copy bridge or SSO. Existing users must log in again.
Do not forward bearer tokens/fragments between origins. Local development is allowed only
with explicitly loopback Supabase configuration; it is not a production auth origin.
Reference: https://supabase.com/docs/guides/auth/redirect-urls .

Ordered operator cutover (not executed by this preflight):
1. Recheck migration SHA/history and deploy only PRODUCT-10F DB/app to csk-booking-5nwh.
2. Verify DB/app, TLS, www 308, safe old-host redirects and public/authorization smoke.
   Do not send signup/reset emails while the old Auth allowlist is still in force;
   successful canonical email completion is not claimed in this intermediate state.
3. Set canonical Site URL, add the two canonical redirects, remove the five old entries.
4. Re-read saved Auth configuration. Fresh login of the explicitly selected test account.
5. Validate signup confirmation, login, recovery/reset, callback, account and tenant booking.
No cookies, refresh tokens or PKCE verifiers are transferred between domains.

Transactional booking/event emails are PRODUCT-10G, not implemented in this patch.
Their future link source is `PLATFORM_BASE_URL` from `lib/platform-domain.ts`.
