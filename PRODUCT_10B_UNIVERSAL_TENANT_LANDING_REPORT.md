# PRODUCT-10B — Universal Tenant Landing + Public Slug

Date: 2026-09-24
Mode: local implementation only
Baseline HEAD: `a9c0eda176fcc24fa2bd392e1c3c6990bfe1be8e` (`main`)

## 1. Source of truth

The implementation was derived from the current repository after PRODUCT-10A, the current local schema, the Next.js 16 App Router documentation bundled in `node_modules`, and the existing tenant route/context adapters.

The audit confirmed:

- `public.tenants.slug` is the technical tenant selector used by trusted server-side tenant context.
- `public.tenant_public_profiles` is the existing, closed public-profile source and is the correct place for public presentation fields.
- `/t/[slug]/[...path]` is the existing operational tenant route shell.
- the previous root `/[slug]` route resolved a published technical slug and redirected to `/t/[slug]`.
- the existing schema has no trustworthy public address, phone, email, opening-hours, or social-link source. Those values were not invented.
- no production write, deployment, second-production-tenant activation, DNS change, or custom-domain change was performed.

Pre-existing unrelated working-tree items remain untouched and excluded: `AGENTS.md`, `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md`, `SAAS_FINAL_MIGRATION_MASTER_REPORT.md`, `FINAL_SAAS_SECURITY_AUDIT_2026_09.md`, and `supabase/drafts/*`.

## 2. Public slug architecture

The forward-only migration `20261005100000_add_public_tenant_landing.sql` extends the existing `tenant_public_profiles` source with:

- required, unique `public_slug`;
- optional `hero_image_path`;
- optional `description`;
- optional `regulations_path`.

For the existing tenant:

- technical tenant slug remains `csk`;
- canonical public slug is `csk-krutla`.

`public_slug` is a public URL selector only. It is not accepted by tenant authorization contracts, does not create membership, and cannot override resource-owned `tenant_id`.

Slug controls include lowercase canonical syntax, length bounds, a system-route deny-list, a unique constraint, and a transaction-advisory-lock-backed namespace guard preventing collisions between public slugs and technical tenant slugs in either write direction.

Migration SHA-256: `525171892E458491881E5C058205B0614DCFE8697E95B9C2E4E35166890EF10B`.

## 3. Routing

- `/csk-krutla` renders the data-driven public landing.
- `/csk` resolves the same published tenant and permanently redirects to `/csk-krutla`.
- `/t/csk` remains compatible and permanently redirects its public root to `/csk-krutla`, preventing a duplicate indexable landing.
- operational routes such as `/t/csk/booking` and `/t/csk/events` remain unchanged.
- unknown, malformed, private, and suspended selectors produce the same safe not-found behavior.
- canonical metadata points to `/{public_slug}`.

## 4. Tenant landing architecture

`PublicTenantLanding` is a universal server-rendered component. It contains no CSK, Krutla, Wolsztyn, logo, address, phone, email, or tenant UUID hardcoding.

The layout retains the established dark graphite and amber/olive direction and renders only available public data. It includes:

- logo or generated initials;
- tenant name and city;
- optional hero and description;
- booking and events CTA;
- an explicit instructor-module “coming soon” state;
- pricing/booking and optional regulations links;
- responsive mobile, tablet, and desktop layouts.

Fields that do not yet have an approved source are omitted and deferred rather than guessed.

## 5. Public DTO

Two minimal readers are added:

1. `get_public_tenant_directory_v2(text)` returns exactly:
   - `public_slug`
   - `tenant_name`
   - `tenant_city`
   - `tenant_logo_path`
2. `get_public_tenant_landing_v1(text)` returns exactly:
   - `tenant_slug`
   - `public_slug`
   - `tenant_name`
   - `tenant_city`
   - `tenant_logo_path`
   - `tenant_hero_image_path`
   - `tenant_description`
   - `tenant_regulations_path`

Both readers are bounded PII-free `SECURITY DEFINER` projections with fixed `search_path`, owned by `postgres`, executable only by `anon` and `authenticated`. Direct table access remains denied to `anon`, `authenticated`, and `service_role`.

The server adapter validates the exact response keys, canonical slugs, bounded strings, and safe same-origin paths before rendering.

## 6. DB/schema changes

Migration:

- `supabase/migrations/20261005100000_add_public_tenant_landing.sql`

Focused test:

- `supabase/tests/20261005100000_add_public_tenant_landing_test.sql`

The migration was applied only to the confirmed local target `127.0.0.1:54322`. It adds no tenant authority, membership, user data, production tenant, DNS configuration, or custom domain.

The existing v1 directory reader remains present for rollout compatibility. The app uses v2.

## 7. Security review

- Public slug is not tenant authority: PASS.
- Resource-bound operational routes retain the technical tenant context: PASS.
- Direct URL manipulation and malformed selectors fail closed: PASS.
- Unknown/private/suspended tenants are not distinguishable through the public reader: PASS.
- Public DTO contains no tenant UUID, membership, user ID, email, phone, address, admin note, billing, audit, or internal feature data: PASS.
- Cross-table slug collision race is serialized in the database: PASS.
- Direct public-profile DML/SELECT remains closed: PASS.
- Cross-tenant local E2E remains isolated: PASS.
- Second production tenant remains not activated: PASS.

## 8. Tests

- Focused PRODUCT-10B SQL: `34/34 PASS`.
- Full Supabase DB suite: `1675/1675 PASS` across 58 files.
- Node full suite: `794/794 PASS`.
- Focused Playwright: `14/14 PASS`.
- Full Playwright: `47/47 PASS`.
- TypeScript (`npx tsc --noEmit`): PASS.
- Production build (`npm run build`): PASS.
- Changed-files ESLint: PASS.
- `git diff --check`: PASS.
- PRODUCT-10B DB fixture cleanup: `0`.
- Synthetic accounts left by an initially sandbox-blocked Playwright attempt were identified exactly and removed locally; final synthetic auth fixture count: `0`.

The only build warning is the pre-existing Next.js middleware-to-proxy deprecation notice.

## 9. Files changed

Application and focused tests:

- `app/[slug]/page.tsx`
- `app/_components/PublicTenantLanding.tsx`
- `app/page.tsx`
- `app/page.test.mjs`
- `app/public-tenant-landing.test.mjs`
- `app/t/[slug]/page.tsx`
- `lib/server/public-tenant-directory.ts`
- `tests/e2e/home-test-warning.spec.ts`
- `tests/e2e/tenant-routing.spec.ts`

Database:

- `supabase/migrations/20261005100000_add_public_tenant_landing.sql`
- `supabase/tests/20261005100000_add_public_tenant_landing_test.sql`

Regression inventory updates:

- `supabase/tests/20260816143000_harden_public_function_execute_acl_test.sql`
- `supabase/tests/20260907100000_add_dormant_tenant_foundation_test.sql`
- the 27 existing SECURITY DEFINER inventory tests from `20260913100000` through `20261004100000`, updated only from the reviewed PRODUCT-10A count `75` to PRODUCT-10B count `77`, plus the required PRODUCT-10A public-profile fixture/schema compatibility updates.

This report is the only new documentation file for PRODUCT-10B.

## 10. Deferred scope

- Tenant Settings UI and managed editing of public branding.
- Public address, contact details, opening hours, and social links after an authoritative public model is approved.
- Feature entitlements and paid packages.
- Platform-admin onboarding.
- Custom domains and DNS for `strzelajtu.pl` or tenant domains.
- New instructor, analytics, advertising, consent, or marketplace systems.

## 11. Final gate

All PRODUCT-10B local acceptance gates passed. Production was untouched, so production readiness still requires a separate migration/application preflight and explicit deployment authorization.

## PRODUCT-10B — HANDOFF

HEAD: `a9c0eda176fcc24fa2bd392e1c3c6990bfe1be8e`
FILES CHANGED: `42` including this report; pre-existing unrelated files excluded
MIGRATIONS: `20261005100000_add_public_tenant_landing.sql`
PUBLIC_SLUG MODEL: `tenant_public_profiles.public_slug`; selector only, never authority
CSK TENANT_SLUG: `csk`
CSK PUBLIC_SLUG: `csk-krutla`

/csk-krutla: PASS — canonical data-driven landing
/csk: PASS — permanent redirect to `/csk-krutla`
/t/csk: PASS — compatible permanent redirect at public root; operational child routes unchanged

TENANT LANDING: PASS
BOOKING CTA: PASS — `/t/csk/booking`, derived from resolved `tenant_slug`
PII: PASS — minimal allowlisted public DTO
TENANT ISOLATION: PASS

FOCUSED SQL: `34/34 PASS`
FULL DB: `1675/1675 PASS`
NODE: `794/794 PASS`
PLAYWRIGHT: `47/47 PASS`
TYPESCRIPT: PASS
BUILD: PASS
ESLINT: PASS
DIFF CHECK: PASS

PRODUCTION WRITE: NO
SECOND PROD TENANT: NOT ACTIVATED
DNS/CUSTOM DOMAIN: UNTOUCHED

PRODUCT-10B LOCAL: PASS
READY FOR PRODUCTION PREFLIGHT: YES
OPEN ITEMS: production preflight/deployment; richer public tenant settings and contact/branding fields remain deferred to later PRODUCT stages.
