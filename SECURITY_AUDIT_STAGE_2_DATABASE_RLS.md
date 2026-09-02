# CSK Booking — etap 2: Supabase, PostgreSQL i RLS

## Metoda i stan schematu

Skontrolowano wszystkie migracje oraz aktualny katalog odtworzonej lokalnej bazy przez zapytania w `BEGIN READ ONLY ... ROLLBACK`. Stan: 14 tabel public, RLS włączone na 14/14, FORCE RLS 0/14, 29 polityk, 58 funkcji, 12 triggerów nieinternalnych, 0 views i 0 materialized views.

## RLS — pełna mapa operacji

| Tabela | SELECT | INSERT | UPDATE | DELETE | Uwagi |
| --- | --- | --- | --- | --- | --- |
| `profiles` | own U; all A | A | own U + all A | brak | trigger blokuje pola uprzywilejowane |
| `reservations` | own U; all A/P | brak | brak bezpośredniej polityki | A | mutacje biznesowe przez RPC |
| `event_registrations` | own U; all A/P/I | A/P | A/P | A/P | bezpośrednie mutacje staff nadal istnieją |
| `events` | aktywne anon/U; all A/P/I | brak | brak | brak | writery V2 RPC |
| `event_lanes` | A/P/I | brak | brak | brak | odczyt staff |
| `shooting_lanes` | aktywne public; all A/P/I | brak | brak | brak | konfiguracja przez RPC |
| `lane_blocks` | aktywne U; all A/P/I | brak | brak | brak | writery RPC |
| `lane_booking_rules` | efektywne anon/U; all staff | brak | brak | brak | writer admin RPC |
| `lane_booking_durations` | aktywne anon/U; all A/P | brak | brak | brak | writer admin RPC |
| `lane_pricing_rules` | aktywne anon/U; all A/P | brak | brak | brak | writer admin RPC |
| `lane_booking_family_configuration_versions` | brak | brak | brak | brak | dostęp przez definer RPC |
| `audit_logs` | A | A/P/I | brak | brak | insert staff ma integralność opartą na kliencie |
| `email_deliveries` | brak | brak | brak | brak | service-only RPC |
| `confirmation_email_rate_limits` | brak | brak | brak | brak | service-only RPC |

Polityki własności używają `user_id = auth.uid()`. Polityki ról używają helperów odczytujących `profiles.role`. W `event_registrations` `is_admin_or_staff()` obejmuje `admin`, `pracownik`, `instruktor`; `is_admin_or_employee()` obejmuje tylko `admin`, `pracownik`.

## IDOR/BOLA i eskalacja

- `profiles`, `reservations` i `event_registrations` ograniczają zwykłego usera do `auth.uid()`; lokalny zestaw DB 37/37 oraz bieżące testy Node potwierdzają ownership-scoped odczyty i brak prostego direct-table bypassu.
- `create_reservation_v2`, `get_my_reservations_v2`, `register_for_event`, prepare confirmation i cancel RPC nie ufają `user_id` z klienta; tożsamość pochodzi z `auth.uid()`.
- RPC administracyjne same pobierają rolę z `profiles`; klient nie przekazuje autorytatywnej roli.
- Trigger `prevent_non_admin_profile_privilege_changes()` blokuje zmianę własnej roli, weryfikacji, user ID i pól administracyjnych. `admin_set_user_role_v1()` jest admin-only i chroni ostatniego administratora.
- Nie ma jeszcze `tenant_id`, więc próby podmiany tenant ID są obecnie niewykonalne, ale nie istnieje również izolacja pomiędzy przyszłymi tenantami.

## RPC

Katalogowo skontrolowano owner, `prosecdef`, `proconfig`, typ zwracany i ACL wszystkich funkcji. Najważniejsze wnioski:

- Krytyczne writery są `SECURITY DEFINER`, owner `postgres`, z jawnym `search_path`; aktualne V2 używają zwykle `pg_catalog, public, pg_temp`.
- Event V1 i stary `create_reservation` pozostają jako rollback wdrożeniowy, ale authenticated EXECUTE jest odebrane.
- Event V2: authenticated EXECUTE, wewnętrznie dokładnie admin/pracownik.
- Lane-block RPC: authenticated EXECUTE, admin/pracownik.
- Family configuration/create oraz admin user RPC: authenticated EXECUTE, wewnętrznie tylko admin.
- `create_reservation_v2`, `register_for_event`, własne odczyty i profile RPC wymagają `auth.uid()`.
- E-mail complete, reserve prepare/complete oraz promotion confirm są service-role only.
- Public reader konfiguracji jest anon/authenticated, zwraca ograniczony shape bez PII.
- Funkcje triggerowe nie stanowią udokumentowanego REST RPC bypassu. `set_updated_at()` jest invoker i nie ma jawnego `search_path`; przy braku CREATE w `public` nie potwierdzono exploita.

## Views, constraints i współbieżność

Brak views eliminuje ryzyko view-owner bypassu w analizowanym schemacie. Istnieją m.in.:

- FK hierarchii osi, event-lanes i zasobów; kontrolowane CASCADE/RESTRICT.
- check constraints czasu eventów/blokad, limitów, statusów oraz spójności token/claim.
- unikalność idempotency request i aktywnych rekordów.
- exclusion constraints przeciwdziałające overlapom rezerwacji/cenników.
- deterministyczne blokady family/event przed zależnymi rekordami w krytycznych RPC.

Nie znaleziono potwierdzonego race condition omijającego aktualne RPC. Bezpośrednie staff DML do event registrations pozostaje jednak alternatywną ścieżką poza częścią inwariantów RPC.

---

### SEC-002

Severity: **HIGH**
Status: **CONFIRMED**
Lokalizacja: `supabase/migrations/20260816090000_remote_baseline.sql:11088-11111`, `pg_default_acl` lokalnej bazy
Opis: domyślne przywileje roli `postgres` nadają `ALL` na przyszłych tabelach, sekwencjach i funkcjach rolom `anon` oraz `authenticated`. Bieżące obiekty są często później jawnie utwardzane, lecz każdy nowy obiekt jest chwilowo lub trwale publicznie wykonywalny/dostępny, jeśli migracja zapomni o REVOKE. Bieżące tabele zachowują też szerokie uprawnienia techniczne, np. TRUNCATE/REFERENCES/TRIGGER, mimo że RLS nie kontroluje TRUNCATE.
Scenariusz wykorzystania: nowa tabela z PII lub nowa SECURITY DEFINER function zostaje dodana bez pełnego REVOKE; klient anon/authenticated uzyskuje dostęp przed wykryciem błędu. Bezpośrednie zdalne wykorzystanie TRUNCATE przez PostgREST nie zostało potwierdzone.
Dane zagrożone: wszystkie przyszłe dane public schema; integralność bieżących tabel przy pojawieniu się dodatkowego kanału SQL.
Dowód: jawne `ALTER DEFAULT PRIVILEGES ... GRANT ALL` dla anon/authenticated; katalog lokalny potwierdził te default ACL.
Rekomendowana poprawka: bezpieczne default privileges (REVOKE dla anon/authenticated), następnie minimalne jawne granty per obiekt i test katalogowy blokujący szerokie ACL.
Test regresyjny wymagany po naprawie: utworzyć w rollback test table/function jako `postgres` i potwierdzić, że anon/authenticated nie dostają automatycznie żadnych praw.

### SEC-007

Severity: **MEDIUM**
Status: **CONFIRMED**
Lokalizacja: policy `Admins can insert audit logs`, baseline `:10560`; ACL `audit_logs`
Opis: każda rola przechodząca `is_admin_or_staff()` — w tym instruktor — może bezpośrednio wstawiać do `audit_logs`. Kolumny aktora, roli, akcji, celu i details są przekazywane przez klienta, więc wpis nie jest kryptograficznie ani triggerowo związany z rzeczywistym aktorem.
Scenariusz wykorzystania: zalogowany instruktor wywołuje REST INSERT i fałszuje zdarzenie administratora lub zaciemnia chronologię. Nie ma polityki UPDATE/DELETE, ale fałszywy INSERT wystarcza do podważenia wiarygodności.
Dane zagrożone: integralność ścieżki audytowej i postępowania wyjaśniającego.
Dowód: `WITH CHECK (public.is_admin_or_staff())` bez kontroli `actor_user_id=auth.uid()` i bez ograniczenia action/details.
Rekomendowana poprawka: odebrać direct INSERT klientom; zapisywać audyt wyłącznie w zaufanych writer RPC/triggerach, aktora wyprowadzać z `auth.uid()` i roli z bazy.
Test regresyjny wymagany po naprawie: direct REST INSERT jako A/P/I/U/anon = DENY; legalna mutacja RPC = dokładnie jeden poprawny audit.

### SEC-008

Severity: **MEDIUM**
Status: **LIKELY**
Lokalizacja: `event_registrations`, policy baseline `:10536`; helper `is_admin_or_staff()`
Opis: instruktor ma globalny SELECT wszystkich zapisów eventowych, łącznie z imieniem, e-mailem, telefonem oraz tokenami promocji. Potrzeba biznesowa globalnego, nieograniczonego odczytu PII i tokenów przez każdego instruktora nie została udokumentowana.
Scenariusz wykorzystania: dowolny instruktor pobiera REST-em wszystkie registrations albo pozyskuje token promocji innego użytkownika. Zasięg funkcjonalny instruktora w Calendar jest ograniczony, ale RLS tabeli jest szerszy niż UI.
Dane zagrożone: PII uczestników i tokeny promocji; potencjalna integralność statusu zapisu.
Dowód: policy `FOR SELECT ... USING (is_admin_or_staff())`; helper obejmuje `instruktor`.
Rekomendowana poprawka: ustalić potrzebę biznesową; udostępnić instruktorowi minimalny DTO/scoped RPC bez kontaktu i tokenów, najlepiej tylko dla przypisanych eventów.
Test regresyjny wymagany po naprawie: instruktor nie może odczytać obcego/globalnego registration ani pól token/contact; admin/pracownik zachowują wymagany dostęp.

### SEC-018

Severity: **MEDIUM**
Status: **CONFIRMED**
Lokalizacja: `event_registrations`, policies baseline `:10524-10532`
Opis: admin i pracownik mogą nadal bezpośrednio INSERT/UPDATE/DELETE event registrations. Jest to równoległy writer poza wyspecjalizowanymi RPC rejestracji, zatwierdzania i anulowania, a więc nie wymusza pełnego zestawu ich blokad, transition checks i audytów.
Scenariusz wykorzystania: przejęte konto pracownika lub błąd przyszłego klienta zmienia status/rekord REST-em z pominięciem oczekiwanej ścieżki biznesowej.
Dane zagrożone: integralność list uczestników, rezerwy, limitów i audytów.
Dowód: obecne INSERT/UPDATE/DELETE policies dla `is_admin_or_employee()` oraz tabela ACL pozwalają na te operacje.
Rekomendowana poprawka: po inwentaryzacji wszystkich writerów przełączyć je na RPC, odebrać direct DML i usunąć mutacyjne policies.
Test regresyjny wymagany po naprawie: direct I/U/D jako admin/pracownik/instruktor/user/anon = DENY; zatwierdzone RPC nadal ALLOW zgodnie z rolami.

### SEC-014

Severity: **LOW**
Status: **POTENTIAL**
Lokalizacja: `lane_blocks`, policy baseline `:10580`
Opis: każdy authenticated może odczytać pełne aktywne lane blocks, w tym swobodny tekst `reason`. UI dostępności potrzebuje głównie przedziału i typu, niekoniecznie wewnętrznego powodu.
Scenariusz wykorzystania: pracownik wpisuje PII lub szczegół techniczny do reason, który następnie jest dostępny przez REST wszystkim użytkownikom.
Dane zagrożone: potencjalne incydentalne PII/informacja operacyjna.
Dowód: globalna polityka SELECT aktywnych blokad; `reason` jest tekstem. Nie potwierdzono obecności PII w danych.
Rekomendowana poprawka: ograniczyć direct SELECT lub publicznie zwracać DTO bez reason; wprowadzić regułę treści.
Test regresyjny wymagany po naprawie: user otrzymuje zakres blokady bez reason; staff otrzymuje reason.

## Ocena etapu

Nie znaleziono potwierdzonego obejścia ownership RLS przez zwykłego użytkownika w aktualnym schemacie. Największe ryzyka bazowe to domyślne ACL, wiarygodność audytu, za szeroki globalny odczyt instruktora oraz pozostawiony direct DML event registrations.
