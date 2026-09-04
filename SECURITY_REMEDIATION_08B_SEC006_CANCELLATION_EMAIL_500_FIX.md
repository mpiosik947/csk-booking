# SECURITY REMEDIATION 08B — SEC-006 CANCELLATION EMAIL HTTP 500 FIX

## Root cause

`POST /api/send-reservation-cancellation` tworzył klienta Supabase z `SUPABASE_SERVICE_ROLE_KEY` i używał go również do wywołania `public.get_reservation_customer_profiles_v1(uuid[])`.

Funkcja ma celowo wąski kontrakt wykonania:

- `SECURITY DEFINER = true`,
- owner: `postgres`,
- volatility: `STABLE`,
- `search_path = pg_catalog, public, pg_temp`,
- `PUBLIC EXECUTE = false`,
- `anon EXECUTE = false`,
- `authenticated EXECUTE = true`,
- `service_role EXECUTE = false`.

Wywołanie jako `service_role` kończyło się SQLSTATE `42501`, zanim route zbudował HTML i wywołał Resend.

## Chosen fix

**OPTION A**

Route używa teraz jednego request-scoped klienta Supabase utworzonego z publicznym anon key oraz nagłówkiem `Authorization: Bearer <caller JWT>`. Ten sam zweryfikowany kontekst `authenticated` obsługuje:

1. `auth.getUser`,
2. odczyt własnego profilu operatora,
3. odczyt konkretnej rezerwacji pod RLS,
4. staff-only `get_reservation_customer_profiles_v1`.

Usunięto z tego flow użycie `SUPABASE_SERVICE_ROLE_KEY`.

## Why least privilege

- Nie rozszerzono ACL funkcji.
- Nie przywrócono `service_role EXECUTE` i nie cofnięto SEC-002.
- `auth.uid()` wewnątrz RPC ponownie odpowiada rzeczywistemu callerowi.
- RPC nadal dopuszcza wyłącznie `admin` i `pracownik`.
- Route przed RPC sprawdza konkretną rezerwację, jej status oraz relację owner/staff.
- RLS zachowuje owner-only odczyt dla zwykłego użytkownika i operacyjny odczyt rezerwacji dla admin/pracownik.
- Provider jest osiągany dopiero po pełnej autoryzacji i poprawnym lookupie.

RPC ogranicza wejście do niepustej tablicy maksymalnie 200 unikalnych identyfikatorów rezerwacji i zwraca tylko profile powiązane z tymi rezerwacjami. Sam route przekazuje dokładnie jeden wcześniej odczytany i autoryzowany `reservation.id`.

## Exact route order

1. Bearer token validation.
2. Caller-authenticated Supabase client creation.
3. `verifyAuthUser` / `auth.getUser`.
4. Payload and UUID validation.
5. Operator profile lookup.
6. Reservation lookup under caller RLS.
7. Ownership/staff authorization.
8. Cancelled-status validation.
9. Owner profile lookup; staff uses the scoped RPC.
10. Recipient validation.
11. Mail configuration validation.
12. Escaped HTML and plain-text construction.
13. Resend invocation.

## Files changed

- `app/api/send-reservation-cancellation/route.ts`
- `app/api/send-reservation-cancellation/route.test.mjs`
- `SECURITY_REMEDIATION_08B_SEC006_CANCELLATION_EMAIL_500_FIX.md`

`SECURITY_REMEDIATION_08A_SEC006_CANCELLATION_500_DIAGNOSIS.md` pozostaje raportem wcześniejszej diagnozy. Istniejąca, wcześniejsza modyfikacja `PRODUCTION_SECURITY_SMOKE_TEST.md` nie została zmieniona w ramach bugfixu.

## ACL changes

Brak.

Nie utworzono migracji i nie zmieniono funkcji, RLS, grantów ani schematu.

## Route tests

Dodano kontrole chroniące:

- użycie caller JWT i anon key,
- całkowity brak service role w cancellation route,
- kolejność auth → reservation → access gate → status gate → profile RPC → HTML → provider,
- kontrolowane 403 dla nieuprawnionego callera,
- kontrolowany błąd lookupu bez raw PostgreSQL details/message/hint,
- brak wywołania providera przed poprawnym lookupem,
- użycie `escapeHtml()` dla wszystkich dynamicznych wartości HTML.

Cancellation template nie zawiera linku ani `href`, dlatego `escapeEmailHref()` nie uczestniczy w tym flow. Wspólny test SEC-006 nadal wymaga `escapeEmailHref()` dla wszystkich czterech template'ów zawierających linki i testuje odrzucanie schematów innych niż HTTP/HTTPS.

## Local reproduction

W izolowanym środowisku lokalnym wykonano syntetyczny scenariusz administratora anulującego rezerwację z wartościami zawierającymi złośliwy HTML.

Wynik po poprawce:

- HTTP: `200`,
- response: `{ "ok": true }`,
- SQLSTATE `42501`: brak,
- HTML build: osiągnięty,
- provider mock: osiągnięty dokładnie przez route,
- prawdziwa wysyłka: nie wykonana,
- cleanup: auth users `0`, profiles `0`, reservations `0`, lanes `0`.

Escaping pozostaje objęty wspólnymi testami: `<script>`, `<img onerror>`, tagi, ampersand, cudzysłowy i apostrof są kodowane jako tekst, bez double escaping.

## Tests

- Focused cancellation + SEC-006 + auth tests: **17/17 PASS**.
- Wszystkie lekkie testy Node: **550/550 PASS**.
- TypeScript `tsc --noEmit`: **PASS**.
- Next.js production build: **PASS**.
- ESLint zmienionych plików: **PASS**.
- Pełny ESLint: **KNOWN ESLINT BASELINE — 14 errors / 6 warnings**.
- New security remediation ESLint regressions: **0**.
- `npm audit --omit=dev`: **0 vulnerabilities**.
- Supabase DB tests: niewymagane i nieuruchomione, ponieważ nie zmieniono SQL ani ACL.

## Compatibility

Zmiana jest app-only i korzysta z istniejącego kontraktu RPC:

| Application | Database | Result |
|---|---|---|
| old | current | istniejący błąd staff cancellation email pozostaje |
| new | current | SAFE — obecne RPC już zezwala `authenticated` i odmawia `service_role` |

Nie istnieje zależna migracja ani przejściowy stan wymagający koordynacji DB.

## Deployment recommendation

**APP FIRST / normal application deployment.**

Nie wykonywać migracji ani zmian ACL. Po wdrożeniu należy wznowić production smoke SEC-006 od Flow 2 i dokończyć wszystkie pięć flow zgodnie z wcześniejszym planem. Ten etap nie wykonywał deploymentu ani ponownego production smoke.

## Verdict

**CANCELLATION EMAIL BUG: FULLY FIXED locally**

**SEC-006: nadal PARTIALLY REMEDIATED do czasu pełnego production smoke wszystkich 5 flow.**
