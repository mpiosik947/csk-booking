# SAAS-9F — FINAL MODULE CUTOVER AUDIT

Date: 2026-09-23 (Europe/Warsaw)

## Decision

The audit found five real operational cutover residuals, so SAAS-9F was not
classified as N/A. The frozen scope is limited to tenant selection/navigation,
one missing tenant-bound cancellation call, and the minimal PII-free selector
needed by the global dashboard. No business table, RLS policy, role scope,
tenant-owned write model, or public DTO is widened.

## Module inventory

| MODULE | TENANT MODEL | AUTHORITY SOURCE | TENANT SOURCE | READ CONTRACTS | WRITE CONTRACTS | PII | LEGACY RESIDUAL | SECURITY RESIDUAL | CUTOVER REQUIRED? | ACTION |
|---|---|---|---|---|---|---|---|---|---|---|
| Public booking | Tenant-scoped public | Active tenant resolved from canonical slug | Server-validated `/t/{slug}` -> tenant UUID | `get_public_booking_configuration_v2`, busy ranges v3 | `create_reservation_v2` after resource binding/onboarding | Public configuration only; owner data stays in authenticated write | Marketing `/booking` remains an explicit CSK compatibility redirect | None; browser tenant selection is checked against resource tenant | No | Retain explicit legacy landing redirect; preserve selected slug after success/login |
| Reservations | Tenant-owned | owner or active tenant membership and hardened RPC | persisted reservation/lane tenant | `get_my_reservations_v3`, admin/report contracts | resource-bound create/cancel/admin writers | Owner/staff DTOs are bounded | Owner page retained unreachable direct `cancel_reservation` fallback | Fallback could bypass selected-route consistency | Yes | Remove fallback; require `/api/tenant-cancel-reservation?tenant=...` |
| Events | Tenant-owned/public tenant-scoped | public active tenant or active staff membership | canonical slug plus persisted event tenant | public list/availability v3/v2; staff v2 | event V3/V2 writers | Public DTO PII-free | Success navigation lost selected slug | Wrong-tenant UX after a correct write | Yes | Keep `/t/{slug}` in post-registration navigation |
| Event registrations | Tenant-owned resource relationship | authenticated owner, resource-bound staff role | persisted event/registration tenant | my-events v2; admin registrations v2 | registration/cancellation/payment/promotion v2 | Minimal participant DTO; public receives none | Cancellation endpoint accepted missing tenant and invoked legacy wrapper | Hidden old operational execution path | Yes | Require canonical tenant slug and v2-only cancellation |
| Reserve/waitlist/promotion | Event-resource scoped | owner token or service boundary; first-confirmed-wins | persisted event/registration/email tenant | bounded participant/promotion contracts | hardened promotion/confirmation RPCs | recipient/resource binding; token not in DTO | Global confirmation page links implied CSK after completion | Navigation only; DB mutation remains resource-bound | Yes | Route post-confirmation choices through global dashboard; preserve exact UUID login return path |
| Check-in | Reservation-resource scoped | staff membership for reservation tenant | reservation/lane tenant | scoped check-in readers | reservation-bound attendance/verification | Minimal operational profile DTO | None | None | No | Retain current resource-bound contracts |
| Lane blocks | Tenant-owned | active admin/employee membership | lane/block tenant | tenant RLS/read surfaces | 9D-3A hardened writers | No customer PII | None | None | No | No change |
| Lane configuration | Tenant-owned hierarchy | active admin membership; employee scope unchanged | root/family/lane tenant | v3 scoped configuration reader | v2/v3 family writers | No customer PII | None; bridges/defaults retired in 9D-5 | None | No | No change |
| Reports | Tenant aggregate | active tenant admin membership | explicit validated tenant UUID | report v3/export v2 closed cores | Read-only | Bounded details/export fields | None | No app-side filter used as authority | No | No change |
| Users | Tenant operational relationship | active tenant admin membership | validated route tenant plus tenant-owned relationship | admin users v2 | role/identity/contact/note/verification v2 | Least-privilege staff DTO | None | No global profile visibility authority | No | No change |
| Memberships | Tenant relationship | membership role/status itself | persisted membership tenant | selector and staff context helpers | controlled membership/role writers | Minimal role/status where required | None | `profiles.role` is physical legacy only, not authority | No | Add only authenticated PII-free active-tenant selector for dashboard |
| Tenant verification | Tenant-owned user state | active membership/resource relationship | explicit tenant/resource | verification v2 | resource-bound verification writers | Tenant-local verification only | Frozen profile fields remain historical | No fallback/dual read/write | No | No change |
| Admin notes | Tenant-owned per user | tenant admin plus operational relationship | note key `(tenant_id,user_id)` | admin users v2 | admin note v2 | Tenant-local note only | None | Cross-tenant note access denied | No | No change |
| Account lifecycle | Global/account-wide by design | authenticated account owner | no tenant selector | export/global profile contracts | global anonymize/delete | Account owner's own data | None | Not conflated with leave-tenant | No | No change |
| Account/profile | Global identity by design | authenticated account owner | no tenant authority | global profile plus tenant verification presentation | `update_my_profile_v2` | Own profile only | Owner links hardcoded legacy aliases | Could silently select CSK for multi-tenant user | Yes | Route operational choices through dashboard selector |
| Dashboard | Global landing/selector | authenticated active memberships | `get_my_active_tenants_v1()` rows | new minimal selector | none | tenant id/slug/name/role only | Hardcoded `/t/csk/...` | Selector could not represent Tenant B | Yes | Render one card per active membership; path remains the later authority |
| Owner reservations/events | Tenant-owned | authenticated owner contracts | required route tenant | v3 reservations / v2 registrations | tenant-bound owner cancellation | Own records only | Direct success/CTA aliases selected CSK | Route context loss | Yes | Preserve tenant slug in every owner navigation/write |
| ICS | Resource/owner scoped | authenticated owner of reservation/registration | resource-derived persisted tenant | resource-specific calendar RPC/routes | none | Explicit PII/secret exclusion | None | No caller tenant authority | No | No change |
| Confirmation/email flows | Resource and recipient scoped | service-only completion plus owner/resource claim | reservation/event/registration tenant | claim/preparation contracts | idempotent service completion | trusted recipient; HTML escaped | Email convenience URLs may land at global selector | No DB authority residual | No | Keep resource-bound server contracts; selector is neutral fallback |
| Public readers | Explicit active tenant | public active tenant resolver and closed cores | validated slug -> tenant UUID | booking/events/check-in public DTOs | none | PII-free allowlists | Explicit `/booking` and `/events` CSK compatibility remain | No exact-single authority inside contracts | No | Retain only as documented compatibility entry points |
| Admin/staff writers | Tenant/resource scoped | active membership role/status | resource tenant wins over selected tenant | bounded admin readers | hardened v2/v3/resource writers | workflow-minimal DTO | None | global `profiles.role` cannot authorize | No | No change |
| Audit logs | Mixed tenant/global | trusted writer/trigger | resolved resource tenant or NULL for account/global event | staff/report access only | protected insert path | details redacted/minimized | None | tenant-owned mutation requires tenant binding | No | No change |

## Frozen implementation scope

1. Add `get_my_active_tenants_v1()` as an authenticated-only, PII-free tenant
   selector. It returns only active memberships for `auth.uid()` and active
   tenants. It is navigation data, never write authority.
2. Make dashboard links membership-backed and remove hardcoded CSK paths.
3. Preserve selected tenant slug through booking/event success and login.
4. Require tenant context for owner reservation/event cancellation and remove
   legacy RPC fallbacks.
5. Replace tenant-ambiguous account/confirmation links with the global selector.
6. Update exact ACL/SECURITY DEFINER inventories from 73 to 74.

## Security outcome

- implicit active-CSK authority in operational paths: **0**
- exact-single-active authority introduced by 9F: **0**
- browser/service-role tenant authority introduced by 9F: **0**
- `profiles.role` tenant authority introduced by 9F: **0**
- compatibility bridge/default dependency introduced by 9F: **0**
- cross-tenant PII expansion: **0**
- new SECURITY DEFINER: **1**, reviewed selector only; target total **74**
- selector ACL: authenticated only; PUBLIC/anon/service_role denied

## Local verification

- clean local migration replay: PASS
- focused selector SQL: 8/8 PASS
- full DB: 1608/1608 PASS
- Node: 789/789 PASS
- TypeScript: PASS
- production build: PASS
- changed-file ESLint: PASS
- focused Playwright: PASS
- full Playwright: 38/38 PASS
- `npm audit --omit=dev`: one moderate `baseline-browser-mapping` denial-of-service advisory; no HIGH/CRITICAL and no dependency change made in 9F
- fixture cleanup: 0 (all SQL changes are transaction/rollback scoped)
- `git diff --check`: PASS, Windows EOL notices only

## Verdict

SAAS-9F LOCAL: **PASS**

SAAS-9F DECISION: **IMPLEMENT MINIMAL RESIDUAL SCOPE**

SAAS-9F DB PRODUCTION DEPLOY: **PASS**

SAAS-9F APP PRODUCTION DEPLOY (`csk-booking-5nwh`): **PASS**

SAAS-9F POST-DEPLOY: **PASS**

Migration history: **LOCAL = REMOTE through `20261002100000`**

Final dry-run: **Remote database is up to date**

Production app commit: **`05cde069aaedac465a98b6d0f57e17e12296d2ad`**

Production GET smoke: **PASS** for `/`, `/t/csk/booking`, `/t/csk/events`,
`/login`, `/account`, `/dashboard`, `/my-reservations`, and `/admin`; no 5xx.

The separate Vercel project named `csk-booking` reported a failed deployment for
the same commit. The authoritative production project used by this audit,
`csk-booking-5nwh`, completed successfully. No claim is made that the unrelated
duplicate project is healthy.

REAL OPERATIONAL RESIDUALS: **0**

READY FOR FINAL GIT CHECKPOINT: **YES**

READY FOR SAAS-9G LOCAL TWO-TENANT E2E: **GO**

SECOND PRODUCTION TENANT: **NO-GO**

SEC-004: **OPEN**
