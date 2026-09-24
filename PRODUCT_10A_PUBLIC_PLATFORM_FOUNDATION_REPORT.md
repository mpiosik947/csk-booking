# PRODUCT-10A — Public Platform Foundation

Date: 2026-09-24 (Europe/Warsaw)

## Scope

The global `/` route becomes the neutral StrzelajTu.pl directory. A separate
tenant public-profile model controls publication independently from tenant
lifecycle. The public reader returns only slug, display name, city and a safe
same-origin logo path. Root `/<slug>` aliases resolve only published tenants and
hand off to the existing `/t/<slug>` architecture.

Out of scope: DNS/custom domains, Tenant Settings, entitlements/packages,
marketplace features, maps, global events and second-production-tenant
activation.

## Data model

`tenant_public_profiles` is keyed by `tenant_id`, closed to direct table access,
RLS-enabled with zero policies, and maintained separately from the security
critical `tenants.status`. `is_public=true` is an explicit publication choice;
an active tenant without that choice is absent from the directory.

`get_public_tenant_directory_v1(text)` is a bounded, stable, PII-free
SECURITY DEFINER reader. It exposes four fields, grants EXECUTE only to anon and
authenticated, rejects oversized search and returns at most 50 results.

The migration bootstraps only the already-active CSK tenant. It does not create
or activate a second tenant.

## UI and routing

- public StrzelajTu.pl brand and platform headline;
- accessible GET search by name, city or slug;
- responsive two-column directory cards with single-column mobile layout;
- safe logo fallback and same-origin image paths only;
- controlled read failure and contextual empty state;
- login and registration links retained;
- no CSK hardcode in global directory routing;
- `/<slug>` validates publication and redirects to canonical `/t/<slug>`.

## Deployment model

DB FIRST, then APP. The old app is compatible with the additive new table/RPC.
The new app requires the new RPC to render the directory; failure remains
controlled and exposes no data.

## Files changed

- `app/page.tsx`, `app/layout.tsx`, `app/[slug]/page.tsx`,
  `app/t/[slug]/layout.tsx`;
- `lib/server/public-tenant-directory.ts`;
- `supabase/migrations/20261004100000_add_public_tenant_directory.sql`;
- `supabase/tests/20261004100000_add_public_tenant_directory_test.sql`;
- homepage Node/Playwright coverage;
- closed SQL ACL, table and SECURITY DEFINER inventory tests updated only for
  the one new table and one new function.

## Security

- no client-supplied tenant authority;
- no direct `tenants` or public-profile table access;
- no service-role browser usage;
- no PII in the directory DTO;
- active lifecycle plus explicit publication required;
- no second production tenant activation;
- no modification of membership or operational authorization.

## Verification

- focused directory SQL: 23/23 PASS;
- full Supabase DB suite: 1641/1641 PASS;
- Node suite: 789/789 PASS;
- TypeScript: PASS;
- production build: PASS;
- changed-files ESLint: PASS;
- focused responsive/search Playwright: 7/7 PASS;
- full Playwright: 40/40 PASS;
- `git diff --check`: PASS;
- synthetic directory fixture remaining: 0;
- second production tenant created or activated: 0.

## Production preflight

- repository: `main` at `e107e95c45611d897fc223e5d643056b38c06591`,
  divergence from `origin/main`: `0/0`;
- migration timestamp `20261004100000` retained intentionally: the deployed
  repository sequence already continues through `20261001100000`,
  `20261002100000` and `20261003100000`, so PRODUCT-10A is the next ordered
  version rather than a wall-clock timestamp chosen for 2026-09-24;
- migration SHA-256:
  `D8E93F15BBDB2849F4C69E99C24129592A2901FE748560C52FD2440C8FF0CAC9`;
- linked history: LOCAL=REMOTE through `20261003100000`;
- local-only/pending: exactly
  `20261004100000_add_public_tenant_directory.sql`;
- `supabase db push --linked --dry-run`: PASS, exactly that one migration;
- migration is additive: one table, one index, one trigger, one bounded reader
  and one bootstrap directory row for the existing tenant; no drop, truncate,
  destructive alter or business-data rewrite;
- the migration is intentionally one-shot and fail-closed if its objects or
  expected baseline differ; normal migration history prevents replay;
- production write and application deployment performed during preflight: 0.

`npm audit --omit=dev` reports one existing moderate advisory in
`baseline-browser-mapping`. No dependency update was made because dependency
remediation is outside PRODUCT-10A and the finding does not alter the directory
authorization or data boundary.

## Production deployment and smoke

- checkpoint/deploy commit:
  `030042d2f41936e91509b5218e51178df1410903`;
- checkpoint push: fast-forward, LOCAL HEAD = `origin/main`, divergence `0/0`;
- deployed migration:
  `20261004100000_add_public_tenant_directory.sql`, applied exactly once;
- post-deploy migration history: LOCAL=REMOTE through `20261004100000`;
- post-deploy dry-run: `Remote database is up to date`, pending migrations: 0;
- relevant Vercel production project `csk-booking-5nwh`: deployment success;
- production `/`: HTTP 200 and new StrzelajTu.pl directory rendered;
- public directory: one explicitly published and active CSK entry;
- public DTO keys: `tenant_slug`, `tenant_name`, `tenant_city`,
  `tenant_logo_path`; forbidden/PII fields: 0;
- search by `Wolsztyn`, `Centrum Szkolenia` and `csk`: one correct result;
- `/csk`: HTTP 200 after canonical redirect to `/t/csk`;
- `/krutla`: safe HTTP 404 because it is not a published tenant slug;
- unknown slug: safe HTTP 404 with no browser console error;
- `/login`, `/account`, `/dashboard`, `/booking` and `/events`: HTTP 200;
- production routes checked: no 5xx;
- the migration's fail-closed active-tenant baseline passed with exactly one
  active tenant; no second production tenant was created or activated;
- DNS and custom-domain configuration: untouched.

The GitHub commit status also contains a failure for a separate Vercel project
named `csk-booking`. It is not the `csk-booking-5nwh` project serving the
verified production URL. The relevant production project completed
successfully and the live response matches the checkpointed PRODUCT-10A app.

## Verdict

PRODUCT-10A PUBLIC PLATFORM FOUNDATION: **FULLY IMPLEMENTED / PROD PASS**

PUBLIC HOME: **PASS**

PUBLIC TENANT DIRECTORY: **PASS**

SEARCH NAME / CITY: **PASS**

ROOT SLUG ROUTING: **PASS**

PII-FREE CONTRACT: **PASS**

SECOND PRODUCTION TENANT: **NOT ACTIVATED**

CUSTOM DOMAIN / DNS: **NOT TOUCHED**

DEPLOYMENT: **DB + APP PROD PASS**
