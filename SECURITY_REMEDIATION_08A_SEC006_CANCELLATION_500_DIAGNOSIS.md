# SECURITY REMEDIATION 08A — SEC-006 CANCELLATION HTTP 500 DIAGNOSIS

## Wynik

**Observed:** HTTP 500

**Root cause:** Endpoint anulowania rezerwacji wykonuje `get_reservation_customer_profiles_v1(uuid[])` klientem Supabase utworzonym z `SUPABASE_SERVICE_ROLE_KEY`. Produkcyjny kontrakt ACL tej funkcji zezwala na `EXECUTE` roli `authenticated`, ale odmawia go `service_role`. W ścieżce administratora/pracownika zapytanie kończy się więc błędem PostgreSQL `42501` (`permission denied for function get_reservation_customer_profiles_v1`), który route mapuje na kontrolowaną odpowiedź HTTP 500: `Nie udało się pobrać danych odbiorcy.`

**Category:** pre-existing cancellation-flow bug / credential-context mismatch exposed by the smoke fixture. Nie jest to regresja helperów SEC-006 ani błąd danych HTML.

**Affected production users:** YES — ścieżka wysyłania e-maila po anulowaniu wykonywanym przez `admin` lub `pracownik` jest dotknięta. Dotyczy to również administratora anulującego własną rezerwację, ponieważ gałąź staff ma pierwszeństwo przed gałęzią owner. Zwykły właściciel korzysta z innej gałęzi odczytu profilu i nie jest objęty dokładnie tym błędem ACL.

**Security impact:** LOW. Nie stwierdzono obejścia autoryzacji, ujawnienia PII ani wykonania niebezpiecznego HTML. Skutek jest dostępnościowo-operacyjny: wiadomość o anulowaniu nie zostaje wysłana w ścieżce staff.

**Fix required:** YES

## 1. Dokładna ścieżka wywołania

1. Frontend najpierw wywołuje kontrolowane RPC anulowania rezerwacji, a następnie wykonuje `POST /api/send-reservation-cancellation` z JWT bieżącej sesji:
   - `app/my-reservations/page.tsx`,
   - `app/admin/reservations/page.tsx`,
   - `app/admin/check-in/page.tsx`.
2. Route `app/api/send-reservation-cancellation/route.ts` tworzy klienta Supabase z service role.
3. `supabase.auth.getUser(accessToken)` prawidłowo identyfikuje użytkownika żądania.
4. Route pobiera rezerwację i profil operatora, sprawdza status oraz ustala `isOwner` i `isStaff`.
5. Dla `admin`/`pracownik` wybierana jest gałąź `isStaff`, która wywołuje `get_reservation_customer_profiles_v1(uuid[])` tym samym klientem service role.
6. PostgreSQL odmawia `EXECUTE` roli `service_role` (`42501`).
7. Route zwraca HTTP 500 przed skonstruowaniem treści wiadomości i przed wywołaniem Resend.

## 2. Flow 1 a Flow 2

| Element | Flow 1: confirmation | Flow 2: cancellation |
|---|---|---|
| Wynik smoke | PASS / HTTP 200 | FAIL / HTTP 500 |
| Użytkownik i odbiorca | ten sam syntetyczny użytkownik i kontrolowany adres | ten sam syntetyczny użytkownik i kontrolowany adres |
| Konfiguracja dostawcy | działała i dostarczyła wiadomość | provider nie został osiągnięty |
| Dane złośliwe HTML | poprawnie escaped | nie są przyczyną; zwykłe dane również dają 500 |
| `escapeEmailHref` | zależnie od template | nie jest używany w route cancellation |
| Punkt błędu | brak | staff-only lookup profilu odbiorcy |
| Rate limit | właściwy dla flow confirmation | route cancellation nie posiada tego limitera |

Flow 1 potwierdza, że produkcyjna konfiguracja wysyłki i dostawca były sprawne w czasie runu. Flow 2 przerywa działanie wcześniej, podczas odczytu danych odbiorcy.

## 3. Dowody

- Katalogowy kontrakt ACL dla `public.get_reservation_customer_profiles_v1(uuid[])`:
  - `authenticated`: `EXECUTE = true`,
  - `service_role`: `EXECUTE = false`.
- Bezpośrednie lokalne wywołanie kontraktu przez PostgREST z rolą service role zwróciło HTTP 403 i SQLSTATE `42501`: `permission denied for function get_reservation_customer_profiles_v1`.
- Lokalna reprodukcja rzeczywistego endpointu, na syntetycznym fixture i lokalnym Supabase, zwróciła HTTP 500 zarówno dla danych zawierających HTML, jak i dla zwykłych danych.
- W obu lokalnych przypadkach odpowiedź brzmiała `Nie udało się pobrać danych odbiorcy.`, a mock dostawcy potwierdził, że wysyłka nie została osiągnięta.
- Fixture lokalnej reprodukcji został usunięty; kontrola końcowa wykazała zero syntetycznych users, profiles, reservations i lanes.
- `git blame` wskazuje, że problematyczna gałąź staff pochodzi z wcześniejszej zmiany niż commit SEC-006. Commit `4a1182f` zastąpił lokalny helper `escapeHtml` wspólnym helperem o równoważnej semantyce.

## 4. Logi produkcyjne

Nie uzyskano bezpiecznego dostępu do logów Vercel dla markera `[TEST][SEC-006][d09778ff]`: dashboard wymagał osobnego logowania, a lokalny Vercel CLI nie był dostępny. Nie pozyskano więc produkcyjnego stack trace i nie podjęto próby obchodzenia autoryzacji.

Brak logów nie zmienia klasyfikacji: odpowiedź endpointu, lokalna reprodukcja tej samej ścieżki oraz bezpośredni test ACL wskazują ten sam punkt awarii.

## 5. Lokalna reprodukcja

- Środowisko zostało zweryfikowane jako lokalne: `NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54321`.
- Utworzono wyłącznie syntetyczny lokalny fixture administratora i anulowanych rezerwacji.
- Malicious HTML data: HTTP 500 przed wysyłką.
- Zwykłe dane: HTTP 500 przed wysyłką.
- Provider reached: `false` w obu przypadkach.
- Nie wysłano żadnej rzeczywistej wiadomości.
- Cleanup: zero pozostałości fixture.

## 6. Helpery bezpieczeństwa

- `escapeHtml()` koduje dynamiczne znaki HTML i nie rzuca wyjątku dla testowych payloadów.
- `escapeEmailHref()` nie uczestniczy w Flow 2; cancellation template nie buduje dynamicznego `href`.
- Nie występuje przekazanie pustego, względnego ani niedozwolonego URL do `escapeEmailHref()`.
- Nie znaleziono double escaping jako przyczyny HTTP 500.
- Błąd występuje przed etapem interpolacji HTML.

## 7. Ocena smoke fixture

Fixture był zgodny ze ścieżką biznesową:

- rezerwacja miała status akceptowany przez cancellation endpoint (`cancelled_by_user`),
- endpoint został wywołany przed cleanupem,
- JWT należał do syntetycznego użytkownika,
- użytkownik miał rolę `admin`, co prawidłowo uruchomiło realną ścieżkę staff,
- odbiorca i konfiguracja wysyłki działały w Flow 1,
- Flow 2 nie korzysta z rate limitera confirmation.

Rola administratora ujawniła istniejący błąd integracyjny, ale nie stanowi błędu fixture.

## 8. Minimalna wymagana poprawka

W `app/api/send-reservation-cancellation/route.ts` odczyty i RPC zależne od `auth.uid()` oraz ACL powinny być wykonywane klientem request-scoped działającym z JWT użytkownika (`authenticated`). Service role nie powinien być używany do `get_reservation_customer_profiles_v1` ani jako substytut kontekstu wywołującego.

Samo nadanie `service_role` prawa `EXECUTE` nie jest rekomendowane, ponieważ maskowałoby błąd kontekstu i rozszerzało ACL. Samo uprzywilejowanie gałęzi owner przed staff naprawiłoby tylko przypadek staff anulującego własną rezerwację, ale nie naprawiłoby anulowania cudzej rezerwacji przez uprawnionego pracownika.

## 9. Pliki wymagające zmiany w osobnym zadaniu

- `app/api/send-reservation-cancellation/route.ts`
- focused behavioral test route cancellation (nowy lub istniejący plik testowy)

Nie jest wymagana zmiana SQL, migracji, RPC ani ACL.

## 10. Wymagane testy regresyjne

- `admin` i `pracownik` anulują cudzą syntetyczną rezerwację: lookup działa w kontekście requester JWT, provider mock jest osiągnięty, odpowiedź success.
- `admin` anulujący własną rezerwację: success.
- zwykły właściciel: zachowanie bez regresji.
- `instruktor` i zwykły user dla cudzej rezerwacji: 403.
- status inny niż anulowany: kontrolowany 409.
- zwykłe oraz złośliwe dane docierają do tego samego etapu wysyłki i są bezpiecznie escaped.
- dowód, że route nie próbuje wykonywać staff-only RPC jako `service_role`.
- mock dostawcy i zero rzeczywistych wiadomości podczas testów.

## Werdykt

HTTP 500 jest skutkiem wcześniejszego błędu cancellation flow: funkcja do staffowego odczytu profilu jest wywoływana z niewłaściwą rolą bazodanową. SEC-006 escaping działa poprawnie i nie spowodował awarii. Wymagana jest osobna, minimalna poprawka uwierzytelnionego kontekstu klienta w route cancellation.
