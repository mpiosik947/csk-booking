# SAAS-9C-2D — Remaining Tenant-Aware RLS & Profile Privacy Hardening

## 1. Executive summary

SAAS-9C-2D został zaimplementowany i zweryfikowany wyłącznie lokalnie. Jedna atomowa migracja zastępuje ostatnie zatwierdzone polityki oparte na globalnych rolach politykami wymagającymi aktywnego członkostwa oraz relacji do tenant-owned rekordu. Nie zmieniono aplikacji, RPC, funkcji `SECURITY DEFINER`, tymczasowych defaultów CSK, sync bridge ani mechanizmu blokady drugiego aktywnego tenanta.

Zakres obejmuje `audit_logs`, `profiles`, `lane_booking_rules`, `lane_booking_durations` i `lane_pricing_rules`. `tenants`, `tenant_memberships` i `email_deliveries` zostały zweryfikowane jako nadal fail-closed.

## 2. Existing policies

Stan wejściowy potwierdzony przed migracją:

- `audit_logs`: globalny SELECT dla `is_admin()`;
- `profiles`: owner SELECT, globalny admin SELECT oraz admin INSERT;
- `lane_booking_rules`: publiczny reader oraz globalny staff SELECT;
- `lane_booking_durations`: publiczny reader oraz globalny admin/employee SELECT;
- `lane_pricing_rules`: publiczny reader oraz globalny admin/employee SELECT;
- `tenants`: zero policies;
- `tenant_memberships`: jeden owner-scoped SELECT;
- `email_deliveries`: zero policies.

Migracja posiada dokładny preflight tych założeń i przerywa się przy driftcie. Zmiana polityk jest wykonywana w ramach jednej transakcji migracyjnej.

## 3. audit_logs RLS

Nowy SELECT wymaga jednocześnie:

- `audit_logs.tenant_id IS NOT NULL`;
- aktywnego membershipu do `audit_logs.tenant_id`;
- tenantowej roli `admin` albo `employee`.

Wynik testów:

- ADMIN_A: audit A ALLOW, audit B DENY, global audit DENY;
- EMPLOYEE_A: audit A ALLOW, audit B DENY;
- USER_A, anon i role bez aktywnego membershipu: DENY;
- INSERT/UPDATE/DELETE/TRUNCATE: nadal niedostępne rolom aplikacyjnym.

Triggery integralności audytu z SAAS-9B-3 nie zostały zmienione.

## 4. profiles privacy

Zachowano owner SELECT przez `auth.uid() = profiles.user_id`. Usunięto globalny admin SELECT oraz bezpośredni admin INSERT.

Minimalna zatwierdzona relacja dla staff została ograniczona do tenant admina i profilu użytkownika, który posiada w tym samym tenancie:

- `reservation`, albo
- `event_registration`.

Aktywny tenant membership z rolą `admin` jest wymagany dla caller tenant. Nie dodano globalnego przeglądania profili, membership-only dostępu ani tenantowego modelu verification. EMPLOYEE_A i INSTRUCTOR_A nie otrzymują nowego bezpośredniego profile SELECT.

Polityka zawęża istniejący dostęp wierszowy i nie dodaje nowych kolumn/DTO. Znane globalne odczyty przez legacy `SECURITY DEFINER` RPC pozostają jawnie odłożone do SAAS-9D.

## 5. Profile registration compatibility

Odebrano `authenticated` bezpośredni INSERT do `profiles`. Kontrolowana ścieżka pozostaje:

`auth.users` → `handle_new_user()` → `profiles` + aktywny membership CSK.

Lokalny reset nie instaluje triggera `auth.users`, mimo że funkcja `handle_new_user()` istnieje. Focused test tworzy produkcyjnie równoważny trigger wyłącznie wewnątrz testowej transakcji, potwierdza dokładnie jeden profil, dokładnie jeden aktywny membership, mapowanie roli `user` i owner read, a następnie wykonuje ROLLBACK. Produkcyjny preflight musi potwierdzić istniejący trigger przed deploymentem.

## 6. lane_booking_rules RLS

Tenant jest wyprowadzany przez `lane_id → shooting_lanes.tenant_id`.

- public: zachowana dotychczasowa semantyka online/hierarchy oraz dodany wymóg aktywnego publicznego tenanta;
- staff: active membership i tenantowa rola `admin`, `employee` albo `instructor`;
- tenant B: DENY dla staff tenant A;
- direct mutation: bez zmian i bez rozszerzenia.

## 7. lane_booking_durations RLS

Tenant jest wyprowadzany przez `lane_id`. Publiczny odczyt zachowuje booking contract tylko dla aktywnego zasobu w aktywnym tenancie. Staff access wymaga aktywnego membershipu oraz roli `admin` lub `employee`. Tenant B, pending, suspended i brak membershipu są deny.

## 8. lane_pricing_rules RLS

Tenant jest wyprowadzany przez `lane_id`. Publiczny pricing dla Booking pozostaje dostępny tylko dla aktywnego zasobu w aktywnym tenancie. Staff access wymaga aktywnego membershipu oraz roli `admin` lub `employee`. Nie otwarto direct mutation.

## 9. tenants verification

- RLS: enabled;
- policies: 0;
- client SELECT/DML: brak;
- `tenants_single_active_runtime_guard`: obecny i niezmieniony;
- drugi tenant: nadal NO-GO.

## 10. tenant_memberships verification

- RLS: enabled;
- jedyna polityka: authenticated SELECT własnych membershipów;
- foreign membership: niewidoczny;
- INSERT/UPDATE/DELETE/TRUNCATE dla klienta: brak;
- brak staff membership administration.

## 11. email_deliveries exposure

Tabela pozostaje server-only:

- zero policies;
- brak SELECT dla PUBLIC, anon i authenticated;
- brak zmian istniejącego uprzywilejowanego kontraktu serwerowego.

## 12. Global-role isolation

Zmodyfikowane polityki nie używają `profiles.role`, `is_admin()`, `is_employee()`, `is_admin_or_employee()`, `is_admin_or_staff()` ani `get_my_role()` do tenant authorization. Końcowy katalog lokalny wykazał `0` odwołań do globalnych helperów w politykach `public`.

`profiles.role` pozostaje legacy runtime bridge, ale sam string roli nie otwiera żadnej polityki zmienionej przez 9C-2D.

## 13. Cross-tenant tests

Focused SQL test zawiera 64 kontrole w jednej transakcji zakończonej ROLLBACK. Pokrywa ADMIN_A, EMPLOYEE_A, INSTRUCTOR_A, USER_A, USER_B, NO_MEMBERSHIP, PENDING, SUSPENDED i Tenant B.

Wynik: **64/64 PASS**.

Testy obejmują audit A/B/global, profile own/related/unrelated/B, public/private lane configuration, role matrices, inactive membership, control-plane fail-closed, register flow, wcześniejsze polityki 9C oraz niezmienione compatibility defaults.

## 14. RLS recursion

Powtarzane odczyty profili i konfiguracji osi zakończyły się bez recursion, stack overflow i policy recursion. Tenant membership helpers są `SECURITY DEFINER` i nie powodują cyklu przez policies.

Wynik: **PASS**.

## 15. Performance

Read-only `EXPLAIN` potwierdził wykorzystanie istniejących indeksów:

- profiles/relations: `profiles_user_id_idx`, `reservations_user_creation_request_key`, `event_registrations_tenant_user_created_idx`;
- rules/lane relation: `lane_booking_rules_pkey` oraz tenant/hierarchy index `shooting_lanes`;
- durations: `lane_booking_durations_lane_duration_key`;
- pricing: `lane_pricing_rules_lane_id_id_key` / istniejący lane index.

Nie zidentyfikowano potrzeby dodania indeksu; scope nie został rozszerzony.

## 16. SECURITY DEFINER boundary

Lokalny katalog zawiera 73 funkcje `SECURITY DEFINER`; 0 z nich odwołuje się bezpośrednio w body do nowych tenant membership helperów. Migracja utrwala fingerprint całego istniejącego zbioru i przerywa się, jeśli dowolna funkcja zostanie zmieniona.

| Path | RLS tenant-aware | SECURITY DEFINER | RLS bypass | Tenant check | SAAS-9D blocker |
|---|---:|---:|---:|---:|---:|
| Direct tables objęte 9C-2D | Tak | Nie | Nie | Tak | Nie |
| `admin_list_users_v1` | N/D | Tak | Tak | Nie | Tak |
| `get_reservation_customer_profiles_v1` | N/D | Tak | Tak | Nie | Tak |
| `update_my_profile_v1` | N/D | Tak | Tak | owner-scoped legacy | Tak, do review/cutover |
| Lane configuration readers/writers | N/D | Tak | Tak | legacy/global | Tak |
| Reservation, calendar, reports, check-in RPC | N/D | Tak | Tak | legacy/global | Tak |
| Event management/read/write RPC | N/D | Tak | Tak | legacy/global | Tak |

Żadnego legacy RPC nie zmieniono w 9C-2D.

## 17. Regression

- local DB reset: PASS;
- focused SAAS-9C-2D SQL: 64/64 PASS;
- full Supabase DB suite: 26 files, 752/752 PASS;
- Node: 734/734 PASS;
- TypeScript `tsc --noEmit`: PASS;
- production build: PASS (Next.js 16.3.4, 37 static pages);
- `git diff --check`: PASS;
- fixture post-check po końcowym local reset: auth users 0, profiles 0, lanes 0, reservations 0, events 0, registrations 0.

Focused Playwright wykonał poprawnie 8/8 responsive Events scenariuszy oraz — w pierwszym czystym przebiegu — wszystkie 5 lane-family scenariuszy. Runner nie zakończył procesu w hooku cleanup. Powtórzenie bez resetu znalazło podwójny lane fixture po pierwszym przebiegu. To ograniczenie harnessu, nie błąd polityk: końcowy dozwolony local DB reset usunął pozostałość, a niezależny post-check zwrócił zero. Przed przyszłym wielokrotnym uruchamianiem należy poprawić cleanup samego testu lane-family, poza zakresem 9C-2D.

Znane ostrzeżenia bez regresji: `middleware` → `proxy` w Next.js oraz `MODULE_TYPELESS_PACKAGE_JSON` w części testów Node.

## 18. Remaining 9C-2E work

Po 9C-2D katalog polityk `public` ma zero odwołań do legacy global-role helperów. 9C-2E pozostaje etapem przeglądowym/gate, nie został zaimplementowany. Wymaga:

- pełnego finalnego RLS isolation audit i fingerprintu wszystkich policies/ACL;
- potwierdzenia braku niejawnych cross-tenant paths przez views i non-definer functions;
- formalnego wykazu 73 ścieżek `SECURITY DEFINER` przekazywanych do SAAS-9D;
- ponownego cross-tenant matrix po finalnym katalogu RLS;
- potwierdzenia, że temporary CSK defaults i single-active guard pozostają aktywne.

## 19. Production deployment plan

Nie wykonano produkcyjnych operacji. Zalecany następny krok to osobny read-only production preflight:

1. potwierdzić HEAD, remote migration history i SHA-256 migracji/testu;
2. potwierdzić dokładny policy/ACL/SECURITY DEFINER baseline oraz produkcyjny `auth.users → handle_new_user` trigger;
3. wykonać `supabase db push --dry-run` i wymagać, aby pending była wyłącznie migracja 9C-2D;
4. oszacować lock risk na rzeczywistych rozmiarach tabel;
5. zatrzymać się przed write i uzyskać osobną zgodę;
6. po ewentualnym deploymencie wykonać cross-tenant read-only/rollback-only smoke i single-tenant runtime smoke.

Rollback migracji wymagałby przywrócenia dawnych globalnych polityk, co obniża bezpieczeństwo. Preferowany fallback po nieudanym postflight to zatrzymanie rollout i diagnoza, nie automatyczne otwieranie legacy dostępu.

## 20. Git status

Nie wykonano `git add`, commit ani push. Zmiany 9C-2D:

- `supabase/migrations/20260911120000_add_remaining_tenant_aware_rls.sql`;
- `supabase/tests/20260911120000_remaining_tenant_aware_rls_test.sql`;
- aktualizacje pięciu historycznych testów oczekiwanego końcowego schematu (bez zmian historycznych migracji);
- niniejszy raport.

Istniejąca przed 9C-2D modyfikacja `SAAS_9C_TENANT_AWARE_RLS_MEMBERSHIP_AUTHORIZATION_PLAN.md` pozostaje niestage'owana i nie została pomieszana z implementacją.

## 21. Final verdict

```text
SAAS-9C-2D LOCAL:
PASS

AUDIT ISOLATION:
PASS

PROFILE PRIVACY:
PASS

REGISTER FLOW:
PASS

LANE RULES / DURATIONS / PRICING RLS:
PASS

GLOBAL ROLE TENANT ACCESS:
PASS

RLS RECURSION:
PASS

LEGACY SINGLE-TENANT RUNTIME:
PASS

READY FOR 9C-2D PRODUCTION PREFLIGHT:
GO

READY FOR 9C-2E:
NO-GO until review

READY FOR SAAS-9D:
NO-GO

SECOND TENANT:
NO-GO

SEC-004:
OPEN
```

# PRODUCTION DEPLOYMENT & POST-DEPLOY VERIFICATION

Verification date: 2026-09-11 (Europe/Warsaw).

## 1. Exact deployment

Finalny pre-push gate ponownie potwierdził project ref `yuyxfodozzpzrdzkmolu`, zgodność LOCAL=REMOTE do `20260911100000`, brak remote-only divergence oraz dokładnie jedną migrację pending. SHA-256 wdrażanego pliku był identyczny z zatwierdzonym:

```text
BBD2A90604F9BCC91DF93863D5C0BE627AA8F1E0F3C9FF7E485ABFD67E7AE38E
```

`supabase db push --linked` zakończył się kodem 0 i zastosował wyłącznie:

```text
20260911120000_add_remaining_tenant_aware_rls.sql
```

Nie wykonano `migration repair`, manualnego SQL zastępującego migrację ani żadnej innej migracji.

## 2. Migration history i finalny dry-run

Po wdrożeniu `supabase migration list --linked` pokazuje `20260911120000` po obu stronach. Wszystkie pozycje local/remote są zgodne, bez divergence. Następny `supabase db push --linked --dry-run` zakończył się kodem 0 i zwrócił:

```text
Remote database is up to date.
```

Jedyny komunikat dodatkowy dotyczył dostępności nowszej wersji CLI; CLI nie zostało zmienione.

## 3. Membership/profile state i brak data rewrite

Finalny odczyt bezpośrednio przed push oraz postflight potwierdziły niezmieniony stan:

| Invariant | Wynik |
|---|---:|
| active tenants | 1 |
| `auth.users` | 9 |
| `profiles` | 9 |
| memberships | 9 |
| active memberships | 9 |
| role distribution | admin 1, user 8 |
| unknown roles/statuses | 0 |
| duplicate memberships | 0 |
| orphan user/tenant memberships | 0 |
| profile/auth orphans | 0 |

Target row counts również pozostały bez zmian: audit 112, rules 11, durations 40, pricing 64. Migracja nie zawierała DML/backfillu.

## 4. RLS, ACL i profiles privacy

Produkcyjny katalog po migracji potwierdza:

- RLS enabled i owner `postgres` dla wszystkich ośmiu kontrolowanych tabel;
- dokładnie 9 docelowych policies, wszystkie wyłącznie `SELECT`;
- zero global-role helper refs w docelowych policies oraz zero takich refs we wszystkich `public` policies;
- `authenticated` ma na `profiles` wyłącznie `SELECT`; INSERT/UPDATE/DELETE/TRUNCATE są `false`, anon SELECT jest `false`;
- usunięto globalne `Admins can view all profiles` i `Admins can insert profiles`;
- nowy staff read wymaga active tenant admin membership oraz relacji przez reservation/event registration.

Efektywny read-only test z `SET LOCAL ROLE authenticated` na istniejących tożsamościach, bez tworzenia fixture i bez DML, dał:

- ordinary user: własny profil 1, wszystkie widoczne profile 1, audit 0, memberships 1;
- tenant admin: własny profil 1, profile widoczne zgodnie z rzeczywistymi relacjami 4, tenant audit 42, global audit (`tenant_id IS NULL`) 0;
- public subset lane config pozostał dostępny (rules 10/11, durations 40/40, pricing 44/64 zgodnie z aktywnymi public predicates);
- tenant admin widzi pełny własny-tenant rules/durations/pricing: 11/40/64.

Produkcja nadal nie ma employee/instructor membershipu ani Tenant B, więc tych wariantów nie tworzono sztucznie. Ich cross-role/cross-tenant zachowanie jest potwierdzone przez dokładne produkcyjne definicje policies i lokalną transakcyjną macierz 64/64. Drugi aktywny tenant pozostaje zablokowany.

## 5. Audit isolation i direct DML

Policy `Tenant admin and employee can view audit logs` wymaga `tenant_id IS NOT NULL` oraz `has_tenant_role_v1(..., ['admin','employee'])`. Produkcyjny test efektywny potwierdził tenant audit ALLOW dla admina, global audit DENY i zwykły user DENY. Tenant B deny wynika z row tenant predicate i został sprawdzony w lokalnej macierzy.

Nie dodano policy INSERT/UPDATE/DELETE. ACL i trigger integralności z 9B-3 pozostały objęte atomowym before/after fingerprint gate migracji.

## 6. Register flow

Formularz `/register` renderuje się poprawnie. Produkcyjny trigger `on_auth_user_created` pozostaje enabled (`O`) i nadal wywołuje `handle_new_user()` dokładnie raz. Funkcja pozostaje `SECURITY DEFINER`, owner `postgres`; surowy source fingerprint nadal wynosi `c17b56dcb6f15f588d5aa8781b5d42ae`. Direct authenticated INSERT do `profiles` jest zamknięty.

Nie utworzono dodatkowego konta produkcyjnego w postflight. Pełny `auth.users -> profile -> active CSK membership -> role=user` został już potwierdzony lokalnym testem transakcyjnym, a produkcyjne liczniki 9/9/9 bez orphanów potwierdzają spójność istniejącego flow.

## 7. Admin Users / Check-in i runtime

Read-only smoke istniejącej sesji administratora zakończył się powodzeniem dla:

- Booking;
- login/register;
- Account;
- Admin dashboard;
- Admin Users;
- Reservations;
- Calendar;
- Reports;
- Events;
- My Events;
- Admin Events;
- Check-in;
- lane configuration.

Admin Users oraz Check-in zakończyły ładowanie bez `permission denied`, raw DB error ani 5xx. Public Booking wyrenderował pięć osi i pełny formularz; jego publiczne rules/durations/pricing oraz availability nie wymagają membershipu.

Pierwsze równoległe otwarcie `/admin/events` zostało przekierowane do logowania, podczas gdy Account i pozostałe admin pages miały aktywną sesję. Natychmiastowe ponowienie załadowało Admin Events poprawnie. Nie odtworzono trwałej regresji RLS ani runtime; obserwacja pozostaje jawnie zapisana jako pojedynczy transient auth redirect.

## 8. Tenants, memberships i email exposure

- `tenants`: RLS enabled, zero policies, brak authenticated direct ACL, active guard istnieje;
- `tenant_memberships`: dokładnie jedna self-read policy; authenticated SELECT=true, INSERT/UPDATE/DELETE=false;
- `email_deliveries`: RLS enabled, zero policies, anon/authenticated SELECT i DML=false;
- brak self role/status escalation i brak client direct DML.

## 9. Security fingerprint i SAAS-9D boundary

Po wdrożeniu inventory nadal zawiera dokładnie 73 funkcje `SECURITY DEFINER`. Kanoniczny fingerprint (owner, nazwa, identity arguments, config i definicja, z normalizacją LF) pozostaje:

```text
0dd807bea5ca20cfbaae9434b53d97a4
```

Migracja wykonała ponadto atomowy before/after fingerprint wszystkich definers, unrelated policies, niezmienianych ACL i auth triggera; każdy drift przerwałby transakcję. `profiles.role` nadal jest `text NOT NULL DEFAULT 'user'`, temporary CSK defaults nadal jest dokładnie 7, active-tenant guard istnieje, a sync bridge/tenant integrity nie zostały zmienione.

Aktualna bypass matrix pozostaje zgodna z sekcją 12: bezpośredni RLS objęty 9C-2D jest tenant-aware, natomiast legacy business RPC `SECURITY DEFINER` nadal omijają table RLS i wymagają target-derived tenant checks w SAAS-9D. Nie zamyka to SEC-004 i nie pozwala uruchomić drugiego tenanta.

## 10. Remaining risks

- Legacy business RPC `SECURITY DEFINER` nadal stanowią jawny blocker SAAS-9D/SEC-004.
- Produkcja ma wyłącznie jeden aktywny tenant; pełna Tenant A/Tenant B macierz pozostaje dowodem lokalnym do czasu kontrolowanego etapu cross-tenant.
- Pojedynczy transient redirect Admin Events nie odtworzył się przy ponowieniu; należy obserwować istniejący auth refresh/runtime, ale nie stanowi dowodu regresji 9C-2D.
- Drugi tenant pozostaje technicznie i operacyjnie NO-GO.

## Production deployment final verdict

```text
SAAS-9C-2D PRODUCTION DEPLOY:
PASS

SAAS-9C-2D POST-DEPLOY:
PASS

AUDIT ISOLATION:
PASS

PROFILE PRIVACY:
PASS

REGISTER FLOW:
PASS

ADMIN USERS / CHECK-IN:
PASS

PUBLIC BOOKING:
PASS

ZERO GLOBAL ROLE POLICY REFS:
PASS

READY FOR GIT CHECKPOINT:
YES

READY FOR SAAS-9C-2E PLANNING:
GO

READY FOR SAAS-9D:
NO-GO

SECOND TENANT:
NO-GO

SEC-004:
OPEN
```

# PRODUCTION PREFLIGHT & DEPLOYMENT READINESS

## 1. Fresh production state

Preflight wykonano 11 września 2026 r. wyłącznie przez read-only zapytania w produkcyjnym Supabase SQL Editor oraz niemutujące polecenia Supabase CLI.

| Kontrola | Wynik |
|---|---:|
| tenants | 1 |
| active tenants | 1 |
| tenant_memberships | 9 |
| membership roles | `admin=1`, `user=8` |
| membership statuses | `active=9` |
| duplicate memberships | 0 |
| orphan membership user_id | 0 |
| orphan membership tenant_id | 0 |
| profiles | 9 |
| auth.users | 9 |
| profiles bez auth.users | 0 |
| auth.users bez profile | 0 |
| unknown membership role | 0 |
| unknown membership status | 0 |

Nie znaleziono unexplained orphan, nieznanej roli, nieprawidłowego statusu ani drugiego aktywnego tenanta.

## 2. Current RLS baseline

Wszystkie osiem kontrolowanych tabel ma RLS enabled, owner `postgres` i `FORCE RLS=false`. Produkcyjny baseline przed 9C-2D zawiera dokładnie 11 polityk:

| Table | Policy | Command | Roles | USING | WITH CHECK |
|---|---|---|---|---|---|
| audit_logs | Admins can view audit logs | SELECT | authenticated | `is_admin()` | — |
| profiles | Users can view own profile | SELECT | authenticated | `user_id = auth.uid()` | — |
| profiles | Admins can view all profiles | SELECT | authenticated | `is_admin()` | — |
| profiles | Admins can insert profiles | INSERT | authenticated | — | `is_admin()` |
| lane_booking_rules | Public can view online lane booking rules | SELECT | anon, authenticated | online resource + active lane + hierarchy/booking-mode predicate | — |
| lane_booking_rules | Staff can view all lane booking rules | SELECT | authenticated | `is_admin_or_staff()` | — |
| lane_booking_durations | Active lane durations are readable | SELECT | anon, authenticated | active duration + active lane | — |
| lane_booking_durations | Admins and employees can view all lane durations | SELECT | authenticated | `is_admin_or_employee()` | — |
| lane_pricing_rules | Active lane pricing rules are readable | SELECT | anon, authenticated | active pricing + active lane | — |
| lane_pricing_rules | Admins and employees can view all lane pricing rules | SELECT | authenticated | `is_admin_or_employee()` | — |
| tenant_memberships | Users can view own tenant memberships | SELECT | authenticated | `user_id = auth.uid()` | — |

`tenants` i `email_deliveries` mają zero policies. Baseline odpowiada dokładnie fail-closed preflightowi migracji. Żadna historyczna migracja nie ma tracked diff; jedyną nową migracją implementacyjną jest 9C-2D. Pięć zmienionych historycznych plików w `supabase/tests` aktualizuje wyłącznie oczekiwania końcowego zatwierdzonego kontraktu.

## 3. Target audit_logs RLS

Migracja zastępuje globalne `is_admin()` polityką wymagającą:

- `audit_logs.tenant_id IS NOT NULL`;
- aktywnego membershipu w tenant rekordu;
- tenantowej roli `admin` albo `employee`.

Global/account audit z `tenant_id IS NULL` jest niewidoczny dla tenant staff. User, anon i PUBLIC nie otrzymują SELECT. Żadne client INSERT/UPDATE/DELETE/TRUNCATE nie zostaje otwarte.

Trigger `set_audit_log_tenant_id` nadal wskazuje na `set_audit_log_tenant_id()` i jest enabled. Migracja nie modyfikuje triggera ani funkcji integralności SAAS-9B-3.

## 4. Target profiles privacy

Owner read `profiles.user_id = auth.uid()` pozostaje bez zmian. Usuwane są:

- `Admins can view all profiles`;
- `Admins can insert profiles`;
- authenticated table INSERT privilege.

Nowy staff SELECT wymaga aktywnego tenant membership z rolą `admin` oraz rzeczywistej relacji target user przez `reservations.user_id` albo `event_registrations.user_id` w tym samym tenant. Samo `profiles.role='admin'` nie autoryzuje odczytu. Tenant B-only oraz unrelated profile pozostają niewidoczne.

Nie dodano tenant-specific verification ani nowych pól. Legacy `SECURITY DEFINER` RPC nadal mogą omijać table RLS i są jawnie odłożone do SAAS-9D.

## 5. Employee/instructor profile-access verification

Docelowa bezpośrednia polityka profili nie daje employee ani instructor dostępu do cudzych profili. Obie role zachowują jedynie owner read swojego własnego profilu.

To nie odcina obecnego Check-in:

- operator ładuje `role, full_name, email` własnego profilu, więc owner policy wystarcza;
- dane klientów dla rezerwacji są ładowane przez istniejący `get_reservation_customer_profiles_v1(reservation_ids)`;
- Admin Users korzysta z `admin_list_users_v1`, a nie direct table SELECT;
- testy źródłowe jawnie pilnują braku fallbacku Admin Users i Check-in do broad direct profile read.

Produkcja nie posiada obecnie membershipu employee ani instructor, więc realny production login tych ról nie był możliwy bez tworzenia fixture. Kompatybilność jest potwierdzona przez aktualny call path, lokalną role matrix i działający admin runtime. Nie wykryto wymogu broad employee/instructor profile SELECT.

## 6. Register-flow compatibility

Produkcja ma dokładnie jeden enabled trigger `on_auth_user_created` na `auth.users`, wywołujący `handle_new_user()`.

`handle_new_user()`:

- owner: `postgres`;
- `SECURITY DEFINER=true`;
- search path: `public, pg_temp`;
- EXECUTE ACL: wyłącznie `postgres`;
- current source fingerprint: `c17b56dcb6f15f588d5aa8781b5d42ae` dla pełnej definicji.

Trigger wykonuje kontrolowaną ścieżkę niezależną od authenticated direct INSERT policy. Stan produkcyjny `auth.users=profiles=memberships=9`, bez orphanów, potwierdza spójność bieżącego flow. Lokalny transakcyjny test potwierdził `auth row → profile → active CSK membership → role=user` i ROLLBACK.

## 7. Admin Users/check-in baseline

Read-only production browser smoke na istniejącej sesji administratora:

- `/account`: własny profil i formularz konta załadowane;
- `/admin/users`: 9 kont, lista i filtry załadowane przez server-side RPC;
- `/admin/check-in`: lista operacyjna i filtry załadowane, pusty stan kontrolowany;
- `/admin/reservations`: 11 rezerwacji, filtry i lista załadowane;
- `/admin`: dashboard operacyjny i action queues załadowane.

Nie wystąpił redirect auth, 5xx ani raw DB/Supabase error. Smoke był read-only; nie użyto żadnej mutującej akcji.

## 8. Rules/durations/pricing contract

Docelowe policies wyprowadzają tenant przez `lane_id → shooting_lanes.tenant_id`.

- public access zachowuje dotychczasowy predicate aktywności/online/hierarchy i dodatkowo wymaga aktywnego publicznego tenanta;
- admin i employee wymagają active membership w tenant osi;
- instructor zachowuje wyłącznie dotychczasowy rules scope, bez dostępu do pricing/durations poza publicznym kontraktem;
- no membership, pending i suspended nie otrzymują privileged access;
- direct mutation ACL/policies pozostają nieotwarte.

Produkcyjne rozmiary są małe: 11 rules, 40 durations i 64 pricing rows.

## 9. Public Booking baseline

Produkcja `/booking` załadowała bez logowania pełną listę pięciu publicznych osi z aktywnym formularzem wyboru. Public config, hierarchy, durations/pricing dependency i availability path nie wymagają membershipu.

Migracja zachowuje role `anon, authenticated` dla publicznych SELECT policies i nie zmienia `get_public_booking_configuration_v1()`. Target predicates zostały wcześniej potwierdzone przez lokalne testy public contract. Nie wykryto blokady publicznego Booking.

## 10. tenants/memberships/email exposure

### tenants

- RLS enabled;
- zero policies;
- brak client ACL;
- partial unique index `tenants_single_active_runtime_guard` istnieje i pozostaje niezmieniony;
- drugi active tenant nadal technicznie blokowany.

### tenant_memberships

- RLS enabled;
- authenticated ma wyłącznie SELECT;
- jedyna policy ogranicza read do `auth.uid()`;
- brak INSERT/UPDATE/DELETE/TRUNCATE, foreign browse, self-role lub self-status mutation;
- service_role nie otrzymuje nieplanowanego table ACL.

### email_deliveries

- RLS enabled;
- zero policies;
- PUBLIC, anon i authenticated nie mają SELECT ani DML;
- pozostaje wyłącznie istniejący server/service baseline;
- `set_email_delivery_tenant_id` pozostaje enabled i niezmieniony.

## 11. Zero global-role refs

Statyczny scan docelowych policy definitions i lokalny katalog po migracji zwróciły zero odwołań do:

- `profiles.role`;
- `get_my_role()`;
- `is_admin()`;
- `is_employee()`;
- `is_admin_or_employee()`;
- `is_admin_or_staff()`.

Nowe policies wymagają relacji wiersza do tenant oraz aktywnego tenant membership. Wynik: PASS.

## 12. SECURITY DEFINER boundary

Produkcyjny inventory nadal zawiera 73 funkcje `SECURITY DEFINER`. Normalizowany LF fingerprint wynosi `0dd807bea5ca20cfbaae9434b53d97a4`, dokładnie tyle samo co zapisany postflight SAAS-9C-2C. Helpery membership, public tenant helper i obie funkcje sync bridge mają identyczne source fingerprints jak lokalne odpowiedniki.

| Path | Direct RLS tenant-aware | SECURITY DEFINER | RLS bypass | Explicit tenant check | SAAS-9D blocker |
|---|---:|---:|---:|---:|---:|
| Direct audit/profile/lane config reads po 9C-2D | Tak | Nie | Nie | Tak | Nie |
| `admin_list_users_v1` | N/D | Tak | Tak | Nie | Tak |
| `get_reservation_customer_profiles_v1` | N/D | Tak | Tak | legacy scoped reservation checks | Tak |
| `get_public_booking_configuration_v1` | N/D | Tak | Tak | public active model, nie caller tenant | Tak/review |
| Lane configuration admin readers/writers | N/D | Tak | Tak | legacy global admin | Tak |
| Reservations/Calendar/Reports/Check-in RPC | N/D | Tak | Tak | legacy global role | Tak |
| Events RPC family | N/D | Tak | Tak | legacy global role/public rules | Tak |

9C-2D nie zmienia żadnego RPC. SEC-004 pozostaje OPEN.

## 13. Cross-tenant evidence

Focused local suite: 64/64 PASS w jednej transakcji z końcowym ROLLBACK.

- audit: ADMIN_A A allow, B deny, global deny; EMPLOYEE_A A allow/B deny; user/anon deny;
- profiles: owner allow; unrelated/B deny; ADMIN_A related A allow; unrelated i Tenant B-only deny;
- rules/durations/pricing: public contract zachowany, A allow/B deny;
- no membership/pending/suspended: privileged deny;
- direct DML: bez rozszerzenia;
- RLS recursion: brak;
- końcowy fixture post-check: 0.

## 14. Harness issue classification

```text
functional scenarios: 13/13 PASS
runner cleanup hook: did not terminate process
final local reset: PASS
fixture remaining: 0
independent post-check: PASS
classification: HARNESS ISSUE / NON-BLOCKING
```

Powtórzenie bez resetu wykazało pozostały lane fixture z pierwszego przerwanego teardownu, nie funkcjonalną regresję. Końcowy local reset i niezależne zapytanie do Auth/profiles/lanes/reservations/events/registrations potwierdziły zero fixture.

## 15. Security fingerprint

| Surface | Production preflight | Comparison |
|---|---|---|
| SECURITY DEFINER | 73; normalized LF `0dd807bea5ca20cfbaae9434b53d97a4` | unchanged vs 9C-2C postflight |
| Tenant helpers | five reviewed helpers; postgres-owned, hardened search paths | source hashes match local |
| Sync bridge | two enabled triggers/functions, postgres-owned | source hashes match local |
| Tenant integrity | composite/tenant FKs, role/status checks and uniqueness definitions | exact definitions match local |
| `profiles.role` | `text NOT NULL DEFAULT 'user'` | unchanged |
| Active tenant guard | `tenants_single_active_runtime_guard` | unchanged |
| Temporary CSK defaults | exactly seven approved tables | unchanged |
| Auth registration | `on_auth_user_created → handle_new_user()` | enabled and hardened |
| Target table owners/RLS | postgres; RLS enabled on all eight tables | expected baseline |

Surowe cross-environment `pg_get_functiondef` hash różnią się przez reprezentację zakończeń linii. Rozstrzygający produkcyjny fingerprint po normalizacji LF jest identyczny z zapisanym fingerprintem postflight 9C-2C; nie ma semantic drift.

## 16. Migration history

`supabase migration list --linked` zakończyło się kodem 0:

- LOCAL=REMOTE dla wszystkich migracji do `20260911100000` włącznie;
- brak remote-only migration;
- brak divergence;
- jedyna local-only/pending migracja: `20260911120000_add_remaining_tenant_aware_rls.sql`.

Nie wykonano `migration repair`.

## 17. SHA-256

Deployment fingerprint:

```text
BBD2A90604F9BCC91DF93863D5C0BE627AA8F1E0F3C9FF7E485ABFD67E7AE38E
```

Plik: `supabase/migrations/20260911120000_add_remaining_tenant_aware_rls.sql`.

Historyczne migracje nie mają tracked diff. Fingerprint musi pozostać niezmieniony do osobno autoryzowanego deploymentu.

## 18. Dry-run

`supabase db push --linked --dry-run`:

- exit code: 0;
- CLI jawnie potwierdził, że migracje nie zostaną wysłane;
- lista zawiera dokładnie jeden wpis: `20260911120000_add_remaining_tenant_aware_rls.sql`;
- nie wykonano production write.

Jedyny warning informuje o dostępności nowszej wersji Supabase CLI; nie wpływa na dry-run i CLI nie zostało zaktualizowane.

## 19. Deployment risk

| Ryzyko | Ocena | Uzasadnienie/mitigacja |
|---|---|---|
| Policy replacement | LOW–MEDIUM | atomowa migracja, dokładny baseline preflight, `lock_timeout=5s`, postflight fingerprints |
| Profiles access regression | MEDIUM | krytyczne zawężenie; Admin Users/Check-in call paths i production baseline zweryfikowane |
| Public Booking regression | LOW–MEDIUM | public role contract zachowany i production Booking działa; wymagany natychmiastowy postflight smoke |
| Lock duration | LOW | policy-only DDL na małych tabelach; największa target tabela ma 112 rows / 188416 bytes |
| Data rewrite | NONE | brak UPDATE/backfill/column/index rewrite |

Target volumes: audit 112, profiles 9, rules 11, durations 40, pricing 64. Krótki okres niskiego ruchu jest wystarczający; pełne maintenance window nie jest uzasadnione przez rozmiary, ale deployment należy przerwać przy lock timeout albo preflight drift.

## 20. Remaining blockers

Brak blockerów dla osobno autoryzowanego produkcyjnego push tej jednej, niezmienionej migracji. Nadal wymagane są:

- jawna zgoda użytkownika na właściwy `db push`;
- ponowne sprawdzenie SHA-256 bezpośrednio przed push;
- natychmiastowy post-deploy RLS/ACL/fingerprint oraz Booking/Admin Users/Check-in smoke;
- checkpoint/review przed rozpoczęciem 9C-2E.

SAAS-9D, drugi tenant i zamknięcie SEC-004 pozostają zablokowane niezależnie od 9C-2D.

## Production preflight final verdict

```text
SAAS-9C-2D PRODUCTION PREFLIGHT:
PASS

AUDIT BASELINE:
PASS

PROFILE PRIVACY BASELINE:
PASS

REGISTER FLOW:
PASS

ADMIN USERS / CHECK-IN COMPATIBILITY:
PASS

PUBLIC BOOKING:
PASS

ZERO GLOBAL ROLE POLICY REFS:
PASS

PLAYWRIGHT HARNESS ISSUE:
NON-BLOCKING

READY FOR PRODUCTION PUSH:
YES

READY FOR SAAS-9C-2E:
NO-GO until 9C-2D production PASS and checkpoint/review

READY FOR SAAS-9D:
NO-GO

SECOND TENANT:
NO-GO

SEC-004:
OPEN
```
