# SAAS-9A — Multi-Tenant Architecture & Migration Audit

Data audytu: 7 września 2026 r.
Repozytorium: `C:\Users\Mpios\Desktop\APP Krutla\APP Krutla\csk-booking`
HEAD: `8195c3cb1f3b49ad5f0ec471b6cec39bc2511da3`
Tryb: read-only architecture audit; bez zmian schematu, danych, produkcji i aplikacji.

Źródła dowodowe: aktualny kod i migracje repozytorium oraz read-only katalog lokalnego PostgreSQL `127.0.0.1:54322`. Lokalny katalog służył do weryfikacji efektywnego schematu, RLS, funkcji, constraints i indeksów; nie jest dowodem stanu danych produkcyjnych.

## 1. Executive Summary

Obecny model jest spójny i utwardzony dla jednej strzelnicy, ale nie posiada żadnej granicy tenantowej. W schemacie `public` istnieje 14 tabel i 75 nazw funkcji, lecz nie ma `tenants`, membership ani kolumny `tenant_id`. Tożsamość, rola i weryfikacja są połączone w jednym globalnym `profiles`. Polityki RLS i funkcje `SECURITY DEFINER` rozpoznają globalne role `admin`, `pracownik` i `instruktor`; administrator CSK otrzymałby więc dostęp do danych każdej kolejnej strzelnicy.

Nie jest to nowa podatność obecnego single-tenant V1. Jest to jednak krytyczny blocker przed utworzeniem drugiego tenanta i potwierdzenie otwartego SEC-004.

Rekomendowany kierunek:

- zachować jedno globalne `auth.users` i globalną tożsamość konta;
- utworzyć `tenants`, `tenant_memberships` oraz minimalny tenantowy profil/weryfikację;
- przenieść role operacyjne do membership;
- przypisać bezpośredni `tenant_id` do korzeni danych biznesowych, a w tabelach potomnych dziedziczyć tenant tam, gdzie relacja jest jednoznaczna;
- wymusić zgodność tenantów przez RLS, tenant-aware RPC i composite FK/constraint triggers;
- przeprowadzić migrację `expand → migrate → contract`, pozostawiając możliwość rollbacku aplikacji do czasu utworzenia drugiego tenanta;
- technicznie zablokować aktywację drugiego tenanta, dopóki stare globalne RPC/policies nie zostaną odebrane.

Rekomendacja końcowa: **GO dla ograniczonego SAAS-9B foundation**, ale **NO-GO dla onboardingu drugiego tenanta**. Minimalny SAAS-9B nie może zmieniać zachowania produkcyjnego V1.

## 2. Current Architecture

- Next.js używa płaskich tras publicznych i prywatnych: `/booking`, `/events`, `/account`, `/my-reservations`, `/my-events` i `/admin/*`; URL nie identyfikuje strzelnicy.
- Browser Supabase client używa jednego globalnego `NEXT_PUBLIC_SUPABASE_URL` i anon key (`lib/supabase.ts`). Drugi prosty klient istnieje w `app/admin/src/lib/supabase.ts`.
- `middleware.ts` chroni `/admin/:path*`, pobiera `auth.getUser()`, a następnie globalne `profiles.role`. Mapa tras w `lib/admin/route-protection.js` rozróżnia role, lecz nie membership.
- RLS minimalizuje bezpośredni DML; mutacje przechodzą głównie przez RPC. To dobry fundament, ale wszystkie role i odczyty operacyjne są globalne.
- `service_role` jest używany w wybranych trasach serwerowych dostarczania e-maili i lifecycle, nie został znaleziony w browserze. Serwerowe lookupy nadal są globalne i wymagają tenantowego ograniczenia.
- Brak React Query, SWR i `unstable_cache`. Większość stanu jest lokalna dla ekranu; zagrożenie cache cross-tenant jest dziś małe, ale musi zostać uwzględnione przy wprowadzaniu tenant resolution.

## 3. Database Inventory

Katalog lokalny potwierdza 14 tabel `public`, brak publicznych views, materialized views, sekwencji i enumów. Identyfikatory są UUID.

| Tabela | PK / główne relacje | Istotne constraints / indeksy | Obecna funkcja |
|---|---|---|---|
| `profiles` | PK `id`, UNIQUE `user_id`, relacja z `auth.users` | indeksy email, role, verification, user_id | globalna tożsamość, globalna rola, weryfikacja, kontakt, declarations, admin note |
| `shooting_lanes` | PK `id`, self-FK `parent_lane_id` | hierarchy/capacity checks, parent index | globalny katalog osi i stanowisk |
| `lane_booking_rules` | PK/FK `lane_id` | capacity validation | globalna dostępność online i limity |
| `lane_booking_durations` | PK UUID, FK lane | UNIQUE `(lane_id,duration_minutes)`, active/order index | czasy zasobu |
| `lane_pricing_rules` | PK UUID, FK lane | GiST exclusion zakresów per lane/day group | cennik zasobu |
| `lane_booking_family_configuration_versions` | PK/FK `root_lane_id` | optimistic version | wersja konfiguracji rodziny |
| `reservations` | PK UUID, FK lane/pricing/user | GiST overlap `(lane_id,booking_period)`, UNIQUE check-in token, UNIQUE `(user_id,creation_request_id)` | rezerwacja i snapshot klienta/ceny/zasobu |
| `lane_blocks` | PK UUID, FK lane | schedule index `(lane_id,date,is_active,start,end)` | blokady zasobów |
| `events` | PK UUID | event date/time checks, późniejsze indeksy list | globalne eventy |
| `event_lanes` | PK `(event_id,lane_id)`, oba FK | reverse index `(lane_id,event_id)` | przypisanie eventu do zasobu |
| `event_registrations` | PK UUID, FK event; owner `user_id` | partial UNIQUE aktywnej rejestracji per user/event, token indexes, pagination indexes | zapisy, reserve, payment, contact snapshots |
| `audit_logs` | PK UUID | indeksy operacyjne z migracji hardening | immutable operational audit |
| `email_deliveries` | PK/claim UUID, FK recipient auth user | UNIQUE `(message_type,record_id)` | idempotent delivery claims |
| `confirmation_email_rate_limits` | klucz zakresu | scope key/timestamps | globalny anty-abuse user/IP |

Triggery obejmują walidację hierarchii/pojemności, blokady konfiguracji i `updated_at`. Funkcja `handle_new_user()` tworzy globalny profil. Efektywny lokalny katalog nie pokazał triggera `auth.users → profiles`, choć funkcja istnieje w baseline, a wcześniejsze testy produkcyjne obserwowały automatyczne tworzenie profilu. Ten drift musi zostać wyjaśniony przed migracją Auth; SAAS-9A nie rozstrzyga na tej podstawie stanu produkcji.

Katalog funkcji obejmuje 75 nazw. Istotne grupy:

- role/profile: `get_my_role`, `is_admin`, `is_admin_or_employee`, `is_admin_or_staff`, `handle_new_user`, `update_my_profile_v1`, admin user RPC, export/anonymization;
- booking/config: `get_public_booking_configuration_v1`, busy ranges V1–V3, `create_reservation`/`v2`, cancellation, lane family readers/writers, conflict resolver/locks;
- events: public availability/list, admin lists/writers, registration/reserve/promotion/payment/cancellation;
- operations: lane blocks, check-in, attendance/payment/admin note;
- reports: report V1/V2, export and internal report-row helper;
- delivery/security: delivery prepare/complete, rate limit, audit redaction.

## 4. Current Single-Tenant Assumptions

1. Global role lookup: all role helpers read `profiles.role` only by `auth.uid()` (`20260816090000_remote_baseline.sql`).
2. Global admin routing: `middleware.ts` and `lib/admin/route-protection.js` have no tenant context.
3. Global public catalog: booking configuration, lanes, prices, durations, public events and availability return all active records.
4. Global operations: dashboard, reservations, lane blocks, calendar and check-in directly query tables without tenant predicate.
5. Global admin RPC: users, events, participants, lane configuration and reports accept filters/resource IDs but no verified tenant.
6. Global conflict domain: reservation/event/block checks start from globally supplied lane UUIDs; isolation is accidental through globally unique IDs, not a tenant invariant.
7. Global settings: `Europe/Warsaw`, `08:00–20:00`, CSK branding/content and parts of PLN presentation are hardcoded in app and SQL.
8. Global profile visibility: an admin can list every profile; verification and admin note are not tenant-specific.
9. Global audit and delivery metadata: records have no tenant attribution.
10. Global application origin: one Supabase project and one flat URL namespace represent CSK.

## 5. Tenant Ownership Matrix

| Entity | Current ownership | Proposed ownership | Class | Direct `tenant_id` | Derived tenant | Migration risk / notes |
|---|---|---|---|---|---|---|
| `auth.users` | platform-global | platform-global | global | No | — | High privacy impact; never tenant-owned |
| `profiles` | global mixed identity/role | minimal global identity/account | global | No | — | High; remove role/verification semantics only after compatibility cutover |
| `tenants` | absent | one company/facility | global registry | PK itself | — | Low additive foundation |
| membership | absent | `(tenant_id,user_id)` relation and role/status | tenant | Yes | — | High security root |
| tenant user profile/verification | embedded in profiles | tenant-specific data, verification, note/requirements | tenant | Yes | membership | High privacy/backfill decision |
| `shooting_lanes` | global | owned by tenant | tenant | **Yes** | — | High; root for booking hierarchy |
| booking rules/durations/pricing | lane-owned | lane-owned | tenant-derived | No initially | lane | Medium; join-based RLS acceptable, composite invariants where referenced |
| config versions | root-lane-owned | root-lane-owned | tenant-derived | No | root lane | Low/medium |
| `reservations` | lane/user relation | tenant transaction | tenant | **Yes** | lane as validation source | High; RLS/report/performance and historical stability justify direct column |
| `lane_blocks` | lane-owned | tenant operation | tenant | Recommended yes | lane | Medium; direct column improves RLS/calendar indexes, must match lane |
| `events` | global | owned by tenant | tenant | **Yes** | — | High; event may exist without lane |
| `event_lanes` | event/lane pair | same-tenant join | tenant relation | Recommended yes | event + lane | High; composite FKs must prevent cross-tenant pairing |
| `event_registrations` | event/user relation | tenant transaction | tenant | **Yes** | event | High; event/user may later be anonymized/null, tenant history must persist |
| `audit_logs` | global generic entity | tenant audit or platform audit | mixed | Yes, nullable | sometimes entity | High visibility; tenant admin only own tenant, platform action may be null |
| `email_deliveries` | global recipient/record | tenant business delivery | mixed | Recommended nullable | record | Medium; idempotency should include tenant where record namespace requires it |
| rate limits | global scope key | global abuse control by default | global | No initially | — | Low; optional tenant quota is a future feature, not isolation requirement |

Do not add redundant `tenant_id` to every lane child table. Ownership is safely derivable there if every access path joins an already tenant-scoped lane and cross-resource references receive composite constraints.

## 6. Global User Architecture

Keep exactly one `auth.users.id` per person. Keep a global profile only for account-owned data needed across the platform: display identity, global email linkage and user-managed contact defaults. Remove tenant authority from it.

Tenant access to global PII must not follow merely from being an admin. A tenant should receive only:

- data explicitly supplied/consented for that tenant;
- minimal identity/contact snapshots necessary for an existing booking/event relation;
- tenant-specific verification data belonging to that tenant.

Cross-tenant `/my-*` can aggregate the signed-in user's own records, but admin views remain tenant-bound. Account export/delete must operate globally while preserving per-tenant operational history and audits under the existing anonymization contract.

## 7. Tenant Membership Architecture

Recommended core table:

`tenant_memberships(tenant_id, user_id, role, status, joined_at, accepted_terms_version, accepted_terms_at, suspended_at, ...)`

- PK/UNIQUE `(tenant_id,user_id)`.
- Roles: `user`, `instruktor`, `pracownik`, `admin` scoped to one tenant.
- Status controls relationship lifecycle, not Auth login.
- A person can be admin A and user B.
- Membership creation must be server/RPC controlled; the browser cannot assert an unvalidated tenant or role.
- No membership and no validated tenant context means no private tenant access (fail-closed).

Platform-level support authority must not be encoded as a tenant membership wildcard.

## 8. Tenant-Specific Verification Model

Use a small tenant-owned record keyed by `(tenant_id,user_id)`, either as a dedicated `tenant_user_profiles` table or a narrow extension of membership. Recommended first version:

- membership: role, relationship status, accepted terms;
- tenant user profile: verification status, verified/rejected timestamps, verifying membership/user, tenant admin note, declarations required by that tenant.

Minimal statuses: `pending`, `verification_required`, `verified`, `rejected`, `suspended`. `not_registered` is absence of membership rather than a stored row.

Admin A may not read or mutate verification B. The current `profiles.permissions_verified_by → profiles.id` must be replaced by tenant-aware actor attribution. Tenant-specific requirements should not start as unrestricted security-critical JSON; implement only fields backed by an approved business rule.

## 9. Roles & Permissions

The current role is conclusively global. `get_my_role()` and all helper predicates read one `profiles.role`. This cannot represent admin A/user B.

Target:

- tenant role lives in membership;
- helpers require a tenant argument or a resource whose tenant is derived in DB;
- a membership lookup must verify `(auth.uid(), tenant_id, active membership)`;
- tenant status must also be active for normal writes;
- platform admin is separate from tenant role and has no implicit row access;
- UI route authorization is secondary; each API/RPC/table boundary repeats server/DB authorization.

## 10. RLS Audit

Effective catalog contains 22 policies. Current behavior and required change:

| Tables | Current policy | SaaS risk | Required tenant rule |
|---|---|---|---|
| profiles | own SELECT; global admin SELECT/INSERT | admin A sees global users | global self only; tenant-facing data through scoped DTO/RPC and membership relation |
| reservations | owner SELECT; global admin/employee SELECT | staff A sees B | owner may see own across allowed context; staff requires matching active membership + row tenant |
| events | public active; global staff all | public data merges tenants; staff cross-access | public active for resolved tenant; staff same tenant |
| event registrations | own; global staff all | staff/instructor cross-tenant PII | owner self; staff assigned/same tenant; instructor policy remains deferred but cannot cross tenant |
| event_lanes | global staff | cross-tenant event/lane visibility | same tenant plus event/lane consistency |
| lanes/config | global public active; global staff | merged catalogs/config | resolved active tenant for public; same-tenant staff |
| lane_blocks | authenticated active globally; global staff | schedule leak | public/booking read only within resolved tenant; staff same tenant |
| audit_logs | global admin | audit leak | tenant admin own tenant only; platform audit separately authorized |

RLS must not depend on an optional tenant filter supplied by the UI. Missing context must produce no rows/deny. Prefer stable helper functions such as `is_tenant_member(tenant_id)` and `has_tenant_role(tenant_id, roles[])`, implemented with safe `search_path`, direct `auth.uid()` and no caller-controlled bypass.

## 11. RPC / SECURITY DEFINER Audit

All critical RPC families are currently tenant-unaware:

| Family | Current tenant source | Cross-tenant risk after tenant B | Required migration |
|---|---|---|---|
| role/user admin | none; global profile role | list/update users from B | tenant-aware role helpers and user relation DTOs |
| booking config/lanes | lane UUID only or none | read/write B with known UUID | resolve tenant from lane; validate membership; public reader accepts validated tenant slug/id |
| reservation create/cancel | lane/reservation UUID + auth.uid | create/cancel/read across boundary if role checks remain global | derive tenant from row/lane and verify membership/tenant state inside transaction |
| conflict locks/resolver | lane family only | no logical tenant assertion | validate all supplied lanes share tenant before locking; keep current lock ordering |
| lane blocks/calendar | object IDs/global reads | staff A operates B | tenant membership plus same-tenant resource checks |
| event writers/readers | event/lane IDs or global list | staff A reads/mutates B; event may bind lane B | event direct tenant, composite event-lane constraint, tenant-aware writers |
| registrations/promotion/payment | event/registration/token | IDOR across tenants for global staff | derive event tenant; owner or tenant membership check; token resolves row then tenant |
| check-in | token/reservation ID | token should not confer cross-context staff access | public minimal token status; staff mutation derives tenant and verifies role |
| reports/users | no tenant | complete cross-tenant dataset | required tenant parameter validated against membership; predicates inside RPC |
| audit/delivery | record/user IDs | wrong tenant attribution/visibility | attach derived tenant, never accept unverified tenant from client |
| account lifecycle | auth.uid global | expected global scope | preserve global semantics, fan out anonymization safely across tenant records |

Security-definer functions must never trust `p_tenant_id` alone. If a tenant ID is accepted for query selection, the function must check active tenant and caller membership before any table access. Resource mutations should derive tenant from locked rows and compare it to the validated context.

Legacy V1 functions with service-only ACL and older `search_path=public,pg_temp` must not be accidentally re-exposed while versioning tenant-aware RPC.

## 12. Constraints & Indexes

Required invariant map:

- tenant slug: global `UNIQUE(normalized_slug)`; custom domain global unique if introduced;
- membership: `UNIQUE(tenant_id,user_id)`;
- lane hierarchy: parent and child must share tenant, enforced by composite self-FK `(tenant_id,parent_lane_id) → (tenant_id,id)` with `UNIQUE(tenant_id,id)`;
- event lanes: event and lane must share tenant via `event_lanes.tenant_id` and two composite FKs, or an equivalent deferred constraint trigger;
- reservation pricing: pricing rule must belong to reservation lane; add composite FK `(pricing_rule_id,lane_id)` to a unique key on pricing rules;
- reservation overlap: current lane UUID already prevents cross-lane conflicts. Add tenant prefix for explicit invariant/query locality, but preserve GiST semantics and active-status predicate;
- pricing range exclusion remains per lane; tenant is inherited and need not be duplicated solely for uniqueness;
- active event registration uniqueness remains `(event_id,user_id)` because event is globally unique; tenant-prefixed indexes are still useful for tenant list queries;
- tokens should remain globally unique/unpredictable;
- human names need not be unique. Any future lane number/local slug should be `UNIQUE(tenant_id,value)`.

Likely indexes after measured query-plan review:

- reservations `(tenant_id,reservation_date,start_time,id)`, `(tenant_id,user_id,...)`;
- events `(tenant_id,is_active,event_date,start_time,id)`;
- registrations `(tenant_id,event_id,status,payment_status,created_at,id)` and `(tenant_id,user_id,created_at,id)`;
- lane blocks `(tenant_id,lane_id,block_date,is_active,start_time,end_time)`;
- shooting lanes `(tenant_id,parent_lane_id,display_order,id)`;
- audit `(tenant_id,created_at,id)`;
- membership `(user_id,status,tenant_id)` plus PK order for tenant administration.

## 13. Reservation Conflict Model

The existing model combines deterministic family locks, hierarchy conflict scopes and a GiST exclusion on active reservations. Preserve all three.

Target transaction order:

1. resolve and lock selected lane;
2. read its tenant from DB;
3. validate requested/resolved tenant and membership/tenant state;
4. resolve only same-tenant family IDs and fail if any mixed tenant is observed;
5. acquire family locks in deterministic UUID order;
6. evaluate reservations, lane blocks and event lanes only for the derived tenant;
7. insert reservation with the same tenant and retain the exclusion guarantee.

Tenant A cannot conflict with B because they cannot share a lane or hierarchy. Do not solve this by merely adding `WHERE tenant_id = p_tenant_id`; cross-tenant composite constraints must make a mixed family impossible.

## 14. Reports Impact

`admin_get_reservation_report_v1/v2`, export and `_admin_reservation_report_rows_v2` currently aggregate the global reservation set after a global admin role check. Every report RPC must require a validated tenant and filter at its base CTE, not after aggregation.

Preserve:

- aggregate/detail filter parity;
- 50-row detail pagination and 5000 export limit;
- CSV formula-injection protection and PII minimization;
- hierarchy semantics/no double count;
- historical snapshot residual already documented.

Hours/timezone must come from tenant configuration. Existing hardcoded `08:00–20:00` and `Europe/Warsaw` are CSK defaults to backfill, not platform constants.

## 15. Events Impact

- `events` needs direct tenant ownership because an event can exist without a lane.
- `event_lanes` must prove both ends have the same tenant.
- `event_registrations` needs durable tenant ownership for RLS, reporting and anonymized/history rows.
- public list/availability RPC must scope to resolved active tenant and remain PII-free.
- admin list/participants and write V2 RPC must validate tenant membership.
- `/my-events` may remain global owner-only or selected-tenant; this is a product decision, not a security shortcut.
- SEC-008 instructor-event assignment remains deferred, but an instructor must never cross a tenant even before the finer event-assignment model exists.

## 16. Check-in Impact

Public token lookup may remain token-addressed and minimal, but the token must resolve a reservation/event registration with a tenant. Staff lookup and mutation must then verify an active role in that tenant. A route-selected tenant must match the token-derived tenant; mismatch is a controlled not-found/deny, never a fallback.

Keep current token window, cancellation invalidation, idempotency and audit protections. Do not expose tenant-internal data in public token DTOs.

## 17. Application Layer Impact

| Area | Current behavior | Required context |
|---|---|---|
| home/public booking/events | one global CSK catalog | tenant slug resolved server-side; public active tenant config |
| login/register/callback | global Auth | remain global; preserve intended return tenant safely |
| account | global profile/self lifecycle | global account plus selected tenant relationship section |
| my reservations/events | owner RPC, currently all CSK | explicit selected tenant or clearly labeled global aggregate |
| admin middleware/layout | global `profiles.role` | tenant from route + server membership/tenant-state check |
| dashboard/reservations/calendar | direct global reads | tenant-aware RPC or table query protected by tenant RLS |
| reports/users/check-in | global admin functions/reads | validated tenant membership and minimal DTO |
| lane config/blocks/events | resource IDs, global role | derive tenant from resource and compare to route context |
| API/email routes | server lookup by global IDs | derive tenant from trusted record; validate caller relation; tenant branding/config |

Recommended route shape for first SaaS release: `/t/[tenantSlug]/booking`, `/t/[tenantSlug]/events`, `/t/[tenantSlug]/admin/...`. Keep global `/login`, `/register`, `/account`, with a validated return path. Compatibility redirects can preserve current CSK URLs during transition.

## 18. Cache / Query Key Risks

No shared client query library or explicit Next data cache was found. Current risk is therefore mostly future-facing.

Rules for SaaS:

- every cache key for tenant data includes immutable tenant ID, not display slug alone;
- tenant resolution response varies by host/path and is never globally memoized without that key;
- private/admin/API responses remain `private, no-store`;
- public configuration may cache by tenant ID plus configuration version;
- logout or tenant switch clears tenant-specific browser state;
- route prefetch must not reuse an admin response across tenants;
- server/service-role helpers must never cache data before authorization.

## 19. Tenant Resolution Options

| Option | Advantages | Risks/cost | Recommendation |
|---|---|---|---|
| subdomain | strong branding/SEO boundary | wildcard DNS/TLS, auth callback/cookie complexity, local dev | Phase 2 |
| path `/t/slug` | explicit, simple Vercel/local dev, easy links and middleware | less white-label; route migration | **First SaaS version** |
| custom domains | best tenant branding | domain verification, TLS, phishing/support complexity | Later |
| in-app selector only | convenient for signed-in global user | weak public deep-link/SEO; context mistakes | Supplement, not primary resolver |

Canonical identifier is tenant UUID; slug/host is only a lookup key. Resolution must confirm tenant is active and pass the immutable ID to DB authorization. Do not trust a cookie/localStorage tenant without server validation.

Minimal public tenant discovery fields: slug, public name, lifecycle/public-booking status, public address/contact, timezone, service summary and optional logo/theme. Do not expose membership counts, staff, internal settings or private verification requirements.

## 20. Recommended Target Architecture

```text
auth.users (global account)
  ├── profiles (minimal global, user-owned identity/default contact)
  └── tenant_memberships (tenant role/status/terms)
        └── tenant_user_profiles (tenant verification/note/requirements data)

tenants
  ├── shooting_lanes ── lane config/durations/pricing/version
  │      ├── reservations
  │      └── lane_blocks
  ├── events ── event_registrations
  │      └── event_lanes ── shooting_lanes (same-tenant constraint)
  ├── audit_logs
  └── tenant configuration (timezone, opening hours, public data)
```

Use explicit tenant IDs in business roots and history rows. Use derived ownership for tightly bound configuration children. All privileged DB helpers operate on `(auth.uid(), tenant_id)` and active tenant/membership. Platform administration is an isolated control plane, not a special tenant role.

Minimal tenant lifecycle: `pending`, `active`, `suspended`, `disabled`.

- pending: setup only, not public;
- active: normal operation;
- suspended: public booking and tenant writes denied; historical/admin read policy must be explicitly defined;
- disabled: no tenant operation; retained history subject to legal lifecycle.

## 21. Existing CSK Migration Strategy

Create one deterministic CSK tenant UUID and preserve every existing business UUID. Backfill ownership rather than copying records.

Validation gates:

- every root lane and event has CSK tenant;
- every child lane matches parent tenant;
- every reservation/block/config row resolves to exactly one CSK lane;
- every event lane connects CSK event and CSK lane;
- every registration resolves to CSK event, including anonymized history;
- all audit/delivery rows are either attributed to CSK or explicitly classified platform/global;
- counts, fingerprints, conflict behavior, reports and historical records match preflight.

Do not infer production trigger behavior only from the local baseline; snapshot `auth.users` profile trigger and effective policies/functions in production before writing migration SQL.

## 22. Migration Dependency Graph

```text
business/privacy decisions
  ↓
production schema + ACL/RLS/function snapshot
  ↓
tenants + dormant CSK tenant
  ↓
memberships + tenant user profile/verification foundation
  ↓
nullable ownership columns on business roots/history
  ↓
CSK backfill + consistency validation
  ↓
tenant composite constraints + tenant-prefixed indexes
  ↓
additive tenant-aware role helpers and versioned RPC
  ↓
tenant-aware RLS installed behind single-CSK/cutover guard
  ↓
path-based tenant resolution + application/API cutover
  ↓
cross-tenant SQL/integration/E2E/concurrency tests
  ↓
revoke legacy RPC/policies + NOT NULL/contract
  ↓
enable creation/activation of tenant B
```

## 23. Ordered Migration Phases

**Phase 0 — decisions and evidence.** Resolve section 29 decisions; backup; dump schema; record counts, definitions, ACL/RLS, grants, indexes, triggers and representative report/conflict results. STOP on drift.

**Phase 1 — dormant foundation.** Add `tenants`, membership and tenant user data tables plus one inactive/internal CSK tenant. Do not change app behavior. Explicitly prevent a second active business tenant.

**Phase 2 — expand ownership.** Add nullable tenant columns only to selected tables. Add indexes without long blocking where possible. No policy may interpret null as global access.

**Phase 3 — backfill.** In bounded transactions assign CSK tenant, derive child ownership, classify global audit/rate-limit rows, validate zero orphan/mixed rows. Keep current app while exactly one tenant exists.

**Phase 4 — constraints.** Add composite unique keys/FKs as `NOT VALID` where supported, validate, then enforce hierarchy/event-lane/pricing invariants. Update exclusion/index strategy without dropping old protection first.

**Phase 5 — additive DB contract.** Add tenant-aware helpers and versioned RPC; test both contract generations. New RPC verifies membership internally. Install tenant-aware policies in a coordinated migration only when all tenant-owned rows are backfilled.

**Phase 6 — application cutover.** Introduce `/t/[slug]`, server tenant resolution, tenant-aware middleware/API/query calls, CSK compatibility redirects and tenant-aware branding/config. New app requires expanded DB; deploy with compatibility RPC present.

**Phase 7 — security cutover.** Verify real roles and cross-tenant denial, then revoke old authenticated RPC, remove global staff policies/helpers, set mandatory tenant columns `NOT NULL` and prohibit unscoped writes.

**Phase 8 — tenant activation.** Only after full test/postflight may tenant B be created/activated. From this point old app rollback is unsafe.

## 24. Rollback Strategy

- Phases 1–4 are additive. Roll back application behavior, not populated columns; never destroy backfilled ownership to recover.
- Keep legacy RPC only while the database guarantees exactly one active CSK tenant. Freeze tenant onboarding during compatibility.
- If tenant-aware DB deploy fails before app cutover, retain old app and disable new RPC/routes.
- If app deploy fails after additive DB, roll back app while CSK is the only tenant.
- If policy cutover fails, fail closed and restore previously captured policy definitions only after confirming one-tenant state and ACL baseline.
- After tenant B exists, do not roll back to an app/RPC that ignores tenant. Fallback is a known tenant-aware release, tenant suspension or write freeze.
- Backup and schema snapshots are recovery inputs; no plan should rely on destructive down migrations for live tenant data.

## 25. Security Risks

### Finding SAAS9A-001

ID: SAAS9A-001
SEVERITY: CRITICAL (for multi-tenant activation; not exploitable as cross-tenant in current one-tenant V1)
AREA: authorization / roles / RLS
AFFECTED FILES: `middleware.ts`, `lib/admin/route-protection.js`, `20260816090000_remote_baseline.sql`
AFFECTED TABLES / FUNCTIONS: `profiles`; `get_my_role`, `is_admin*`; all staff RLS policies
CURRENT BEHAVIOR: one global profile role authorizes all rows.
RISK: admin/employee/instructor A gains equivalent authority over B.
SAAS IMPACT: direct SEC-004 violation.
RECOMMENDED SOLUTION: tenant membership roles and tenant-required helper predicates.
MIGRATION PHASE: 1, 5, 7.
TEST REQUIRED: complete role-by-tenant matrix and missing-context fail-closed tests.

### Finding SAAS9A-002

ID: SAAS9A-002
SEVERITY: HIGH
AREA: data ownership
AFFECTED FILES: baseline schema and all business modules
AFFECTED TABLES / FUNCTIONS: lanes, reservations, blocks, events, registrations, audit
CURRENT BEHAVIOR: no tenant ownership column or registry exists.
RISK: records cannot be securely partitioned or audited by tenant.
SAAS IMPACT: tenant B cannot be safely represented.
RECOMMENDED SOLUTION: ownership matrix from section 5 and validated CSK backfill.
MIGRATION PHASE: 1–4.
TEST REQUIRED: zero null/orphan/mixed-tenant rows and count/fingerprint parity.

### Finding SAAS9A-003

ID: SAAS9A-003
SEVERITY: CRITICAL (for multi-tenant activation)
AREA: SECURITY DEFINER / IDOR
AFFECTED FILES: booking, event, report, check-in and admin migrations/API call-sites
AFFECTED TABLES / FUNCTIONS: all privileged RPC families in section 11
CURRENT BEHAVIOR: caller passes resource IDs; functions check global role or ownership, never membership in the resource tenant.
RISK: guessed/obtained UUID can target another tenant; definer bypass magnifies impact.
SAAS IMPACT: cross-tenant read/write/escalation.
RECOMMENDED SOLUTION: derive tenant from locked records and validate active membership/context inside each RPC.
MIGRATION PHASE: 5–7.
TEST REQUIRED: hostile tenant-ID/resource-ID substitution for every RPC.

### Finding SAAS9A-004

ID: SAAS9A-004
SEVERITY: HIGH
AREA: relational integrity
AFFECTED FILES: baseline schema
AFFECTED TABLES / FUNCTIONS: lane hierarchy, `event_lanes`, reservation pricing linkage
CURRENT BEHAVIOR: FKs prove object existence, not same-tenant ownership.
RISK: mixed-tenant graph bypasses otherwise correct RLS/RPC assumptions.
SAAS IMPACT: conflicts, calendar and reports can leak/corrupt tenant data.
RECOMMENDED SOLUTION: composite same-tenant FKs/validated triggers.
MIGRATION PHASE: 4.
TEST REQUIRED: attempts to connect event A/lane B, child A/parent B, price B/reservation A.

### Finding SAAS9A-005

ID: SAAS9A-005
SEVERITY: HIGH
AREA: profile privacy / verification
AFFECTED FILES: account/admin users/booking and profile RPC migrations
AFFECTED TABLES / FUNCTIONS: `profiles`, admin user and verification RPC
CURRENT BEHAVIOR: identity, contact, permissions, tenant verification, role and admin note are one global record.
RISK: tenant admin sees or changes data unrelated to their tenant; verification propagates unintentionally.
SAAS IMPACT: violates data minimization and business model.
RECOMMENDED SOLUTION: global user-owned profile plus tenant-specific relationship/verification DTO.
MIGRATION PHASE: 1, 5–7.
TEST REQUIRED: admin A cannot inspect/modify relationship B; global user still serves A and B.

### Finding SAAS9A-006

ID: SAAS9A-006
SEVERITY: HIGH
AREA: public/admin read models
AFFECTED FILES: `/booking`, `/events`, admin dashboard/calendar/reports/users/events
AFFECTED TABLES / FUNCTIONS: public config/events; report/list RPC; direct table reads
CURRENT BEHAVIOR: global result sets with no tenant resolver.
RISK: merged catalogs and cross-tenant operational/PII data.
SAAS IMPACT: public correctness and private isolation failure.
RECOMMENDED SOLUTION: route-derived tenant and bounded tenant-aware RPC/DTO.
MIGRATION PHASE: 5–7.
TEST REQUIRED: response equality to selected tenant scope and no PII expansion.

### Finding SAAS9A-007

ID: SAAS9A-007
SEVERITY: MEDIUM
AREA: audit/delivery attribution
AFFECTED FILES: audit, e-mail, lifecycle migrations/routes
AFFECTED TABLES / FUNCTIONS: `audit_logs`, `email_deliveries`, delivery/rate-limit RPC
CURRENT BEHAVIOR: no tenant attribution; audit admin is global.
RISK: audit visibility leaks and ambiguous incident ownership.
SAAS IMPACT: weak forensic boundary.
RECOMMENDED SOLUTION: nullable tenant on mixed audit/delivery records, tenant-scoped reads; keep abuse rate limit global initially.
MIGRATION PHASE: 2–7.
TEST REQUIRED: audit A invisible to B; platform events explicitly null/platform-scoped.

### Finding SAAS9A-008

ID: SAAS9A-008
SEVERITY: MEDIUM
AREA: tenant configuration / application
AFFECTED FILES: booking, reports, calendar, event validation, e-mail templates/layout/legal content
AFFECTED TABLES / FUNCTIONS: booking/report/event functions
CURRENT BEHAVIOR: CSK brand, Warsaw timezone and 08:00–20:00 are platform constants.
RISK: incorrect hours, DST, communication and reports for another tenant.
SAAS IMPACT: blocks configurable facility operation.
RECOMMENDED SOLUTION: backfill CSK tenant settings and consume one tenant config contract.
MIGRATION PHASE: 1, 5–6.
TEST REQUIRED: two tenants with different timezone/hours/brand and no state bleed.

### Finding SAAS9A-009

ID: SAAS9A-009
SEVERITY: MEDIUM
AREA: performance
AFFECTED FILES: report/event list migrations and calendar queries
AFFECTED TABLES / FUNCTIONS: reservations, events, registrations, blocks, audit
CURRENT BEHAVIOR: indexes are global and not prefixed by tenant.
RISK: growing scans/RLS joins and unstable pagination at SaaS volume.
SAAS IMPACT: latency and lock amplification.
RECOMMENDED SOLUTION: tenant-prefixed composite indexes based on `EXPLAIN` and actual predicates.
MIGRATION PHASE: 4, 8.
TEST REQUIRED: per-tenant query plans and bounded response/load tests.

### Finding SAAS9A-010

ID: SAAS9A-010
SEVERITY: HIGH
AREA: migration safety
AFFECTED FILES: future migrations/deployment plan
AFFECTED TABLES / FUNCTIONS: all tenant-owned data and old RPC/policies
CURRENT BEHAVIOR: adding tenant B while old global policies/RPC exist would immediately expose B.
RISK: temporary or permanent cross-tenant window.
SAAS IMPACT: catastrophic isolation failure during rollout.
RECOMMENDED SOLUTION: hard one-active-tenant guard, additive compatibility, coordinated security cutover, then enable B.
MIGRATION PHASE: all.
TEST REQUIRED: deployment-state compatibility matrix and automatic tenant-B activation gate.

## 26. Test Strategy

**SQL/RLS matrix** for anon, user A/B, admin A/B, employee A/B, instructor A/B and platform service. Test SELECT/INSERT/UPDATE/DELETE against every tenant-owned table. Missing/invalid tenant context must deny.

**RPC/IDOR tests:** for every public/authenticated/privileged RPC substitute tenant B ID, resource B UUID, mixed arrays and stale versions as caller A. Verify stable controlled denial, unchanged rows, timestamps and audit counts.

**Global account tests:** one auth user has membership A and B with different roles/status/verification. Own screens work in both; admins see only their tenant relationship and activity.

**Relational integrity:** cross-tenant parent, event-lane, pricing-reservation and audit entity links fail at DB level.

**Concurrency:** retain reservation family lock ordering, exclusion conflicts, event capacity, delivery claims and configuration optimistic locking; demonstrate simultaneous A/B operations do not block/conflict except on truly global abuse controls.

**Module integration:** booking, availability, calendar Day/Week/Month, reports/CSV, users, events/reserve/promotion, lane blocks/config, check-in, emails and account lifecycle for two tenants.

**Playwright:** path tenant resolution, switcher, direct URL denial, back/forward, stale tenant cookies, multi-tab A/B, mobile and branding. Capture network requests and assert tenant-scoped contracts/no PII.

**Migration tests:** production-shaped clone, repeatable backfill, constraints validation, old/new app compatibility, abort/rollback at each phase, counts/fingerprints before/after.

## 27. Performance Considerations

- RLS membership checks need indexed `(tenant_id,user_id,status)` and should avoid repeated unindexed profile joins.
- Begin tenant-filtered report/list queries at the base relation so aggregation and pagination process only one tenant.
- Keep public event availability bounded to the current tenant/page.
- Add tenant prefix to high-cardinality schedule/report indexes after `EXPLAIN (ANALYZE, BUFFERS)` on production-shaped data.
- Composite FKs introduce supporting unique indexes; avoid redundant duplicates.
- Large backfills should be batched, observable and followed by `ANALYZE`; use nonblocking index creation where platform transaction rules permit.
- Tenant config reads may be cached by `(tenant_id,configuration_version)`; private operational data should remain no-store.

## 28. SEC-004 Closure Criteria

SEC-004 can be closed only when all are true:

1. every tenant-owned root/history row has non-null, validated ownership;
2. all cross-object links enforce same tenant;
3. roles and verification are tenant-specific;
4. RLS denies A→B for all CRUD and missing context;
5. every SECURITY DEFINER/browser/server RPC derives or validates tenant in DB;
6. public contracts expose only resolved active tenant and remain PII-minimal;
7. reservations/conflicts, calendar, reports, users, events, blocks/config and check-in are tenant-scoped;
8. audit visibility and attribution are tenant-scoped;
9. no browser service-role use or server ID bypass exists;
10. cross-tenant SQL, integration, Playwright and concurrency suites pass;
11. legacy global grants/RPC/policies are revoked;
12. tenant B activation gate and post-deploy production smoke pass.

## 29. Blocking Decisions

These decisions cannot be safely inferred from the repo:

1. **Global profile sharing.** A: tenant receives current global contact/details after membership; B: user explicitly supplies/consents a tenant copy. A is simpler but risks over-sharing. B is safer and supports different requirements. **Recommend B**, with minimal booking contact snapshots.
2. **Membership creation.** A: membership automatically on first public interaction; B: explicit join/terms acceptance before tenant-specific state. **Recommend transactional B** during first booking/registration, with recorded terms version; browsing remains membership-free.
3. **Suspended tenant semantics.** A: block only new public writes; B: block public and tenant staff writes, preserve authorized history/report reads. **Recommend B**, with platform-only recovery path.
4. **Cross-tenant “My” screens.** A: global aggregate; B: selected tenant only. **Recommend B initially** for clarity, optional global owner-only aggregate later.
5. **Platform support access.** A: platform admin automatically reads tenant data; B: separate control-plane role with no default data access and audited break-glass. **Recommend B**.
6. **Initial URL boundary.** A: path; B: subdomain from day one. **Recommend path** for first SaaS version, preserving an abstraction for future host/custom-domain resolution.
7. **Tenant verification data set.** A: copy all current declarations/contact to every tenant; B: tenant explicitly defines required fields and receives only submitted fields. **Recommend B**, but the exact first-version required fields need owner/legal approval before backfill.

## 30. Recommended SAAS-9B Scope

Minimal, safe SAAS-9B foundation only:

1. capture/commit reproducible schema/RLS/ACL/function/trigger inventory checks;
2. define and test one `tenants` table with lifecycle and globally unique slug;
3. create exactly one CSK tenant row;
4. define `tenant_memberships` and minimal tenant verification/profile table, without moving production authorization yet;
5. define separate platform-role foundation with no implicit tenant data grants, only if required for tenant creation;
6. add no tenant B, no business-table `tenant_id` backfill, no route change, no RLS/RPC cutover;
7. document compatibility, down/fallback behavior and automated “only one active tenant” guard;
8. add focused DB tests proving new foundation ACL is fail-closed and has no effect on V1 flows.

SAAS-9B should be an additive, dormant database foundation. Business ownership/backfill belongs to a separately reviewed SAAS-9C. This keeps the first step small enough to audit and roll back without pretending SEC-004 is closed.

## 31. GO / NO-GO Recommendation

**GO — only for the minimal SAAS-9B foundation defined in section 30.**

**NO-GO — for activating/onboarding a second tenant, changing production authorization, or claiming SEC-004 remediated.**

Conditions before starting SAAS-9B:

- decide global-profile sharing/consent, membership creation and tenant suspension semantics;
- verify the effective production `auth.users → profiles` trigger and capture production schema/ACL/RLS/function fingerprints;
- agree that path-based resolution is the first delivery target;
- enforce a hard guard that tenant B cannot become active during compatibility phases.

The current single-tenant CSK remains valid while these SaaS changes are dormant. The architecture is migratable without changing existing UUIDs or losing history, but tenant isolation must be established across data ownership, constraints, RLS, RPC and application routing before any second facility exists.
