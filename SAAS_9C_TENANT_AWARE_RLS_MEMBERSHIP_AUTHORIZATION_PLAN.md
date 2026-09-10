# SAAS-9C — Tenant-Aware RLS & Membership Authorization

Technical implementation plan only. No SAAS-9C migration, SQL write, application change, deployment, or production mutation was performed while preparing this document.

Repository evidence point: `main` at `15afba00d8d624a8cadc848552a294bf4d782352` after the final SAAS-9B-3 documentation checkpoint. The effective local PostgreSQL catalog was inspected read-only at `127.0.0.1:54322`; the accepted SAAS-9B-3 production verification remains the production schema baseline.

## 1. Executive summary

SAAS-9B-1 through 9B-3 established one guarded CSK tenant, dormant memberships, durable tenant ownership on eight business/history tables, seven validated composite relationships, derived tenant integrity for email/audit, and tenant-prefixed indexes. They did not change authorization. Runtime authorization remains global because `profiles.role`, `get_my_role()`, `is_admin()`, `is_admin_or_employee()`, `is_admin_or_staff()`, browser checks, middleware, RLS policies, and many `SECURITY DEFINER` functions still have no tenant argument or membership check.

SAAS-9C should establish a membership authorization foundation and replace table-level tenant-data RLS with row-tenant membership checks. It must not pretend to complete the SaaS cutover:

- SAAS-9C owns membership backfill, fail-closed tenant-role helpers, membership synchronization during the compatibility period, and tenant-aware table RLS.
- SAAS-9D owns tenant-aware business RPC/writer/read contracts and removal of global-role authorization from `SECURITY DEFINER` business functions.
- SAAS-9E owns trusted application tenant resolution, routing, middleware, session/UI context, and URL behavior.
- SAAS-9F owns coordinated module cutover for reports, events, calendar, check-in, booking, and other operational screens.
- SAAS-9G owns complete cross-tenant/concurrency testing.
- SAAS-9H is the only stage that may close SEC-004 and authorize removal of the second-active-tenant guard.

The role vocabulary, existing-account activation rule, and legacy/canonical role aliases are approved. SAAS-9C-1 local implementation is **GO**; every production write remains separately gated.

## 2. Current authorization architecture

### 2.1 Identity and global role

- `auth.users` is the global account identity.
- `public.profiles` is global and has no `tenant_id`.
- `profiles.role` accepts the runtime vocabulary `admin`, `pracownik`, `instruktor`, and `user`.
- `handle_new_user()` creates a global profile with role `user`.
- `get_my_role()` returns `profiles.role` for `auth.uid()`.
- `is_admin()`, `is_admin_or_employee()`, and `is_admin_or_staff()` are `SECURITY DEFINER` functions reading `profiles.role`.
- Current helper `search_path=public` is weaker than the newer repository standard `pg_catalog, public, pg_temp`; SAAS-9C helpers must use the hardened standard.

### 2.2 Application boundary

`middleware.ts` protects `/admin/:path*` by calling `auth.getUser()`, then directly selecting `profiles.role`. `lib/admin/route-protection.js` maps global Polish role names to routes. The same global role is read through `get_my_role()` by the home/admin dashboard, Calendar, Reports, Events, Users, and Lane Configuration. Admin Check-in and Dashboard also read `profiles.role` directly. Server routes for reservation cancellation and event reserve promotion directly read operator roles from `profiles`.

These UI checks are defense-in-depth only. They are not tenant authorization and must not be used as proof that a row belongs to the selected tenant.

### 2.3 Effective membership foundation

`tenant_memberships` currently has:

| Element | Effective definition |
|---|---|
| Primary key | `(tenant_id, user_id)` |
| Tenant FK | `tenant_id -> tenants(id) ON DELETE CASCADE` |
| User FK | `user_id -> auth.users(id) ON DELETE CASCADE` |
| Role constraint | `admin`, `employee`, `user` |
| Status constraint | `active`, `pending`, `suspended` |
| Defaults | role `user`, status `pending` |
| Indexes | `(user_id,status,tenant_id)` and `(tenant_id,role,status,user_id)` |
| RLS | enabled |
| Policies | zero |
| Client ACL | none for `PUBLIC`, `anon`, `authenticated`, or `service_role` |
| Runtime usage | none |

Production verification recorded zero memberships before SAAS-9C. The one-active-tenant partial unique guard remains mandatory.

## 3. Global-role dependencies

### 3.1 Dependency classes

| Current authorization source | Current consumers | Tenant-aware target | Migration phase | Risk |
|---|---|---|---|---|
| `profiles.role` via `get_my_role()` | home/admin UI, Calendar, Reports, Events, Users, Lane Configuration, admin calendar API | versioned `get_my_tenant_role_v1(tenant_id)` after trusted tenant resolution | helper foundation in 9C; callers cut over in 9E/9F | High: changing the old no-argument helper now would break deployed clients |
| Direct `profiles.role` reads | `middleware.ts`, Dashboard, Check-in, cancellation email route, reserve-promotion route | trusted tenant context plus membership role; DB resource tenant validation | 9E for middleware/UI; 9D for server routes | Critical before tenant B |
| `is_admin()` | profile/audit policies and legacy RPC/trigger checks | `has_tenant_role(tenant_id,['admin'])` | RLS in 9C; RPCs in 9D | High |
| `is_admin_or_employee()` | reservations and lane-config policies; many operational RPCs | active membership role in `admin/employee` for the row/resource tenant | RLS in 9C; RPCs in 9D | Critical before tenant B |
| `is_admin_or_staff()` | lanes, blocks, events, event lanes/registrations | active membership role in `admin/employee/instructor` for row tenant, subject to SEC-008 residual | RLS in 9C; RPCs in 9D | High |
| Inline profile-role queries in `SECURITY DEFINER` functions | admin lists/reports/users/events, lane writers, reservation/event operations, check-in/payment/profile administration, email preparation | derive tenant from trusted target and call tenant-role helper | 9D | Critical; RLS does not constrain table-owner functions |
| Global route-role map | `/admin/*` middleware and client display | selected tenant membership role plus route matrix | 9E | High |
| `service_role` | email completion/claims, event reserve promotion, Auth Admin account deletion | trusted record-derived tenant, explicit actor authorization before bypass, bounded DTO | contract inventory in 9C; implementation 9D/9E | Critical |

### 3.2 Database function inventory

Read-only catalog inspection found 47 current functions whose definitions directly read `profiles`, invoke legacy role helpers, or enforce global admin/staff behavior. They fall into these groups:

- role foundation: `get_my_role`, `is_admin`, `is_admin_or_employee`, `is_admin_or_staff`;
- lane/configuration: `admin_create_lane_block`, `admin_update_lane_block`, `admin_set_lane_block_active`, `admin_create_lane_booking_family_v1`, `admin_get_lane_booking_configuration_v1/v2`, `admin_set_lane_booking_configuration`, `admin_set_lane_booking_family_configuration_v2`, `lane_booking_family_business_snapshot_v2`;
- reservations/check-in: `create_reservation`, `create_reservation_v2`, `cancel_reservation`, `get_check_in_reservation_v1`, `get_reservation_customer_profiles_v1`, `update_reservation_admin_note`, `update_reservation_attendance`, `update_reservation_payment`;
- events: `admin_create_event`, `admin_create_event_v2`, `admin_update_event`, `admin_update_event_v2`, `admin_set_event_active`, `admin_set_event_active_v2`, `admin_list_events_v1`, `admin_list_event_registrations_v1`, `register_for_event`, `cancel_event_registration`, `approve_event_registration`, `mark_event_registration_paid`;
- reports/users: `admin_get_reservation_report_v1/v2`, `admin_get_reservation_report_export_v1`, `admin_list_users_v1`, `admin_set_user_role_v1`, `admin_set_user_note_v1`, `update_profile_identity`, `update_profile_contact_details`, `update_profile_verification`;
- account/email/profile support: `anonymize_my_account_v1`, `export_my_data_v1`, `prepare_confirmation_email`, `update_my_profile_v1`, `prevent_non_admin_profile_privilege_changes`, `handle_new_user`.

This inventory is a 9D migration manifest. SAAS-9C must not silently rewrite all of these functions. It may replace legacy helper usage only inside RLS definitions and introduce new versioned helpers.

## 4. `tenant_memberships` readiness

The table shape, primary key, FKs, status constraint, and indexes are suitable for active-membership checks. Three changes/decisions are required before activation:

1. **Instructor vocabulary blocker.** Current profiles and route permissions include `instruktor`, but the membership constraint excludes it. Mapping `instruktor -> user` would silently remove existing operational access; mapping it to `employee` would silently expand access. Recommended resolution: extend the membership role constraint with canonical value `instructor`, and map `instruktor -> instructor`. This scopes the existing role to a tenant without implementing the deferred instructor-to-event assignment model. SEC-008 remains an intra-tenant accepted/deferred residual.
2. **Membership activation rule.** Recommended backfill is one active CSK membership for every auth-backed profile, including unverified users, because membership status expresses tenant relationship/access and profile verification remains a separate current concept. This needs explicit approval and production preflight evidence.
3. **Write authority.** Browser roles must retain no direct INSERT/UPDATE/DELETE on memberships. Tenant admin membership management belongs to controlled, audited RPCs in 9D. SAAS-9C may grant authenticated SELECT only for the caller's own membership rows.

No new enum type is recommended. Preserve text plus explicit CHECK for low-risk expansion and compatibility with the existing table.

## 5. Existing-user membership backfill

### 5.1 Mandatory production preflight

Before any migration, record counts and fail closed if any condition is non-zero:

- `profiles` without matching `auth.users`;
- Auth users in the intended CSK user universe without a profile;
- duplicate `profiles.user_id` (should already be constrained);
- existing membership rows that conflict with the calculated CSK row;
- profile roles outside `admin/pracownik/instruktor/user` after trim/lower normalization;
- more or fewer than exactly one active CSK tenant;
- any tenant other than CSK with business rows or memberships;
- any drift in RLS/ACL/function fingerprints accepted after SAAS-9B-3.

The production preflight must report the actual role distribution without PII. Local data is not a substitute for production counts.

### 5.2 Explicit role map

Approved forward compatibility map:

| Legacy `profiles.role` | Membership role |
|---|---|
| `admin` | `admin` |
| `pracownik` | `employee` |
| `instruktor` | `instructor` |
| `user` | `user` |

Approved reverse compatibility map while `profiles.role` remains the active legacy authorization source:

| Membership role | Legacy `profiles.role` |
|---|---|
| `admin` | `admin` |
| `employee` | `pracownik` |
| `instructor` | `instruktor` |
| `user` | `user` |

The bridge must translate explicitly in both directions. It must never compare the legacy and membership values as if `pracownik=employee` or `instruktor=instructor` were identical strings.

No fallback mapping is allowed. NULL, blank, unknown, mixed, or malformed roles stop the migration.

### 5.3 Backfill algorithm

1. Lock only the relevant role/membership transition surfaces with a short `lock_timeout`; do not lock business tables.
2. Re-run all preflight assertions inside the migration transaction.
3. Extend the role CHECK only after confirming there are no existing invalid membership values.
4. Insert one CSK membership per eligible profile with `status='active'` and the explicit map above.
5. Do not use a broad `ON CONFLICT DO UPDATE`. A conflicting pre-existing membership is a blocker, not data to overwrite.
6. Assert inserted count equals the exact preflight profile count and every source role maps bijectively.
7. Assert zero missing/extra memberships and zero role mismatches.
8. Install the one-way compatibility synchronization described below before commit.

### 5.4 Preventing a dual-source split

During 9C, `profiles.role` remains the authoritative compatibility source for existing application and RPC code, while RLS begins consuming derived CSK memberships. A dormant one-time backfill alone is unsafe because later role changes would diverge.

Use a temporary, **one-way** CSK bridge:

- an `AFTER INSERT OR UPDATE OF role` trigger on `profiles` maps the normalized legacy role into the user's CSK membership;
- the trigger inserts the membership for a new profile and updates only the CSK membership role for an existing profile;
- it never writes memberships for any other tenant;
- it never maps unknown roles;
- it does not react to membership writes, avoiding bidirectional recursion;
- its function uses hardened `search_path`, explicit schema qualification, and no client EXECUTE grant;
- membership direct DML remains unavailable to browser roles.

This bridge makes `profiles.role -> CSK membership` deterministic while legacy code is active. In 9D/9E, controlled role-management RPCs must become the only dual-write/cutover point. The bridge is removed only after all role reads/writes use tenant membership and reconciliation proves zero mismatch.

## 6. Tenant-aware authorization helper design

Recommended additive, versioned helper surface:

| Logical helper | Contract | Exposure |
|---|---|---|
| `is_tenant_member_v1(p_tenant_id uuid)` | true only when `auth.uid()` has an active membership and tenant is active | `authenticated` EXECUTE only |
| `has_tenant_role_v1(p_tenant_id uuid,p_roles text[])` | true only for active membership in the exact tenant and an allowed normalized role | `authenticated` EXECUTE only |
| `get_my_tenant_role_v1(p_tenant_id uuid)` | returns caller's active role or NULL; never another user's role | `authenticated` EXECUTE only |
| internal `active_single_tenant_id_v1()` | returns the sole active tenant only while the single-active guard exists; NULL/failure on ambiguity | internal/public-reader use only, no general client contract |

Implementation requirements:

- identity comes only from `auth.uid()`;
- NULL tenant, NULL user, empty roles, unknown roles, inactive tenant, pending membership, and suspended membership all fail closed;
- caller-provided tenant ID is only a lookup key, never proof of authorization;
- row policies call helpers with the row's `tenant_id`;
- `SECURITY DEFINER`, owner `postgres`, `STABLE`, and `SET search_path TO pg_catalog, public, pg_temp`;
- all relations/functions schema-qualified;
- `REVOKE ALL ... FROM PUBLIC, anon, service_role`; grant only the minimum to `authenticated`;
- no dynamic SQL;
- no role from JWT custom metadata or browser state;
- preserve existing no-argument helpers unchanged until their consumers move in 9D/9E.

The helper must check `tenants.status='active'`. A suspended/disabled tenant therefore denies tenant operations even if membership remains active.

## 7. RLS recursion analysis

Unsafe pattern:

```text
tenant_memberships policy
  -> has_tenant_role_v1(...)
     -> SELECT tenant_memberships
        -> tenant_memberships policy
           -> recursion
```

Safe pattern:

1. Membership self-read policy uses only `user_id = auth.uid()` (and optionally a direct tenant-status EXISTS that does not call a membership helper).
2. Tenant-role helpers are owner-controlled `SECURITY DEFINER` functions that directly query `tenant_memberships` and `tenants`; they do not depend on membership-table RLS evaluation.
3. No helper used by membership RLS calls back into a policy that invokes the same helper.
4. Tenant admin listing/managing memberships is not implemented as broad table RLS. It uses a bounded tenant-aware RPC in 9D.
5. Focused tests execute helper calls and membership SELECT under authenticated roles and explicitly assert absence of PostgreSQL `42P17`/infinite recursion.

Do not enable `FORCE ROW LEVEL SECURITY` on `tenant_memberships` while using an owner helper unless a separately reviewed non-recursive access design replaces the owner bypass. RLS remains protection for clients; helper correctness and minimal EXECUTE ACL protect the definer path.

## 8. Table-by-table RLS matrix

All target staff rules below require `membership.status='active'` and `tenants.status='active'` for the row's exact tenant. Direct destructive DML remains denied unless explicitly noted; controlled writes stay in RPC and are migrated in 9D.

| Table | Operation | Current policy | Target 9C policy | Owner/user rule | Admin/employee/instructor rule | Public rule | Risk |
|---|---|---|---|---|---|---|---|
| `shooting_lanes` | SELECT | active rows to PUBLIC; all rows to global staff | public active rows only for the single active tenant; staff rows only with same-tenant role | authenticated users retain public active view | admin/employee/instructor same tenant | active only, resolved by sole-active bridge while guard exists | High |
| `shooting_lanes` | INSERT/UPDATE/DELETE | no client write policy/ACL | keep denied; family writers move in 9D | none | controlled RPC only | none | High |
| `reservations` | SELECT | own rows; global admin/employee | own row only with active same-tenant membership; admin/employee same tenant | `user_id=auth.uid()` plus membership in row tenant | admin/employee; instructor denied as today | none | Critical |
| `reservations` | INSERT/UPDATE/DELETE | no direct client DML after hardening | keep denied | controlled owner RPC only | controlled RPC only | none | Critical |
| `lane_blocks` | SELECT | any authenticated sees active; global staff sees all | active block only within caller tenant; staff same tenant; public booking remains via bounded public contract | active same-tenant member | admin/employee/instructor same tenant | no new direct anon policy | High |
| `lane_blocks` | INSERT/UPDATE/DELETE | no direct DML | keep denied | none | controlled RPC in 9D | none | High |
| `events` | SELECT | anon/auth active globally; global staff all | public active rows for resolved sole active tenant; staff same tenant | public active view | admin/employee/instructor same tenant | PII-free active data only | High |
| `events` | INSERT/UPDATE/DELETE | controlled RPC | keep direct DML denied | registration is separate RPC | controlled RPC in 9D | none | High |
| `event_lanes` | SELECT | global staff | same-tenant staff; public event contracts remain RPC-based | no direct user access | admin/employee/instructor same tenant | none | High |
| `event_lanes` | INSERT/UPDATE/DELETE | controlled RPC | keep denied; composite FK already enforces tenant equality | none | controlled RPC in 9D | none | Critical |
| `event_registrations` | SELECT | owner; global admin/employee/instructor | owner with same-tenant membership; staff same tenant | `user_id=auth.uid()` plus membership | preserve admin/employee/instructor same-tenant behavior pending SEC-008 assignment model | none | Critical; SEC-008 remains |
| `event_registrations` | INSERT/UPDATE/DELETE | direct DML removed | keep denied | controlled owner RPC | controlled RPC in 9D | none | Critical |
| `email_deliveries` | SELECT/INSERT/UPDATE/DELETE | RLS enabled, no client policy/ACL | keep all direct client access denied | none | bounded RPC/service path only | none | Critical |
| `audit_logs` | SELECT | global admin | tenant admin sees only `tenant_id = membership tenant`; NULL/global audit excluded | none | tenant admin only; employee/instructor denied unless separately approved | none | Critical |
| `audit_logs` | INSERT/UPDATE/DELETE | direct mutation denied | keep denied | none | trusted business functions only | none | Critical |
| `tenants` | SELECT | no policy/ACL | authenticated caller may read minimal row for own active membership; public resolution stays a bounded contract | own membership tenant | same rule; role does not widen tenant set | no raw table grant | Medium |
| `tenants` | INSERT/UPDATE/DELETE | denied; one-active guard | keep denied | none | future platform provisioning only, outside 9C | none | Critical |
| `tenant_memberships` | SELECT | no policy/ACL | caller may read only own rows; tenant-admin list deferred to bounded 9D RPC | `user_id=auth.uid()` | own rows only through table | none | High |
| `tenant_memberships` | INSERT/UPDATE/DELETE | denied | keep denied; temporary trusted sync trigger and future controlled 9D RPC only | no self-escalation | no direct admin DML | none | Critical |
| `profiles` | SELECT | own row; global admin all profiles | own row only by direct table access; remove global admin table-wide policy | `user_id=auth.uid()` | tenant staff profile access only through tenant-scoped minimal DTO in 9D | none | Critical privacy boundary |
| `profiles` | INSERT | authenticated admin policy; Auth trigger also creates profiles | remove direct authenticated admin insert after confirming no app dependency; keep trusted Auth trigger | Auth lifecycle only | no direct insert | none | High |
| `profiles` | UPDATE/DELETE | direct updates already hardened; no broad delete | keep denied; self/admin controlled RPCs remain pending 9D tenant review | controlled self RPC | controlled tenant-aware RPC later | none | High |

### 8.1 Tenant-derived configuration tables

`lane_booking_rules`, `lane_booking_durations`, `lane_pricing_rules`, and `lane_booking_family_configuration_versions` have no direct `tenant_id` but derive tenant through `shooting_lanes`. They must not retain global helper policies when root tables become tenant-aware.

- Public active/online policies must join the lane and require the sole active public tenant during the guarded transition.
- Staff read policies must join the lane and call the tenant-role helper for `lane.tenant_id`.
- No direct client DML is added.
- Configuration-family writers remain a 9D responsibility.

`confirmation_email_rate_limits` remains a global anti-abuse table with no browser read/write contract. Do not attach tenant ownership merely for symmetry; tenant-specific rate-limit semantics require a separate threat/model decision.

## 9. `profiles` and global-user privacy impact

`profiles` is a global account profile. A tenant membership must not grant unrestricted read access to every global field or every global user. The current `Admins can view all profiles` policy becomes unsafe as soon as roles are tenant scoped.

Target design:

- a user retains direct access to their own global profile;
- tenant staff discover a person only through an active membership or a tenant-owned operational relation (reservation/event registration);
- staff DTOs expose only fields needed for the operation;
- no tenant role permits arbitrary `SELECT * FROM profiles`;
- global account lifecycle/export/anonymization stays owner-scoped;
- `admin_note`, verification, and permit/qualification semantics are currently global fields and cannot safely represent different tenant decisions.

SAAS-9C should remove global direct admin profile SELECT/INSERT exposure where application compatibility permits, but must not invent a tenant-specific verification model. Before second tenant activation, either add a tenant-user operational profile/verification relation or explicitly define which profile fields are globally shareable with informed user consent. This is a blocker for SAAS-9H, not for installing dormant/backfilled membership helpers under the one-tenant guard.

## 10. Admin/employee model

- `admin` and `employee` are tenant roles, not global account roles.
- Admin A may administer only tenant A rows and memberships through future controlled RPCs.
- Employee A may perform only the current employee operation subset for tenant A.
- Neither role implies access to tenant B.
- A global account may be `admin` in CSK and `user` elsewhere.
- Platform provisioning authority, if ever introduced, must be separate from tenant role and must not inherit tenant data access.
- The existing `pracownik` UI label can remain Polish while the canonical DB membership value is `employee`.

The current `admin_set_user_role_v1` changes global `profiles.role`; it cannot be the final tenant role management API. During the bridge it may continue only for CSK and must synchronize the CSK membership. A versioned, tenant-aware replacement belongs to 9D.

## 11. Public-read preservation

Current public behavior depends on direct active-lane/event policies and `SECURITY DEFINER` readers such as:

- `get_public_booking_configuration_v1()`;
- public busy/availability booking functions;
- `get_public_event_availability_v1()`;
- `get_public_event_list_v2(...)`.

9C must not block current CSK booking. While `tenants_single_active_runtime_guard` guarantees exactly one active runtime tenant, direct public policies can constrain rows to that single active tenant without a browser-provided tenant identifier. Public `SECURITY DEFINER` functions still bypass RLS and therefore remain explicitly in the 9D/9F migration inventory.

Before the guard is removed, public reads must take a trusted, validated tenant context (normally a route slug resolved to an active tenant) and scope every underlying query. Returning all active tenants is never an acceptable future implementation.

Public contracts remain PII-free and must not expose memberships, profiles, audit, email delivery, or internal tenant IDs unless a reviewed route contract needs a stable public identifier.

## 12. `service_role` inventory

No browser service-role usage was found. The current server-side paths are:

| Path | Current use | Required tenant control | Phase |
|---|---|---|---|
| `app/api/account/delete/route.ts` | Auth Admin `deleteUser()` after owner-scoped anonymization RPC | global account operation; verify anonymization touches only rows owned by authenticated user across all memberships/tenants and never accepts arbitrary user ID | 9D review; account routing in 9E |
| `lib/server/confirmation-email-delivery.ts` and three confirmation/cancellation routes | service client completes email claim/delivery after auth-context prepare | claim must carry/derive tenant from trusted reservation/event registration; completion must verify claim/record tenant, not browser input | 9D |
| `lib/server/event-reserve-promotion.ts` | service client prepares promotions and directly reads event/registrations | authenticate/authorize initiating staff before obtaining bypass client; derive tenant from event; constrain all reads/completions to same tenant; minimal recipient DTO | 9D/9E |
| load-test scripts | local-only test administration | preserve localhost safety; never production runtime | test tooling only |

Because `service_role` bypasses RLS and retains platform-managed broad table ACL, no service path may rely on 9C RLS. Each requires explicit tenant resolution, actor authorization, resource ownership validation, and bounded response DTO. SAAS-9C documents and tests the expected contract; 9D implements business-function changes.

## 13. Audit and email authorization

SAAS-9B-3 already derives and validates tenant ownership for `email_deliveries` and tenant-scoped audit targets.

### Email

- Keep direct table access denied to all client roles.
- Tenant ownership must continue to be derived from the trusted reservation/event target.
- Staff actions validate membership against that derived tenant before a claim is created.
- Service completion accepts only a valid claim tied to the same delivery/tenant.

### Audit

- Tenant-scoped rows have non-null `tenant_id` derived from the target.
- Global/account/platform rows retain `tenant_id=NULL`.
- Tenant admin A may read only non-null audit rows for A.
- Tenant admin never sees global NULL audit by virtue of tenant role.
- Global audit access requires a separate platform authority that does not exist in 9C.
- Audit INSERT/UPDATE/DELETE remains inaccessible directly.

The current global admin audit SELECT policy must be replaced during the 9C RLS cutover. Audit-producing `SECURITY DEFINER` writers are reviewed tenant-by-tenant in 9D.

## 14. Legacy `profiles.role` transition

### Phase A — source-compatible membership population

`profiles.role` remains authoritative. Backfill CSK memberships and install the one-way profile-to-CSK sync bridge. No application authorization reads membership yet.

### Phase B — additive tenant helpers

Install and test membership helpers. Existing `get_my_role()` and global helper signatures remain unchanged for deployed compatibility. No old helper is redefined to infer a tenant.

### Phase C — table RLS cutover

Replace legacy global-role policies on tenant-owned/derived tables with row-tenant membership policies. The CSK backfill makes current users compatible. UI may still show legacy role, but RLS is tenant authoritative and fail closed for suspended/missing membership.

### Phase D — prove legacy role cannot grant row access

Tests deliberately set a global admin role without membership in tenant B and prove table access B is denied. Conversely, membership B with global `user` must grant only the role permitted in B. Reconcile CSK profile/member role mapping after every test.

### Later 9D/9E transition

Versioned RPCs and middleware switch to membership. Role writes use one controlled tenant membership contract. The temporary sync bridge is retired only after all consumers and producers are cut over. `profiles.role` may remain as a deprecated compatibility/display column until a later contract migration; it must no longer authorize tenant data.

## 15. Temporary CSK default interaction

Seven temporary CSK defaults remain on:

- `shooting_lanes`;
- `reservations`;
- `lane_blocks`;
- `events`;
- `event_lanes`;
- `event_registrations`;
- `email_deliveries`.

Do not remove them in 9C. Existing legacy writers do not supply tenant ownership and would fail immediately.

Mandatory 9D sequence:

1. introduce tenant-aware writer versions and/or patch every still-authorized legacy writer to derive and explicitly write CSK while the guard is active;
2. verify no authorized INSERT path depends on defaults;
3. remove all seven defaults in one reviewed contract migration;
4. assert every write without explicit/derived tenant now fails;
5. only then cut application callers to fully tenant-aware writer contracts;
6. keep the second-active-tenant guard until SAAS-9H.

The production gate must assert `csk_defaults=0` before any second tenant can become active.

## 16. Migration phases

Do not implement 9C as one large migration.

### 9C-0 — decisions and production preflight

- approve instructor membership vocabulary;
- approve which existing profiles receive active CSK membership;
- capture production role distribution, counts, orphan checks, policy/ACL/function fingerprints;
- verify exactly one active CSK tenant, zero memberships, zero non-CSK business ownership, seven defaults, and active guard;
- enumerate all current policies/functions against effective production catalog;
- STOP on drift or unknown role.

No schema write.

### 9C-1A — membership vocabulary, backfill, and sync bridge

- minimally extend role CHECK if `instructor` is approved;
- backfill CSK memberships with exact count assertions;
- install one-way profile-to-CSK membership synchronization;
- keep membership client DML denied;
- no RLS consumer cutover yet.

Production gate: local DB reset/test, rollback-only matrix, migration dry-run, backup/checkpoint, short lock plan, post-deploy reconciliation.

### 9C-1B — helper foundation and safe self-read

- add versioned tenant helpers;
- hardened owner/search path/ACL;
- add own-membership SELECT policy/ACL only if needed for forthcoming context UI;
- optionally add authenticated own-tenant minimal SELECT policy while keeping raw tenants unavailable to anon;
- retain legacy helper definitions/fingerprints unchanged.

Production gate: helper truth table, recursion test, ACL audit, invalid/null/suspended/disabled fail-closed cases.

### 9C-2A — booking/catalog RLS cutover

Replace policies for `shooting_lanes`, derived lane configuration tables, `reservations`, and `lane_blocks`. Preserve public CSK booking through the sole-active-tenant bridge. Do not add direct writes.

Production gate: user/employee/admin/instructor CSK regression, anon booking, same-tenant owner reads, synthetic dormant-tenant cross-IDOR denial, application smoke.

### 9C-2B — events/audit/email/profile RLS cutover

Replace policies for `events`, `event_lanes`, `event_registrations`, `audit_logs`, and global profile direct access. Keep `email_deliveries` direct deny. Preserve public events via the sole-active bridge. Do not change business RPC definitions.

Production gate: public event contracts, owner registrations, staff tenant scope, SEC-008 residual explicitly recorded, audit NULL isolation, profile PII minimization, email direct deny.

### 9C-3 — legacy-RLS retirement verification

- assert no policy on a tenant-owned/derived table references `is_admin()`, `is_admin_or_employee()`, `is_admin_or_staff()`, or unscoped `profiles.role`;
- keep old functions only for still-deployed RPC/app compatibility;
- capture new RLS/ACL/helper fingerprints;
- execute full cross-tenant RLS matrix and current single-tenant regression;
- document every remaining global-role function as mandatory 9D work;
- do not remove the active-tenant guard or CSK defaults.

## 17. Test strategy

### 17.1 Focused SQL tests

Use synthetic tenants A/B and global users in one transaction ending in rollback. The production second-active guard means tenant B should be dormant for 9C policy tests unless a local-only test temporarily models active status without weakening the production guard migration.

Minimum matrix:

- User A/member A: own reservation/event registration A allowed; foreign owner A denied; tenant B denied.
- User A without membership B: all private B reads/writes denied.
- Admin A: staff reads A allowed; B denied even if `profiles.role='admin'`.
- Employee A: employee operations/read A allowed; B denied; admin-only A denied.
- Instructor A: current permitted same-tenant catalog/event visibility preserved; reservation customer/private operations remain according to current contract; B denied.
- Global user with A+B memberships: own permitted operations in both; different roles are enforced independently.
- Public: only explicitly public active data for the guarded active tenant; no memberships/PII/audit/email.
- Membership escalation: user cannot insert/update own role/status or another membership.
- Cross-tenant IDOR: substitute B resource IDs in every direct query; deny/no rows.
- Helper recursion: no recursion error; NULL/invalid tenant and empty role list return false/NULL.
- Tenant status: pending/suspended membership and suspended/disabled tenant deny.
- Audit: admin A sees audit A, not B or NULL/global.
- Email: no client table access; derived-tenant trigger invariants remain.
- Global role mismatch: `profiles.role=admin` plus no B membership never grants B table access.
- Reconciliation: CSK profile role and membership role stay mapped after controlled legacy role changes.

### 17.2 Service-role contract tests

RLS cannot test service bypass. Unit/integration tests must assert that each server path:

- authenticates the actor before creating a bypass client;
- resolves tenant from the trusted record, not request JSON/query params;
- verifies actor membership/ownership in that tenant;
- restricts all follow-up IDs to the resolved tenant;
- returns a bounded DTO and never exposes service credentials.

### 17.3 Regression suite per migration

- focused 9C SQL tests;
- full Supabase DB suite;
- all Node tests;
- TypeScript;
- production build;
- relevant Playwright for login, booking, admin, reservations, calendar, reports, events, check-in;
- npm audit production dependencies;
- ESLint changed files/full known baseline check;
- `git diff --check`.

### 17.4 Production gates

Every production step requires migration-history equality, SHA-256 capture, exact dry-run, lock-risk review, no unrelated pending migration, post-deploy catalog assertions, rollback-only synthetic checks where safe, full runtime smoke, and zero fixture residue.

## 18. Rollback strategy

### 18.1 Before RLS cutover

9C-1A/1B are additive. If validation fails inside the migration, the transaction rolls back. After deployment but before any RLS consumer cutover, a reviewed rollback may remove the sync trigger/helpers/memberships and restore the original membership CHECK because runtime still uses `profiles.role`.

### 18.2 After RLS cutover

Prefer forward-fix. Membership rows and sync bridge preserve the information needed to repair a policy. Emergency rollback is a separately prepared migration that restores exact pre-9C policy definitions and ACL fingerprints; it does not delete memberships or weaken unrelated ACL. Do not use migration repair.

Each domain cutover is separate so booking can be rolled forward/fixed without reverting event/audit policy work, and vice versa. A failed application smoke stops the next phase.

### 18.3 Compatibility safety

- old application + 9C-1 database: safe; membership is synchronized but not consumed;
- old application + 9C-2 database: intended to remain functional for CSK because all users are backfilled and policies evaluate row tenant; must be proven in staging/local E2E before production;
- 9E application + pre-9C database: unsafe; therefore app tenant-context deployment must not precede helpers/memberships;
- second active tenant in any 9C state: prohibited by the guard.

## 19. SEC-004 impact

SAAS-9C closes only the table-RLS/global-membership portion of SEC-004:

- active memberships become tenant scoped;
- global roles no longer grant direct table access to another tenant;
- tenant-owned/derived table RLS becomes row-tenant aware;
- tenant audit visibility is isolated;
- direct membership privilege escalation is denied.

SEC-004 remains **OPEN** because:

- legacy and business `SECURITY DEFINER` RPCs still authorize through global `profiles.role` until 9D;
- service-role paths are not fully tenant constrained until 9D/9E;
- middleware and application routing have no trusted tenant context until 9E;
- public and module read contracts require explicit tenant cutover in 9D/9F;
- reports/events/calendar/check-in/booking need end-to-end tenant context validation in 9F;
- cross-tenant concurrency and IDOR proof is incomplete until 9G;
- tenant-user verification/profile privacy and all residual gates require final 9H audit.

SEC-004 may close only after SAAS-9H proves all of those boundaries, removes temporary compatibility mechanisms as planned, and confirms second-tenant activation is safe.

## 20. Blocking decisions

### Blocker 1 — instructor role

Approve one option before migration authoring:

- **Recommended:** add membership role `instructor`, map `instruktor -> instructor`, preserve current same-tenant permissions, leave SEC-008 assignment scoping deferred.
- Reject mapping to `user` (silent privilege removal) or `employee` (silent privilege escalation).

### Blocker 2 — existing membership universe/status

Approve whether every auth-backed profile becomes an `active` CSK member. Recommended: yes, with verification status remaining independent. If inactive/former accounts require exclusion, the exact data signal must be identified before backfill; it cannot be guessed.

### Required evidence, not a business decision

- production role distribution and orphan counts;
- zero existing conflicting memberships;
- exact effective production RLS/ACL/function fingerprints;
- proof that removing global admin direct profile SELECT/INSERT does not break current application flows;
- explicit list of public reader functions for the 9D manifest.

## 21. GO / NO-GO

The implementation shape is technically viable and preserves the single-tenant runtime through a controlled bridge. It deliberately does not activate a second tenant, remove CSK defaults, rewrite business RPCs, or switch application routing.

SAAS-9C TECHNICAL PLAN: **READY**

READY FOR SAAS-9C IMPLEMENTATION: **NO-GO — instructor-role and membership-activation decisions required, followed by production read-only preflight**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 24. SAAS-9C-1 PRODUCTION PREFLIGHT & DEPLOYMENT READINESS

Preflight wykonano 10 września 2026 r. dla produkcyjnego projektu o ref `yuyxfodozzpzrdzkmolu`. Produkcyjna część była read-only: odczyty katalogów/danych, `migration list` i `db push --linked --dry-run`. Nie wykonano produkcyjnego DML/DDL, migracji, `migration repair`, właściwego `db push`, commita ani pushu Git.

### 24.1 Fresh auth/profile state i account-state inventory

| Kontrola | Wynik |
|---|---:|
| `auth.users` | 9 |
| `profiles` | 9 |
| sparowane Auth ↔ profile | 9 |
| profile bez Auth | 0 |
| Auth bez profilu | 0 |
| role `admin` / `user` | 1 / 8 |
| role `pracownik` / `instruktor` | 0 / 0 |
| rola NULL/blank/nieznana | 0 |
| deleted users | 0 |
| obecnie banned users | 0 |
| niepotwierdzony email | 1 |
| verification `pending` / `verified` / `rejected` | 5 / 3 / 1 |

Niepotwierdzony email nie jest niejednoznacznym stanem według zatwierdzonego kontraktu 9C-1: backfill aktywuje każde konto posiadające profil i rekord Auth, które nie jest usunięte ani aktualnie zbanowane. `verification_status` i potwierdzenie email nie są `membership.status`; migracja świadomie nie miesza tych wymiarów. Każdy orphan, deleted/banned account albo nieznana/nienormalizowana rola nadal zatrzymuje migrację fail-closed.

### 24.2 Current membership state i dokładny wynik backfillu

Produkcja przed wdrożeniem ma `tenant_memberships = 0`, duplicate `(tenant_id,user_id) = 0`, orphan `user_id = 0` i orphan `tenant_id = 0`.

| Oczekiwany wynik 9C-1A | Liczba |
|---|---:|
| kwalifikujące profile | 9 |
| wszystkie CSK memberships po backfillu | 9 |
| rola `admin` | 1 |
| rola `user` | 8 |
| rola `employee` | 0 |
| rola `instructor` | 0 |
| status `active` | 9 |
| status `pending` | 0 |
| status `suspended` | 0 |

Mapowanie jest jawne i bez fallbacku: `admin→admin`, `user→user`, `pracownik→employee`, `instruktor→instructor`; odwrotnie `admin→admin`, `user→user`, `employee→pracownik`, `instructor→instruktor`. Nieznana wartość zwraca NULL w funkcji mapującej, a trigger/migracja kończy się błędem zamiast zgadywać rolę.

### 24.3 `handle_new_user` i ścieżka nowego konta

Rzeczywisty katalog produkcyjny potwierdza trigger `on_auth_user_created`: `AFTER INSERT ON auth.users FOR EACH ROW`, wywołujący `public.handle_new_user()`. Funkcja jest własnością `postgres`, działa jako `SECURITY DEFINER`, ma `search_path = public, pg_temp`, a `PUBLIC`, `anon`, `authenticated` i `service_role` nie mają bezpośredniego `EXECUTE`.

`handle_new_user()` pobiera z Auth email oraz bezpiecznie normalizowane metadane imienia/nazwiska/telefonu, po czym wykonuje upsert profilu z domyślną rolą `user` i `verification_status = pending`. Po 9C-1 dokładna ścieżka nowej rejestracji będzie następująca:

1. `INSERT auth.users` uruchamia produkcyjny `on_auth_user_created`;
2. `handle_new_user()` tworzy/upsertuje `profiles` z `role=user`;
3. `AFTER INSERT OR UPDATE OF role ON profiles` uruchamia `sync_profile_role_to_csk_membership()`;
4. trigger widzi istniejący, nieusunięty i niezbanowany rekord Auth;
5. jawne mapowanie daje membership role `user`;
6. brakujący membership CSK zostaje utworzony ze statusem `active`.

Nie jest wymagany późniejszy ręczny backfill. Lokalny katalog nie zawiera platformowego triggera `auth.users→profiles`, dlatego lokalny test dowodzi kroku `profile→membership`, natomiast istnienie i kontrakt pierwszego kroku potwierdzono bezpośrednio w katalogu produkcyjnym. Nowy-user flow pozostaje obowiązkowym smoke po wdrożeniu.

### 24.4 Sync bridge: rekurencja, non-CSK safety i status

Bridge jest tymczasowo dwukierunkowy, zgodnie z zatwierdzoną decyzją. Rekurencję kończą symetryczne warunki `IS DISTINCT FROM`: profil aktualizuje CSK membership tylko, gdy canonical role faktycznie się różni, a CSK membership aktualizuje profil tylko, gdy legacy role faktycznie się różni. Drugie wejście triggera zastaje już wartość docelową i nie wykonuje kolejnego UPDATE. Reverse trigger natychmiast zwraca `NEW` dla `tenant_id <> CSK`, więc membership przyszłego tenant B nie może zmienić globalnego `profiles.role`.

Focused test zakończył się `47/47 PASS`, exit code 0, jednym `BEGIN`/`ROLLBACK` i zerem fixture. Dodatkowy rollback-only test zakończył się komunikatem `SAAS9C_EXTRA_ROLLBACK_TEST_PASS` i potwierdził:

- deterministyczne zakończenie obu kierunków bez infinite recursion;
- zmianę tenant B `user→employee` bez zmiany profilu i CSK membership;
- zachowanie `membership.status` osobno dla `active`, `pending` i `suspended`, zarówno przy forward, jak i reverse role sync;
- dokładnie dwa membershipy syntetycznego użytkownika i `remaining_fixture=0` po rollbacku.

### 24.5 Helper security model

Wszystkie cztery planowane helpery są własnością `postgres`, mają `SECURITY DEFINER` i `search_path = pg_catalog, public, pg_temp`.

| Funkcja | PUBLIC | anon | authenticated | service_role | Tożsamość / walidacja |
|---|---|---|---|---|---|
| `is_tenant_member_v1(uuid)` | brak | brak | EXECUTE | brak | wyłącznie `auth.uid()`; wskazany tenant musi istnieć i być active; membership musi być active |
| `has_tenant_role_v1(uuid,text[])` | brak | brak | EXECUTE | brak | wyłącznie `auth.uid()`; tenant i membership active; role-array niepusty i wyłącznie z approved vocabulary |
| `get_my_tenant_role_v1(uuid)` | brak | brak | EXECUTE | brak | wyłącznie `auth.uid()`; zwraca rolę własnego active membership w active tenant |
| `active_single_tenant_id_v1()` | brak | brak | brak | brak | helper wewnętrzny; zwraca ID tylko przy dokładnie jednym active tenant |

Żaden helper nie przyjmuje dowolnego `user_id`; parametr tenant ID nie omija kontroli członkostwa/tożsamości. NULL, nieznana rola, pusty role-array, dormant tenant, brak sesji i suspended membership kończą się fail-closed.

### 24.6 Membership RLS i direct privilege escalation

Planowana jedyna polityka brzmi logicznie `user_id = (select auth.uid())` i nie wywołuje helpera czytającego `tenant_memberships`; nie istnieje więc cykl `policy→helper→RLS→policy`. Focused test potwierdził, że authenticated widzi wyłącznie własne membershipy, a cudze są niewidoczne.

ACL daje `authenticated` wyłącznie TABLE SELECT. `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`, `REFERENCES`, `TRIGGER` i `MAINTAIN` pozostają niedostępne; anon nie ma dostępu. Testy potwierdziły deny dla self-assignment, zmiany role/status, usuwania i tworzenia membershipu innej osoby. Helpery nie są dostępne dla anon ani service_role przez jawny grant.

### 24.7 Legacy runtime compatibility i fingerprinty

9C-1 nie przełącza aplikacji ani business RLS/RPC na membership authorization. `profiles.role`, `get_my_role()`, `is_admin()`, `is_admin_or_employee()` i `is_admin_or_staff()` pozostają aktywnym legacy źródłem autoryzacji. Nie zmieniają się Booking, Reservations, Events, Calendar, Reports, Check-in, lane configuration, profile update ani writer contracts.

Świeży preflight potwierdził zachowanie zakresu 9B-3: jeden active CSK tenant, partial unique index `tenants_single_active_runtime_guard`, osiem validated tenant FK i dokładnie siedem temporary CSK defaults. Porównywalne production baseline pozostają: business RLS `f5c428bd4e241af39f690c1aafcfad08`, table ACL `cf05faffa475999df163338c3c1e805f`, 66 funkcji `SECURITY DEFINER`, oraz niezmienione indywidualne hashe krytycznych legacy helperów (`get_my_role`, `is_admin`, `is_admin_or_employee`) i public readers zapisane w sekcji 22. Nie porównywano ze sobą aggregate hashy zbudowanych różnymi zapytaniami/orderingiem, aby nie zgłaszać sztucznego driftu.

Dozwolony drift po wdrożeniu ogranicza się do: rozszerzenia membership role CHECK o `instructor`, dziewięciu CSK membershipów, dwóch triggerów i funkcji mapujących/synchronizujących, czterech helperów, authenticated SELECT oraz jednej self-read policy na `tenant_memberships`. Migracja 9C-1B sama wykonuje snapshot i postflight legacy helperów oraz wszystkich non-membership policies.

### 24.8 Migration history i deployment fingerprints

`supabase migration list --linked` zakończył się kodem 0. LOCAL=REMOTE przez produkcyjny checkpoint `20260909130000`; brak remote-only i divergence. Pending są dokładnie:

1. `20260910100000_add_csk_membership_backfill_sync.sql` — SHA-256 `9BD9F91237E79351C348BE9457DF14CDFEECE251311105D15EA27FCC31D2AF5C`;
2. `20260910110000_add_tenant_membership_authorization_helpers.sql` — SHA-256 `22F063D9A15097062724A1CF7EE0E234B7D6B0EC296D68BABEFFF73E88149758`.

Są to dokładnie dwie nowe migracje. Historyczne migracje 9B nie mają tracked diff. Po tym preflight migracje są deployment-frozen; każda edycja wymaga ponownego pełnego review, SHA i dry-run.

### 24.9 Lock/write risk

9C-1A zmienia CHECK na obecnie pustej tabeli membership, wstawia tylko dziewięć wierszy i tworzy dwa triggery. `ALTER TABLE` wymaga krótkiego silnego locka, ale przy zerowym membership volume oczekiwany czas i ryzyko są niskie. Interakcja Auth/profile jest chroniona transakcją, preflightem 1:1, limitami `lock_timeout=5s` i `statement_timeout=120s`. Wdrożenie powinno nastąpić w okresie małego ruchu, aby nie kolidować z chwilowym tworzeniem/zmianą profilu; pełne maintenance window nie jest wymagane przy obecnym wolumenie.

9C-1B tworzy cztery małe funkcje, jeden grant i jedną politykę na małej tabeli; lock/write risk jest niski. Funkcjonalne ryzyko dotyczy głównie błędnego ACL/RLS, ale migracyjny postflight i focused matrix zatrzymują szeroki grant, recursive policy albo drift legacy authorization.

### 24.10 Dry-run i runtime baseline

`supabase db push --linked --dry-run` zakończył się kodem 0 i wskazał dokładnie, w kolejności: `20260910100000_add_csk_membership_backfill_sync.sql`, następnie `20260910110000_add_tenant_membership_authorization_helpers.sql`. Nie wykonano właściwego pushu.

Bieżący read-only HTTP baseline: `/booking`, `/login`, `/register`, `/events` i `/account` odpowiadają bez 5xx; anonimowe wejścia `/admin`, `/admin/reservations`, `/admin/calendar`, `/admin/reports`, `/admin/check-in` i `/admin/lane-configuration` bezpiecznie kończą na `/login?redirectTo=...`. Najnowsze zapisane production smoke potwierdzają funkcjonalne PASS dla Booking, Reservations, Calendar, Reports, Events, Check-in, lane configuration, login oraz account/profile update. Po deploymencie trzeba ponownie wykonać ten sam matrix, ze szczególnym testem: normalna rejestracja tworzy dokładnie jeden profil i jeden active CSK membership `user`.

### 24.11 Blocking issues i rekomendacja

Nie wykryto blokera danych, membershipów, roli, account state, historii migracji, bridge recursion, non-CSK isolation, status preservation, helper ACL/RLS ani dry-run. Znane ograniczenia pozostają świadome: aplikacja nadal autoryzuje przez `profiles.role`, helpery nie są jeszcze konsumowane przez business RLS, local stack nie odtwarza produkcyjnego triggera Auth→profile, a właściwy new-user end-to-end proof musi być wykonany po wdrożeniu. Żadne z nich nie rozszerza aktualnego runtime ani nie zezwala na drugi tenant.

SAAS-9C-1 PRODUCTION PREFLIGHT: **PASS**

NEW USER MEMBERSHIP PATH: **PASS**

SYNC BRIDGE RECURSION: **PASS**

NON-CSK MEMBERSHIP SAFETY: **PASS**

MEMBERSHIP STATUS PRESERVATION: **PASS**

HELPER SECURITY: **PASS**

MEMBERSHIP RLS: **PASS**

READY FOR PRODUCTION PUSH: **YES**

READY FOR SAAS-9C-2: **NO-GO until 9C-1 production PASS**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 23. Approved role bridge and SAAS-9C-1 local checkpoint

The product owner approved the complete compatibility map:

| Direction | Source | Target |
|---|---|---|
| legacy → membership | `admin` | `admin` |
| legacy → membership | `user` | `user` |
| legacy → membership | `pracownik` | `employee` |
| legacy → membership | `instruktor` | `instructor` |
| membership → legacy | `admin` | `admin` |
| membership → legacy | `user` | `user` |
| membership → legacy | `employee` | `pracownik` |
| membership → legacy | `instructor` | `instruktor` |

No fallback or string-identity assumption is allowed. An unknown value aborts synchronization. The reverse bridge is limited to CSK while `profiles.role` remains the deployed legacy authorization source; a membership of another tenant never rewrites the global legacy role.

Local SAAS-9C-1 implementation is split as approved:

- `20260910100000_add_csk_membership_backfill_sync.sql`: role constraint expansion, production-preflight assertions, deterministic active-CSK backfill, explicit mapping functions, two-way compatibility bridge, lifecycle-status preservation, and banned/deleted-account fail-closed checks;
- `20260910110000_add_tenant_membership_authorization_helpers.sql`: minimal versioned tenant membership helpers, hardened function ACL/search path/ownership, and one non-recursive authenticated self-read policy on memberships.

The phase does not modify business-table RLS, legacy role helpers, business RPCs, application tenant resolution, the seven temporary CSK defaults, or any writer. Local clean reset and the complete database test suite pass. Production deployment remains blocked pending a dedicated migration-history/data/fingerprint/dry-run preflight.

SYNC BRIDGE: **READY**

SAAS-9C-1 LOCAL IMPLEMENTATION: **PASS**

READY FOR SAAS-9C-1 PRODUCTION PREFLIGHT: **GO**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 25. SAAS-9C-1 PRODUCTION DEPLOYMENT & POST-DEPLOY VERIFICATION

Wdrożenie i post-deploy verification wykonano 10 września 2026 r. na linked production project `yuyxfodozzpzrdzkmolu`. Po zatwierdzonym pushu nie wykonywano żadnej niezależnej trwałej zmiany danych ani schematu, `migration repair`, ręcznej naprawy SQL, zmiany aplikacji, commita ani pushu Git.

### 25.1 Final pre-push gate

Bezpośrednio przed wdrożeniem ponownie potwierdzono:

- `auth.users=9`, `profiles=9`, matched `9`, profile orphan `0`, Auth bez profilu `0`;
- `deleted=0`, aktualnie banned `0`, unknown/nienormalizowane role `0`;
- role profili: `admin=1`, `user=8`;
- `tenant_memberships=0`, duplicate membership `0`, orphan user/tenant `0`;
- kwalifikujące profile `9`, oczekiwane CSK membershipy `9`, w tym `admin=1`, `user=8`, wszystkie `active`;
- aktywny tenant CSK był dokładnie jeden;
- LOCAL=REMOTE do `20260909130000`, bez remote-only divergence;
- pending były dokładnie dwie zatwierdzone migracje.

Fingerprints przed push:

| Migracja | SHA-256 |
|---|---|
| `20260910100000_add_csk_membership_backfill_sync.sql` | `9BD9F91237E79351C348BE9457DF14CDFEECE251311105D15EA27FCC31D2AF5C` |
| `20260910110000_add_tenant_membership_authorization_helpers.sql` | `22F063D9A15097062724A1CF7EE0E234B7D6B0EC296D68BABEFFF73E88149758` |

Finalny dry-run zakończył się kodem 0 i wskazał wyłącznie te dwa pliki, w tej kolejności.

### 25.2 Deployment output i historia migracji

`supabase db push --linked` zastosował kolejno:

1. `20260910100000_add_csk_membership_backfill_sync.sql`;
2. `20260910110000_add_tenant_membership_authorization_helpers.sql`.

Polecenie zakończyło się kodem 0 i komunikatem `Finished supabase db push`. Post-deploy `migration list --linked` pokazuje LOCAL=REMOTE dla obu wersji `20260910100000` i `20260910110000`. Końcowy `db push --linked --dry-run` zakończył się kodem 0 oraz `Remote database is up to date`.

### 25.3 Membership backfill

| Post-deploy control | Wynik |
|---|---:|
| wszystkie membershipy | 9 |
| CSK membershipy | 9 |
| role `admin` / `user` | 1 / 8 |
| role `employee` / `instructor` | 0 / 0 |
| status `active` | 9 |
| mapping mismatch względem `profiles.role` | 0 |
| profil bez CSK membership | 0 |
| duplicate `(tenant_id,user_id)` | 0 |
| orphan `user_id` / `tenant_id` | 0 / 0 |

Backfill odpowiada dokładnie świeżemu pre-push expected result.

### 25.4 New-user path, bridge i rollback proof

Kontrolowany test produkcyjny wykonano w jednej jawnej transakcji zakończonej `ROLLBACK`. Użyto wyłącznie unikalnego syntetycznego konta i dormant tenant fixture. Test udowodnił rzeczywisty łańcuch:

`auth.users INSERT → on_auth_user_created → handle_new_user() → profiles(user,pending) → sync_profile_role_to_csk_membership() → CSK membership(user,active)`.

Następnie potwierdzono:

- forward sync `profiles.pracownik → membership.employee`;
- reverse sync `membership.instructor → profiles.instruktor`;
- deterministyczne zakończenie triggerów bez rekurencji;
- status `suspended` pozostał `suspended` po zmianie roli profilu na `admin`;
- membership dormant tenant B zmieniony `user→employee` nie zmienił ani globalnego profilu, ani CSK membership;
- second-active-tenant guard nie został usunięty ani obchodzony.

Po rollbacku: synthetic Auth users `0`, synthetic profiles `0`, synthetic tenants `0`; trwały production membership total pozostał `9`.

### 25.5 Membership RLS, escalation i helpery

Produkcja ma dokładnie jedną membership policy: authenticated SELECT z warunkiem `user_id = (select auth.uid())`. Transakcyjny test potwierdził own row visible i foreign rows hidden. Próby authenticated `INSERT`, zmiany `role`, zmiany `status` i `DELETE` zakończyły się `42501`; anon SELECT również zakończył się `42501`.

ACL po wdrożeniu:

- authenticated: SELECT `true`, INSERT/UPDATE/DELETE `false`;
- anon: SELECT/DML `false`;
- service_role: jawny TABLE SELECT/DML `false` w zatwierdzonym kontrakcie 9C-1.

Każdy z czterech helperów ma owner `postgres`, `SECURITY DEFINER`, `search_path=pg_catalog, public, pg_temp` i brak EXECUTE dla PUBLIC/anon/service_role. Authenticated ma EXECUTE wyłącznie do `is_tenant_member_v1`, `has_tenant_role_v1` i `get_my_tenant_role_v1`; `active_single_tenant_id_v1` pozostaje całkowicie wewnętrzny. Produkcyjny test potwierdził poprawne wyniki trzech helperów dla syntetycznego active user membership. Tożsamość pochodzi wyłącznie z `auth.uid()`, bez parametru arbitrary `user_id`.

### 25.6 Legacy compatibility i security fingerprints

`profiles.role` pozostaje aktywnym runtime authorization source. Business RLS, Booking/Events RLS, RPC authorization i application role checks nie zostały przełączone na membershipy.

Post-deploy fingerprint business policies z wyłączeniem świadomie dodanej `tenant_memberships` policy nadal wynosi `f5c428bd4e241af39f690c1aafcfad08`. `get_my_role()` i `is_admin()` zachowały production hashe odpowiednio `dc8858eed7d2fd2d1ab47d22b0000b06` i `89a221fa092af2a457db05a64b7e8d18`. Migracja 9C-1B dodatkowo wykonała w tej samej transakcji before/after snapshot `get_my_role`, `is_admin`, `is_admin_or_employee`, `is_admin_or_staff` i wszystkich non-membership policies; każdy drift przerwałby deployment.

Tekstowy `pg_get_functiondef()` dla produkcyjnego `is_admin_or_employee()` ma inny whitespace niż definicja odtworzona przez lokalny baseline, dlatego raw hash różni się (`15514f...` vs lokalny `396512...`). Źródła są semantycznie identyczne (`auth.uid()` oraz role `admin/pracownik`), a po usunięciu whitespace oba mają identyczny hash `48dff104c291e517a36c7b3817f75026`. Nie jest to drift spowodowany wdrożeniem.

Liczba `SECURITY DEFINER` wzrosła z 66 do oczekiwanych 72: dokładnie dwa sync triggery i cztery helpery. Dwie funkcje mapujące pozostają `SECURITY INVOKER`. Active-tenant guard nadal istnieje, a liczba temporary CSK defaults nadal wynosi 7. `profiles.role` i tenant integrity constraints nie zostały zmienione poza zatwierdzonym rozszerzeniem membership role CHECK o `instructor`. Nie wykryto nieplanowanego business table ACL/RLS/RPC driftu.

### 25.7 Runtime smoke

W realnej zalogowanej sesji administratora, po wdrożeniu, bez wykonywania mutacji:

| Moduł | Wynik |
|---|---|
| Admin dashboard | PASS |
| Reservations | PASS |
| Calendar | PASS |
| Reports | PASS |
| Events admin | PASS |
| Check-in | PASS |
| Lane configuration | PASS |
| Booking public | PASS |
| Events public | PASS |
| Account/profile screen | PASS |
| Register | PASS |
| Login | PASS |

Wszystkie ekrany załadowały właściwy nagłówek i dane/stan bez 5xx lub application error. Nie zmieniono profilu, rezerwacji, eventu ani konfiguracji.

### 25.8 Remaining risks i final verdict

SAAS-9C-1 jest nadal warstwą kompatybilności: business authorization pozostaje legacy, dwa systemy ról są synchronizowane, siedem CSK defaults nadal istnieje, a drugi tenant jest technicznie i proceduralnie zabroniony. Bridge musi zostać usunięty dopiero po kontrolowanym cutoverze tenant-aware writers/authorization. SEC-004 nie jest tym etapem zamknięty.

SAAS-9C-1 PRODUCTION DEPLOY: **PASS**

SAAS-9C-1 POST-DEPLOY VERIFICATION: **PASS**

MEMBERSHIP BACKFILL: **PASS**

NEW USER MEMBERSHIP PATH: **PASS**

SYNC BRIDGE: **PASS**

PRIVILEGE ESCALATION: **PASS**

READY FOR GIT CHECKPOINT: **YES**

READY FOR SAAS-9C-2 PLANNING: **GO**

READY FOR SAAS-9C-2 IMPLEMENTATION: **NO-GO until checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 22. PRODUCTION PREFLIGHT & FINAL IMPLEMENTATION PHASING

This section records the read-only production preflight performed after approval of the target membership role `instructor` and the conditional existing-user membership rule. All production statements were SELECT/catalog reads in the Supabase SQL Editor. No DML, DDL, migration, fixture, RLS/ACL change, RPC call with mutation semantics, or deployment was executed.

### 22.1 Auth/profile counts

| Metric | Production result |
|---|---:|
| AUTH USERS | 9 |
| PROFILES | 9 |
| MATCHED | 9 |
| PROFILE ORPHANS | 0 |
| AUTH WITHOUT PROFILE | 0 |

The production identity/profile universe is one-to-one for all nine current accounts. There is no orphan requiring inference or manual classification.

### 22.2 Role inventory and mapping

| Current production role | Count | Target membership role | Mapping confidence |
|---|---:|---|---|
| `admin` | 1 | `admin` | Confirmed/approved |
| `user` | 8 | `user` | Confirmed/approved |
| `employee` | 0 | `employee` | Approved target mapping; no current row |
| `instruktor` | 0 | `instructor` | Confirmed/approved; no current row |
| Unknown/NULL/blank | 0 | none | Would block |

The current production dataset can be backfilled without ambiguous role conversion.

There is one repository-contract discrepancy that must be resolved before installing the ongoing sync bridge: current application code, route permissions, helpers, and administrative RPC semantics use legacy value `pracownik`, not `employee`. Examples include `middleware.ts`, `lib/admin/route-protection.js`, reservation/event server routes, `is_admin_or_employee()`, `is_admin_or_staff()`, and `admin_set_user_role_v1`. Production has zero employee/pracownik rows today, so this does not block the one-time data calculation, but a later legacy role change to `pracownik` would be unmappable under the literal approved list.

Required decision for implementation:

- recommended compatibility input map: both `employee` and legacy `pracownik` map to canonical membership `employee`;
- canonical membership output remains exactly `admin/employee/user/instructor`;
- do not change legacy application labels or `profiles.role` vocabulary in 9C-1;
- if this alias is not approved, the sync bridge must fail closed on `pracownik`, which would break a legitimate current admin role operation.

No mapping was applied during preflight.

### 22.3 Account-status inventory and membership-status recommendation

Production `auth.users` exposes the potentially relevant account-level columns `banned_until` and `deleted_at`; `email_change_confirm_status` is an email-change workflow field, not an account suspension state. Production counts are:

| Account state | Count | Recommended membership status |
|---|---:|---|
| live: not currently banned and `deleted_at IS NULL` | 9 | `active` |
| currently banned (`banned_until > now()`) | 0 | do not create active membership; fail/explicitly classify before migration |
| soft-deleted (`deleted_at IS NOT NULL`) | 0 | no live membership; fail/explicitly classify before migration |

`profiles` has no account disabled/suspended/banned/blocked/deleted/inactive column. Its only status-like field is `verification_status`, with production distribution:

| Verification status | Count |
|---|---:|
| `pending` | 5 |
| `rejected` | 1 |
| `verified` | 3 |

Verification is not membership lifecycle. Pending or rejected verification must not automatically produce a suspended membership. Given the approved conditional rule and the observed zero banned/deleted accounts, all nine current matched live users are eligible for `status='active'` in the planned CSK backfill.

The migration must repeat these checks transactionally. Any account that becomes banned/deleted between this preflight and implementation requires explicit handling and must stop the migration rather than be silently activated.

### 22.4 Current membership state

| Check | Result |
|---|---:|
| total memberships | 0 |
| duplicate `(tenant_id,user_id)` pairs | 0 |
| missing Auth user FK target | 0 |
| missing tenant FK target | 0 |
| existing membership roles | none |
| existing membership statuses | none |

The expected dormant baseline is confirmed. There is no row to merge or overwrite. The implementation must continue to treat any newly appearing membership before deployment as drift and STOP; it must not use blanket upsert.

### 22.5 Membership schema extension

Production definition:

- type: `text`, NOT NULL;
- default role: `user`;
- current role CHECK: `role = ANY (ARRAY['admin','employee','user'])`;
- required CHECK: add `instructor`, retaining all current values;
- status type: `text`, NOT NULL;
- status default: `pending`;
- status CHECK: `active`, `pending`, `suspended`;
- primary key: `(tenant_id,user_id)`;
- supporting indexes: `(user_id,status,tenant_id)` and `(tenant_id,role,status,user_id)`.

Adding `instructor` to the text CHECK is metadata/constraint work and rewrites no row value. Existing data impact is zero because the table is empty. Existing indexes already support all four role values and need no definition change. Tests must prove all four target roles are accepted, unknown/legacy Polish membership outputs are rejected, and `instruktor` is normalized only at the compatibility input boundary.

### 22.6 Verified 47-function dependency matrix

Production catalog confirms exactly 47 functions matching the current global authorization dependency criteria. All are currently `SECURITY DEFINER`.

| Group | Production functions | Current auth source | Target auth source | Phase | Risk |
|---|---|---|---|---|---|
| DB role helpers | `get_my_role`, `is_admin`, `is_admin_or_employee`, `is_admin_or_staff` | `auth.uid() -> profiles.role` | versioned active membership helpers for exact tenant | 9C helper foundation; old signatures retired later | Critical |
| Lane/block/config | `admin_create_lane_block`, `admin_update_lane_block`, `admin_set_lane_block_active`, `admin_create_lane_booking_family_v1`, `admin_get_lane_booking_configuration_v1`, `admin_get_lane_booking_configuration_v2`, `admin_set_lane_booking_configuration`, `admin_set_lane_booking_family_configuration_v2`, `lane_booking_family_business_snapshot_v2` | inline profile role or legacy helpers | target resource/root tenant plus membership role | 9D | Critical |
| Reservation/check-in | `create_reservation`, `create_reservation_v2`, `cancel_reservation`, `get_check_in_reservation_v1`, `get_reservation_customer_profiles_v1`, `update_reservation_admin_note`, `update_reservation_attendance`, `update_reservation_payment` | owner plus global profile role | authenticated owner and/or staff membership in derived lane/reservation tenant | 9D | Critical |
| Event lifecycle | `admin_create_event`, `admin_create_event_v2`, `admin_update_event`, `admin_update_event_v2`, `admin_set_event_active`, `admin_set_event_active_v2`, `admin_list_events_v1`, `admin_list_event_registrations_v1`, `register_for_event`, `cancel_event_registration`, `approve_event_registration`, `mark_event_registration_paid` | owner plus global profile role | event/registration tenant plus active membership | 9D | Critical |
| Reports/users | `admin_get_reservation_report_v1`, `admin_get_reservation_report_v2`, `admin_get_reservation_report_export_v1`, `admin_list_users_v1`, `admin_set_user_role_v1`, `admin_set_user_note_v1`, `update_profile_identity`, `update_profile_contact_details`, `update_profile_verification` | global admin/employee role | selected tenant membership and tenant-bounded DTO; global profile operations separately constrained | 9D/9E/9F | Critical privacy |
| Account/email/profile support | `anonymize_my_account_v1`, `export_my_data_v1`, `prepare_confirmation_email`, `update_my_profile_v1`, `prevent_non_admin_profile_privilege_changes`, `handle_new_user` | owner/global profile or legacy role | global-owner logic where appropriate; tenant derived from each business target where applicable | 9D review; global profile lifecycle retained | High |

Function-specific production metadata also confirms several legacy functions still use weaker `search_path=public` or `public, pg_temp` rather than the newer hardened convention. SAAS-9D must version or replace those definitions; 9C must not bulk-edit them as a side effect of RLS work.

### 22.7 Non-function authorization dependency inventory

| Category | Name/file | Current source | Target source | Owner phase | Risk |
|---|---|---|---|---|---|
| DB RLS | 22 effective policies listed below | global helpers or owner UID | row tenant plus membership; owner UID plus row tenant | 9C-3/9C-4 | Critical |
| App server middleware | `middleware.ts` | direct `profiles.role` | route-resolved tenant plus membership role | 9E | Critical |
| Route permission map | `lib/admin/route-protection.js` | global Polish role | canonical tenant role mapped to route capability | 9E | High |
| API | `app/api/admin/calendar-feed/route.ts` | `get_my_role()` | trusted tenant context plus membership | 9E/9F | High |
| API | `app/api/send-reservation-cancellation/route.ts` | direct operator `profiles.role`, reservation RLS/owner | reservation-derived tenant plus owner or tenant staff membership | 9D | Critical |
| API | `app/api/send-event-reserve-promotion/route.ts` | direct `profiles.role` before service bypass | event-derived tenant plus admin/employee membership | 9D/9E | Critical |
| API | account/calendar/register/cancel/create/email routes | auth user and current RPC contracts | global owner where appropriate; tenant-bound RPC for business records | 9D/9E | High |
| Frontend visibility | home, admin dashboard, Calendar, Reports, Events, Users, Lane Configuration | `get_my_role()` | selected tenant membership role | 9E/9F | Medium; not an authorization boundary |
| Frontend visibility | Dashboard/Check-in | direct own `profiles.role` | selected membership role | 9E/9F | Medium; DB must remain authoritative |

### 22.8 Current production RLS inventory

The effective target/derived-table inventory contains 22 policies. Tables `email_deliveries`, `tenants`, `tenant_memberships`, and `lane_booking_family_configuration_versions` have RLS enabled and zero policies.

| Table / command | Current policy and condition | Current dependency | Target tenant condition | Public/owner/staff requirement |
|---|---|---|---|---|
| `audit_logs` SELECT | `Admins can view audit logs`: `is_admin()` | global admin | `tenant_id IS NOT NULL AND has_tenant_role(tenant_id,['admin'])` | no public; global NULL audit excluded |
| `event_lanes` SELECT | `Admins and staff can view event lanes`: `is_admin_or_staff()` | global staff | membership in row tenant | no public; approved staff roles only |
| `event_registrations` SELECT | staff: `is_admin_or_staff()`; owner: `user_id=auth.uid()` | global staff/owner | staff membership in row tenant; owner UID plus active membership in row tenant | no public; never membership alone for foreign user data |
| `events` SELECT | staff global; anon/auth active globally | global staff / active flag | staff membership for row tenant; public active row for resolved active tenant | preserve `/events` before login |
| `lane_blocks` SELECT | staff global; all authenticated active globally | global staff / active flag | same-tenant membership; bounded public booking remains RPC-based | no new broad anon table read |
| `lane_booking_durations` SELECT | public active lane join; global admin/employee | lane activity / global helper | join lane and use lane tenant; public sole-active tenant | preserve active duration catalog |
| `lane_booking_rules` SELECT | public online hierarchy join; global staff | lane hierarchy / global helper | join lane/parent same tenant; staff membership | preserve online booking rules |
| `lane_pricing_rules` SELECT | public active lane join; global admin/employee | lane activity / global helper | join lane and use lane tenant; public sole-active tenant | preserve public prices |
| `profiles` INSERT | `Admins can insert profiles`: `is_admin()` | global admin | remove direct tenant-admin insert after compatibility proof | Auth trigger/global lifecycle only |
| `profiles` SELECT | global admin all; owner own | global admin / UID | direct own only; tenant staff through bounded relation-aware DTO | no public; no all-profile tenant grant |
| `reservations` SELECT | global admin/employee; owner own | global staff / UID | staff membership in row tenant; owner UID plus membership in row tenant | no public; owner condition remains mandatory |
| `shooting_lanes` SELECT | PUBLIC active globally; global staff all | active flag / global staff | active row for sole active public tenant; staff membership in row tenant | preserve booking catalog |

There are no direct INSERT/UPDATE/DELETE policies on the tenant-owned business tables after prior hardening. SAAS-9C must not add any. Controlled writes remain RPC responsibilities for SAAS-9D.

Production ACL confirms authenticated read-only table grants on audit, event lanes/registrations/events, lane blocks/configuration, reservations, and shooting lanes; `profiles` has authenticated SELECT/INSERT; `tenant_memberships` and `tenants` have only owner ACL. Service-role platform ACL remains broad and is not constrained by RLS.

### 22.9 Exact public-read contract

Production anon-executable function surface relevant to current public UX is:

| Function | Current caller | Required preservation |
|---|---|---|
| `get_public_booking_configuration_v1()` | `/booking` before authentication | public PII-free active CSK hierarchy/configuration |
| `get_public_event_availability_v1()` | `/events` availability | public aggregate counts only, no registration PII |
| `get_public_event_list_v2(search,scope,page,page_size)` | `/events` | bounded public event DTO, max-page contract, no participant PII |
| `get_public_check_in_status_v1(token)` | bearer-token check-in page | minimal token status DTO; token validity remains the authorization capability |

`get_lane_booking_busy_ranges_v3(lane,date)` is not anon-executable; it is available to authenticated/service roles and is used once the booking user is authenticated. Its output must become tenant-bound through the trusted lane ID in 9D without widening anon ACL.

Direct table public policies currently expose active shooting lanes and active event/lane pricing/duration/rule data. During 9C they must remain limited to the sole active tenant via the active-tenant guard bridge. They must not require membership because public Booking and Events must work before login.

No raw `tenants`, `tenant_memberships`, profile, registration, reservation, email, or audit table read is part of the public contract.

### 22.10 Final RLS recursion solution

Use the minimal pattern already proposed:

- own-membership policy is direct: `user_id = auth.uid()`; it does not call the membership helper;
- tenant-data policies pass their row's `tenant_id` into one small helper;
- helper is `STABLE SECURITY DEFINER`, owner `postgres`, fully schema-qualified, `SET search_path TO pg_catalog, public, pg_temp`;
- helper reads `tenant_memberships` and `tenants` as owner, avoiding recursive membership RLS;
- identity is only `auth.uid()`;
- NULL tenant/user, invalid role arrays, pending/suspended membership, and non-active tenant return false;
- revoke from `PUBLIC`, `anon`, and `service_role`; grant only required EXECUTE to `authenticated`;
- tenant-admin membership lists/updates use later bounded 9D RPCs, not recursive broad membership policies.

This small definer surface is necessary because a normal invoker helper would recursively evaluate the policy on the table it queries. Do not enable FORCE RLS on the membership table without redesigning this access path.

### 22.11 User-owned and staff rules

For reservations and event registrations, ownership is conjunctive:

```text
auth.uid() = row.user_id
AND active membership exists for row.tenant_id
AND row tenant is active
```

Membership alone never permits a normal user to see another user's row. A global account with memberships A+B can see only its own rows in both tenants.

Staff access is also row-tenant scoped:

- admin A: approved admin scope only where `row.tenant_id=A`;
- employee A: current employee scope only where `row.tenant_id=A`;
- instructor A: no expansion beyond the current contract, and never tenant B.

Current instructor contract verified from repo/catalog:

- UI routes: `/admin`, Calendar, and Events; not Reservations, Lane Blocks, Check-in, Reports, Users, or Lane Configuration;
- RLS reads: all shooting lanes, lane booking rules, lane blocks, events, event lanes, and event registrations through current `is_admin_or_staff()`;
- no reservation staff read (`reservations` uses admin/employee);
- calendar API excludes reservation records for instructor;
- event mutation controls remain admin/employee in application/RPC checks.

9C narrows these reads to the instructor's tenant but does not create event assignment. The broad intra-tenant event-registration access remains SEC-008 deferred and must not be described as remediated.

### 22.12 Profiles privacy findings

Production confirms admin CSK currently can read every profile through `Admins can view all profiles` using global `is_admin()`. The effective `profiles` ACL also allows authenticated SELECT and INSERT subject to RLS.

Target:

- user direct read remains own profile only;
- tenant staff must reach customer data only through a tenant-owned membership/reservation/event-registration relation;
- operational RPC returns a minimal DTO, not the full profile;
- address, permits, qualifications, verification notes, admin note, and cross-tenant/global identity fields are disclosed only when the specific operation requires them;
- tenant membership alone must not expose profiles of unrelated global users;
- direct tenant-admin INSERT into global profiles should be removed after confirming no runtime dependency;
- tenant-specific verification is not implemented in 9C and remains a pre-second-tenant product/privacy decision.

Existing helpers such as `get_reservation_customer_profiles_v1` and `admin_list_users_v1` are global definer paths and therefore remain mandatory 9D work even after table RLS changes.

### 22.13 Service-role inventory

| Path/function | Why service role | Input tenant source today | Current auth/ownership check | Bypass risk | Fix phase |
|---|---|---|---|---|---|
| `app/api/account/delete/route.ts` | Auth Admin `deleteUser` | global authenticated user; no tenant parameter | Bearer user verified; anonymization RPC uses caller identity | cross-tenant lifecycle rows must all be owner-derived; never accept target user ID | 9D contract review / 9E context |
| `lib/server/confirmation-email-delivery.ts` used by reservation confirmation/cancellation and event registration confirmation | complete delivery claims/provider state | record ID prepared under authenticated RPC; service completion receives claim ID | caller Auth and flow-specific ownership/staff checks precede prepare | service completion bypasses RLS; claim must bind tenant and target | 9D |
| `lib/server/event-reserve-promotion.ts` | promotion claim, recipient lookup, provider completion | event ID supplied to server flow | API first verifies user and global admin/pracownik profile role | service client directly reads event/registrations; IDOR if tenant actor check is omitted | 9D/9E |
| load-test scripts | local fixture/admin test support | local safety configuration | localhost guard | must never become production runtime | tooling only |

9C RLS is never considered sufficient for these paths. Each 9D change must derive tenant from the trusted resource, validate actor membership in that tenant before bypass, bind all follow-up IDs to the same tenant, and return minimal DTOs.

### 22.14 Temporary CSK defaults and retirement gate

Production confirms exactly seven defaults, all equal to CSK UUID `c5c00000-0000-4000-8000-000000000001`, on:

1. `shooting_lanes` — remove only after tenant-aware lane-family create writer explicitly writes tenant;
2. `reservations` — remove only after tenant-aware reservation writer derives tenant from selected lane and explicitly writes it;
3. `lane_blocks` — remove only after tenant-aware block writer derives tenant from lane;
4. `events` — remove only after tenant-aware event-create writer receives validated context and writes tenant;
5. `event_lanes` — remove only after event update/create writer explicitly writes the validated event/lane tenant;
6. `event_registrations` — remove only after registration writer derives tenant from event;
7. `email_deliveries` — remove only after prepare/delivery writer derives tenant from the trusted business record.

Recommended 9D gate:

- 9D-1 installs versioned tenant-aware writers while defaults remain;
- 9D-2 updates/validates every still-authorized legacy CSK path to write tenant explicitly;
- production telemetry/tests prove zero authorized path relies on defaults;
- 9D-3 removes all seven defaults and asserts writes without explicit/derived tenant fail;
- application writer cutover follows only after this gate;
- second-active-tenant guard remains through SAAS-9H.

Second tenant activation with any CSK default present is an unconditional NO-GO.

### 22.15 Final sync-bridge design

Recommended temporary bridge remains a one-way profile-to-CSK membership synchronization trigger because:

- the one-time backfill cannot prevent later role drift;
- `admin_set_user_role_v1` still writes `profiles.role`;
- application and 47 database functions still read the legacy field;
- direct membership DML must remain unavailable.

Bridge contract:

1. fires only on profile INSERT and actual role change;
2. resolves only the fixed CSK tenant while the single-active guard is present;
3. validates the source role against an approved explicit map;
4. creates/updates only that user's CSK membership role, preserving membership lifecycle status unless the row is newly created;
5. new live profile receives active CSK membership under the approved account rule;
6. never writes another tenant;
7. no reverse membership-to-profile trigger and no bidirectional recursion;
8. owner/search path/grants follow the hardened internal-trigger pattern;
9. post-statement reconciliation failure aborts the profile role change;
10. retirement requires zero profile/member mapping mismatch and all runtime role readers/writers cut over to memberships.

The aliases `pracownik -> employee`, `instruktor -> instructor`, `employee -> pracownik`, and `instructor -> instruktor` are approved. The bridge is ready and must preserve the exact mapping without fallback values.

### 22.16 Exact final phase split

| Phase | Scope | Production gate | Excluded |
|---|---|---|---|
| SAAS-9C-1A | extend membership role CHECK with `instructor`; repeat production preflight; backfill nine eligible CSK memberships; install one-way sync bridge | exact counts/map, zero drift, full DB tests, dry-run, rollback-only role reconciliation | no helper/RLS consumption |
| SAAS-9C-1B | add minimal versioned tenant membership helpers and non-recursive own-membership read contract | helper truth table, ACL/search path/owner checks, recursion tests | no business policy/RPC changes |
| SAAS-9C-2 | tenant-aware RLS for shooting lanes, lane-derived config, reservations, and lane blocks | public booking, owner/staff A allow, dormant B deny, current runtime smoke | no writer changes |
| SAAS-9C-3 | tenant-aware RLS for events, event lanes, event registrations, audit, and global profile direct access; email remains direct deny | public events, owner registration, same-tenant staff, audit NULL isolation, profile privacy | no SEC-008 assignment model, no tenant verification model |
| SAAS-9C-4 | legacy global-role isolation verification and policy fingerprint checkpoint | no tenant-owned policy references global helpers; full matrix/regression | old helpers/RPCs remain for 9D compatibility |

This five-step split is safer than a single RLS migration because membership/helper behavior can be proven before any current read policy changes, and Booking can be stopped/forward-fixed independently from Events/Profile/Audit.

### 22.17 Concrete test identities and matrix

Local-only/reset-isolated fixtures while the production second-tenant guard remains:

| Identity | Membership A | Membership B | Required proof |
|---|---|---|---|
| `USER_A` | user active | none | own A allow; foreign A/B deny |
| `USER_B` | user active | none | own B-fixture relation only where modeled locally; A deny |
| `ADMIN_A` | admin active | none | admin A allow; B deny despite any global role |
| `EMPLOYEE_A` | employee active | none | employee A allow; admin-only deny; B deny |
| `INSTRUCTOR_A` | instructor active | none | current permitted A reads only; no expansion; B deny |
| `GLOBAL_USER_A_B` | user active | different approved role active | own rows across A/B; independent role enforcement |
| `NO_MEMBERSHIP_GLOBAL_ADMIN` | none | none | global profile admin alone grants no tenant-table access |
| `SUSPENDED_A` | suspended | none | all tenant-private access deny |

Additional cases: anon documented public reads only; membership self-escalation deny; direct membership DML deny; invalid tenant/role array fail closed; no RLS recursion; audit A/B/NULL isolation; service-role explicit tenant validation; profile/member sync on every approved forward and reverse role mapping; unknown values fail closed.

No tenant B is created or activated on production for these tests. Cross-tenant fixture is local only until later roadmap gates.

### 22.18 Security fingerprint baseline

The following production fingerprints were captured before implementation:

| Surface | Fingerprint |
|---|---|
| RLS policies | `f5c428bd4e241af39f690c1aafcfad08` |
| table ACL | `cf05faffa475999df163338c3c1e805f` |
| all `SECURITY DEFINER` functions | `5445f1861478c5f563ecb97fc543ad8c` |
| legacy role helpers | `3b1c1da09c72c8fcf4c9ace679947913` |
| `tenant_memberships` column schema | `c4e894377f09bc1e095c640e2093a661` |
| approved public-reader aggregate | `3492dd04f5df8abff544aaa06eb7d1fd` |

`profiles.role` is plain `text NOT NULL DEFAULT 'user'` and has no CHECK/enum constraint; its constraint fingerprint is therefore NULL. This is material: application/RPC validation, not schema, currently limits legacy role values.

Individual public-reader hashes:

- `get_public_booking_configuration_v1`: `2aee39e3d37d3d1a19f58c3626aa0365`;
- `get_public_event_availability_v1`: `40adf74cb5adec5df3b4745fc7851433`;
- `get_public_event_list_v2`: `fe075d7057149b0a0bad0129419a3e99`;
- `get_public_check_in_status_v1`: `ea4a14a4e8e7d3c6d36d4c9b92da15c5`.

Authenticated booking-busy v3 baseline: `119f24a2b9226fdd4a85b9bec8013e4e`.

Every migration must compare the expected changed fingerprint set and require all unrelated fingerprints to remain identical.

### 22.19 Rollback/forward-fix refinement

- 9C-1A and 1B are additive and transactional. Before RLS cutover, a reviewed rollback may remove the bridge/helpers/memberships and restore the original role CHECK.
- Backfill must never be repaired by manual production UPDATE or migration repair.
- After 9C-2/3 policy cutover, keep memberships and bridge; restore only the exact previous policy/ACL definitions if emergency rollback is necessary.
- Prefer forward-fix for a single domain because Booking and Events policies deploy separately.
- Each production phase requires migration-history equality, exact dry-run, short lock timeout, post-deploy fingerprints, runtime smoke, and zero fixture residue.
- Any global-role-to-membership mismatch, public booking regression, helper recursion, or cross-tenant allow is a STOP condition.

### 22.20 Final preflight verdict and blockers

Production data preflight itself passes:

- 9/9 Auth/profile match;
- zero orphans;
- only currently mappable `admin/user` roles;
- zero banned/deleted accounts;
- verification kept separate from membership;
- zero memberships and zero membership FK/duplicate anomalies;
- seven expected CSK defaults;
- current RLS/ACL/function/public contract baseline captured.

The target membership schema, backfill calculation, RLS design, recursion solution, migration split, and explicit two-way compatibility aliases are approved. SAAS-9C-1 local implementation is ready; production deployment remains a separate NO-GO until local evidence and a dedicated production preflight pass.

SAAS-9C PRODUCTION PREFLIGHT: **PASS**

ROLE MODEL: **READY — canonical membership roles admin/employee/user/instructor approved**

MEMBERSHIP BACKFILL: **READY — current nine live profiles map unambiguously**

RLS DESIGN: **READY**

SYNC BRIDGE: **READY — explicit `pracownik/instruktor` ↔ `employee/instructor` mapping approved**

READY FOR SAAS-9C-1 LOCAL IMPLEMENTATION: **GO**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**
