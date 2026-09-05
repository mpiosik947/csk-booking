# CSK Booking — ETAP 8 Events / Trainings

## Gap analysis i plan implementacji

Data przeglądu: 5 września 2026 r.  
Zweryfikowany HEAD: `63e05eb`  
Zakres: `/events`, `/admin/events`, `/my-events`, powiązane API, RPC, SQL, e-maile i testy.

Analiza była statyczna i read-only. Nie uruchamiano produkcyjnych operacji, nie zmieniano bazy, konfiguracji ani implementacji. Jedynym utworzonym plikiem jest ten raport.

## Podsumowanie wykonawcze

ETAP 8 jest funkcjonalny, ale pozostaje **PARTIAL**. Krytyczne ścieżki — publiczny odczyt dostępności, atomowy zapis, lista rezerwowa, potwierdzenie promocji, anulowanie, administracyjne CRUD i przypisywanie zasobów — istnieją i są chronione przez backend. Moduł nie jest jednak domknięty produktowo z trzech powodów:

1. Istnieją dwa potwierdzone problemy poprawności prezentacji: panel admina błędnie upraszcza część statusów płatności, a `/my-events` wylicza 72-godzinne okno anulowania w strefie przeglądarki zamiast w `Europe/Warsaw` używanej przez backend.
2. Duże listy są pobierane bez paginacji; administracyjna lista uczestników używa `select('*')` i przekazuje do przeglądarki więcej pól niż wymaga ekran.
3. Brakuje browser/E2E dla kompletnego cyklu eventu oraz dopracowanego widoku uczestników na telefonach.

Nie stwierdzono nowej oczywistej regresji bezpieczeństwa. Odłożony model dostępu instruktora (SEC-008) pozostaje poza zakresem.

## 1. Aktualny inventory

### Publiczne `/events`

| Funkcja | Status | Stan faktyczny |
|---|---|---|
| Lista eventów | DONE | Jedno wywołanie `get_public_event_availability_v1()` zwraca aktywne eventy w stabilnej kolejności. |
| Szczegóły eventu | DONE | Karty oraz rozwijany/modalny widok pokazują opis, termin, lokalizację, cenę i limit. |
| Autorytatywna dostępność | DONE | `registered_count`, `reserve_count`, `available_spots` i `sold_out` są liczone w DB, niezależnie od owner-scoped RLS. Produkcyjny smoke został wcześniej zakończony PASS. |
| Widoczność dostępności dla anon | PARTIAL | RPC świadomie zezwala `anon`, lecz UI ukrywa bieżące liczniki i status przed niezalogowanym użytkownikiem, pokazując tylko limit oraz zachętę do logowania. |
| Zapis | DONE | Zalogowany użytkownik przechodzi przez modal potwierdzenia i atomowy `register_for_event`; frontend odświeża dane z autorytatywnego RPC. |
| Lista rezerwowa | DONE | Backend wybiera `registered` lub `reserve`; publiczny helper wymusza kolejkę rezerwową, gdy `reserve_count > 0`. |
| Sold out | DONE | Backend nie zwraca wartości ujemnych, a UI rozpoznaje brak miejsc i ścieżkę rezerwową. Pełna informacja jest widoczna dopiero po logowaniu. |
| Potwierdzenie promocji | DONE | Osobna strona `/events/confirm/[token]` jest read-only w GET; mutacja wymaga zalogowanego właściciela i POST do kontrolowanego API. |
| Anulowanie | PARTIAL | Nie jest wykonywane na `/events`; prawidłowa owner-scoped operacja istnieje w `/my-events`. Publiczna strona nie prowadzi użytkownika bezpośrednio do zarządzania istniejącym zapisem. |
| Payment state | N/A | Publiczna lista ofert nie musi ujawniać indywidualnego statusu płatności. Status własnego zapisu jest w `/my-events`. |
| Loading / empty / error | DONE | Są jawne stany ładowania, pustej listy i kontrolowanego błędu; malformed RPC response jest fail-closed. |
| Event nieaktywny/anulowany | PARTIAL | `is_active=false` usuwa event z publicznego RPC. Nie istnieje osobny publiczny status „anulowany”. Aktywny event historyczny nie jest odfiltrowany przez RPC ani UI. |
| Mobile UX | DONE z zastrzeżeniem | Karty, przyciski i modale są responsywne i zawijają tekst; brak browser smoke przy 320/375/430 px. |

Istotny szczegół: RPC filtruje tylko `is_active=true`. Jeżeli operator nie dezaktywuje zakończonego eventu, pozostaje on na publicznej liście, choć `register_for_event` odrzuci zapis po rozpoczęciu eventu. To bezpieczne dla danych, ale mylące dla użytkownika.

### Administracyjne `/admin/events`

| Funkcja | Status | Stan faktyczny |
|---|---|---|
| Lista eventów | DONE | Eventy i przypisane zasoby są ładowane z jawną relacją self-FK `parent_lane_id`; parser jest fail-closed i ma ochronę przed stale response. |
| Tworzenie | DONE | `admin_create_event_v2` obsługuje hierarchy-aware lane assignment i konflikt zasobów. |
| Edycja | DONE | `admin_update_event_v2` zachowuje przypisania, w tym nieaktywny zasób już używany przez event. |
| Aktywacja/dezaktywacja | DONE | `admin_set_event_active_v2`; brak call-site'ów V1. |
| Lane assignment | DONE | Obsługiwane są standalone lanes, parent i positions, czytelne hierarchy labels oraz wiele zasobów. |
| Capacity | DONE | Limit uczestników jest edytowany i egzekwowany przez atomowy backend zapisu. |
| Uczestnicy | PARTIAL | Lista działa na żądanie, ale pobiera wszystkie rekordy eventu przez `select('*')`, bez paginacji i wyszukiwania. |
| Reserve list | DONE | Oddzielna lista, deterministyczna kolejność po `created_at` i `id`. |
| Promocja reserve | PARTIAL | Automatyczna promocja następuje po zwolnieniu miejsca przez anulowanie. Istnieje API wysyłki promocji, ale panel nie ma jawnej akcji uruchomienia/ponowienia promocji niezależnie od anulowania. |
| Payment marking | PARTIAL / BROKEN UI | `mark_event_registration_paid` działa, ale widok rozpoznaje tylko `paid_on_site`; `paid`, `unpaid`, `free` i `voucher` są prezentowane jako „Płatność na miejscu”. |
| Cancellation | DONE | Kontrolowane API anuluje zapis i, gdy zwolniono miejsce, uruchamia promocję rezerwy. |
| E-maile | PARTIAL | Potwierdzenie rejestracji i promocji istnieje. Brak osobnego e-maila o anulowaniu rejestracji eventowej i brak payment-related e-maila; są to decyzje produktowe, nie potwierdzone błędy. |
| Statusy | PARTIAL | `registered`, `approved`, `reserve`, `cancelled` są rozdzielone. Historyczny `participant` jest różnie traktowany przez warstwy i wymaga decyzji o kanonicznej semantyce. |
| Loading / empty / error | DONE z zastrzeżeniem | Kontrolowane stany istnieją; lista uczestników nie ma osobnego przycisku retry. |
| Mobile UX | PARTIAL | Główne karty i formularze są responsywne, ale listy uczestników pozostają szerokimi tabelami z poziomym scrollem i małymi akcjami. |

Panel jest rozbudowanym, monolitycznym komponentem. To nie jest samo w sobie błąd, ale zwiększa ryzyko zmian i utrudnia testowanie realnych interakcji.

### Użytkownika `/my-events`

| Funkcja | Status | Stan faktyczny |
|---|---|---|
| Lista własnych zapisów | DONE | Jawne `.eq('user_id', user.id)` oraz owner-scoped RLS. |
| Upcoming vs history | DONE | Widok rozdziela bieżące i historyczne wpisy oraz sortuje je chronologicznie. |
| Status zapisu | DONE | Czytelne etykiety dla `registered`, `approved`, `reserve`, `participant` i `cancelled`. |
| Płatność | DONE | Używany jest współdzielony `getPaymentStatusLabel`, obejmujący aktywne statusy płatności. |
| Anulowanie | PARTIAL / BROKEN UX | Backend prawidłowo stosuje `Europe/Warsaw` i limit 72 godzin. Frontend tworzy lokalny `Date`, więc w innej strefie czasowej może błędnie pokazać albo ukryć akcję. Backend nadal odrzuca niedozwoloną mutację. |
| Potwierdzenie promocji | PARTIAL | Bezpieczny flow działa z linku e-mail, ale `/my-events` nie eksponuje oczekującej akcji ani bezpośredniego przejścia do potwierdzenia. Token słusznie nie jest zwracany w liście. |
| Aktualizacja po anulowaniu | DONE | Lokalny rekord zmienia status po sukcesie kontrolowanego API. |
| Historia | DONE z zastrzeżeniem | Jest czytelna, lecz wszystkie własne zapisy są pobierane bez limitu/paginacji. |
| Loading / empty / error | DONE z zastrzeżeniem | Stany są kontrolowane; brak dedykowanego retry i formalnego parsera odpowiedzi. |
| Mobile UX | DONE z zastrzeżeniem | Widok kart dobrze skaluje się w kodzie CSS; brak browser testów na wymaganych szerokościach. |

`/my-events` rzutuje wynik zapytania na typ bez walidacji struktury. Nie jest to znany exploit, ale odstaje od fail-closed parserów używanych w public availability i admin events.

## 2. Search, filtry i paginacja

| Moduł | Search | Daty | Active/upcoming/history | Status | Paginacja | Stabilny sort | Empty | Reset | URL params |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `/events` | Nie | Nie | Nie | Nie | Nie | Tak, DB | Tak | N/A | Nie |
| `/admin/events` | Nie | Nie | Tylko all/active/hidden | Tak, `is_active` | Nie | Tak, nearest/latest + tie-breaker | Tak | Przez wybór `all` | Nie |
| `/my-events` | Nie | Nie | Automatyczny podział upcoming/history | Nie | Nie | Tak funkcjonalnie; brak jawnego tie-breakera ID | Tak | N/A | Nie |

Najbardziej użyteczne dziś:

- `/events`: domyślne odseparowanie nadchodzących od zakończonych; wyszukiwanie dopiero przy większej liczbie ofert.
- `/admin/events`: search po tytule/lokalizacji, upcoming/past/inactive i paginacja; status `is_active` nie zastępuje czasu wydarzenia.
- `/my-events`: paginacja historii; prosty filtr statusu jest pomocny, lecz nie jest blockerem dla małej liczby zapisów.
- lista uczestników: search/status/payment oraz paginacja są ważniejsze niż kolejne filtry na samych eventach, ponieważ ekran przetwarza PII i może rosnąć szybciej.

## 3. Public Events UX

### Mocne strony

- Jedno autorytatywne i PII-free źródło prawdy.
- Atomowy backend pozostaje ostateczną ochroną przed overbookingiem.
- Duplicate registration, sold out i reserve mają kontrolowane komunikaty.
- Po zapisie dostępność jest odświeżana; stara odpowiedź nie nadpisuje nowszego kontekstu.
- Formularz nie odsłania surowych błędów backendu.

### Luki

- Anon ma prawo do PII-free availability, ale nie widzi jej w UI. To wymusza logowanie przed poznaniem podstawowej dostępności.
- Aktywne, lecz rozpoczęte/zakończone wydarzenie może pozostać ofertą publiczną.
- Nie ma bezpośredniej ścieżki „zarządzaj moim zapisem”; użytkownik musi sam przejść do `/my-events`.
- Brak filtrów nie jest obecnie udowodnionym błędem; filtr upcoming/history ma jednak bezpośrednią wartość przy rosnącej historii.

## 4. Admin Events UX

Administrator może tworzyć, edytować, aktywować, dezaktywować, przypisywać zasoby, oglądać uczestników, anulować zapisy i oznaczać płatność. Największe problemy operacyjne to:

1. Brak search oraz rozróżnienia upcoming/past wymusza skanowanie całej listy.
2. Uczestnicy, rezerwa i anulowani są szerokimi tabelami bez mobilnej prezentacji kartowej.
3. Status płatności jest niepoprawnie upraszczany do dwóch tekstów.
4. Automatyczna promocja rezerwy jest ukryta w flow anulowania; brak jawnej informacji o ostatnim wyniku i kontrolowanej akcji ponowienia.
5. Pobierane są wszystkie kolumny rejestracji, choć ekran potrzebuje ograniczonego DTO.
6. Brak paginacji participant list może zwiększyć czas odpowiedzi i ilość PII obecnego w pamięci przeglądarki.

## 5. My Events UX

Podział na nadchodzące i historię jest dobry, a statusy zapisów i płatności są czytelne. Najważniejszą korektą jest użycie wspólnego, warszawskiego modelu czasu przy obliczaniu widoczności anulowania. `window.confirm` działa, ale jest słabszy dostępnościowo i wizualnie niż istniejące kontrolowane modale. Brak paginacji historii oraz retry to późniejszy polish.

Potwierdzenie promocji z bezpiecznego linku działa. Dodanie tokenu do listy użytkownika byłoby niewłaściwe; ewentualny CTA powinien korzystać z nowego, bezpiecznego owner-scoped kontraktu albo kierować użytkownika do wiadomości e-mail, nie ujawniając tokenu.

## 6. Spójność business flow

### Status rejestracji

| Status | Backend capacity | Public availability | Admin | My Events |
|---|---|---|---|---|
| `registered` | Zajmuje miejsce | Liczony | Uczestnik | Zapisany |
| `approved` | Zajmuje miejsce | Liczony | Uczestnik | Potwierdzony |
| `reserve` | Nie zajmuje miejsca | Liczony osobno | Rezerwa | Lista rezerwowa |
| `cancelled` | Nie zajmuje miejsca | Pomijany | Anulowani | Anulowany |
| `participant` | Traktowany jako aktywny przez część starszych flow | Nie jest liczony | Uczestnik | Uczestnik |

Cztery wymagane statusy są spójne. `participant` jest historycznym/transitional statusem: widoki traktują go jako aktywny, lecz publiczny capacity contract liczy tylko `registered` i `approved`, a anulowanie `participant` nie sygnalizuje zwolnienia miejsca. Przed zmianą należy najpierw sprawdzić, czy taki status występuje w realnych aktywnych danych. Bez tego nie wolno zgadywać nowej semantyki.

### Status płatności

Wspólny helper rozpoznaje `pay_on_site`, `paid`, `paid_on_site`, `unpaid`, `free` i `voucher`. `/my-events` go używa. `/admin/events` ma lokalne sprawdzenie tylko `paid_on_site`, dlatego jego tekst nie odpowiada części rzeczywistych statusów. Backendowa mutacja oznaczenia płatności ustawia `paid_on_site` i pozostaje spójna.

### Reserve → registered i cancellation

- Zwolnienie miejsca po anulowaniu `registered`/`approved` uruchamia atomową promocję najstarszych pozycji reserve.
- Użytkownik otrzymuje link, a właściwe potwierdzenie jest owner-scoped i mutujące wyłącznie przez POST.
- Po potwierdzeniu status przechodzi na `registered`; powtórzenie jest kontrolowane.
- Interfejs aktualizuje anulowany wpis lokalnie, ale nie odświeża całej listy uczestników i wszystkich konsekwencji promocji bez kolejnego pobrania.

## 7. Funkcjonalny przegląd e-maili

| Flow | Status | Uwagi |
|---|---|---|
| Potwierdzenie rejestracji | DONE | Delivery claim, rate limit, bezpieczny HTML; błąd dostawy nie cofa poprawnego zapisu. |
| Potwierdzenie miejsca na reserve | DONE | Ten sam endpoint rozróżnia wariant po statusie rejestracji. |
| Oferta/promocja z reserve | DONE | Automatycznie uruchamiana po zwolnieniu miejsca; zawiera link do potwierdzenia. |
| Potwierdzenie wykorzystania promocji | DONE | Wysyłane po poprawnej mutacji owner-scoped. |
| Anulowanie rejestracji eventowej | MISSING / PRODUCT DECISION | Brak dedykowanego maila; nie mylić z e-mailem anulowania rezerwacji osi. |
| Zmiana statusu płatności | MISSING / PRODUCT DECISION | Brak osobnego payment-related e-maila. |

Brak dwóch ostatnich wiadomości nie narusza obecnego kontraktu bezpieczeństwa. Należy je dodać tylko po decyzji biznesowej o oczekiwanej komunikacji, idempotency i limicie wysyłki.

## 8. Mobile UX

Ocena wynika z kodu i klas responsywnych; brak dedykowanego browser smoke dla Events.

| Szerokość | `/events` | `/admin/events` | `/my-events` |
|---|---|---|---|
| 320 px | Prawdopodobnie poprawne karty i modale | Ryzyko poziomego scrolla tabel uczestników i zbyt małych akcji | Prawdopodobnie poprawne karty |
| 375 px | Prawdopodobnie poprawne | Te same problemy tabel | Prawdopodobnie poprawne |
| 430 px | Prawdopodobnie poprawne | Tabele nadal wymagają scrolla | Prawdopodobnie poprawne |
| Tablet | Czytelny grid | Formularze poprawne, participant table nadal gęsta | Czytelne karty |
| Desktop | Czytelny | Pełna funkcjonalność, lecz lista uczestników jest informacyjnie przeładowana | Czytelny |

Modalne formularze mają ograniczenie wysokości i wewnętrzny scroll. Najwyższy priorytet mobile to participant management: karty na małych ekranach, większe touch targets i jasna hierarchia status/płatność/akcje.

## 9. Browser/E2E coverage

Playwright jest skonfigurowany z ochroną lokalnego Supabase, ale obecne specy dotyczą tworzenia rodzin osi oraz responsywności Reports. Nie istnieje Events E2E.

| Krytyczny flow | Pokrycie niższego poziomu | Browser/E2E |
|---|---|---|
| 1. Public event list | RPC/SQL i parser/source tests | Brak |
| 2. Registration | DB/API kontrakt częściowo | Brak |
| 3. Sold out | Public helper/SQL | Brak |
| 4. Reserve | Helper/SQL i mail helper | Brak |
| 5. Promotion | SQL/server helpers | Brak |
| 6. Confirmation | 7 testów kontraktu + DB security test | Brak |
| 7. Cancellation | SQL/API source coverage | Brak |
| 8. My Events | Tylko ogólny safe-error source check | Brak |
| 9. Admin participants | Source/pure helper tests | Brak |
| 10. Mobile layouts | Klasy CSS/source | Brak |

Aktualne focused testy obejmują co najmniej:

- `app/admin/events/page.test.mjs`: 23 testy,
- `lib/admin/events/event-management.test.mjs`: 74 testy,
- `lib/public-event-availability.test.mjs`: 7 testów,
- `lib/server/event-reserve-confirmation-contract.test.mjs`: 7 testów,
- aktywne DB testy availability, confirmation i direct-DML oraz legacy testy modelu/event writers.

To jest solidne pokrycie kontraktów i czystej logiki, ale mock/source assertions nie potwierdzają renderowania, nawigacji, modali, refreshu i responsywności w prawdziwej przeglądarce.

## 10. Security boundary — szybka kontrola regresji

**SECURITY REGRESSION: NONE CONFIRMED.**

- Publiczne `/events` korzysta wyłącznie z zatwierdzonego PII-free availability DTO.
- `anon` i ordinary user nie otrzymują administracyjnej listy uczestników.
- Owner list `/my-events` jest ograniczona do `user.id` i RLS.
- Mutacje rejestracji/potwierdzenia/anulowania przechodzą przez kontrolowane RPC/API.
- Nie znaleziono użycia `service_role` w browserowych call-site'ach Events.
- SEC-008/instructor access pozostaje świadomie odłożony i bez zmian.

Zidentyfikowany hardening, nie nowa regresja: admin participant query powinno zastąpić `select('*')` minimalnym DTO. Obecny admin ma prawo do tych danych, lecz wewnętrzne tokeny i pola dostawy nie są potrzebne w przeglądarce.

## 11. Performance

| Obszar | Ocena |
|---|---|
| Public availability | Jedno RPC, bez N+1. Liczy agregaty dla wszystkich rejestracji i zwraca wszystkie aktywne eventy; bez ograniczenia daty/paginacji będzie rosło wraz z historią. |
| Admin event list | Pobiera wszystkie eventy z relacjami lane; lokalne filtrowanie i sortowanie. Brak paginacji. |
| My Events | Pobiera pełną historię użytkownika. Brak paginacji. |
| Participant list | Jedno zapytanie dopiero po wybraniu eventu, więc brak N+1 na liście eventów. Pobiera jednak wszystkie wiersze i wszystkie kolumny. |
| Historyczne zakresy | Aktywne stare eventy pozostają w publicznym zbiorze, a admin/my-events nie mają backendowych granic zakresu. |
| Indeksy | Istnieje indeks wspierający event/status/created_at, ale nie rozwiązuje payloadu `select('*')` ani braku limitów. |

Najpierw należy ograniczyć participant DTO i dodać backendową paginację. Publiczny reader można rozszerzać dopiero na podstawie rzeczywistej skali; obecne jedno RPC jest znacznie lepsze niż per-event/N+1.

## 12. Plan implementacji

### EVENTS-8A — spójność statusów i domknięcie business UX

**Cel:** usunąć potwierdzone błędy prezentacji i uczynić istniejące flow jednoznacznymi bez przebudowy modelu.

**Zakres:**

- użyć wspólnego mapowania statusów płatności w admin events,
- ujednolicić obliczanie 72-godzinnego okna anulowania z `Europe/Warsaw`,
- pokazać anonowi autorytatywną PII-free dostępność, którą już legalnie zwraca RPC,
- odseparować rozpoczęte/zakończone eventy od aktualnej oferty albo jawnie je oznaczyć,
- zastąpić admin `event_registrations.select('*')` minimalnym, walidowanym DTO,
- opisać w panelu wynik automatycznej promocji i umożliwić kontrolowane ponowienie istniejącego flow, jeżeli backend zwraca stan do ponowienia,
- wykonać read-only check występowania aktywnego statusu `participant`; dopiero na podstawie wyniku zatwierdzić jego semantykę,
- e-mail anulowania i payment e-mail pozostawić jako osobną decyzję produktową.

**Przewidywane pliki:**

- `app/events/page.tsx`,
- `app/my-events/page.tsx`,
- `app/admin/events/page.tsx`,
- `lib/admin/events/event-management.ts`,
- `lib/payment-status.ts` lub mały współdzielony helper czasu Events,
- odpowiadające pliki `*.test.mjs`.

**DB:** nie dla potwierdzonych korekt UI/DTO. Warunkowo tak tylko wtedy, gdy analiza danych wykaże aktywne użycie `participant` lub potrzebny będzie nowy owner-scoped stan promocji. Nie zmieniać semantyki bez tego dowodu.

**Ryzyko:** MEDIUM. Dotyka czasu anulowania, statusów i danych uczestników, ale nie wymaga zmiany atomowych writerów.

**Deployment:** APP ONLY dla podstawowego zakresu. Jeśli pojawi się addytywny kontrakt DB: DB FIRST, potem aplikacja.

**Testy:** focused public/admin/my-events, strefy czasowe i DST, wszystkie statusy płatności, exact participant DTO/no tokens, reserve promotion result/retry, Node, TypeScript, build, ESLint changed files, DB regression bez zmiany writerów.

**DONE:** brak błędnych etykiet płatności; UI i backend zgadzają się co do okna anulowania; anon widzi autorytatywną dostępność; stare eventy nie wyglądają jak otwarta oferta; admin browser nie otrzymuje internal fields; status `participant` ma udokumentowaną, przetestowaną decyzję.

### EVENTS-8B — skalowalne listy, search, filtry i paginacja

**Cel:** zachować responsywność i minimalizację danych przy rosnącej liczbie eventów, zapisów i historii.

**Zakres:**

- dodać minimalne, paginowane kontrakty read dla admin event list i participant management,
- rozważyć paginowany owner-scoped read dla `/my-events`,
- admin: search, upcoming/past/inactive, data, status/payment uczestnika,
- my-events: paginacja historii i opcjonalny status,
- public: upcoming jako domyślny zakres; search/date dopiero jeśli uzasadnia je liczba ofert,
- stabilna kolejność z jednoznacznym tie-breakerem,
- filtry odtwarzane z URL, reset i page reset po zmianie filtra,
- zachować dokładnie obecny model ról, w tym odłożony SEC-008.

**Przewidywane pliki:** nowe addytywne migracje i DB testy read RPC, `app/admin/events/page.tsx`, `app/my-events/page.tsx`, ewentualnie `app/events/page.tsx`, nowe parsery w `lib/` i focused tests.

**DB:** YES — server-side pagination i bezpieczne filtrowanie participant PII powinny mieć autorytatywny kontrakt DB, nie browser bulk fetch.

**Ryzyko:** HIGH. Nowe read contracts dotykają PII, RLS/ACL i spójności KPI/counts z paginowanymi detalami.

**Deployment:** DB FIRST dla addytywnych RPC, następnie APP; stary klient musi działać po migracji. Po przełączeniu osobno ocenić usunięcie starych call-site'ów.

**Testy:** macierz ról, PII allowlist, parent/position labels, status/payment/date/search combinations, page boundaries i stabilność, large synthetic dataset lokalnie, owner isolation, malformed/stale response, pełne DB/Node/TypeScript/build.

**DONE:** żadna lista nie wymaga nieograniczonego bulk fetch; filtry i szczegóły mają ten sam zakres; URL odtwarza widok; page size i kolejność są deterministyczne; browser otrzymuje tylko wymagane pola.

### EVENTS-8C — mobile i browser workflow polish

**Cel:** potwierdzić realne zachowanie kompletnego flow i domknąć responsywność.

**Zakres:**

- mobilne karty participant/reserve/cancelled zamiast obowiązkowego szerokiego table scroll,
- minimum 44–48 px dla głównych touch actions,
- spójne confirmation, loading, empty, error i retry,
- rozbić monolityczne fragmenty admin page na testowalne komponenty bez zmiany business logic,
- lokalny Playwright dla 10 krytycznych flow i szerokości 320/375/430/tablet/desktop,
- używać wyłącznie syntetycznego fixture i lokalnego Supabase guard.

**Przewidywane pliki:** komponenty Events w `app/`/`components/`, `tests/e2e/events-workflows.spec.ts`, istniejąca konfiguracja Playwright bez osłabienia local-only guard, testy komponentów/helperów.

**DB:** NO, poza korzystaniem z wcześniej wdrożonych addytywnych kontraktów EVENTS-8B.

**Ryzyko:** MEDIUM. Główne ryzyko to regresja akcji w responsywnych wariantach i niestabilne fixture E2E.

**Deployment:** APP ONLY.

**Testy:** public list, registration, sold out, reserve, promotion, confirmation, cancellation, my-events, admin participants; keyboard/focus; wszystkie docelowe viewporty; brak overflow i double actions; pełna regresja.

**DONE:** 10 krytycznych flow przechodzi w przeglądarce; admin participant management jest używalny od 320 px; brak poziomego overflow strony; error/retry są kontrolowane; desktop nie ma regresji.

## Końcowy status

```text
ETAP 8 EVENTS/TRAININGS:
PARTIAL

PUBLIC EVENTS:
CORE DONE / UX PARTIAL — authoritative PII-free availability i atomowy zapis działają; anon nie widzi liczników, a zakończone aktywne eventy nie są odseparowane.

ADMIN EVENTS:
PARTIAL — CRUD, hierarchy, uczestnicy, reserve, cancellation i payment writer działają; błędne etykiety części statusów płatności, brak skalowalnego participant read i słaby mobile table UX.

MY EVENTS:
PARTIAL — owner list, statusy, płatność, historia i cancellation działają; frontendowe okno anulowania nie używa jawnie Europe/Warsaw, brak paginacji/retry i browser tests.

MISSING / BROKEN:
BROKEN: admin payment labels dla paid/unpaid/free/voucher; my-events cancellation eligibility poza Europe/Warsaw. MISSING/PARTIAL: paginowane participant/history reads, admin search/upcoming-past, jawny promotion retry UX, Events Playwright, mobilne participant cards. Event cancellation/payment e-mails wymagają decyzji produktowej.

UX RISKS:
Anon nie widzi publicznej dostępności mimo bezpiecznego RPC; aktywny historyczny event wygląda jak aktualna oferta; admin participant tables są trudne na telefonie; brak browserowej weryfikacji kompletnego cyklu.

PERFORMANCE RISKS:
Admin events, my-events i participant list są niepaginowane; participant list pobiera select('*'); public RPC nie ogranicza aktywnych eventów czasowo. Nie stwierdzono N+1 na głównych listach.

SECURITY REGRESSION:
NONE CONFIRMED — SEC-008 pozostaje odłożony. Zalecane ograniczenie admin participant DTO usuwa zbędny internal-field payload.

RECOMMENDED FIRST IMPLEMENTATION:
EVENTS-8A — spójność statusów, czasu anulowania, publicznej prezentacji availability i minimalnego participant DTO.

DB CHANGE REQUIRED:
YES — dla pełnego ETAPU 8B (server-side pagination/filtering i minimalne read contracts); podstawowy EVENTS-8A może pozostać APP ONLY, o ile status participant nie wymaga zmiany kontraktu.

DEPLOYMENT MODEL:
DB FIRST — addytywne read contracts EVENTS-8B; APP ONLY dla niezależnych korekt EVENTS-8A/8C.

NEXT 3:
1. EVENTS-8A — correctness i missing business UX.
2. EVENTS-8B — minimalne paginowane read contracts, search i filtry.
3. EVENTS-8C — mobile participant UX i pełne Playwright/E2E.
```

