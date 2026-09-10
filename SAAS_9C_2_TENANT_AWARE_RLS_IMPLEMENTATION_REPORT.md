# SAAS-9C-2A/2B — Tenant-Aware Booking RLS Implementation Report

## 1. Executive summary

SAAS-9C-2A and SAAS-9C-2B were implemented and verified locally only. The change replaces the six legacy SELECT policies on `shooting_lanes`, `reservations`, and `lane_blocks` with tenant-aware policies based on active `tenant_memberships`. No application code, business RPC, temporary CSK default, active-tenant guard, Events RLS, production database, or deployment was changed.

The direct-table boundary now fails closed across tenants. Legacy `SECURITY DEFINER` RPCs still bypass RLS and remain explicit SAAS-9D blockers. Consequently SECOND TENANT remains NO-GO and SEC-004 remains OPEN.

## 2. 9C-2A verification

- `tenant_memberships` exists and retains exactly the owner self-read policy.
- Existing profiles and CSK memberships reconcile after a clean local reset.
- Approved role mapping remains `admin/admin`, `user/user`, `pracownik/employee`, and `instruktor/instructor`.
- `active` membership authorizes only the explicit membership role; `pending`, `suspended`, absent membership, unknown roles, and NULL tenant fail closed.
- The four 9C-1 helpers remain `SECURITY DEFINER`, owned by `postgres`, with fixed `search_path = pg_catalog, public, pg_temp`.
- `is_tenant_member_v1`, `has_tenant_role_v1`, and `get_my_tenant_role_v1` remain authenticated-only. `active_single_tenant_id_v1` remains internal with no client execute.
- No existing helper grant was expanded.
- Membership self INSERT/UPDATE/DELETE remains denied.
- Repeated policy/helper evaluation produces no RLS recursion.

One new minimal policy-only helper was added: `is_active_public_tenant_v1(uuid)`. It returns only boolean, verifies exactly one active tenant and matching active tenant ID, is hardened as above, and is executable only by `anon` and `authenticated`. It does not expose tenant metadata or expand grants on any existing helper.

## 3. Test identities

The rollback-only test creates unique local identities for `USER_A`, `USER_B`, `ADMIN_A`, `EMPLOYEE_A`, `INSTRUCTOR_A`, `NO_MEMBERSHIP_USER`, plus pending and suspended users. It creates a unique dormant Tenant B and synthetic A/B lanes, reservations, pricing rules, and lane blocks. A controlled local status swap proves the multi-tenant owner case while preserving the one-active-tenant guard.

All SQL fixture is inside one transaction ending in `ROLLBACK`. Playwright uses its existing localhost-only fixture/cleanup guard.

## 4. Existing policy inventory

Before 9C-2B:

| Table | Policy | Source |
|---|---|---|
| `shooting_lanes` | public active rows | `is_active` only |
| `shooting_lanes` | all staff rows | global `is_admin_or_staff()` |
| `reservations` | own rows | `user_id = auth.uid()` only |
| `reservations` | all staff rows | global `is_admin_or_employee()` |
| `lane_blocks` | active rows | authenticated + `is_active` only |
| `lane_blocks` | all staff rows | global `is_admin_or_staff()` |

## 5. Policies removed

- `Public can view active shooting lanes`
- `Staff can view all shooting lanes`
- `Users can view own reservations`
- `Admins and staff can view all reservations`
- `Anyone can view active lane blocks`
- `Admins and staff can view all lane blocks`

All six are dropped and replaced atomically in one migration transaction. There is no permissive old-plus-new window.

## 6. Policies added

- `Public can view active tenant shooting lanes`
- `Tenant staff can view shooting lanes`
- `Tenant members can view own reservations`
- `Tenant admin and employee can view reservations`
- `Tenant members can view active lane blocks`
- `Tenant staff can view lane blocks`

All are SELECT-only. No INSERT, UPDATE, or DELETE policy was added.

## 7. `shooting_lanes` RLS

- Public and authenticated callers may read active lanes only from the exactly-one active tenant.
- Active tenant admin/employee/instructor memberships may read all lanes in their tenant.
- Ordinary membership does not grant inactive/admin catalog access.
- A global `profiles.role` value alone does not authorize another tenant.
- Dormant Tenant B lanes are invisible while CSK is active.

## 8. `reservations` RLS

- Owner access requires both `user_id = auth.uid()` and an active membership in `reservation.tenant_id` whose tenant is active.
- A user with active memberships in multiple tenants can read their own reservation in whichever tenant is currently active; ownership never exposes another user's record.
- Admin and employee access requires the corresponding active role in the row tenant.
- Instructor receives no global reservation access. An instructor would retain ordinary owner access only for their own reservation, matching the previous owner policy.
- Missing, pending, suspended, or dormant-tenant membership denies private reads.

## 9. `lane_blocks` RLS

- An authenticated active member can read active blocks in their tenant, preserving the previous logged-in availability contract without exposing another tenant.
- Tenant admin/employee/instructor retain their existing same-tenant all-block read.
- Anon still has no direct `lane_blocks` SELECT ACL.
- Direct mutation remains unavailable; controlled RPCs are unchanged.

## 10. Public read preservation

- Public active lane SELECT remains available without membership, now restricted to the guarded active tenant.
- `get_public_booking_configuration_v1()` anon execution remains unchanged.
- `get_lane_booking_busy_ranges_v3()` authenticated execution remains unchanged.
- Pricing/configuration and availability RPC definitions were not modified.
- Full local Playwright public Booking passed.

Public definer RPCs are still CSK transitional contracts and must receive explicit tenant predicates in SAAS-9D before a second active tenant.

## 11. Owner access

Verified:

- User A own A reservation: ALLOW.
- User A own B reservation while B is dormant: DENY.
- User A own B reservation while B is the single active tenant and User A has active B membership: ALLOW.
- User A reading User B reservation: DENY.
- No-membership, pending, and suspended owners: DENY.

## 12. Admin access

- Admin A lanes/reservations/blocks in Tenant A: ALLOW.
- Admin A equivalent rows in Tenant B: DENY.
- Global legacy role alone does not cross the tenant boundary in direct SELECT policies.

## 13. Employee access

- Employee A retains the current operational read scope in Tenant A.
- Employee A Tenant B access: DENY.
- No admin-only or membership-management privilege was introduced.

## 14. Instructor behavior

- Same-tenant full lane and lane-block visibility is preserved.
- Tenant B visibility is denied.
- No global reservation access was added.
- Events/event registrations were not changed. SEC-008 remains deferred.

## 15. Membership status semantics

Only an active membership in an active tenant authorizes tenant-private or staff access. Record existence with `pending` or `suspended` status is insufficient. Invalid role arrays and NULL tenant IDs fail closed.

## 16. Cross-tenant IDOR tests

The 60-check RLS suite covers Tenant B identifiers for SELECT, direct UPDATE, DELETE, and INSERT. Tenant A admin cannot directly mutate Tenant B lanes, reservations, or blocks. Direct DML is blocked by table ACL and the absence of mutation policies. Composite tenant foreign keys remain unchanged as a structural second line of defense.

## 17. RLS recursion tests

- Membership self-read does not invoke membership helpers.
- Policy helpers are hardened definers and do not recurse through the caller's membership policy.
- Repeated evaluation across generated rows completed normally.
- No infinite recursion, stack overflow, or policy recursion error occurred.

## 18. Performance/query-plan notes

Local `EXPLAIN (COSTS OFF)` confirmed:

- `shooting_lanes_tenant_hierarchy_order_idx` for tenant catalog reads;
- `reservations_tenant_schedule_idx` for tenant/date reservation reads;
- `lane_blocks_tenant_schedule_idx` for tenant/date block reads;
- `tenant_memberships_user_status_tenant_idx` for membership self lookups.

The planner uses an init plan for `auth.uid()` in owner predicates. No new index was required.

## 19. SECURITY DEFINER bypass matrix

| Path | RLS applies | RLS bypassed | Membership tenant check | Safe for second tenant | Status |
|---|---:|---:|---:|---:|---|
| Direct reservation INSERT/UPDATE/DELETE | Yes | No | Not applicable: ACL/policy deny | Yes, denied | Keep denied |
| `create_reservation_v2` | No | Yes | No complete check; legacy/default bridge | No | SAAS-9D blocker |
| `cancel_reservation` | No | Yes | Ownership/global legacy role, not membership tenant | No | SAAS-9D blocker |
| reservation payment/attendance/admin-note RPCs | No | Yes | Global legacy staff role | No | SAAS-9D blocker |
| lane family/config writers | No | Yes | Global legacy admin role | No | SAAS-9D blocker |
| lane-block create/update/toggle RPCs | No | Yes | Global legacy admin/employee role | No | SAAS-9D blocker |
| `get_my_reservations_v2` / busy-range reads | No | Yes | Owner/object rules without complete tenant context | No second-tenant claim | SAAS-9D review |

The test deliberately proved the residual: Admin A could invoke legacy `admin_set_lane_block_active` against a Tenant B block because the function is `SECURITY DEFINER` and trusts global `profiles.role`. The entire transaction rolled back. This is expected evidence, not a 9C-2B regression, and is the direct reason SECOND TENANT remains NO-GO.

## 20. Legacy runtime compatibility

- `profiles.role` remains present and active for unchanged legacy runtime paths.
- The CSK role sync bridge remains installed.
- All seven temporary CSK defaults remain.
- The second-active-tenant unique guard remains.
- Critical RPC definitions/fingerprints are unchanged by the migration.
- Public Booking, admin operational screens, reservation flows, Calendar, Reports, Events, Check-in, and lane configuration passed the available local test coverage.

## 21. Full regression

| Check | Result |
|---|---|
| Local `supabase db reset` | PASS, exit 0 |
| SAAS-9C-2A focused | PASS, 25/25 |
| SAAS-9C-2B/cross-tenant focused | PASS, 60/60 |
| Full Supabase DB suite | PASS, 24 files / 622 tests |
| Node full suite | PASS, 734/734 |
| TypeScript | PASS |
| Next.js production build | PASS |
| Playwright full local suite | PASS, 30/30 |
| Query-plan review | PASS |
| `git diff --check` | PASS for tracked and new files |

Build retains the known Next.js `middleware` to `proxy` deprecation warning. `npm audit --omit=dev` reports one moderate advisory in `baseline-browser-mapping@2.10.30`, transitively from `next@16.3.4`; it is unrelated to the RLS implementation and was not modified here.

## 22. Deferred 9C-2C/2D/2E

No policy was changed for Events, event registrations, audit, email deliveries, tenants, or membership staff administration. No legacy-policy retirement checkpoint beyond the booking tables was performed.

## 23. SAAS-9D blockers

Every listed booking writer/read definer must derive tenant from trusted rows, validate actor membership/role in that tenant, constrain follow-up IDs, explicitly write tenant ownership, and stop relying on CSK defaults. Service-role paths require the same trusted-tenant binding. No second tenant may activate before those changes and later 9E–9H gates.

## 24. Production deployment plan

No production action is authorized. A future dedicated preflight must verify membership reconciliation, policy/ACL/helper/RPC fingerprints, one active CSK tenant, seven defaults, integrity constraints, table sizes/locks, migration history, SHA-256, exact dry-run, and rollback readiness. Deployment should apply only `20260910120000_add_tenant_aware_booking_rls.sql`, followed by direct RLS matrix verification and Booking/admin/Reservations/Calendar/Reports/Check-in smoke. Stop and use a reviewed forward-fix or exact-policy rollback migration on any regression; never use migration repair.

## 25. Git status

The implementation remains unstaged and uncommitted. No Git push was performed.

## 26. Final verdict

SAAS-9C-2A LOCAL: **PASS**

SAAS-9C-2B LOCAL: **PASS**

PUBLIC BOOKING CONTRACT: **PASS**

CROSS-TENANT RLS: **PASS**

RLS RECURSION: **PASS**

LEGACY SINGLE-TENANT RUNTIME: **PASS**

READY FOR 9C-2A/2B PRODUCTION PREFLIGHT: **GO**

READY FOR PRODUCTION WRITE: **NO**

READY FOR 9C-2C: **NO-GO until review**

READY FOR SAAS-9D: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 28. PRODUCTION DEPLOYMENT & POST-DEPLOY VERIFICATION

### 28.1 Final pre-push gates

Bezpośrednio przed wdrożeniem ponownie potwierdzono:

- branch `main`, HEAD `23a226ea1a152ea8cb3994d746db49771cb1950b`;
- linked project `yuyxfodozzpzrdzkmolu`;
- SHA-256 migracji `20260910120000_add_tenant_aware_booking_rls.sql` = `A5A16933CE5DECDA0B0AB41CD5CDBE693E83B109AAD5F54A11B4780B5EFC2CF1`;
- LOCAL=REMOTE przez `20260910110000`, bez remote-only migration i bez divergence;
- jedyną pending migration był `20260910120000_add_tenant_aware_booking_rls.sql`;
- produkcja: 1 active tenant, 9 memberships (9 active), 0 orphan users, 0 orphan tenants, 0 profile/membership role mismatches;
- `git diff --check`: PASS.

### 28.2 Deployment result

Wykonano dokładnie jeden zatwierdzony production push:

```text
npx.cmd supabase db push --linked --yes
```

CLI wskazał i zastosował wyłącznie:

```text
20260910120000_add_tenant_aware_booking_rls.sql
```

Polecenie zakończyło się kodem 0 i komunikatem `Finished supabase db push`. Nie wykonywano `migration repair`, ręcznego SQL wdrożeniowego ani innych migracji.

### 28.3 Migration history and post-deploy dry-run

Po wdrożeniu `npx.cmd supabase migration list --linked` potwierdził LOCAL=REMOTE także dla `20260910120000`. Ponowny:

```text
npx.cmd supabase db push --linked --dry-run
```

zakończył się kodem 0 i wynikiem `Remote database is up to date.` Brak pending migrations.

### 28.4 Production RLS / ACL verification

Bezpośredni, read-only odczyt produkcyjnego katalogu potwierdził RLS enabled na wszystkich 3 tabelach oraz dokładnie 6 polityk, wyłącznie `SELECT`:

- `shooting_lanes`: `Public can view active tenant shooting lanes`, `Tenant staff can view shooting lanes`;
- `reservations`: `Tenant members can view own reservations`, `Tenant admin and employee can view reservations`;
- `lane_blocks`: `Tenant members can view active lane blocks`, `Tenant staff can view lane blocks`.

Liczba mutation policies na tych tabelach wynosi 0. Liczba referencji do legacy helperów `is_admin`, `is_admin_or_employee` i `is_admin_or_staff` w nowych politykach wynosi 0. Migracja nie zmieniła table ACL: fingerprint pozostał `e1b387cc6dffcdd11beda90478c3381f`.

Kontrakt pozostaje zgodny z lokalną macierzą 60/60: public widzi wyłącznie aktywne osie aktywnego single tenanta; owner widzi wyłącznie własne rezerwacje przy aktywnym membership; admin/employee widzą rezerwacje tenanta; instructor nie otrzymuje globalnego odczytu rezerwacji; aktywne lane blocks są widoczne wyłącznie tenant members, a pełny odczyt lanes/blocks ma tenant staff. Nie aktywowano Tenant B i nie wykonywano produkcyjnych mutacji w celu ponownego symulowania cross-tenant fixture.

### 28.5 Public tenant helper

`is_active_public_tenant_v1(uuid)` ma ownera `postgres`, `SECURITY DEFINER`, volatility `STABLE` i `search_path=pg_catalog, public, pg_temp`. Efektywny `EXECUTE`:

| Role | EXECUTE |
|---|---:|
| PUBLIC | NO |
| anon | YES |
| authenticated | YES |
| service_role | NO |

Helper zwraca wyłącznie boolean, wymaga wskazanego active tenanta oraz dokładnie jednego active tenanta w systemie. Nie ujawnia tenant metadata ani memberships.

### 28.6 Membership, legacy auth and integrity invariants

Fresh post-deploy verification potwierdził:

- active tenants = 1;
- memberships = 9, active memberships = 9;
- orphan membership users = 0;
- orphan membership tenants = 0;
- profile/membership role mismatches = 0;
- 4 membership authorization helpery;
- 2 istniejące sync bridge triggery (`sync_profile_role_to_csk_membership`, `sync_csk_membership_role_to_profile`);
- 7 temporary CSK defaults;
- partial unique guard `tenants_single_active_runtime_guard` istnieje;
- `profiles.role` nadal ma typ `text`, bez schema CHECK, i pozostaje aktywnym legacy runtime authorization source.

### 28.7 Security fingerprints and existing RPCs

Post-deploy production fingerprints są zgodne z preflightem:

- unrelated RLS policies: `d68e1129e7e53e5c36ffe16053f16acf`;
- booking table ACL: `e1b387cc6dffcdd11beda90478c3381f`;
- `get_my_role()`: `dc8858eed7d2fd2d1ab47d22b0000b06`;
- `is_admin()`: `89a221fa092af2a457db05a64b7e8d18`.

Liczba funkcji `SECURITY DEFINER` wynosi 73, czyli oczekiwany baseline 72 plus nowy, minimalny helper public tenant. Wbudowany transakcyjny postflight migracji porównał definicje wszystkich wcześniejszych definers oraz unrelated RLS/booking ACL i przerwałby wdrożenie przy drift. Istniejące RPC nie zostały zmienione.

### 28.8 Public and authenticated runtime smoke

Po wdrożeniu realne produkcyjne ekrany załadowały właściwy content lub kontrolowany empty state, bez runtime 5xx:

- public: `/`, `/booking`, `/events`, `/login`, `/register`;
- authenticated: `/account`;
- admin: `/admin`, `/admin/reservations`, `/admin/calendar`, `/admin/reports`, `/admin/events`, `/admin/check-in`, `/admin/lane-configuration`.

`/booking` zwrócił aktualną listę osi/stanowisk przez istniejący publiczny read path. `/events` zwrócił kontrolowany publiczny stan bez participant PII. Login i rejestracja renderują się poprawnie; sesja administratora pozostała ważna. Nie klikano akcji mutujących i nie wykonano produkcyjnego fixture.

### 28.9 Known SECURITY DEFINER bypass

Status pozostaje świadomie niezmieniony: **KNOWN**. Legacy definers nadal omijają table RLS i nie wszystkie wiążą operację z tenant membership; ich tenant-aware cutover należy do SAAS-9D. Wdrożenie 9C-2A/2B nie rozszerzyło tego bypassu i nie zmieniło żadnego istniejącego RPC. Drugi tenant pozostaje technicznie zablokowany.

### 28.10 Production rollback posture

Nie był potrzebny rollback: push, katalogowe postflight checks i runtime smoke przeszły. W przypadku późniejszej regresji właściwą ścieżką pozostaje przejrzana forward-fix / exact-policy rollback migration; `migration repair` i ręczne zmiany schematu pozostają zakazane.

### 28.11 Final production verdicts

SAAS-9C-2A/2B PRODUCTION DEPLOY: **PASS**

SAAS-9C-2A/2B POST-DEPLOY VERIFICATION: **PASS**

PRODUCTION RLS / ACL: **PASS**

PUBLIC BOOKING / EVENTS: **PASS**

RUNTIME SMOKE: **PASS**

SECURITY DEFINER BYPASS: **KNOWN**

READY FOR GIT CHECKPOINT: **YES**

READY FOR 9C-2C: **NO-GO pending checkpoint/review and separate approval**

READY FOR SAAS-9D: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 27. PRODUCTION PREFLIGHT & DEPLOYMENT READINESS

Preflight wykonano 10 września 2026 r. dla połączonego projektu produkcyjnego `yuyxfodozzpzrdzkmolu`. Produkcyjna część obejmowała wyłącznie odczyty katalogów i agregatów, publiczne HTTP/RPC, `migration list` oraz `db push --linked --dry-run`. Nie wykonano produkcyjnego DML/DDL, właściwego `db push`, `migration repair`, zmiany aplikacji, commita ani Git push.

### 27.1 Local changeset review

- Branch: `main`.
- HEAD: `23a226ea1a152ea8cb3994d746db49771cb1950b`.
- `git diff --check`: **PASS**.
- Historyczne migracje 9B i 9C-1: **bez zmian**.
- Jedyna nowa migracja implementacyjna 9C-2A/2B: `supabase/migrations/20260910120000_add_tenant_aware_booking_rls.sql`.
- Nowe testy: foundation verification `20260910115000` oraz booking RLS matrix `20260910120000`.
- Zmienione historyczne pliki testowe nie modyfikują produkcyjnego SQL. Aktualizują wyłącznie zamrożone oczekiwania katalogowe po zatwierdzonym dodaniu helpera i wymianie sześciu polityk: funkcja/ACL inventory, dokładne nazwy polityk SELECT, dozwolony tenant-helper scope i fingerprint non-booking policies. Gwarancje braku mutation policy, minimalnych ACL, ownership i fail-closed pozostają aktywne.
- Realny tracked diff z pominięciem końców linii obejmuje plan oraz sześć historycznych testów; nowe artefakty pozostają untracked. Ostrzeżenia Git dotyczą wyłącznie przyszłej konwersji LF/CRLF, nie dodatkowej treści.

Stan plików podczas preflight:

```text
 M SAAS_9C_TENANT_AWARE_RLS_MEMBERSHIP_AUTHORIZATION_PLAN.md
 M supabase/tests/20260816143000_harden_public_function_execute_acl_test.sql
 M supabase/tests/20260904200000_harden_reservation_direct_delete_test.sql
 M supabase/tests/20260907100000_add_dormant_tenant_foundation_test.sql
 M supabase/tests/20260909110000_backfill_csk_tenant_ownership_test.sql
 M supabase/tests/20260909130000_tenant_relationship_integrity_test.sql
 M supabase/tests/20260910110000_tenant_membership_authorization_foundation_test.sql
?? SAAS_9C_2_TENANT_AWARE_RLS_IMPLEMENTATION_REPORT.md
?? supabase/migrations/20260910120000_add_tenant_aware_booking_rls.sql
?? supabase/tests/20260910115000_tenant_authorization_rls_foundation_verification_test.sql
?? supabase/tests/20260910120000_tenant_aware_booking_rls_test.sql
```

### 27.2 Fresh membership state

| Kontrola | Produkcja |
|---|---:|
| tenants / active tenants / active CSK | 1 / 1 / 1 |
| tenant memberships | 9 |
| roles | `admin=1`, `user=8` |
| statuses | `active=9` |
| duplicate `(tenant_id,user_id)` | 0 |
| orphan `user_id` / orphan `tenant_id` | 0 / 0 |
| unknown role / invalid status | 0 / 0 |
| profile ↔ membership role mismatch | 0 |

Stan jest dokładnie zgodny z post-SAAS-9C-1 baseline; nie wystąpił drift wynikający z nowej rejestracji.

### 27.3 Current production RLS baseline

Przed wdrożeniem istnieje dokładnie sześć polityk, wszystkie `SELECT`, bez `WITH CHECK`:

| Tabela | Policy | Role | USING |
|---|---|---|---|
| `shooting_lanes` | `Public can view active shooting lanes` | PUBLIC | `is_active = true` |
| `shooting_lanes` | `Staff can view all shooting lanes` | authenticated | `is_admin_or_staff()` |
| `reservations` | `Users can view own reservations` | authenticated | `user_id = auth.uid()` |
| `reservations` | `Admins and staff can view all reservations` | authenticated | `is_admin_or_employee()` |
| `lane_blocks` | `Anyone can view active lane blocks` | authenticated | `is_active = true` |
| `lane_blocks` | `Admins and staff can view all lane blocks` | authenticated | `is_admin_or_staff()` |

Legacy staff policies zależą od globalnego `profiles.role` przez helpery `is_admin_or_staff()` / `is_admin_or_employee()`. Migracja ma fail-closed preflight wymagający dokładnie tego baseline; jakakolwiek inna nazwa, komenda lub predykat zatrzyma wdrożenie.

### 27.4 Target policy comparison

- `shooting_lanes`: aktywny publiczny katalog pozostaje dostępny dla anon/authenticated, ale wyłącznie dla jedynego aktywnego tenanta; pełny odczyt staff jest ograniczony do aktywnego membershipu `admin`, `employee` lub istniejącego zakresu `instructor` w tenancie rekordu.
- `reservations` owner: wymagane jednocześnie `auth.uid() = user_id` i aktywny membership w tenancie rekordu. Własny rekord innego/dormant tenanta nie jest ujawniany, a cudzy rekord pozostaje DENY.
- `reservations` staff: wyłącznie `admin`/`employee` w tenancie rekordu. Instructor nie otrzymuje nowego dostępu.
- `lane_blocks`: aktywny member widzi aktywny blok własnego tenanta; `admin`/`employee`/`instructor` zachowują staff read tylko we własnym tenancie. Nie dodano anon/user write ani żadnej mutation policy.
- Żaden nowy predykat nie wywołuje `profiles.role`, `is_admin()`, `is_admin_or_employee()` ani `is_admin_or_staff()`.
- ACL tabel pozostaje niezmieniony; migracja wymienia wyłącznie sześć polityk SELECT i dodaje jeden boolean helper dla publicznego katalogu osi.

### 27.5 Public-read baseline

| Surface | Result |
|---|---|
| `/booking` | HTTP 200, aktywne rodziny osi widoczne |
| `/events` | HTTP 200 |
| `/login` | HTTP 200 |
| `get_public_booking_configuration_v1()` as anon | HTTP 200; zatwierdzony PII-free lane/config contract |
| `get_public_event_list_v2(...)` as anon | HTTP 200; contract v2 response |

Public Booking nie odczytuje bezpośrednio prywatnych reservations. Nowa publiczna policy osi używa `is_active_public_tenant_v1(tenant_id)`, który zwraca wyłącznie boolean, wymaga dokładnie jednego active tenanta i nie ujawnia membershipów.

### 27.6 Owner and staff access contracts

Owner access nie wynika z samego membershipu: potrzebna jest zgodność `auth.uid()` z `reservations.user_id` oraz active membership tenanta rekordu. Staff access wymaga active membership i jawnej roli. Admin/employee Tenant A nie widzą Tenant B. Instructor zachowuje lane/lane-block read, ale nadal nie ma globalnego reservation read. Globalny legacy `profiles.role` nie autoryzuje nowych policies.

### 27.7 Membership-status semantics

`is_tenant_member_v1()` i `has_tenant_role_v1()` autoryzują wyłącznie, gdy tenant ma `status='active'` i membership ma `status='active'`. `pending`, `suspended`, brak membershipu, NULL tenant, nieznana rola i niezatwierdzony role-array kończą się fail-closed. Samo istnienie wiersza membership nie wystarcza.

### 27.8 Cross-tenant and recursion proof

Po wykryciu pięciu pozostawionych lokalnych fixture Playwright wykonano czysty **lokalny** `supabase db reset` na `127.0.0.1:54322` (bez `--linked`). Pierwsza próba liczyła te obce fixture w CSK i dlatego nie była miarodajna; nie wykryła defektu migracji. Po resecie:

- foundation verification: **25/25 PASS**;
- tenant-aware booking RLS: **60/60 PASS**;
- Admin A: Tenant A ALLOW, Tenant B DENY;
- Employee A: Tenant A ALLOW, Tenant B DENY;
- User A: own active Tenant A ALLOW; own Tenant B ALLOW dopiero po kontrolowanym lokalnym przełączeniu Tenant B do active; User B data DENY;
- no membership / pending / suspended: private or privileged access DENY;
- IDOR przez Tenant B IDs: direct INSERT/UPDATE/DELETE DENY;
- repeated helper evaluation: PASS, bez policy recursion/stack error;
- transakcje zakończone ROLLBACK; `remaining_fixture=0`.

### 27.9 Performance

Lokalne `EXPLAIN (COSTS OFF)` potwierdziło tenant-prefixed access paths: `reservations_tenant_schedule_idx`, `lane_blocks_tenant_schedule_idx`, `tenant_memberships_user_status_tenant_idx`; lane lookup użył istniejącego tenant/id unique index. Wszystkie pięć wymaganych indeksów (w tym hierarchy i role/status membership) istnieje także w produkcyjnym katalogu. Nie ma uzasadnienia dla nowego indeksu w 9C-2.

### 27.10 SECURITY DEFINER bypass inventory

Znany bypass pozostaje oczekiwany i należy do SAAS-9D. Lokalny test dowodzi go konkretnie przez `admin_set_lane_block_active`: globalny Admin A może wskazać ID bloku Tenant B, ponieważ definer omija RLS i nie wykonuje membership tenant check. Transakcja testowa została wycofana.

Aktualny callable inventory funkcji `SECURITY DEFINER`, które czytają/mutują booking tables i nie konsumują jeszcze helperów tenant-membership, obejmuje:

- booking/reservations: `create_reservation_v2`, `cancel_reservation`, `get_my_reservations_v2`, `get_lane_booking_busy_ranges`, `get_lane_booking_busy_ranges_v2`, `get_lane_booking_busy_ranges_v3`, `update_reservation_admin_note`, `update_reservation_attendance`, `update_reservation_payment`, `get_reservation_customer_profiles_v1`;
- lane configuration/blocks: `admin_create_lane_block`, `admin_update_lane_block`, `admin_set_lane_block_active`, `admin_create_lane_booking_family_v1`, `admin_get_lane_booking_configuration_v1`, `admin_get_lane_booking_configuration_v2`, `admin_set_lane_booking_family_configuration_v2`;
- reports/events touching booking resources: `admin_get_reservation_report_v1`, `admin_get_reservation_report_v2`, `admin_get_reservation_report_export_v1`, `admin_create_event_v2`, `admin_update_event_v2`, `admin_set_event_active_v2`, `admin_list_events_v1`;
- account/check-in/delivery/public read paths requiring 9D tenant review: `anonymize_my_account_v1`, `export_my_data_v1`, `get_check_in_reservation_v1`, `get_public_check_in_status_v1`, `prepare_confirmation_email`, `get_public_booking_configuration_v1`.

Nie każda z tych funkcji jest eksploatowalna w current single-tenant: zachowują obecne ownership/token/global-role checks i część jest celowo publicznym PII-free readem. Wspólny brak to brak pełnego, jawnego tenant binding wymaganego przed drugim tenantem. Dlatego bypass jest **KNOWN**, nie nieoczekiwanym blockerem 9C-2, ale pozostaje blockerem SAAS-9D/second tenant.

### 27.11 Security fingerprint

Fresh production catalog potwierdził:

- 72 funkcje `SECURITY DEFINER` — oczekiwany post-9C-1 baseline;
- 4 membership helpery;
- 2 triggery sync bridge;
- 7 validated composite tenant relationship FK oraz validated membership→tenant FK;
- partial unique guard `tenants_single_active_runtime_guard`;
- 7 temporary CSK defaults;
- `profiles.role` nadal `text` bez schema CHECK i pozostaje legacy runtime source.

Porównywalne produkcja↔czysty local fingerprinty są identyczne: non-target policies `d68e1129e7e53e5c36ffe16053f16acf`, booking-table ACL `e1b387cc6dffcdd11beda90478c3381f`, `get_my_role()` `dc8858eed7d2fd2d1ab47d22b0000b06`, `is_admin()` `89a221fa092af2a457db05a64b7e8d18`. Dokładny legacy target-policy baseline jest zapisany w 27.3. Migracja dodatkowo wykonuje w jednej transakcji before/after fingerprint wszystkich unrelated policies, istniejących definers oraz booking ACL; każdy nieplanowany drift przerywa wdrożenie.

### 27.12 Migration history and SHA gate

`supabase migration list --linked` zakończył się kodem 0. LOCAL=REMOTE przez `20260910110000`; brak remote-only migration i divergence. Jedyna local pending migration to `20260910120000_add_tenant_aware_booking_rls.sql`.

Ponownie wyliczony SHA-256:

```text
A5A16933CE5DECDA0B0AB41CD5CDBE693E83B109AAD5F54A11B4780B5EFC2CF1
```

Jest identyczny z zatwierdzonym SHA gate.

### 27.13 Dry-run

`npx.cmd supabase db push --linked --dry-run` zakończył się kodem 0 i jawnie potwierdził, że migracje nie zostaną wdrożone. Plan zawiera dokładnie jeden plik:

```text
20260910120000_add_tenant_aware_booking_rls.sql
```

Nie wykonano właściwego `db push`.

### 27.14 Runtime smoke

Zalogowana produkcyjna sesja administratora otworzyła bez redirectu i bez runtime 5xx: `/admin`, `/admin/reservations`, `/admin/calendar`, `/admin/reports`, `/admin/events` i `/admin/check-in`. Publiczne `/booking`, `/events` i `/login` zwróciły 200. Ekrany załadowały właściwe dane/empty states; nie wykonano żadnej akcji mutującej.

### 27.15 Deployment risk

Migracja nie przepisuje danych i nie zmienia ACL tabel ani istniejących RPC. Ryzyko dotyczy krótkiego locka przy drop/create policy na trzech tabelach oraz natychmiastowej zmiany widoczności SELECT. `lock_timeout=5s`, `statement_timeout=120s`, fail-closed baseline i transakcyjny postflight ograniczają ryzyko. Oczekiwany czas to sekundy; krótkie okno niskiego ruchu wystarcza. Pełny maintenance window nie jest wymagany przy obecnym wolumenie, ale deployment należy zatrzymać przy lock timeoutie lub dowolnym pre/postflight exception.

### 27.16 Remaining blockers and final verdicts

Po wdrożeniu obowiązkowy jest ponowny public Booking + authenticated owner/staff RLS smoke oraz runtime smoke. Następnie potrzebny jest checkpoint/review przed 9C-2C. Legacy definers nadal uniemożliwiają SAAS-9D i drugi tenant. SEC-004 nie jest zamknięty.

SAAS-9C-2A/2B PRODUCTION PREFLIGHT: **PASS**

PUBLIC BOOKING PRE-DEPLOY BASELINE: **PASS**

CROSS-TENANT RLS: **PASS**

SECURITY DEFINER BYPASS: **KNOWN**

READY FOR PRODUCTION PUSH: **YES**

READY FOR 9C-2C: **NO-GO until production PASS and checkpoint/review**

READY FOR SAAS-9D: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**
