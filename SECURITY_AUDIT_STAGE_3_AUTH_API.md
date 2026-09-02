# CSK Booking — etap 3: Auth, role i API Next.js

## Zakres

Przejrzano middleware, strony logowania/rejestracji/resetu, callback Auth, 8 route handlers, wszystkie wywołania `auth.getUser()`, klienty Supabase, formularze administracyjne oraz miejsca renderowania dynamicznego HTML. Nie znaleziono Server Actions ani `dangerouslySetInnerHTML`.

## Middleware i role

`middleware.ts` chroni `/admin/:path*`, weryfikuje użytkownika przez Supabase Auth i rolę z `profiles`. Mapa aktualnych tras jest jawna i poprawnie zawęża wrażliwe moduły. Middleware nie jest jedynym zabezpieczeniem: route calendar ma kontrolę serwerową, a pozostałe zapisy administracyjne opierają się na RLS/RPC.

Istotne obserwacje:

- brak użytkownika lub Auth error przekierowuje do loginu;
- brak/awaria profilu kieruje do dashboardu;
- aktualne znane trasy mają mapę ról;
- nowa, niewymieniona trasa `/admin/*` dziedziczy bazowe uprawnienie wszystkich trzech ról staff — finding SEC-011;
- logika endpointów używa wspólnego klasyfikatora Auth i rozróżnia brak sesji, 403, awarię Auth i nieznany błąd.

## API matrix

| Route | Auth | Ownership/rola | Mutacja | Ocena |
| --- | --- | --- | --- | --- |
| `/api/admin/calendar-feed` | Bearer + getUser | jawny role check | brak | fail-closed, instructor DTO bez reservations |
| `/api/cancel-event-registration` | Bearer | RPC owner/staff | tak przez RPC | kontrolowany kontrakt |
| `/api/create-reservation` | Bearer | `auth.uid()` w V2 RPC | tak przez RPC | allowlista input, brak fallback/retry |
| `/api/register-event` | Bearer | `auth.uid()` w RPC | tak przez RPC | allowlista input |
| `/api/send-event-registration-confirmation` | Bearer | owner/status przed prepare | e-mail/RPC | rate limit, claim, idempotencja |
| `/api/send-event-reserve-promotion` | serwerowy workflow | service-only RPC | e-mail/RPC | techniczny endpoint; ACL RPC zawężone |
| `/api/send-reservation-cancellation` | Bearer | owner lub staff | e-mail | service role dopiero po sprawdzeniu caller |
| `/api/send-reservation-confirmation` | Bearer | owner/status przed prepare | e-mail/RPC | rate limit, claim, idempotencja |

## Mass assignment

Nie znaleziono niekontrolowanego `.update(body)` ani `.insert(body)` w krytycznych ścieżkach. Parsowanie requestów pozwala na zdefiniowane pola, UUID i typy. Klient nie ustala autorytatywnie `role`, `user_id`, `verification_status` ani przyszłego `tenant_id`. Direct update profilu używa jawnej listy pól i jest dodatkowo chroniony triggerem; zmiana płatności registration dotyczy jednej kolumny.

## Sesja i CSRF

- Sesja Supabase jest cookie-based przez SSR; własnych magazynów tokenów w browser storage nie znaleziono.
- Mutujące API wymagają bearer tokenu, co ogranicza klasyczny cookie-CSRF.
- OAuth callback nie przyjmuje dowolnego zewnętrznego redirectu.
- Publiczna strona confirmation wykonuje mutację w trakcie GET — finding SEC-003.
- Parametry cookie (`Secure`, `SameSite`, expiry) zależą od Supabase SSR i środowiska wdrożenia; ich produkcyjnego rezultatu nie zweryfikowano.

## XSS

React domyślnie escapuje UI, a `dangerouslySetInnerHTML` nie występuje. Dwa ręcznie budowane szablony HTML e-mail wstawiają dane bez escapowania — finding SEC-006. Pozostałe confirmation/cancellation helpers mają własne escape HTML.

---

### SEC-003

Severity: **HIGH**
Status: **CONFIRMED**
Lokalizacja: `app/events/confirm/[token]/page.tsx:240-275`
Opis: zwykły GET strony z tokenem natychmiast wywołuje service-role RPC `confirm_event_reserve_promotion`, zmieniając status uczestnictwa. GET nie jest bezpieczny/idempotentny semantycznie i bywa automatycznie otwierany przez skanery poczty, link preview oraz prefetch.
Scenariusz wykorzystania: skaner bezpieczeństwa skrzynki odwiedza link przed użytkownikiem; miejsce zostaje potwierdzone bez jego świadomej akcji. Osoba z wyciekiem URL może również potwierdzić status.
Dane zagrożone: integralność event registration i pojemności wydarzenia; dalszy e-mail.
Dowód: page server component wywołuje RPC podczas renderowania GET.
Rekomendowana poprawka: GET tylko pokazuje bezpieczne potwierdzenie; właściwa zmiana przez POST po jawnej akcji, token jednorazowy/expiring, CSRF/origin defense adekwatne do modelu.
Test regresyjny: GET nie zmienia DB; POST z ważnym tokenem zmienia raz; scanner GET/prefetch pozostawia rekord bez zmian.

### SEC-006

Severity: **MEDIUM**
Status: **CONFIRMED**
Lokalizacja: `app/events/confirm/[token]/page.tsx:102-156`, `lib/server/event-reserve-promotion.ts:510-549`
Opis: customer name, event title/location i link są interpolowane do HTML bez HTML escaping. Dane użytkownika lub administratora mogą wstrzyknąć znaczniki/linki do wiadomości.
Scenariusz wykorzystania: złośliwa nazwa/lokalizacja zawiera HTML; dostawca/klient pocztowy renderuje zmienioną treść lub phishing link. Skrypty zwykle są filtrowane przez klientów pocztowych, ale HTML/phishing pozostają realne.
Dane zagrożone: wiarygodność komunikacji, odbiorcy wiadomości.
Dowód: bezpośrednie `${displayName}`, `${event?.title}`, `${event?.location}` w template literal HTML, bez helpera escape.
Rekomendowana poprawka: wspólny encoder HTML dla każdej wartości dynamicznej oraz bezpieczne budowanie URL.
Test regresyjny: wartości zawierające `<`, `>`, `&`, quote są zakodowane w HTML, a plain-text zachowuje czytelność.

### SEC-011

Severity: **MEDIUM**
Status: **CONFIRMED**
Lokalizacja: `middleware.ts:10-43,154-184`
Opis: route authorization jest fail-open względem przyszłych ścieżek `/admin/*`: po przejściu bazowego `adminAccess` nieznana trasa nie pasuje do żadnego wpisu i jest dozwolona instruktorowi/pracownikowi. Aktualne trasy są pokryte, a DB pozostaje drugą warstwą.
Scenariusz wykorzystania: deweloper dodaje admin-only stronę i zapomina dopisać ją do mapy; instruktor może otworzyć jej server/client read path.
Dane zagrożone: zależne od przyszłej trasy; potencjalnie PII i konfiguracja.
Dowód: pętla tylko odrzuca przy dopasowaniu route; brak dopasowania kończy się `return response`.
Rekomendowana poprawka: deny-by-default dla nieznanej ścieżki albo centralna deklaracja uprawnień współdzielona z testem kompletności routingu.
Test regresyjny: syntetyczna niezarejestrowana `/admin/secret` = DENY dla wszystkich poza jawnie określonym przypadkiem.

### SEC-010

Severity: **MEDIUM**
Status: **NOT VERIFIED**
Lokalizacja: formularze Auth i zewnętrzna konfiguracja Supabase Auth
Opis: rejestracja w UI dopuszcza hasło od 6 znaków, podczas gdy reset/account wymagają 8. Repozytorium nie zawiera autorytatywnego `supabase/config.toml`, a zdalnej polityki Auth nie odczytywano. Jeśli provider również dopuszcza 6, polityka jest słaba i niespójna.
Scenariusz wykorzystania: użytkownik tworzy krótkie hasło bardziej podatne na credential stuffing/brute force.
Dane zagrożone: konta użytkowników i przypisane PII.
Dowód: statyczna rozbieżność walidacji frontend; ustawienie provider jest niezweryfikowane.
Rekomendowana poprawka: potwierdzić i ustawić spójną silną politykę po stronie Auth; UI ma ją odzwierciedlać, nie zastępować.
Test regresyjny: integracyjny test policy z providerem dla wartości poniżej/na granicy.

### SEC-013

Severity: **LOW**
Status: **CONFIRMED**
Lokalizacja: strony login/register/forgot/account i wybrane panele klienta
Opis: część UI/console używa surowego Supabase `error.message` lub loguje cały error object. API serwerowe przeważnie zwraca kontrolowane komunikaty, ale browser może ujawnić nazwy obiektów lub szczegóły implementacji uwierzytelnionemu użytkownikowi.
Scenariusz wykorzystania: celowo błędny request powoduje komunikat PostgREST z detalem struktury.
Dane zagrożone: metadane schematu i diagnostyka; nie znaleziono sekretów.
Dowód: statyczne wystąpienia fallbacków `error.message`/`console.error(error)` w klientach.
Rekomendowana poprawka: mapować na stabilne kody UI, logować server-side tylko bezpieczne pola correlation/code.
Test regresyjny: błąd zawierający SQL/table name nie pojawia się w DOM ani console loggerze produkcyjnym.

### SEC-015

Severity: **LOW**
Status: **CONFIRMED**
Lokalizacja: `app/api/send-reservation-cancellation/route.ts:190-380`
Opis: właściciel lub staff może ponawiać wysyłkę e-mail dla już anulowanej rezerwacji; nie znaleziono dedykowanego rate limitu ani idempotency ledger tej wiadomości. Ownership ogranicza zwykłego usera do własnej skrzynki, lecz konto staff ma szerszy wpływ.
Scenariusz wykorzystania: seria requestów powoduje spam/koszty dostawcy.
Dane zagrożone: dostępność/koszt, komfort odbiorcy.
Dowód: status cancelled jest warunkiem wysyłki, ale brak unikalnego delivery claim.
Rekomendowana poprawka: claim/idempotency i limit per reservation/actor; kontrolowany resend tylko dla admina.
Test regresyjny: drugie równoległe i sekwencyjne wywołanie nie wysyła ponownie bez jawnej ścieżki resend.

## Ocena etapu

API input validation i ownership są ogólnie dojrzałe, a krytyczne writery delegują do kontrolowanych RPC. Etap wymaga przeglądu głównie z powodu mutującego GET, HTML e-mail i przyszłościowego fail-open routingu.
