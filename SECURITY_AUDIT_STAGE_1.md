# CSK Booking — audyt bezpieczeństwa, etap 1

Data audytu: 2026-08-16
Zakres: statyczna analiza całego repozytorium oraz odczytowy katalog lokalnego PostgreSQL/Supabase po pełnym lokalnym resecie. Produkcja nie była używana.
Punkt odniesienia Git: `main`, `c144dba Merge pull request #4 from mpiosik947/fix/auth-error-classification`.

## 1. Architektura bezpieczeństwa

```text
Przeglądarka
  ├─ Next.js App Router / Client Components
  │    ├─ Supabase JS (publiczny URL + anon key, sesja użytkownika)
  │    ├─ REST tabel chroniony ACL + RLS
  │    └─ RPC PostgreSQL chronione ACL + auth.uid() + kontrola roli
  ├─ /api/* (Bearer JWT)
  │    └─ Supabase Auth getUser() → jawna kontrola właściciela/roli → RPC
  └─ strony serwerowe z tokenem w URL
       └─ klient service-role wyłącznie po stronie serwera

Next.js middleware
  └─ chroni /admin/*, odczytuje sesję oraz profiles.role

Supabase/PostgreSQL
  ├─ 14 tabel public, RLS włączone na wszystkich
  ├─ 29 polityk
  ├─ 58 funkcji public (RPC, helpery, funkcje triggerów)
  └─ 12 triggerów nieinternalnych; brak views/materialized views
```

Projekt używa Next.js 16 App Router, React 19 i TypeScript. Nie znaleziono Pages Router ani Server Actions (`"use server"`). Osiem handlerów `app/api/**/route.ts` tworzy warstwę serwerową; znaczna część operacji aplikacji idzie również bezpośrednio z klienta przez Supabase REST/RPC. `middleware.ts` jest kontrolą nawigacyjną dla panelu, ale autorytatywne zabezpieczenia pozostają w RLS i RPC.

## 2. Authentication

- Rejestracja: `/register`, Supabase Auth; profil powstaje przez `handle_new_user()`.
- Logowanie: `/login`; redirect jest ograniczony do lokalnych, dozwolonych ścieżek.
- Callback OAuth: `/auth/callback`; docelowa ścieżka jest stała.
- Reset hasła: `/forgot-password`, `/reset-password`; kod wymieniany jest po stronie serwera, parametry są usuwane, po zmianie hasła następuje wylogowanie.
- Sesja: cookies obsługiwane przez `@supabase/ssr`; nie znaleziono własnego zapisu tokenów w `localStorage`, `sessionStorage` ani ręcznego `document.cookie`.
- API: wspólny `verifyAuthUser()` rozróżnia 401, 503 i 500; testy pokrywają brak sesji, nieważny JWT, Auth 5xx i awarię sieci.
- Middleware: `auth.getUser()` oraz odczyt `profiles.role`; awaria Auth w middleware jest obecnie traktowana jak brak sesji i skutkuje przekierowaniem do logowania (`middleware.ts:107-126`).

## 3. Mapa ról

Rzeczywiste wartości w bazie i kodzie są polskie, nie angielskie:

| Rola | Znaczenie | Zakres obecny |
| --- | --- | --- |
| `user` | klient | własny profil, rezerwacje i zapisy; publiczna konfiguracja |
| `instruktor` | instruktor | panel Calendar/Events oraz globalny odczyt zapisów eventowych przez `is_admin_or_staff()` |
| `pracownik` | pracownik | operacje bieżące, rezerwacje, eventy, blokady, check-in |
| `admin` | administrator aplikacji | globalny dostęp administracyjny, użytkownicy, konfiguracja i raporty |

Role są zapisane w `profiles.role`. Zmiana roli odbywa się przez admin-only `admin_set_user_role_v1()`; trigger `prevent_non_admin_profile_privilege_changes()` blokuje samodzielną zmianę roli, pól weryfikacji, identyfikatorów i pól administracyjnych. Middleware mapuje trasy: konfiguracja/użytkownicy/raporty tylko admin; rezerwacje/blokady/check-in admin+pracownik; calendar/events admin+pracownik+instruktor (`middleware.ts:10-43`).

## 4. Dane, PII i RLS

Wszystkie 14 tabel mają RLS włączone; `FORCE ROW LEVEL SECURITY` jest wyłączone. Skróty: A=admin, P=pracownik, I=instruktor, U=user, anon=niezalogowany.

| Tabela | Dane osobowe | RLS | U | P | I | A |
| --- | --- | --- | --- | --- | --- | --- |
| `profiles` | tak: tożsamość, kontakt, adres, deklaracje, weryfikacja | tak | własny SELECT/ograniczony UPDATE | profil klienta przez scoped RPC | brak globalnego odczytu | globalny S/I/U |
| `reservations` | tak: snapshot imienia, e-mail, telefon, historia, token check-in | tak | własny SELECT, mutacje przez RPC | globalny SELECT i kontrolowane RPC | brak globalnego SELECT | globalny SELECT, DELETE i RPC |
| `event_registrations` | tak: imię, e-mail, telefon, token promocji | tak | własny SELECT, RPC | globalny S/I/U/D | globalny SELECT | globalny S/I/U/D |
| `events` | zasadniczo nie; opis/lokalizacja mogą zawierać PII | tak | aktywne SELECT | wszystkie SELECT, mutacje RPC | wszystkie SELECT | wszystkie SELECT, mutacje RPC |
| `event_lanes` | nie | tak | brak | SELECT | SELECT | SELECT |
| `shooting_lanes` | nie; nazwa może przypadkowo zawierać PII | tak | aktywne SELECT | wszystkie SELECT | wszystkie SELECT | wszystkie SELECT, konfiguracja RPC |
| `lane_blocks` | potencjalnie: swobodny `reason` | tak | aktywne SELECT | wszystkie SELECT, mutacje RPC | wszystkie SELECT | wszystkie SELECT, mutacje RPC |
| `lane_booking_rules` | nie | tak | efektywne publiczne SELECT | wszystkie SELECT | wszystkie SELECT | wszystkie SELECT, writer RPC |
| `lane_booking_durations` | nie | tak | aktywne publiczne SELECT | wszystkie SELECT | przez publiczny zakres | wszystkie SELECT, writer RPC |
| `lane_pricing_rules` | nie | tak | aktywne publiczne SELECT | wszystkie SELECT | przez publiczny zakres | wszystkie SELECT, writer RPC |
| `lane_booking_family_configuration_versions` | nie | tak | brak | brak | brak | writer/reader RPC |
| `audit_logs` | tak/pseudonimowe: aktor, cel, szczegóły | tak | brak | INSERT jako staff | INSERT jako staff | SELECT i INSERT |
| `email_deliveries` | tak/pseudonimowe: odbiorca, provider ID | tak | brak bezpośredni | brak bezpośredni | brak | service-only RPC |
| `confirmation_email_rate_limits` | pseudonimowe: UUID/HMAC IP, czasy | tak | brak bezpośredni | brak | brak | service-only RPC |

## 5. Mapa funkcji bazy

Pełny katalog lokalny zawierał 58 funkcji. Grupy wejściowe:

- Eventy: `admin_create_event`, `admin_update_event`, `admin_set_event_active` (V1 service-only) oraz wersje `_v2` (authenticated, admin/pracownik), `register_for_event`, `approve_event_registration`, `cancel_event_registration`, funkcje promocji rezerwy.
- Rezerwacje: `create_reservation`, `create_reservation_v2`, `cancel_reservation`, `get_my_reservations_v2`, trzy wersje busy-ranges, operacyjne RPC płatności/frekwencji/notatki i scoped customer profiles.
- Osie i konfiguracja: `admin_create_lane_booking_family_v1`, oba admin readers, family writer V2, stary writer konfiguracji, lane-block writers, public config reader, family/scope/lock/normalization helpery.
- Użytkownicy: `admin_list_users_v1`, `admin_set_user_role_v1`, `admin_set_user_note_v1`, profile identity/contact/verification, `handle_new_user`.
- E-mail: prepare/complete, rate-limit, reserve promotion.
- Role: `get_my_role`, `is_admin`, `is_admin_or_employee`, `is_admin_or_staff`.
- Triggery/walidacja: `prevent_non_admin_profile_privilege_changes`, `set_updated_at`, `set_booking_configuration_updated_at`, walidatory capacity/hierarchy oraz rule capacity.

Krytyczne RPC używają `SECURITY DEFINER`, właściciela `postgres`, jawnego `search_path`, sprawdzają `auth.uid()` i role. Funkcje tylko-triggerowe i proste helpery obejmują pozostałą część katalogu. Nie znaleziono views ani materialized views.

## 6. Punkty wejścia i powierzchnie ataku

- 8 API routes: calendar-feed, cancel-event-registration, create-reservation, register-event, dwa confirmation e-mail, reserve promotion oraz cancellation e-mail.
- Supabase REST z przeglądarki: profile, event registrations, events, konfiguracja publiczna i odczyty panelu.
- Publiczne/authenticated RPC PostgreSQL.
- Formularze Auth, Booking, Events, Admin, Check-in.
- Tokeny w URL: check-in i event reserve confirmation.
- Publiczne strony i publiczne/anon RPC konfiguracji.
- Resend jako zewnętrzny dostawca e-mail.
- Nie znaleziono kodu Supabase Storage ani polityk Storage w repozytorium; stan zewnętrznych bucketów pozostaje niezweryfikowany.

## 7. Obszary skierowane do głębszego audytu

1. ACL/default privileges i relacja z RLS.
2. Mutacja wykonywana przez GET na publicznej stronie tokenowej.
3. Globalny dostęp instruktora do `event_registrations`.
4. Integralność `audit_logs`.
5. Renderowanie danych w HTML e-mail.
6. Ekspozycja PII przez check-in bearer token.
7. Brak granicy `tenant_id`.
8. Zależności z podatnościami, retencja PII i nagłówki bezpieczeństwa.

## Ograniczenia

Analiza schematu dotyczy odtworzonej bazy lokalnej i migracji repozytoryjnych. Konfiguracji Supabase Auth, platformowych nagłówków Vercel, bucketów Storage, dostawcy e-mail oraz stanu produkcji nie weryfikowano.

**STAGE 1 RESULT: NEEDS REVIEW**
