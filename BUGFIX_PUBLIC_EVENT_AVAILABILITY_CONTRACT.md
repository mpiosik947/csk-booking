# Bugfix: public event availability contract

## Root cause

Publiczna strona `/events` pobierała aktywne wydarzenia bez rejestracji dla
użytkownika anonimowego, a po zalogowaniu dodawała zagnieżdżoną relację
`event_registrations(id, registration_status)`. Następnie przeglądarka liczyła
uczestników i wolne miejsca z otrzymanych wierszy.

Polityka RLS `Users can view own event registrations` udostępnia zwykłemu
użytkownikowi wyłącznie rekordy z `user_id = auth.uid()`. Globalny agregat
wyliczony z owner-scoped wyniku był więc niepełny: liczba uczestników była
zaniżona, a liczba wolnych miejsc zawyżona. Użytkownik anonimowy nie otrzymywał
w ogóle relacji rejestracji. Panel administratora i `/my-events` korzystają z
odrębnych modeli: panel ma operacyjny odczyt staff, a `/my-events` celowo czyta
wyłącznie zapisy właściciela.

## Old counting model

- źródło: bezpośredni `SELECT` `events` z nested `event_registrations`,
- agregacja: w React na widocznych przez RLS wierszach,
- zajętość: każdy status poza dokładnym `cancelled` i `reserve`,
- wada dodatkowa: ta reguła była szersza niż writer, który liczy wyłącznie
  znormalizowane `registered` i `approved`.

## New authoritative contract

Dodano addytywny RPC:

`public.get_public_event_availability_v1()`

Funkcja zwraca po jednym deterministycznie posortowanym wierszu dla aktywnego
eventu:

- `event_id`, `title`, `description`, `event_date`, `start_time`, `end_time`,
  `location`, `price`,
- `max_participants`,
- `registered_count`,
- `reserve_count`,
- `available_spots`,
- `sold_out`.

`registered_count` obejmuje dokładnie znormalizowane statusy `registered` i
`approved`, zgodnie z `register_for_event`, potwierdzeniem promocji oraz panelem
administratora. `reserve` jest liczony osobno i nie zajmuje capacity.
`available_spots = max(max_participants - registered_count, 0)`.

Istniejąca zasada kolejki pozostaje bez zmian: jeżeli istnieje lista rezerwowa,
frontend nadal kieruje kolejne zgłoszenie na listę rezerwową, nawet gdy fizyczna
różnica capacity jest dodatnia. Po skutecznym zapisie frontend odświeża dane z
RPC zamiast dopisywać lokalny, potencjalnie niepełny wiersz rejestracji.

RPC jest `STABLE`, `SECURITY DEFINER`, należy do `postgres`, ma `search_path =
pg_catalog, public, pg_temp` i jawny `EXECUTE` wyłącznie dla `anon` oraz
`authenticated`. `PUBLIC` i `service_role` nie mają `EXECUTE`.

## PII exposure

**NONE.** Kontrakt nie zwraca `user_id`, nazw klienta, e-maili, telefonów,
identyfikatorów rejestracji ani tokenów. Parser frontendowy wymaga dokładnego
zestawu 13 pól i odrzuca cały response zawierający dodatkowy klucz lub
niespójne wartości aggregate. Polityki SELECT `event_registrations` nie zostały
rozszerzone; SEC-008 pozostaje bez zmian.

## Files changed

- `app/events/page.tsx`
- `lib/public-event-availability.ts`
- `lib/public-event-availability.test.mjs`
- `supabase/migrations/20260905120000_add_public_event_availability_v1.sql`
- `supabase/tests/20260905120000_add_public_event_availability_v1_test.sql`
- `supabase/tests/20260816143000_harden_public_function_execute_acl_test.sql`
- `BUGFIX_PUBLIC_EVENT_AVAILABILITY_CONTRACT.md`

## Tests

- focused Node: 7/7 PASS,
- focused SQL: 22/22 PASS, końcowy `ROLLBACK`,
- all Node: 625/625 PASS,
- all DB test files: 15/15 PASS,
- TypeScript: PASS,
- Next.js build: PASS,
- `npm audit --omit=dev`: 0 vulnerabilities,
- `git diff --check`: PASS.

Pełny ESLint zachowuje istniejący baseline i nie ma nowych regresji z tego
zadania. Aktualny wynik to 13 errors / 6 warnings (o jeden istniejący
`no-explicit-any` mniej po usunięciu starego castu z `/events`); pozostałe
problemy dotyczą istniejącego długu, w tym wcześniejszych konstrukcji w
`app/events/page.tsx`.

Test SQL potwierdza między innymi: capacity 10 i 3 uczestników daje 7 wolnych
miejsc, ordinary user z owner-scoped widokiem 0 cudzych rejestracji otrzymuje
ten sam aggregate co stan biznesowy, reserve nie zajmuje capacity, sold-out ma
0 miejsc, cancellation zwiększa availability, reserve promotion przenosi jeden
rekord między licznikami, response jest PII-free, wynik dla wielu użytkowników
jest deterministyczny, a istniejący writer nadal kieruje nadmiarowy zapis na
reserve zamiast powodować overbooking.

## Compatibility

| Application | Database | Result |
|---|---|---|
| OLD | OLD | Działa, ale zachowuje błędne owner-scoped liczenie |
| OLD | NEW | SAFE — migracja jest addytywna, stara aplikacja ignoruje RPC |
| NEW | OLD | UNSAFE — `/events` fail-closed, ponieważ RPC nie istnieje |
| NEW | NEW | SAFE — autorytatywny PII-free read model |

## Deployment

**DB FIRST.** Najpierw zastosować wyłącznie migrację
`20260905120000_add_public_event_availability_v1.sql` i zweryfikować sygnaturę,
ACL oraz anonimowy odczyt. Dopiero potem wdrożyć aplikację. Rollback aplikacji po
migracji jest bezpieczny, ponieważ RPC jest addytywny. Wdrożenie aplikacji przed
bazą spowoduje kontrolowany błąd ładowania `/events`.

## Verdict

**PUBLIC EVENT AVAILABILITY: FULLY FIXED**
