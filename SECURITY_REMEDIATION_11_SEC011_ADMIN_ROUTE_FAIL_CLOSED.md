# SECURITY REMEDIATION 11 — SEC-011 ADMIN ROUTE FAIL-CLOSED

## Status

- SEC-ID: SEC-011
- Original severity: MEDIUM
- Scope: ochrona stron `/admin/*` oraz niezależna ochrona `/api/admin/*`
- Verdict: **SEC-011 FULLY REMEDIATED**

## Before

`middleware.ts` obejmował matcherem `/admin/:path*`, uwierzytelniał użytkownika i pobierał jego rolę z `public.profiles`, ale szczegółowe ograniczenia ról stosował tylko wtedy, gdy ścieżka pasowała do ręcznie wpisanego klucza `routePermissions`.

Nieznana nowa ścieżka `/admin/*`, której programista nie dopisał do mapy, przechodziła do `NextResponse.next()` dla każdej bazowej roli staff (`admin`, `pracownik`, `instruktor`). Był to fail-open dla przyszłych tras. Dodatkowo użycie `path.startsWith(route)` nie respektowało granic segmentów, więc np. `/admin/events-extra` dziedziczyło uprawnienia `/admin/events`.

Ukrywanie kafelków i kontrole klienckie stron nie były uznawane za granicę bezpieczeństwa. Bezpośredni URL nadal przechodzi przez middleware, a operacje wrażliwe pozostają chronione przez serwerowe RPC/RLS.

## After

Autorytatywna mapa tras została przeniesiona do `lib/admin/route-protection.js` i jest używana przez middleware oraz testy kontraktowe.

Zasady:

- `/admin` wymaga jednej z bazowych ról staff: `admin`, `pracownik`, `instruktor`;
- znane strony zachowują dotychczasowe, bardziej szczegółowe role;
- każda nieznana przyszła ścieżka `/admin/*` jest domyślnie **admin-only**;
- dopasowanie znanej trasy działa wyłącznie dla dokładnej ścieżki albo jej potomka oddzielonego `/`;
- `/administrator` nie jest błędnie traktowane jako `/admin`;
- brak użytkownika, błąd `getUser()`, błąd profilu, brak profilu albo nieznana rola nigdy nie prowadzą do `NextResponse.next()`;
- rola pochodzi wyłącznie z zaufanego odczytu `public.profiles` po serwerowym `getUser()`. Query string, body i stan klienta nie uczestniczą w decyzji.

Nie wykonano szerokiej migracji konwencji Next.js z `middleware` do `proxy`; jest to niezależna zmiana techniczna i nie jest wymagana do zamknięcia SEC-011.

## Route and role matrix

| Route | Anon | User | Instruktor | Pracownik | Admin | Ochrona szczegółowa |
|---|---:|---:|---:|---:|---:|---|
| `/admin` | DENY | DENY | ALLOW | ALLOW | ALLOW | middleware, filtrowanie modułów w UI |
| `/admin/calendar` | DENY | DENY | ALLOW | ALLOW | ALLOW | middleware + własna rola strony + chroniony API feed |
| `/admin/events` | DENY | DENY | ALLOW (odczyt) | ALLOW | ALLOW | middleware; mutacje nadal ograniczone przez Event V2 RPC |
| `/admin/check-in` | DENY | DENY | DENY | ALLOW | ALLOW | middleware + kontrola roli strony + chronione RPC |
| `/admin/lane-blocks` | DENY | DENY | DENY | ALLOW | ALLOW | middleware + chronione RPC |
| `/admin/reservations` | DENY | DENY | DENY | ALLOW | ALLOW | middleware + RLS/RPC |
| `/admin/lane-configuration` | DENY | DENY | DENY | DENY | ALLOW | middleware + `get_my_role` + admin-only RPC |
| `/admin/reports` | DENY | DENY | DENY | DENY | ALLOW | middleware + `get_my_role` + RLS/RPC |
| `/admin/users` | DENY | DENY | DENY | DENY | ALLOW | middleware + `get_my_role` + admin-only RPC |
| `/admin/__future-test-route` | DENY | DENY | DENY | DENY | ALLOW | bezpieczny domyślny wariant middleware; strona nie została utworzona |
| `/api/admin/calendar-feed` | DENY (401) | DENY (403) | ALLOW | ALLOW | ALLOW | niezależny Bearer JWT, klasyfikacja Auth i `get_my_role` w route handlerze |

Nie znaleziono innych route handlerów w `/api/admin/*`. Nie znaleziono innych tras aplikacji, które deklarowałyby się jako staff-only poza wskazanymi stronami i API.

## API authorization

`app/api/admin/calendar-feed/route.ts` nie polega na middleware stron:

- wymaga tokenu Bearer;
- weryfikuje użytkownika serwerowo;
- rozróżnia brak autoryzacji (401), niedostępność Auth (503), inne błędy serwera (500) i brak wymaganej roli (403);
- pobiera rolę przez `get_my_role`;
- nie używa service role;
- zachowuje ograniczenie danych rezerwacji dla instruktora.

Nie zmieniono kontraktu endpointu.

## Regression coverage

Dodany test SEC-011 potwierdza:

1. segmentową identyfikację `/admin`;
2. pełną mapę wszystkich obecnych stron administracyjnych;
3. odmowę dla `user` i braku roli na każdej obecnej stronie;
4. admin-only default dla `/admin/__future-test-route`;
5. prawidłowe dziedziczenie przez potomków i brak błędnego dopasowania `/admin/events-extra`;
6. kolejność `getUser` → zaufany profil → autoryzacja trasy;
7. fail-closed przy błędzie użytkownika/profilu;
8. brak zaufania do roli z klienta;
9. niezależną ochronę `/api/admin/calendar-feed` i bezpieczną klasyfikację HTTP.

Istniejące testy stron admin-only i check-in zostały przepięte na wspólną mapę, aby nie testowały usuniętej, zduplikowanej definicji w tekście middleware.

## Verification

- Focused SEC-011/admin tests: **49/49 PASS**
- All Node tests: **575/575 PASS**
- TypeScript (`npx.cmd tsc --noEmit`): **PASS**
- Next.js build: **PASS**
- Focused ESLint changed files: **PASS, 0 findings**
- Full ESLint: **KNOWN ESLINT BASELINE — 14 errors / 6 warnings**
- New security remediation ESLint regressions: **0**
- `npm audit --omit=dev`: **PASS — 0 vulnerabilities**
- `git diff --check`: **PASS**
- Supabase DB tests: not run; no SQL, migration, RLS, ACL or database contract changed.

## Compatibility and deployment

Zmiana jest aplikacyjna i backward-compatible z obecną bazą. Nie wymaga migracji ani zmiany środowiska. Po zwykłym wdrożeniu aplikacji nowe i omyłkowo nieujęte w mapie strony `/admin/*` będą dostępne wyłącznie administratorowi do czasu jawnego przypisania szerszej roli.

Ostrzeżenie builda o wycofywanej konwencji pliku `middleware` jest istniejącym zaleceniem Next.js 16.3.4, a nie regresją bezpieczeństwa ani błędem kompilacji.

## Final verdict

**SEC-011 FULLY REMEDIATED**

Mechanizm nie przepuszcza już nowej strony administracyjnej wskutek braku wpisu w mapie, zachowuje istniejącą macierz ról, chroni bezpośrednie URL-e i nie zmienia autoryzacji API, RPC ani bazy danych.
