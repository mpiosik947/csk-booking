# PRODUCT-10C — Tenant Settings + Public Sections On/Off

## 1. Current model inventory

| Field / capability | Current source before PRODUCT-10C | Public | Editable before PRODUCT-10C | New schema required |
| --- | --- | --- | --- | --- |
| Technical tenant identity and lifecycle | `tenants` (`slug`, `name`, `status`) | No | No | No |
| Public slug and listing state | `tenant_public_profiles` (`public_slug`, `is_public`) | Selector/listing only | No | No |
| Display name, city, description | `tenant_public_profiles` | Yes | No tenant settings UI | No |
| Logo and hero paths | `tenant_public_profiles` | Yes | No tenant settings UI | No |
| Regulations path | `tenant_public_profiles.regulations_path` | Yes | No tenant settings UI | No |
| Public address, phone, email | No dedicated public fields | No | No | Yes |
| Opening hours | No dedicated field | No | No | Yes |
| Social links | No dedicated structured field | No | No | Yes |
| Public section visibility | Hard-coded presentation | N/A | No | Yes |
| Tenant authority | `tenant_memberships.role/status` | No | N/A | No |
| Booking, events and other operational features | Existing tenant-scoped routes and RPCs | According to their contracts | Existing operational flows | No |

The existing `tenant_public_profiles` record already owns the tenant landing presentation. Extending it avoids a second one-to-one settings table and duplicate public profile data.

## 2. Chosen architecture

- `tenant_public_profiles` remains the single source of truth for public presentation.
- PRODUCT-10C adds public contact fields and seven boolean visibility flags to that table.
- Existing tenants receive `true` defaults for every flag, preserving the current CSK public experience.
- The public reader is versioned as `get_public_tenant_landing_v2(text)` and returns an explicit allowlist.
- Admin reads and writes use hardened RPCs. The technical tenant slug is a selector; authority is derived exclusively from an active `tenant_memberships` row with role `admin`.
- Visibility is presentation state only. It does not disable operational routes and is not an entitlement.
- No `if tenant === 'csk'`, first-active-tenant fallback or implicit CSK authority was introduced.

## 3. DB/schema changes

Forward-only migration:

`20261006100000_add_tenant_public_settings.sql`

SHA-256:

`33D153D92D5BFDEB95C9687F5AF8551C486AB71DE6B7AE3437AF33F29F7A30B4`

Added to `tenant_public_profiles`:

- `public_address`
- `public_phone`
- `public_email`
- `opening_hours`
- `social_links jsonb`
- `show_booking`
- `show_pricing`
- `show_instructor`
- `show_events`
- `show_about`
- `show_contact`
- `show_regulations`

All visibility flags are non-null and default to `true`. The migration does not activate another tenant, modify DNS/custom domains, change packages, add billing data or edit any deployed historical migration.

## 4. RLS/RPC

`tenant_public_profiles` remains RLS-enabled with zero policies and without direct table privileges for `PUBLIC`, `anon`, `authenticated` or `service_role`.

New contracts:

- `admin_get_tenant_public_settings_v1(text)` — authenticated admin-only settings reader.
- `admin_update_tenant_public_settings_v1(text,jsonb,timestamptz)` — authenticated admin-only, validated write with optimistic concurrency.
- `get_public_tenant_landing_v2(text)` — minimal public landing reader for `anon` and `authenticated`.

The admin contracts:

- never accept `tenant_id`;
- resolve a tenant from its technical slug;
- require an active admin membership for that resolved tenant;
- do not use `profiles.role`;
- reject unknown payload keys, including attempted `tenant_id`, `slug`, `public_slug`, status or entitlement mutation;
- use a fixed hardened `search_path` and minimal EXECUTE grants.

The public slug remains selector-only and confers no write or tenant authority.

The public V2 reader enforces visibility at the database contract boundary:

- `show_contact=false` masks address, phone, email and opening hours to `NULL`, and social links to an empty object;
- `show_about=false` masks the description to `NULL`;
- `show_regulations=false` masks the regulations path to `NULL`.

This prevents direct anon/authenticated RPC calls from bypassing presentation privacy.

## 5. Admin UI

Added tenant-scoped `/admin/settings`, reachable through `/t/[slug]/admin/settings` and visible only to admins in the existing admin navigation.

The screen provides:

- public display name, city and description;
- existing logo/hero path display fields without inventing upload infrastructure;
- regulations path;
- public address, phone, email and opening hours;
- bounded HTTPS social links;
- all seven public visibility controls;
- loading, controlled error/retry, success and concurrency-conflict states.

The browser sends the route tenant slug but no tenant UUID. Server-side membership remains authoritative. Employee access to the route and both settings RPCs is denied.

## 6. Public rendering

`PublicTenantLanding` consumes only the validated V2 DTO. It omits disabled sections completely, including their cards, headings and calls to action:

- `show_booking` controls the booking CTA;
- `show_pricing` controls pricing;
- `show_instructor` controls instructor content;
- `show_events` controls event content/CTA;
- `show_about` controls description/about;
- `show_contact` controls public address, phone, email, opening hours and social links;
- `show_regulations` controls regulations.

Combinations including only booking, contact and regulations render without empty wrappers, orphan headings or layout gaps. Tenant booking/events routes remain operational because PRODUCT-10C visibility is not a PRODUCT-10D entitlement. Raw public RPC tests independently verify both enabled values and database-level masking for `anon` and `authenticated` callers.

## 7. Validation

Validation is enforced in the mutation RPC and repeated at the public DTO adapter boundary:

- bounded display name, city, description, address, phone, public email and opening-hours text;
- normalized lowercase public email with format validation;
- social link key allowlist and bounded `http`/`https` URLs only;
- rejection of `javascript:` and malformed schemes;
- JSON object shape and exact payload-key allowlist;
- boolean type validation for every visibility flag;
- optimistic concurrency through the expected `updated_at` value;
- no raw HTML rendering.

## 8. Security matrix

| Actor / action | Result |
| --- | --- |
| Active Admin A reads/updates Tenant A | ALLOW |
| Active Admin A reads/updates Tenant B | DENY |
| Active Employee A | DENY |
| Active Instructor A | DENY |
| Active ordinary User A | DENY |
| Pending admin membership | DENY |
| Suspended admin membership | DENY |
| Global `profiles.role=admin` without membership | DENY |
| Anonymous settings read/write | DENY |
| Anonymous public landing V2 read | ALLOW, allowlisted DTO only |
| Attempt to mutate tenant/public slug, status, authority or entitlement | DENY |

Audit entries are tenant-bound and record actor, tenant, action, target and changed field names. They do not record submitted contact values or other unnecessary PII.

## 9. Tests

- Focused SQL: **35/35 PASS**.
- Full Supabase DB suite: **59 files, 1710/1710 PASS**.
- Node: **798/798 PASS**.
- Playwright focused: **5/5 PASS**.
- Playwright full: **48/48 PASS**.
- TypeScript: **PASS**.
- Production build: **PASS**.
- Changed-files ESLint: **PASS — 0 errors**; one pre-existing React hooks warning remains in `app/admin/page.tsx` and is not caused by PRODUCT-10C.
- `git diff --check`: **PASS**.
- Local fixture cleanup: tenants 0, memberships 0, profiles 0, auth users 0, audit fixtures 0.

Historical SQL contract files were updated only for the intentional function/audit inventory changes introduced by this migration: SECURITY DEFINER `77 → 80`, three new RPCs, one additional audited writer and the normalized audit trigger fingerprint.

## 10. Files changed

Product code and tests:

- `app/_components/PublicTenantLanding.tsx`
- `app/admin/page.tsx`
- `app/admin/settings/page.tsx`
- `app/admin/settings/settings.test.mjs`
- `app/page.test.mjs`
- `app/public-tenant-landing.test.mjs`
- `app/t/[slug]/[...path]/page.tsx`
- `lib/admin/route-protection.js`
- `lib/admin/route-protection.test.mjs`
- `lib/server/public-tenant-directory.ts`
- `lib/tenant-routing.ts`
- `tests/e2e/tenant-public-settings.spec.ts`

Database:

- `supabase/migrations/20261006100000_add_tenant_public_settings.sql`
- `supabase/tests/20261006100000_add_tenant_public_settings_test.sql`
- existing SQL inventory/regression tests affected by the intentional RPC, audit writer and SECURITY DEFINER inventory changes.

Documentation:

- `PRODUCT_10C_TENANT_SETTINGS_REPORT.md`

Pre-existing changes in `AGENTS.md`, SaaS planning/master reports, `FINAL_SAAS_SECURITY_AUDIT_2026_09.md` and `supabase/drafts/*` are unrelated and excluded from PRODUCT-10C.

## 11. Deferred to PRODUCT-10D

- Feature/package entitlements and the future `entitlement allows AND tenant setting enabled` decision.
- SaaS package/billing configuration.
- Logo/hero upload and storage lifecycle; PRODUCT-10C does not create ad-hoc storage infrastructure.
- Platform Admin onboarding and conservative defaults for newly provisioned tenants.
- Custom domains and DNS for `strzelajtu.pl`.
- Second production tenant activation.
- Final legal/GDPR content model and richer regulations content management.

## 12. Final gate

PRODUCT-10C is locally complete. Tenant settings are admin-only and tenant-isolated, visibility is not authority or entitlement, the public DTO remains explicitly allowlisted, CSK keeps its existing public UX through safe defaults, and all automated gates pass.

No production write, deployment, staging, commit or push was performed. The next permitted step is a separate production preflight.

**PRODUCT-10C LOCAL: PASS**

**READY FOR PRODUCTION PREFLIGHT: YES**
