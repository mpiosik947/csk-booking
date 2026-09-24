# PRODUCT-10D — SaaS Packages + Feature Entitlements

Date: 2026-09-24
Repository baseline: `77e3bf0c2f83dc632143af22d656abee856ec2fc` (`main`)
Mode: local implementation only; no staging, commit, push, deployment, or production write

## 1. Existing module inventory

| Feature | Public UI | Admin UI / server route | Main read/write contracts | Main tables | Authority before 10D | Visibility setting | Entitlement |
|---|---|---|---|---|---|---|---|
| `booking` | tenant landing CTA, `/t/[slug]/booking` | reservations, lane configuration, dashboard booking queues | public booking configuration, busy ranges, reservation create/cancel, lane-family configuration | `reservations`, `shooting_lanes`, booking rules/durations/pricing | tenant context + membership/resource ownership | `show_booking`; pricing presentation uses `show_pricing` | required |
| pricing | landing price section within booking | lane configuration | booking configuration readers/writers | lane rules/durations/pricing | same as booking | `show_pricing` | covered by `booking`; no artificial key |
| `events` | landing CTA, `/t/[slug]/events` | admin events and participant management | public event list/availability, event CRUD, registration approval/cancel/payment, reserve promotion | `events`, `event_lanes`, `event_registrations` | tenant context + membership/resource ownership | `show_events` | required |
| `instructors` | landing instructor CTA/section | no independent operational module | landing DTO only | tenant public profile | public tenant selector | `show_instructor` | required for public presentation |
| `staff` | none | `/t/[slug]/admin/users` | tenant user list; role, note, identity/contact/verification writers | `tenant_memberships`, tenant notes/verifications, `profiles` | active tenant membership and operational relationship | none | required |
| `checkin` | token flow remains resource-bound | `/t/[slug]/admin/check-in` | check-in reader, attendance and customer verification writers | reservations and tenant verification | reservation tenant + active staff membership | none | required |
| `reports` | none | `/t/[slug]/admin/reports` | paginated report and export RPCs | tenant-owned reservation/report inputs | active tenant admin membership | none | required |
| `lane_blocks` | reflected in booking availability | `/t/[slug]/admin/lane-blocks` | lane-block readers/writers | `lane_blocks`, `shooting_lanes` | lane resource tenant + staff membership | none | required for mutations/module access |
| lane configuration | affects booking | `/t/[slug]/admin/lane-configuration` | configuration V3 and family create/update writers | shooting lanes and configuration tables | active tenant admin membership | none | covered by `booking` |
| `advanced_calendar` | none | `/t/[slug]/admin/calendar`, calendar feed API | scoped calendar readers/feed | reservations, events, lanes | tenant membership + scoped resources | none | required |
| `branding` | base name/logo/hero remain available | settings retain base public identity | tenant landing/settings contracts | `tenant_public_profiles` | tenant profile settings authority | no separate 10C toggle | catalogued, not used to remove essential identity |
| `custom_domain` | no runtime integration | none | none | none | not implemented | none | placeholder only; PRODUCT-10F |

About, contact, and regulations remain baseline public-profile capabilities, not paid feature keys.

## 2. Feature catalog

The stable technical catalog is:

`booking`, `events`, `instructors`, `staff`, `checkin`, `reports`, `lane_blocks`, `advanced_calendar`, `branding`, `custom_domain`.

Keys are internal technical identifiers. They carry no public plan name, price, billing interval, trial, discount, or payment meaning. No feature is silently enabled as a dependency. The two bootstrap plans contain explicit feature sets; dependencies can later be validated by the Platform Admin writer without introducing magic auto-enable behavior.

## 3. Package architecture

- `current_full_v1`: internal compatibility plan containing all ten catalogued features.
- `booking_only_v1`: internal test/future-use plan containing only `booking`.
- CSK receives an explicit active `current_full_v1` assignment by migration.
- Missing assignment, inactive/unknown plan, inactive/unknown feature, or resolver failure means **not entitled**.
- There is no tenant-facing plan or entitlement writer. Plan mutation is deferred to PRODUCT-10E.
- Plan keys and the full commercial configuration are not returned by public landing readers.

## 4. DB schema

Forward-only migration: `supabase/migrations/20261007100000_add_saas_feature_entitlements.sql`.

Added closed tables:

- `saas_features(feature_key, description, active, created_at)`
- `saas_plans(id, plan_key, status, created_at, updated_at)`
- `saas_plan_features(plan_id, feature_key)`
- `tenant_plan_assignments(tenant_id, plan_id, status, assigned_at)`

All four tables have RLS enabled, zero permissive policies, and no direct table access for `PUBLIC`, `anon`, `authenticated`, or `service_role`. Referential constraints prevent orphan assignments/catalog links. The schema contains no price or billing data.

Migration SHA-256: `7EC71B28295BBD67C0277A867B352B883474E8018A15C28EC4B32FB5ECDC4C04`.

Local migration replay and local schema dry-run both pass; `supabase db diff --local --schema public` reports `No schema changes found`. The only new migration file after the deployed PRODUCT-10C baseline is `20261007100000_add_saas_feature_entitlements.sql`.

## 5. Effective entitlement resolution

Canonical DB engine:

- `tenant_has_feature_v1(uuid,text)` — closed internal resolver, fail-closed, minimal `service_role` execute for trusted server paths.
- `get_my_tenant_feature_access_v1(uuid,text)` — authenticated active-member boolean wrapper.
- `get_my_tenant_features_v1(uuid)` — authenticated active-member effective key list used by tenant UI.
- `get_public_tenant_feature_access_v1(uuid,text)` — public boolean wrapper limited to `booking`, `events`, and `instructors`; it requires an active, public tenant and discloses no plan/catalog details.

All functions have a fixed qualified search path. Tenant membership establishes caller authority; entitlement can only narrow that authority. For existing resources, the protected operation derives the tenant from the lane, reservation, event, or registration rather than trusting a caller-provided selector.

## 6. Tenant Settings integration

PRODUCT-10C visibility remains independent. Effective public presentation is calculated by the landing V2 reader as:

`stored visibility flag AND tenant_has_feature_v1(tenant_id, feature_key)`.

The settings reader returns only three operational booleans (`booking`, `events`, `instructors`) under `feature_access`; it does not expose plan keys, assignments, catalog rows, billing, or prices. Unavailable visibility toggles are disabled with a neutral “not available in current plan” explanation. Saving a visibility flag cannot self-grant a feature.

## 7. Route enforcement

The server route map gates:

- public: `booking`, `events`;
- staff: reservations/lane configuration, events, users, check-in, reports, lane blocks, calendar.

`/t/[slug]/[...path]` resolves a trusted tenant context first and then performs a fail-closed feature RPC check before rendering the module. Missing entitlement returns the existing safe not-found behavior. Public slug remains a selector, never authority. Owner continuity routes (`my-reservations`, `my-events`) remain available for existing obligations/history.

The admin dashboard loads effective features, avoids unavailable module reads, and hides unavailable module links. It contains no checkout or upgrade flow.

## 8. RPC / DB enforcement

Enforcement is not UI-only:

- public booking configuration and public event list/availability fail closed;
- lane-family configuration/create and 17 selected-tenant staff RPCs check membership-aware entitlements;
- busy-range, check-in, legacy participant/payment, and reserve-promotion functions derive tenant from the resource and enforce the matching feature;
- calendar feed and reserve-promotion server routes check entitlements before operational reads/writes;
- table triggers block new feature use on reservations, event registrations, events, lane blocks, and shooting lanes.

Entitlement ACL inventory is covered by SQL regression tests. SECURITY DEFINER inventory changes from 80 to 85 exactly: four hardened resolver/wrapper functions plus one closed trigger function. No unexpected grant or SECURITY DEFINER drift remains in the local suite.

## 9. Continuity exceptions

Gated as new feature use:

- new reservation and event registration creation;
- new/active event, lane-block, and lane configuration use;
- module-specific privileged reads/writes and direct routes.

Continuity-safe:

- owner reads of existing reservations/events;
- cancellation and history needed for existing obligations;
- deactivation/deletion needed to safely close existing event/lane/block data;
- account/profile lifecycle.

No data is deleted when an entitlement is absent. The entitlement layer does not rewrite tenant ownership or role authorization.

## 10. Authorization matrix

| Case | Result |
|---|---|
| Tenant Admin A + active membership A + entitled feature A | ALLOW within existing role scope |
| Tenant Admin A + active membership A + missing feature A | DENY |
| Tenant Admin A attempts catalog/plan/assignment write | DENY |
| Tenant Admin A targets Tenant B | DENY regardless of either plan |
| Global `profiles.role=admin` without active membership | DENY |
| Pending/suspended/no membership | DENY |
| Employee/instructor/user with entitlement | Existing role limits remain; no privilege expansion |
| Anonymous caller | Public effective behavior only; no private access or plan details |
| Missing assignment/unknown key/resolver error | DENY / false |

## 11. Synthetic tenant matrix

- Tenant A / CSK-compatible full plan: all current modules remain available; existing full-product regression passes.
- Tenant B / booking-only: public profile and booking CTA/route work when visibility is on; events/instructor presentation and staff event/users/check-in/reports/lane-block/calendar modules are absent; direct routes and RPC/write bypasses are denied.
- Cross-tenant plan, resource, and PII access remains denied.
- Local E2E fixtures now create an explicit public profile and plan assignment and remove both during cleanup.

Final local cleanup evidence: synthetic tenants `0`, synthetic users `0`, non-CSK assignments `0`, CSK active `current_full_v1` assignment `1`.

## 12. Security review

- No service-role key is present in browser code.
- No client write path exists for catalog, plans, plan features, or assignments.
- No CSK authority hardcode exists; CSK behavior comes from an explicit row assignment.
- No first-active, missing-plan, public-slug, or implicit-tenant fallback is used.
- Public DTOs expose effective booleans/allowlisted landing fields only; no plan identity, tenant UUID expansion, membership, billing, internal note, or user PII is added.
- Entitlement checks never replace tenant membership, resource ownership, RLS, or role checks.
- PRODUCT-10A/B/C routing, landing, settings, authorization, and privacy tests remain green.
- Second production tenant remains not activated. DNS/custom domains are untouched.

## 13. Tests

- Focused PRODUCT-10D SQL: **48/48 PASS**.
- Full Supabase DB suite: **60 files, 1758/1758 PASS**.
- Node suite: **803/803 PASS**.
- Focused Playwright (10D + public settings + two-tenant): **3/3 PASS**.
- Full Playwright: **49/49 PASS**.
- TypeScript: **PASS** (`tsc --noEmit`).
- Production build: **PASS** (39 routes/pages generated).
- Changed-files ESLint: **PASS with 0 errors, 1 pre-existing `react-hooks/exhaustive-deps` warning** in `app/admin/page.tsx`; no new lint error.
- `git diff --check`: **PASS** (only Windows line-ending conversion notices).
- Local schema diff: **PASS**, no schema drift.

Known accepted residuals were not reopened: middleware deprecation, baseline browser advisory, unauthenticated account diagnostic, and obsolete Vercel project.

## 14. Files changed

Product code and targeted tests:

- `lib/tenant-features.ts`
- `lib/server/tenant-route-context.ts`
- `app/t/[slug]/[...path]/page.tsx`
- `app/admin/page.tsx`
- `app/admin/settings/page.tsx`
- `app/api/admin/calendar-feed/route.ts`
- `app/api/send-event-reserve-promotion/route.ts`
- `app/product-10d-entitlements.test.mjs`
- related admin/reserve-promotion Node tests
- `tests/e2e/product-10d-entitlements.spec.ts`
- related public-settings and two-tenant E2E fixtures

Database:

- `supabase/migrations/20261007100000_add_saas_feature_entitlements.sql`
- `supabase/tests/20261007100000_add_saas_feature_entitlements_test.sql`
- historical SQL regression inventories/fingerprints updated only for the five new functions, four closed tables, one trigger, grants, and the expected SECURITY DEFINER count.

Excluded and untouched by PRODUCT-10D: `AGENTS.md`, `supabase/drafts/*`, unrelated SaaS reports/plans, production configuration, DNS, and custom domains.

## 15. Deferred billing / Platform Admin scope

Deferred to PRODUCT-10E or later:

- Platform Admin writer and audited assignment changes;
- commercial plan names, prices, billing intervals, trials, discounts, Stripe, invoices;
- tenant self-service upgrade/checkout;
- custom-domain provisioning (PRODUCT-10F);
- decisions about monetizing advanced branding beyond essential tenant name/logo identity.

## 16. Final gate

PRODUCT-10D local acceptance criteria are satisfied. The canonical entitlement engine is fail-closed; CSK continuity is explicit; no self-grant or role expansion exists; landing/settings/navigation/routes/RPCs/database writes are enforced; continuity paths remain available; both synthetic plan matrices and full regressions pass.

**PRODUCT-10D LOCAL: PASS**
**READY FOR PRODUCTION PREFLIGHT: YES**

## 17. Production deployment verification

Deployment checkpoint: `3877970ac8a010eac70d89981c4bfa760a052137`.

- Migration `20261007100000_add_saas_feature_entitlements.sql` was applied exactly once with SHA-256 `7EC71B28295BBD67C0277A867B352B883474E8018A15C28EC4B32FB5ECDC4C04`.
- Local and remote migration history match through `20261007100000`; the final dry-run reports that the remote database is up to date.
- Production contains 10 unique active feature keys, two active technical plans, one explicit CSK `current_full_v1` assignment, and zero non-CSK assignments.
- The production SECURITY DEFINER inventory is 85. The four entitlement tables have RLS enabled, zero policies, and zero direct grants to PUBLIC, anon, authenticated, or service_role.
- Protected entitlement functions have no PUBLIC or anon execution. The intentionally public allowlisted boolean reader remains available only to anon/authenticated.
- The production resolver returns `true` for CSK booking, `false` for an unknown feature, and `false` for a missing tenant. Direct anonymous assignment-table access returns HTTP 401.
- The landing DTO contains no plan, entitlement, billing, assignment, membership, tenant UUID, admin note, or user identifier fields.
- GitHub/Vercel reports a successful deployment of the checkpoint to the intended `csk-booking-5nwh` project. The unused `csk-booking` project is not a deployment target.
- Public, tenant-scoped, account, dashboard, login, and protected admin routes were smoke-tested with zero 5xx responses. Anonymous admin access redirects to login.
- PRODUCT-10A, PRODUCT-10B, PRODUCT-10C, auth/account, tenant isolation, visibility masking, existing-data continuity, and the local booking-only/full-plan matrices remain passing.
- The second production tenant remains inactive. DNS and custom domains remain untouched.

**PRODUCT-10D PRODUCTION: PASS**
**PRODUCT-10E READY: YES**
