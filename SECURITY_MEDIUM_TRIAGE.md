# CSK Booking — Security Medium Findings Triage

Data: 2026-09-02

Punkt odniesienia: `main` @ `24b6e24` (`docs: add production security smoke results`).

Zakres: ponowna statyczna weryfikacja ośmiu findingów MEDIUM z audytu z 2026-08-16 względem aktualnego kodu, migracji, raportów remediation i produkcyjnego smoke testu. Nie zmieniono kodu, SQL, migracji ani konfiguracji.

## Uwzględnione zmiany po audycie

- SEC-001: zależności produkcyjne zaktualizowane; `npm audit --omit=dev` po remediation nie zawierał HIGH ani CRITICAL.
- SEC-002: ACL funkcji, tabel, sekwencji i default privileges w zakresie kontrolowanym przez aplikację zostały utwardzone. Pozostały zarządzany residual `supabase_admin` jest zaakceptowanym ryzykiem platformowym LOW.
- SEC-003: publiczny GET jest read-only, potwierdzenie wymaga zalogowanego właściciela i POST. Produkcyjny smoke test przeszedł w całości.
- Zmiany te nie zamknęły automatycznie żadnego z poniższych ośmiu findingów. Ograniczyły jednak część powierzchni SEC-018.

## Podsumowanie bieżącego stanu

| SEC-ID | Bieżący status | Exploitability | Priorytet |
|---|---|---:|---|
| SEC-005 | CONFIRMED | MEDIUM | P1 |
| SEC-006 | CONFIRMED | MEDIUM | P1 |
| SEC-007 | CONFIRMED | MEDIUM | P1 |
| SEC-008 | CONFIRMED | HIGH | P1 |
| SEC-009 | CONFIRMED | LOW | P2 |
| SEC-010 | REQUIRES VERIFICATION | LOW | P2 |
| SEC-011 | CONFIRMED | LOW | P3 |
| SEC-018 | PARTIALLY REMEDIATED | MEDIUM | P1 |

---

## SEC-005 — długowieczny check-in bearer token ujawnia PII

**SEC-ID:** `SEC-005`

**Original severity:** `MEDIUM`

**Current status:** `CONFIRMED`

**Affected files / database objects:**

- `app/check-in/[token]/page.tsx:38,85-113,190-208`
- `app/api/send-reservation-confirmation/route.ts:200-233,274`
- `app/my-reservations/page.tsx:571-572`
- `lib/my-reservations.ts:11,35,81-99`
- `public.reservations.check_in_token`
- `public.get_my_reservations_v2()`

**Problem:** publiczny server component nadal tworzy klienta `service_role`, wyszukuje rezerwację wyłącznie po `check_in_token` i renderuje imię, telefon oraz e-mail. Token jest trwałym UUID z unikalnym indeksem, ale bez pola expiry, revocation ani rotacji. Zmiana SEC-003 dotyczyła innego tokenu i nie ograniczyła check-in.

**Real attack scenario:** link lub QR trafia do historii przeglądarki, logu poczty, zrzutu ekranu, komunikatora albo nagłówka referrer. Posiadacz linku może bez logowania wielokrotnie odczytywać dane kontaktowe i status wizyty tak długo, jak rekord istnieje.

**Affected data:** imię i nazwisko/snapshot nazwy klienta, e-mail, telefon, data i godzina rezerwacji, status rezerwacji, płatności i obecności, relacja osi.

**Current exploitability:** `MEDIUM` — token ma wysoką entropię i nie jest praktycznie enumerowalny, ale sam link jest kompletnym bearer credential i nie wygasa.

**Recommended remediation:** zastąpić publiczny odczyt PII modelem krótkotrwałego, rotowalnego tokenu przechowywanego jako digest. Publiczny GET powinien zwracać co najwyżej neutralny stan bez PII albo kierować do uwierzytelnionego staff check-in. Odczyt danych operacyjnych powinien przechodzić przez scoped RPC wymagające `auth.uid()` i roli admin/pracownik. Należy określić expiry, revocation po zakończeniu/anulowaniu, rotację i zachowanie istniejących linków w migracji przejściowej.

**Expected files/migrations affected:** nowa migracja token lifecycle/RPC; `app/check-in/[token]/page.tsx`; `app/admin/check-in/page.tsx`; `app/api/send-reservation-confirmation/route.ts`; `app/my-reservations/page.tsx`; `lib/my-reservations.ts`; testy public check-in, Auth/RPC i DB.

**Regression risk:** `HIGH` — zmiana dotyka QR/linków już wysłanych, check-in personelu, e-maila i kontraktu owner read.

**Suggested tests:** token poprawny/wygasły/cofnięty/obrócony; brak PII dla anon; staff ALLOW, instruktor/user DENY; stary token po rotacji DENY; brak tokenu plaintext w bazie i logach; link z istniejącego e-maila ma kontrolowaną migrację; check-in nadal działa na mobile i po odświeżeniu.

**Estimated implementation scope:** `LARGE`

---

## SEC-006 — HTML injection w e-mailach eventowych

**SEC-ID:** `SEC-006`

**Original severity:** `MEDIUM`

**Current status:** `CONFIRMED`

**Affected files / database objects:**

- `lib/server/event-reserve-promotion.ts:510-537`
- `lib/server/event-reserve-confirmation-email.ts:71,85-112`
- dane źródłowe: `event_registrations.customer_name`, `events.title`, `events.location`

**Problem:** dwa aktualne szablony HTML nadal interpolują bez kodowania `displayName`, tytuł i lokalizację eventu. Inne szablony, np. `send-event-registration-confirmation`, mają lokalny `escapeHtml`, ale ochrona nie jest wspólna i nie obejmuje dwóch wskazanych ścieżek.

**Real attack scenario:** złośliwa wartość w nazwie klienta albo wartość eventu kontrolowana przez przejęte konto operatora wstawia elementy HTML/linki do wiadomości, zmienia treść wizualną lub tworzy phishing w zaufanym szablonie CSK. Skrypty są zwykle blokowane przez klientów poczty, ale HTML/link injection pozostaje realne.

**Affected data:** integralność treści wiadomości, reputacja nadawcy, odbiorcy promocji i potwierdzeń; potencjalnie kliknięcia w podmienione linki.

**Current exploitability:** `MEDIUM`

**Recommended remediation:** utworzyć jeden server-only encoder HTML i kodować każdy dynamiczny tekst oraz atrybut URL w HTML. Plain-text pozostawić tekstem, bez encji HTML. Dodać bezpieczne budowanie URL i nie dopuszczać schematów innych niż oczekiwany origin HTTPS.

**Expected files/migrations affected:** `lib/server/event-reserve-promotion.ts`; `lib/server/event-reserve-confirmation-email.ts`; nowy mały helper, np. `lib/server/email-html.ts`; testy obu szablonów. Bez migracji.

**Regression risk:** `LOW`

**Suggested tests:** dokładne kodowanie `<`, `>`, `&`, `"`, `'`; payload z tagiem/linkiem nie pojawia się surowo w HTML; polskie znaki pozostają poprawne; wersja text nadal czytelna; właściwy link potwierdzenia występuje dokładnie raz.

**Estimated implementation scope:** `SMALL`

---

## SEC-007 — staff może fałszować audit logs

**SEC-ID:** `SEC-007`

**Original severity:** `MEDIUM`

**Current status:** `CONFIRMED`

**Affected files / database objects:**

- `public.audit_logs`
- policy `Admins can insert audit logs` z `WITH CHECK (public.is_admin_or_staff())`
- `supabase/migrations/20260816090000_remote_baseline.sql:10560`
- `supabase/migrations/20260902120000_harden_public_table_sequence_acl.sql:34`

**Problem:** po SEC-002 `anon` utracił dostęp, a techniczne prawa klientów zostały ograniczone. Rdzeń findingu pozostał jednak bez zmian: każdy zalogowany admin, pracownik lub instruktor ma bezpośredni `INSERT` przez ACL/RLS i może sam ustawić pola aktora, roli, akcji, celu i details. Aplikacja nie wykonuje już bezpośrednich insertów, natomiast baza nadal je dopuszcza.

**Real attack scenario:** przejęte lub złośliwe konto staff tworzy fałszywe rekordy przypisujące operację innemu operatorowi albo wprowadza mylące szczegóły, podważając dowodową wartość audytu i reakcję na incydent.

**Affected data:** integralność `audit_logs`, identyfikacja aktora, historia zmian rezerwacji/eventów/konfiguracji/użytkowników.

**Current exploitability:** `MEDIUM` — wymaga konta jednej z trzech ról staff, ale atak jest pojedynczym bezpośrednim INSERT REST/SQL.

**Recommended remediation:** odebrać `authenticated INSERT` i usunąć politykę client INSERT. Audyty tworzyć wyłącznie wewnątrz kontrolowanych SECURITY DEFINER RPC albo dedykowanego internal-only helpera, który bierze aktora z `auth.uid()` i rolę z `profiles`, a action/details generuje po stronie zaufanej. Nie przyjmować autorytatywnego actor ID/role/details od klienta.

**Expected files/migrations affected:** jedna migracja ACL/RLS; ewentualny internal audit helper; test katalogowy i macierz direct INSERT; testy wszystkich RPC zapisujących audit. Aplikacyjne call-sites nie powinny wymagać zmiany po potwierdzeniu obecnego braku direct insertów.

**Regression risk:** `MEDIUM` — istnieje 14 ścieżek SQL tworzących audyty; trzeba potwierdzić je wszystkie oraz zadania service-role.

**Suggested tests:** direct INSERT jako anon/user/instruktor/pracownik/admin DENY; każde kontrolowane RPC nadal tworzy dokładnie jeden prawidłowy audit; actor zawsze równa się sesji; błąd audytu wycofuje mutację; brak auditu dla denied/no_change; details bez PII/tokenów.

**Estimated implementation scope:** `MEDIUM`

---

## SEC-008 — globalny instructor SELECT event registrations

**SEC-ID:** `SEC-008`

**Original severity:** `MEDIUM`

**Current status:** `CONFIRMED`

**Affected files / database objects:**

- policy `Admins and staff can view all event registrations`
- `supabase/migrations/20260816090000_remote_baseline.sql:10536`
- `public.is_admin_or_staff()` obejmujące `admin`, `pracownik`, `instruktor`
- `app/admin/events/page.tsx:518-525` (`select("*")`)
- routing instruktora do `/admin/events` w `middleware.ts`

**Problem:** pierwotne `LIKELY` można obecnie podnieść do `CONFIRMED`. Instruktor ma tabelowy SELECT oraz globalną politykę opartą na `is_admin_or_staff()`. Odczyt nie ma warunku przypisania do eventu ani minimalnego DTO; `select("*")` obejmuje pola kontaktowe oraz tokeny promocji.

**Real attack scenario:** dowolne konto instruktora lub przejęta sesja wykonuje bezpośredni REST SELECT tabeli albo otwiera listę rejestracji eventów i pobiera dane wszystkich zapisanych osób, także dla wydarzeń niezwiązanych z instruktorem.

**Affected data:** imię, e-mail, telefon, user ID, status/płatność, token i czasy promocji, identyfikatory eventów oraz historia zapisów.

**Current exploitability:** `HIGH` — wymaga roli instruktora, ale nie wymaga dodatkowego IDOR, zgadywania tokenu ani przypisania; globalny odczyt jest jawnie dozwolony.

**Recommended remediation:** natychmiast wyłączyć instruktora z globalnej policy tabeli, zastępując ją `is_admin_or_employee()`. Jeżeli instruktor potrzebuje operacyjnego widoku, dostarczyć osobny SECURITY DEFINER reader z minimalnym DTO i rzeczywistym warunkiem przypisania. Ponieważ obecny model nie ma assignment instruktora do eventu, najbezpieczniejszy stan przejściowy to brak dostępu instruktora do danych uczestników, przy zachowaniu dostępu do nieosobowych danych eventu.

**Expected files/migrations affected:** migracja RLS; ewentualny scoped RPC i frontend Events; `app/admin/events/page.tsx`; testy macierzy ról i DTO. Calendar nie powinien wymagać zmiany, ponieważ ma już ograniczony feed bez PII instruktora.

**Regression risk:** `MEDIUM` — trzeba rozdzielić widoczność eventu od widoczności jego uczestników i potwierdzić oczekiwany workflow instruktora.

**Suggested tests:** instruktor direct SELECT `event_registrations` DENY; admin/pracownik global ALLOW; user own ALLOW i other DENY; widok Events instruktora nie pobiera `customer_*`, `promotion_*` ani `user_id`; scoped assignment ALLOW dopiero po wdrożeniu autorytatywnego modelu przypisania.

**Estimated implementation scope:** `MEDIUM`

---

## SEC-009 — brak technicznej retencji, anonimizacji i eksportu

**SEC-ID:** `SEC-009`

**Original severity:** `MEDIUM`

**Current status:** `CONFIRMED`

**Affected files / database objects:** `profiles`, `reservations`, `event_registrations`, `audit_logs`, `email_deliveries`, pola tokenów i snapshoty kontaktowe; brak centralnego workflow w repozytorium.

**Problem:** aktualny HEAD nadal nie definiuje kompletnej polityki czasu przechowywania, automatycznego wygaszania/anonimizacji, eksportu danych osoby ani bezpiecznej realizacji usunięcia konta z zależnościami historycznymi. Historyczne cleanupy testowe nie są lifecycle danych klientów.

**Real attack scenario:** po innym incydencie osoba atakująca uzyskuje większy historyczny zbiór PII niż potrzebny operacyjnie. Brak spójnego workflow może też powodować niekompletną realizację żądania dostępu/usunięcia albo przypadkowe naruszenie integralności FK/audytu podczas ręcznego cleanupu.

**Affected data:** profile i adresy, dane kontaktowe, deklaracje i weryfikacja, snapshoty rezerwacji i eventów, tokeny, historia płatności/obecności, e-mail metadata i audyty.

**Current exploitability:** `LOW` — finding zwiększa skutek przyszłego naruszenia i ryzyko prywatności, ale sam nie daje bezpośredniego dostępu atakującemu.

**Recommended remediation:** najpierw zatwierdzić macierz kategorii danych, podstaw prawnych i okresów retencji. Następnie wdrożyć idempotentne, atomowe zadania: wygaśnięcie tokenów, anonimizacja snapshotów po terminie, zachowanie minimalnego audytu, owner export oraz kontrolowane delete/anonymize. Job ma używać service context, limitowanych batchy, dry-run/report mode i audit bez PII. Projekt musi być zgodny z przyszłym `tenant_id`.

**Expected files/migrations affected:** dokument polityki; migracje pól lifecycle/statusów/indeksów; server-only job lub Edge Function/cron; owner export endpoint; testy DB i integracyjne. Dokładny zakres zależy od decyzji prawnej i biznesowej.

**Regression risk:** `HIGH` — nieodwracalne usuwanie/anonimizacja oraz zależności FK, raporty, płatności i audyty.

**Suggested tests:** dry-run i idempotencja; granice wieku; rekord tuż przed/po cutoff; zachowanie wymaganych danych finansowych/audytowych; brak osieroconych FK; export tylko właściciela; tenant scope przed SaaS; rollback dla częściowej awarii; zero PII w logach joba.

**Estimated implementation scope:** `LARGE`

---

## SEC-010 — możliwie słaba i niespójna polityka hasła

**SEC-ID:** `SEC-010`

**Original severity:** `MEDIUM`

**Current status:** `REQUIRES VERIFICATION`

**Affected files / database objects:**

- `app/register/page.tsx:38-39` — minimum 6 znaków
- `app/reset-password/page.tsx:100-101` — minimum 8 znaków
- `app/account/page.tsx:516-534` — minimum 8 znaków
- zewnętrzna konfiguracja Supabase Auth password policy, breached-password protection i rate limits

**Problem:** frontend pozostaje niespójny. Rejestracja akceptuje sześć znaków, a reset i zmiana hasła wymagają ośmiu. Repozytorium nie jest autorytatywnym źródłem server-side policy. Produkcyjny smoke używał silnych losowych haseł, więc nie zweryfikował dolnej granicy.

**Real attack scenario:** jeżeli produkcyjny Auth faktycznie dopuszcza hasła sześcioliterowe bez dodatkowych zabezpieczeń, nowe konta są bardziej podatne na password spraying, credential stuffing i przejęcie po ponownym użyciu słabego hasła. Sama różnica komunikatów może również wprowadzać użytkownika w błąd.

**Affected data:** sesje i całość danych dostępnych przejętemu kontu; dla staff potencjalnie dane wielu klientów.

**Current exploitability:** `LOW` do czasu potwierdzenia server-side minimum; wzrośnie do `MEDIUM`, jeśli produkcja rzeczywiście akceptuje słabe hasła.

**Recommended remediation:** wykonać read-only eksport/screenshot autorytatywnych ustawień Auth i udokumentować minimum, ochronę przed leaked passwords, CAPTCHA/rate limits oraz MFA dla staff. Następnie ustawić politykę po stronie Auth i współdzielony frontendowy kontrakt co najmniej na tę samą wartość; komunikat UI nie może być jedyną kontrolą. Zmianę wymagań dla istniejących użytkowników wdrażać z planem komunikacji.

**Expected files/migrations affected:** konfiguracja Supabase Auth; wspólny helper/constant walidacji; `app/register/page.tsx`; `app/reset-password/page.tsx`; `app/account/page.tsx`; testy Auth UI/integracyjne. Zwykle bez migracji SQL.

**Regression risk:** `MEDIUM` — możliwość zablokowania rejestracji/resetów i rozbieżność z ustawieniami dostawcy.

**Suggested tests:** granica `N-1/N`; rejestracja, reset i zmiana hasła mają identyczny kontrakt; server odrzuca hasło słabsze mimo pominięcia UI; rate limiting; bezpieczne komunikaty bez user enumeration; osobny smoke MFA/step-up dla staff, jeśli zostanie włączony.

**Estimated implementation scope:** `SMALL` dla weryfikacji i ujednolicenia UI, `MEDIUM` z rolloutem polityki/MFA.

---

## SEC-011 — przyszłe trasy admin są chronione fail-open

**SEC-ID:** `SEC-011`

**Original severity:** `MEDIUM`

**Current status:** `CONFIRMED`

**Affected files / database objects:** `middleware.ts:10-43,168-186`; wszystkie przyszłe `app/admin/**/page.tsx`.

**Problem:** middleware najpierw dopuszcza każdą rolę `admin`, `pracownik` lub `instruktor`, potem sprawdza znane prefiksy. Jeśli żaden wpis `routePermissions` nie pasuje, funkcja zwraca `NextResponse.next()`. Wszystkie obecne moduły są wymienione, więc nie ma potwierdzonej ekspozycji aktualnej strony; konstrukcja pozostaje jednak fail-open dla nowej trasy. Dodatkowo `startsWith` nie respektuje granic segmentu.

**Real attack scenario:** deweloper dodaje przyszłą stronę `/admin/billing`, `/admin/security` albo `/admin/tenants` z założeniem ochrony admin-only, ale zapomina dopisać mapę. Instruktor lub pracownik otrzymuje dostęp na poziomie middleware. RLS/RPC mogą ograniczyć dane, lecz UI i każdy słabiej chroniony endpoint tej strony stają się dostępne.

**Affected data:** zależne od przyszłej strony; potencjalnie ustawienia, dane użytkowników, raporty lub tenant administration.

**Current exploitability:** `LOW` — aktualnie nie ma niezamapowanej istniejącej strony z wrażliwą funkcją.

**Recommended remediation:** default deny dla każdej nieznanej ścieżki `/admin/*`, dopasowanie po pełnym segmencie oraz jedno źródło capability map używane przez middleware i nawigację. Dodać test enumerujący wszystkie `app/admin/**/page.tsx` i wymagający jawnej reguły lub jawnego wyjątku dla `/admin`.

**Expected files/migrations affected:** `middleware.ts`; ewentualny wspólny `lib/admin/route-permissions.ts`; middleware/route completeness tests. Bez SQL.

**Regression risk:** `LOW` — ryzykiem jest wyłącznie przypadkowe zablokowanie legalnej trasy, łatwe do wykrycia testem macierzy.

**Suggested tests:** nieznana `/admin/future` DENY; każdy istniejący page ma regułę; admin/pracownik/instruktor dla każdej trasy; granice `/admin/users` vs `/admin/users-extra`; query string bez wpływu; awaria Auth fail-closed bez redirect loop.

**Estimated implementation scope:** `SMALL`

---

## SEC-018 — bezpośredni staff DML do event registrations

**SEC-ID:** `SEC-018`

**Original severity:** `MEDIUM`

**Current status:** `PARTIALLY REMEDIATED`

**Affected files / database objects:**

- policies INSERT/UPDATE/DELETE na `public.event_registrations` w baseline `:10524-10532`
- `supabase/migrations/20260902120000_harden_public_table_sequence_acl.sql:36`
- `app/admin/events/page.tsx:1252-1255`
- kontrolowane RPC: `register_for_event`, `approve_event_registration`, `cancel_event_registration`, funkcje promocji

**Problem:** SEC-002 odebrał techniczne prawa i pozostawił `authenticated` tylko `SELECT`, `INSERT`, `DELETE`; tabelowy UPDATE został usunięty. To blokuje część pierwotnej powierzchni, ale admin/pracownik nadal mogą bezpośrednio wstawiać i usuwać dowolne event registrations przez RLS. Polityka UPDATE pozostała w katalogu, choć nie ma odpowiadającego table ACL. Frontend Events nadal próbuje bezpośrednio aktualizować `payment_status`, więc po hardeningu ACL ten call-site jest niespójny z aktualnym kontraktem i powinien zostać zastąpiony RPC, a nie ponownie otwarty grantem.

**Real attack scenario:** złośliwe/przejęte konto admina lub pracownika wykonuje bezpośredni INSERT/DELETE, omija walidację przejść, blokady pojemności, spójne auditowanie i kontrolowany kontrakt błędów. Może stworzyć nieprawidłowy zapis albo usunąć historię zapisu bez śladu oczekiwanego przez workflow.

**Affected data:** uczestnictwo i lista rezerwowa eventów, dane kontaktowe, payment status, tokeny/claimy promocji, pojemność oraz audyty.

**Current exploitability:** `MEDIUM` — wymaga roli admin/pracownik, ale pozostawione INSERT/DELETE są bezpośrednio osiągalne.

**Recommended remediation:** zinwentaryzować wszystkie writery, dodać brakujący atomowy RPC dla zmiany płatności event registration i przełączyć frontend. Następnie odebrać `authenticated INSERT/DELETE`, usunąć trzy mutacyjne policies tabeli oraz pozostawić mutacje wyłącznie SECURITY DEFINER RPC z kontrolą roli, blokadami i audytem. Nie przywracać column/table UPDATE w celu naprawy obecnego call-site.

**Expected files/migrations affected:** nowa migracja RPC/ACL/RLS; `app/admin/events/page.tsx`; helper/testy event registration actions; DB test macierzy direct DML i wszystkich przejść.

**Regression risk:** `HIGH` — event registration ma wiele stanów, kolejkę/promocję, pojemność, płatność i e-mail; trzeba zachować istniejące flow admin/pracownik/user.

**Suggested tests:** direct I/U/D jako anon/user/instruktor/pracownik/admin DENY; każdy dozwolony writer RPC ma pozytywną macierz ról; płatność przez RPC; approve/cancel/register/promotion bez regresji; blokady event→registration; audit dokładnie raz; denied/no_change bez auditu; testy współbieżności i rollback.

**Estimated implementation scope:** `MEDIUM`

---

## Priorytety

### P1 — zrobić teraz

1. **SEC-008** — bezpośredni globalny odczyt PII i tokenów przez instruktora jest obecnie osiągalny.
2. **SEC-005** — publiczny, niewygasający bearer token ujawnia PII po wycieku linku.
3. **SEC-007** — audit pozostaje zapisywalny przez klienta staff i nie jest wiarygodną granicą dowodową.
4. **SEC-018** — nadal istnieje direct INSERT/DELETE, a frontendowy payment UPDATE jest niespójny z utwardzonym ACL.
5. **SEC-006** — potwierdzony HTML injection; naprawa jest mała i powinna wejść bez oczekiwania na większe migracje.

### P2 — zrobić po P1

1. **SEC-010** — najpierw autorytatywnie zweryfikować remote Auth policy, potem ujednolicić server/UI.
2. **SEC-009** — zaprojektować i wdrożyć lifecycle PII po decyzji prawnej/biznesowej, przed większą akumulacją danych i przed SaaS.

### P3 — hardening / może poczekać

1. **SEC-011** — bieżące strony są zamapowane, ale middleware powinien zostać zmieniony na deny-by-default przed dodaniem kolejnych modułów admin/SaaS.

## Grupowanie

### Wspólny program: trusted database writers

SEC-007 i SEC-018 mają wspólną przyczynę: zaufanie do bezpośredniego DML klienta `authenticated` zamiast do kontrolowanych RPC. Powinny być projektowane razem, aby actor/audit/transition contracts były spójne, ale wdrażane jako dwie osobne migracje i dwa checkpointy. Łączenie ich w jeden duży deploy zwiększyłoby blast radius i utrudniło rollback.

### Wspólny obszar: token i wiadomości

SEC-005 i SEC-006 dotyczą flow komunikacji z klientem, ale nie powinny być jedną remediation. SEC-005 zmienia model tokenu i DB/API, natomiast SEC-006 jest lokalnym kodowaniem HTML. Wspólny release nie daje korzyści bezpieczeństwa współmiernej do ryzyka.

### Auth perimeter

SEC-010 i SEC-011 należy śledzić pod jednym epicem Auth, ale naprawiać osobno: pierwszy wymaga decyzji/config dostawcy, drugi jest deterministyczną zmianą routingu aplikacji.

## Proponowana kolejność remediation

1. **SECURITY REMEDIATION 04 — SEC-008 Instructor Event Registration Scope**

   Odebranie globalnego tabelowego PII instruktora; minimalny/scoped reader tylko jeśli istnieje uzasadniony model przypisania.

2. **SECURITY REMEDIATION 05 — SEC-005 Expiring Check-in Capability**

   Projekt i migracja token lifecycle, eliminacja publicznego PII oraz kontrolowana kompatybilność istniejących QR/linków.

3. **SECURITY REMEDIATION 06 — SEC-007 Trusted Audit Writes**

   Revoke direct INSERT, usunięcie policy client insert, pełna regresja wszystkich wewnętrznych audit writerów.

4. **SECURITY REMEDIATION 07 — SEC-018 Event Registration Writer Boundary**

   RPC dla brakujących operacji, switch call-sites, a następnie revoke direct I/U/D i usunięcie mutacyjnych policies.

5. **SECURITY REMEDIATION 08 — SEC-006 Event Email HTML Encoding**

   Wspólny encoder oraz testy wszystkich dynamicznych wartości w dwóch nadal podatnych szablonach.

6. **SECURITY REMEDIATION 09 — SEC-010 Auth Password Policy Verification**

   Read-only evidence remote config, decyzja minimum/MFA, server-side rollout i jeden kontrakt UI.

7. **SECURITY REMEDIATION 10 — SEC-009 PII Lifecycle**

   Najpierw zatwierdzona polityka, następnie etapowany export/expiry/anonymization job z dry-run i audit.

8. **SECURITY REMEDIATION 11 — SEC-011 Admin Route Default Deny**

   Centralna mapa capabilities, segment-safe matching i automatyczny completeness test przed rozbudową SaaS.

Remediation 08 jest technicznie mała i może być wykonana równolegle organizacyjnie, ale nie powinna opóźniać 04–07. Remediation 05 i 10 wymagają osobnego zatwierdzenia projektu danych przed implementacją.

## Tabela kolejności

| Kolejność | SEC-ID | Status | Priorytet | Zakres | Ryzyko regresji |
|---:|---|---|---|---|---|
| 1 | SEC-008 | CONFIRMED | P1 | RLS + ewentualny scoped RPC/UI | MEDIUM |
| 2 | SEC-005 | CONFIRMED | P1 | DB token lifecycle + API/UI/e-mail | HIGH |
| 3 | SEC-007 | CONFIRMED | P1 | audit ACL/RLS/RPC tests | MEDIUM |
| 4 | SEC-018 | PARTIALLY REMEDIATED | P1 | event registration RPC + ACL/RLS/UI | HIGH |
| 5 | SEC-006 | CONFIRMED | P1 | server e-mail helpers/tests | LOW |
| 6 | SEC-010 | REQUIRES VERIFICATION | P2 | Supabase Auth config + Auth UI | MEDIUM |
| 7 | SEC-009 | CONFIRMED | P2 | policy + lifecycle jobs/export | HIGH |
| 8 | SEC-011 | CONFIRMED | P3 | middleware + route tests | LOW |

## Wniosek

Żaden z ośmiu pierwotnych findingów MEDIUM nie jest obecnie w pełni zamknięty. Najważniejszą zmianą klasyfikacji jest SEC-008: z `LIKELY` na `CONFIRMED`, z wysoką bieżącą exploitability w ramach konta instruktora. SEC-018 jest częściowo ograniczony przez SEC-002, lecz nadal wymaga zamknięcia direct INSERT/DELETE oraz naprawy niespójnego frontendowego payment writer. SEC-010 pozostaje jedynym findingiem wymagającym autorytatywnej weryfikacji konfiguracji zewnętrznej przed decyzją o zmianie.
