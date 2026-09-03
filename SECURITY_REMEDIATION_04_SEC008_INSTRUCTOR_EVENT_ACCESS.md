# SECURITY REMEDIATION 04 — SEC-008 Instructor Event Access

## Status analizy

**SEC-ID:** SEC-008

**Original severity:** MEDIUM

**Current status:** CONFIRMED

**Verdict:** **SEC-008 BLOCKED BY DATA MODEL**

Analiza została wykonana na gałęzi `main`, przy HEAD `24b6e24 docs: add production security smoke results`. Zgodnie z warunkiem zadania nie wdrożono zmiany RLS: aktualny model nie zawiera autorytatywnego przypisania instruktora do eventu.

## Before

### Polityki i ACL `public.event_registrations`

Tabela ma włączone RLS i dwie polityki SELECT dla roli bazodanowej `authenticated`:

- `Admins and staff can view all event registrations` — `USING (public.is_admin_or_staff())`;
- `Users can view own event registrations` — `USING (user_id = auth.uid())`.

`public.is_admin_or_staff()` obejmuje role aplikacyjne:

- `admin`,
- `pracownik`,
- `instruktor`.

Po hardeningu SEC-002 rola `authenticated` nadal ma tabelowe `SELECT`, a faktyczny zakres wierszy określa RLS. `anon` nie ma tabelowego SELECT. `service_role` zachowuje dostęp techniczny zgodnie z aktualnym kontraktem platformy.

W rezultacie każdy zalogowany instruktor spełnia globalną politykę i może odczytać wszystkie rekordy `event_registrations`, niezależnie od eventu.

### Dane dostępne przez tabelę

`event_registrations` zawiera:

- identyfikatory: `id`, `event_id`, `user_id`;
- PII: `customer_name`, `customer_email`, `customer_phone`;
- dane operacyjne: `registration_status`, `payment_status`, `created_at`;
- sekrety/capabilities promocji: `promotion_token`, `promotion_token_expires_at`;
- metadane dostarczenia i potwierdzenia: `promotion_email_sent_at`, `promotion_confirmed_at`;
- dane claimu i prób: `promotion_claim_id`, `promotion_claim_expires_at`, `promotion_attempt_count`, `promotion_last_attempt_at`, `promotion_last_error_code`.

### Rzeczywiste ścieżki odczytu dostępne instruktorowi

1. `app/admin/events/page.tsx`
   - middleware dopuszcza instruktora do `/admin/events`;
   - UI jawnie informuje instruktora, że może przeglądać listy uczestników;
   - `loadRegistrations(eventId)` wykonuje `.from("event_registrations").select("*")`;
   - przeglądarka otrzymuje cały rekord, w tym tokeny i claimy, mimo że komponent renderuje przede wszystkim imię, e-mail, telefon i statusy;
   - instruktor może wybrać dowolny event widoczny w panelu, ponieważ eventy również mają globalny staff SELECT.

2. `app/admin/page.tsx`
   - dashboard jest dostępny instruktorowi;
   - zagnieżdżony select eventów pobiera `event_registrations(registration_status)` dla nadchodzących eventów;
   - obecna globalna polityka pozwala instruktorowi otrzymać zbiorcze statusy wszystkich eventów.

3. `app/events/page.tsx`
   - dla każdego zalogowanego użytkownika publiczna lista eventów dołącza `event_registrations(id, registration_status)`;
   - zwykły user widzi dzięki RLS tylko własne rekordy, ale instruktor — przez globalną politykę — otrzymuje identyfikatory i statusy zapisów wszystkich użytkowników dla aktywnych eventów.

4. `app/my-events/page.tsx`
   - odczyt jest jawnie filtrowany `.eq("user_id", user.id)` i stanowi prawidłową ścieżkę własnościową;
   - ten call-site sam nie wykorzystuje globalnego dostępu instruktora.

5. Bezpośredni PostgREST
   - instruktor nie jest ograniczony do powyższych ekranów; jego JWT może wykonać bezpośredni SELECT tabeli, a RLS zwróci globalny zbiór.

Endpointy serwerowe obsługujące confirmation/promotion nie stanowią dowodu przypisania instruktora do eventu; mają własne kontrakty właściciela albo technicznego delivery flow.

## Current access matrix

W aktualnym schemacie pojęcie „Assigned event” nie istnieje. W kolumnie tej pokazano rzeczywiste zachowanie dla dowolnego hipotetycznie przypisanego eventu — baza nie odróżnia go od eventu obcego.

| Role | Own registration | Assigned event | Other event | All registrations |
|---|---:|---:|---:|---:|
| `anon` | DENY | N/A / DENY | DENY | DENY |
| `user` | ALLOW | N/A | DENY | DENY |
| `instruktor` | ALLOW | ALLOW, ale bez kontroli przypisania | **ALLOW** | **ALLOW** |
| `pracownik` | ALLOW | N/A / ALLOW | ALLOW | ALLOW |
| `admin` | ALLOW | N/A / ALLOW | ALLOW | ALLOW |
| `service_role` | ALLOW technicznie | ALLOW technicznie | ALLOW technicznie | ALLOW technicznie |

## Brakujący model przypisania

Repozytorium nie zawiera żadnego z wymaganych, jednoznacznych mechanizmów:

- `events.instructor_id`;
- `events.created_by` o semantyce prowadzącego;
- `event_staff`;
- `event_instructors`;
- ownership eventu przez instruktora;
- innej relacji `event ↔ instructor`.

`event_lanes` wiąże event wyłącznie z osią. Rola `instruktor` w `profiles` oraz deklaracja `qualification_instructor` nie przypisują użytkownika do konkretnego eventu. Autor eventu nie jest zapisywany w `events`, a utworzenie eventu przez admina/pracownika nie oznacza prowadzenia go przez tę osobę.

Nie można więc napisać poprawnej polityki „instruktor widzi przypisane eventy” bez zgadywania relacji biznesowej.

## Docelowy model dostępu

| Role | Own registration | Assigned event | Other event | All registrations |
|---|---:|---:|---:|---:|
| `anon` | DENY | DENY | DENY | DENY |
| `user` | ALLOW | N/A | DENY | DENY |
| `instruktor` | ALLOW | ALLOW przez kontrolowany, minimalny reader | DENY | DENY |
| `pracownik` | ALLOW | ALLOW | ALLOW | ALLOW zgodnie z obecnym modelem operacyjnym |
| `admin` | ALLOW | ALLOW | ALLOW | ALLOW |
| `service_role` | dostęp wyłącznie dla zatwierdzonych flow technicznych | dostęp techniczny | dostęp techniczny | nie jest ścieżką UI instruktora |

Docelowo instruktor nie powinien otrzymywać tabelowego `select('*')`. Przypisanie powinno umożliwiać odczyt wyłącznie minimalnego kontraktu potrzebnego do prowadzenia wskazanego eventu.

## Minimalna proponowana zmiana architektoniczna

### 1. Relacja `public.event_instructors`

Minimalna relacja powinna zawierać:

- `event_id uuid NOT NULL` — FK do `public.events(id)` z `ON DELETE CASCADE`;
- `instructor_user_id uuid NOT NULL` — FK do unikalnego `public.profiles(user_id)` albo, po świadomej decyzji, do `auth.users(id)`;
- `created_at timestamptz NOT NULL DEFAULT transaction_timestamp()`;
- `assigned_by uuid` — zalecany identyfikator aktora dla audytu przypisania;
- PRIMARY KEY `(event_id, instructor_user_id)`.

Sama obecność profilu nie dowodzi roli. Kontrolowany writer przypisania musi sprawdzać, że docelowy profil ma aktualnie rolę `instruktor`. Trzeba też ustalić zachowanie po zmianie roli instruktora: odrzucenie zmiany roli, automatyczne/deklaratywne usunięcie przypisań albo traktowanie nieaktualnych przypisań jako nieaktywnych.

### 2. Kontrolowane zarządzanie przypisaniami

- admin i — wyłącznie jeśli biznes to zatwierdzi — pracownik przypisują/odpinają instruktorów przez atomowy RPC;
- brak bezpośredniego client INSERT/UPDATE/DELETE tabeli relacji;
- RPC wyprowadza aktora z `auth.uid()`, sprawdza rolę w bazie i zapisuje audit;
- instruktor może odczytać własne przypisania, ale nie listę wszystkich instruktorów ani cudze przypisania.

### 3. Minimalny reader uczestników

Preferowany jest osobny SECURITY DEFINER RPC, np. `get_assigned_event_participants_v1(event_id)`, który:

- wymaga `auth.uid()`;
- zezwala adminowi/pracownikowi zgodnie z obecnym modelem;
- instruktorowi zezwala tylko przy istniejącym przypisaniu `(event_id, auth.uid())` i aktualnej roli `instruktor`;
- zwraca jawny `RETURNS TABLE`, bez `SELECT *`;
- nie zwraca `promotion_token`, pól expiry/claim, `user_id`, błędów delivery ani innych metadanych technicznych;
- zwraca dane kontaktowe tylko wtedy, gdy zostanie udokumentowana konkretna potrzeba operacyjna. Bez takiej decyzji minimalny DTO powinien ograniczać się np. do `registration_id`, bezpiecznej nazwy/etykiety oraz statusu uczestnictwa;
- ma `PUBLIC/anon/service_role EXECUTE = false`, `authenticated EXECUTE = true`, bezpieczny `search_path`, owner `postgres` i fail-closed role check.

Równolegle globalną politykę tabelową należy zmienić z `is_admin_or_staff()` na `is_admin_or_employee()`. Polityka własnościowa `user_id = auth.uid()` pozostaje. Dzięki temu instruktor zachowuje dostęp do własnego zapisu, ale nie może ominąć DTO bezpośrednim PostgREST.

### 4. Wpływ na UI/admin

- formularz tworzenia/edycji eventu potrzebuje wyboru zero, jednego lub wielu instruktorów;
- lista wyboru musi pochodzić z kontrolowanego admin/employee readera profili ograniczonego do roli `instruktor` i minimalnych pól;
- `/admin/events` dla instruktora powinno pokazywać tylko eventy przypisane albo pozostawić publiczny katalog eventów bez panelu uczestników dla nieprzypisanych pozycji;
- przycisk „Pokaż zapisanych” musi używać scoped RPC, nie tabeli;
- dashboard i publiczne `/events` muszą przestać opierać liczniki na globalnej widoczności `event_registrations` instruktora. Publiczne liczniki powinny pochodzić z bezpiecznego agregatu lub mieć semantykę ownership-only;
- etykieta „Tryb instruktora” musi mówić o listach uczestników przypisanych szkoleń, nie wszystkich szkoleń.

## RLS changes

**W tym zadaniu: brak.**

Po zatwierdzeniu modelu wymagane będą co najmniej dwie etapowane migracje:

1. migracja modelu i dormant RPC:
   - tabela `event_instructors`, constrainty, indeksy, RLS/ACL;
   - kontrolowane RPC przypisywania;
   - scoped participant reader;
   - opcjonalny bezpieczny reader przypisanych eventów;
   - bez odebrania starego dostępu do czasu przełączenia klienta;

2. migracja revoke/switch po wdrożeniu UI:
   - zastąpienie globalnej polityki SELECT `is_admin_or_staff()` polityką dla `is_admin_or_employee()`;
   - potwierdzenie, że instruktor ma wyłącznie własne wiersze tabeli oraz przypisane DTO przez RPC;
   - usunięcie nieużywanego runtime call-site `select('*')`.

Taki rollout zapobiega przerwie między zmianą DB i wdrożeniem aplikacji.

## Data exposure

Obecne `select('*')` jest szersze od potrzeb UI i przekazuje do przeglądarki pola, których TypeScriptowy typ `Registration` nawet nie deklaruje. RLS ogranicza wiersze, nie kolumny, więc samo dodanie relacji przypisania nadal ujawniałoby instruktorowi tokeny i claimy przypisanych eventów.

Wymagane jest zastąpienie tego odczytu jawnym DTO. Danych kontaktowych nie należy automatycznie uznawać za potrzebne: decyzja powinna wskazać zadanie instruktora wymagające e-maila lub telefonu. Tokeny promocji i pola claimu nie są potrzebne instruktorowi w żadnym opisanym flow.

## Wymagane testy

### Model i writer przypisań

- admin może przypisać i odpiąć instruktora;
- pracownik ALLOW albo DENY zgodnie z zatwierdzoną decyzją biznesową;
- instruktor/user/anon nie mogą mutować przypisań;
- nie można przypisać nieistniejącego eventu ani użytkownika bez aktualnej roli `instruktor`;
- duplikat przypisania jest idempotentny albo kontrolowanie odrzucony;
- zmiana roli nie pozostawia aktywnego, uprzywilejowanego przypisania;
- legalna zmiana tworzy dokładnie jeden bezpieczny audit.

### USER

- User A: własna rejestracja — ALLOW;
- User A: rejestracja User B — DENY;
- brak regresji `/my-events` i publicznego zapisu.

### INSTRUCTOR

- Instructor A: participant DTO przypisanego eventu — ALLOW;
- Instructor A: participant DTO niepowiązanego eventu — DENY;
- Instructor A: bezpośredni SELECT cudzej rejestracji — DENY;
- globalny SELECT zwraca najwyżej własne rejestracje instruktora;
- brak `promotion_*`, claimów, `user_id` i niezatwierdzonego PII w DTO;
- Instructor B nie dziedziczy przypisania Instructor A;
- usunięte przypisanie natychmiast odbiera dostęp;
- stale/zmieniona rola instruktora powoduje DENY.

### EMPLOYEE / ADMIN

- admin globalny odczyt — ALLOW;
- pracownik globalny odczyt — ALLOW zgodnie z obecnym modelem;
- istniejące operacyjne RPC pozostają bez regresji.

### ANON

- tabelowy SELECT `event_registrations` — DENY;
- scoped RPC — brak EXECUTE albo kontrolowane DENY;
- brak PII w publicznych event queries.

### Frontend i kontrakt

- instruktor widzi tylko przypisane listy;
- event obcy nie pokazuje przycisku/listy albo zwraca kontrolowany brak dostępu;
- brak `select('*')` dla registrations;
- dashboard oraz `/events` nie ujawniają globalnych identyfikatorów/statusów instruktorowi;
- admin/pracownik zachowują bieżący workflow;
- testy statyczne zabraniają pól `promotion_*`, claimów i `user_id` w DTO instruktora.

### Regresja końcowa po przyszłej implementacji

- focused SEC-008 DB/RLS tests;
- wszystkie Supabase DB tests;
- focused Events/dashboard tests;
- wszystkie Node tests;
- `npx.cmd tsc --noEmit`;
- `npm.cmd run build`;
- pełny ESLint z rozdzieleniem znanego baseline od nowych regresji;
- `git diff --check`;
- test wdrożeniowy DB-first/app-switch/revoke bez okna nadmiernego dostępu lub awarii UI.

## Tests

W tej iteracji nie utworzono ani nie uruchomiono nowych testów, ponieważ zadanie nakazuje STOP przed implementacją RLS przy braku autorytatywnej relacji. Uruchamianie pełnej regresji bez zmiany implementacji nie zamknęłoby findingu i nie zastąpiłoby decyzji o modelu danych.

## After

**Stan po tej analizie jest funkcjonalnie taki sam jak Before.** Nie zmieniono kodu, SQL, migracji, RLS, ACL ani bazy produkcyjnej. Raport definiuje wymagany model docelowy, ale SEC-008 pozostaje otwarty do czasu:

1. zatwierdzenia semantyki przypisania instruktorów;
2. wdrożenia relacji i kontrolowanych writerów;
3. przełączenia UI na minimalny scoped reader;
4. odebrania instruktorowi globalnej polityki tabelowej;
5. zaliczenia macierzy RLS i regresji aplikacji.

## Regression risk

**HIGH** — zmiana dotyka widoczności panelu Events, publicznych zagnieżdżonych selectów, dashboardowych liczników, tabelowego RLS oraz nowego lifecycle przypisań. Jednoetapowe odebranie globalnego SELECT przed przełączeniem UI może zepsuć istniejący tryb instruktora; samo dodanie scoped RLS bez DTO nadal ujawni tokeny w `select('*')`.

## Końcowy werdykt

```text
SEC-008 BLOCKED BY DATA MODEL
```

Nie istnieje bezpieczna, jednoznaczna implementacja zasady „assigned event” w aktualnym schemacie. Następnym krokiem musi być zatwierdzenie relacji `event_instructors` i zakresu minimalnego DTO, a nie zgadywana zmiana RLS.
