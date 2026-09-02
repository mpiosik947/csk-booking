# SECURITY REMEDIATION 01 — publiczny GET

## Finding

- SEC-ID: `SEC-003`
- Severity: `HIGH`
- Status przed poprawką: `CONFIRMED`
- Plik: `app/events/confirm/[token]/page.tsx`
- Publiczny URL: `GET /events/confirm/[token]`
- Mutująca funkcja: `public.confirm_event_reserve_promotion(text)`

Renderowanie publicznej strony potwierdzenia natychmiast wywoływało RPC przy użyciu klienta `service_role`. Samo otwarcie linku zmieniało `event_registrations.registration_status` z `reserve` na `registered`, ustawiało `promotion_confirmed_at`, czyściło pola claimu i mogło uruchomić dalszą wysyłkę wiadomości. Link mógł zostać otwarty bez sesji przez użytkownika, skaner poczty, crawler, link preview, prefetch lub bezpośrednie wpisanie URL.

## Root cause

Mutacja była umieszczona bezpośrednio w renderowaniu server component strony obsługiwanej metodą GET. Autoryzację zastępowały znajomość tokenu w URL i użycie `service_role`, więc request nie był związany z uwierzytelnionym właścicielem rejestracji. Naruszało to semantykę bezpiecznego GET i umożliwiało nieświadome potwierdzenie miejsca przez automatyczne otwarcie linku.

## Before

1. Wiadomość zawierała link do `/events/confirm/[token]`.
2. Publiczny GET renderował server component.
3. Component tworzył klienta `service_role`.
4. GET wywoływał `confirm_event_reserve_promotion(token)` i mutował rejestrację.
5. Po sukcesie GET odczytywał dane rejestracji i wysyłał e-mail potwierdzający.

Nie była wymagana sesja użytkownika ani jawne zatwierdzenie operacji.

## After

1. `GET /events/confirm/[token]` wyłącznie renderuje formularz i nie tworzy klienta bazy, nie wywołuje RPC, nie wykonuje `fetch` i nie wysyła wiadomości.
2. Użytkownik świadomie wysyła formularz do `POST /api/confirm-event-reserve-promotion`.
3. POST wymaga tokenu Bearer i weryfikuje sesję wspólnym helperem Auth.
4. Payload ma ścisły kontrakt `{ token }`; nie przyjmuje `user_id`, roli ani dodatkowych pól.
5. RPC działa w kontekście `authenticated`, pobiera tożsamość wyłącznie z `auth.uid()` i wymaga, aby użytkownik był właścicielem rejestracji wskazanej tokenem.
6. Brak sesji zwraca bezpieczne `401`, a próba potwierdzenia cudzego rekordu `403`.
7. Po poprawnym potwierdzeniu odczyt do wiadomości jest dodatkowo ograniczony przez `registration_id` i `user_id` oraz wykonany klientem użytkownika przy zachowanym RLS.
8. Flow nie używa `service_role`. RPC zachowuje dotychczasową walidację tokenu, terminu ważności, statusu, pojemności i blokad.

API nie eksportuje handlera GET, dlatego mutująca trasa akceptuje wyłącznie POST. Strona GET pozostaje bezpiecznym, read-only punktem wejścia.

## Files changed

- `app/api/confirm-event-reserve-promotion/route.ts`
- `app/events/confirm/[token]/ConfirmEventReserveForm.tsx`
- `app/events/confirm/[token]/page.tsx`
- `lib/server/auth-user-verification.test.mjs`
- `lib/server/event-reserve-confirmation-contract.test.mjs`
- `lib/server/event-reserve-confirmation-contract.ts`
- `lib/server/event-reserve-confirmation-email.ts`
- `supabase/migrations/20260816130000_secure_event_reserve_confirmation_post.sql`
- `supabase/tests/20260816130000_secure_event_reserve_confirmation_post_test.sql`
- `SECURITY_REMEDIATION_01_PUBLIC_GET.md`

Migracja zmienia wyłącznie funkcję bezpośrednio odpowiedzialną za finding i jej ACL EXECUTE: odbiera EXECUTE `service_role` oraz przyznaje je `authenticated`. Nie zmienia RLS, tabel, danych ani innych RPC.

## Security controls

```text
GET READ-ONLY: PASS
AUTHENTICATION: PASS
AUTHORIZATION: PASS
RLS PRESERVED: PASS
IDOR/BOLA CHECK: PASS
```

- GET: statyczny test kontraktowy potwierdza brak klienta Supabase, RPC, `fetch` i mechanizmu automatycznej mutacji w stronie.
- Authentication: POST weryfikuje Bearer JWT; brak sesji zwraca `401`.
- Authorization: RPC wymaga `auth.uid()` oraz zgodności `event_registrations.user_id`; obcy użytkownik otrzymuje odmowę `42501`, mapowaną na bezpieczne `403`.
- RLS: nie wyłączono ani nie zmieniono RLS. Odczyt po sukcesie działa w kontekście zalogowanego użytkownika i jest owner-scoped.
- IDOR/BOLA: klient nie przesyła `user_id` ani roli; token cudzego rekordu nie pozwala na mutację. Test DB potwierdza brak zmiany rekordu po odmowie.
- Least privilege: endpoint i flow nie używają `service_role`; EXECUTE RPC mają `authenticated`, a nie `anon`, `PUBLIC` lub `service_role`.
- Safe errors: odpowiedzi HTTP mają kontrolowane kody i nie zwracają surowych szczegółów Supabase/Postgres.

## Tests

```text
Test suites executed:
- focused Node security/contract: 2 files
- full Node test run: 540 tests
- local Supabase DB test run: 4 files / 47 tests
- TypeScript: npx.cmd tsc --noEmit
- focused ESLint for changed TypeScript/TSX files
- production build: npm.cmd run build
- npm test: attempted, but package.json has no test script

Tests passed:
- focused Node: 16/16
- full Node: 540/540
- Supabase DB: 47/47, including SEC-003 contract 10/10
- TypeScript: PASS
- focused ESLint: PASS

Tests failed:
- final applicable test runs: 0
- npm test command: unavailable (Missing script: "test"); not reported as PASS

Tests skipped:
- full Node: 0
- Supabase DB: 0

Build: PASS
git diff --check: PASS (informational LF/CRLF warnings only)
```

The DB contract test verifies missing authentication, anon denial, authenticated non-owner denial without mutation, owner success, exactly the expected single transition, stable fields, cleared claim, idempotent second use and controlled unknown-token handling. It runs in one transaction ending with `ROLLBACK`. A final read-only local query confirmed zero remaining SEC-003 fixture events, registrations, profiles and Auth users.

Local safety guard confirmed `NEXT_PUBLIC_SUPABASE_URL` points to `127.0.0.1`. No linked/remote database command was executed.

## Regression risk

`MEDIUM`

The confirmation flow and RPC authorization boundary change materially: confirmation now requires an authenticated owner and an explicit POST. Risk is limited by strict request/response contracts, owner-scoped DB authorization, focused application tests, a transactional DB security test, full Node regression, TypeScript, ESLint and a successful production build. The migration has not been deployed.

## Manual diff review

- GET contains no mutation or automatic POST: PASS.
- POST has explicit authentication and record ownership authorization: PASS.
- Client cannot provide or replace `user_id` or role: PASS.
- No `service_role` use remains in the confirmation flow: PASS.
- RLS remains enabled and unchanged: PASS.
- API response is limited to the existing technical confirmation result and safe error codes: PASS.
- No unrelated application, dependency, tenant, database or security finding was changed: PASS.

## OUT OF SCOPE FINDING

`SEC-006` remains unchanged: dynamic values in the existing event-reserve confirmation e-mail HTML are not consistently escaped. This finding is separate from SEC-003 and was deliberately not remediated in this change.

## Delivery status

- Git commit: not performed.
- Git push: not performed.
- Deployment: not performed.
- Production database operation: not performed.
