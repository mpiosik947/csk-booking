# CSK Booking — etap 7: testy bezpieczeństwa

## Środowisko

- Wyłącznie lokalny Supabase/PostgreSQL: `127.0.0.1:54322`.
- Żadnych połączeń do produkcji, db push, repair, service-role bypass produkcji ani destrukcyjnych testów.
- Baza została wcześniej odtworzona z migracji repozytoryjnych.
- Zapytania audytowe katalogu wykonywano `BEGIN READ ONLY ... ROLLBACK`.
- Nie dodawano nowych testów, ponieważ nadrzędny zakres zabrania modyfikacji kodu; uruchomiono istniejące testy.

## Faktycznie wykonane

### 1. Bieżący Supabase DB test suite

Polecenie: `npx.cmd supabase test db --local`
Wynik: **PASS**, 3 pliki, **37/37** testów, exit code 0.

Zakres istniejących testów obejmuje bieżące kontrakty schematu, family creation oraz cross-writer invariants. Testy wykonują własne transakcje/cleanup zgodnie z harness Supabase.

### 2. Pełny lekki zestaw Node

Polecenie: `node --test`
Wynik: **PASS**, **533/533**, 0 failed, 0 skipped, exit code 0.

Security-relevant pokrycie widoczne w wyniku:

- Auth: brak user/invalid JWT = 401; Auth 5xx/network = 503; unknown = 500; role 403; frontend nie wylogowuje na 503.
- API reservation: ścisły input contract, stabilne kody, wyłącznie V2, brak fallback/retry, bezpieczne logowanie.
- Confirmation e-mail: ownership przed prepare, rate limit, claim/idempotencja, provider failure, brak provider ID, brak drugiej wysyłki.
- Calendar: query validation, scoped DTO, instructor bez reservations/PII, role fail-closed.
- Admin users: admin-only read/writers, controlled errors i szczegóły.
- Profile/check-in/reservation operations: scoped RPC, brak direct generic writers, controlled failures.
- Booking/hierarchy: malformed input fail-closed, stale response protection i brak V2 fallback.

### 3. Trzy historyczne psql security harnesses

Uruchomiono pełną ścieżką PostgreSQL 18, z `ON_ERROR_STOP=1`, na lokalnej bazie. Wszystkie zatrzymały się w setupie **przed asercjami bezpieczeństwa**:

| Plik | Exit | Przyczyna |
| --- | --- | --- |
| `20260813075757_harden_instructor_reservation_scope_test.sql` | 3 | `P0-B fixture setup failed` |
| `20260813195210_harden_admin_user_management_test.sql` | 3 | fixture wymaga jednego historycznego reservation baseline |
| `20260807120000_harden_event_mutations_test.sql` | 3 | nie utworzono kompletu syntetycznych profili per role |

Skrypty są w katalogu `tests_legacy_20260816`, a odpowiadające historyczne migracje są obecnie placeholderami wchłoniętymi do remote baseline. Nie wolno raportować tych harnessów jako PASS ani jako dowodu regresji security. Błąd nastąpił wewnątrz transakcji; zamknięcie połączenia wycofało stan.

### 4. Dependency audit

Polecenie: `npm audit --omit=dev`
Wynik narzędzia: **4 HIGH** production dependency findings (`next`, `nanoid`, `postcss`, `sharp`). Nie wykonano `npm audit fix`. Reachability poszczególnych advisory nie została dynamicznie udowodniona; SEC-001.

## Macierz pokrycia wymaganych prób

| Próba | Wynik | Poziom dowodu |
| --- | --- | --- |
| user own reservation/profile | PASS | bieżące DB + Node/statyczne RLS |
| user other reservation/profile | PASS w bieżących kontraktach | statyczne RLS + istniejące security tests |
| anon protected data | PASS w bieżących kontraktach | ACL/RLS katalog + DB tests |
| pracownik/admin operacje | PASS | DB/Node i definicje RPC |
| instructor scoped Calendar | PASS | Node test + route DTO |
| instructor global event registration PII | **obecnie ALLOW** | katalog RLS; finding SEC-008 |
| user → admin/pracownik escalation | DENY według trigger/RPC | DB tests + definicje; legacy full matrix nieuruchamialna |
| IDOR przez podmianę ID | DENY w przeanalizowanych owner RPC | DB/Node/statyczne |
| mass assignment role/user_id/status | DENY/allowlist | Node/statyczne |
| direct staff mutation event registrations | **obecnie ALLOW** | katalog RLS; finding SEC-018 |
| RPC bypass anon/auth | brak potwierdzonego bypassu krytycznych RPC | ACL katalog + DB tests |
| unauthenticated API | 401 | Node tests |

## Niezweryfikowane / wymagane środowisko

1. Produkcyjne Supabase Auth policy, MFA, rate limits, token lifetime i SMTP.
2. Produkcyjne cookies/headers/CDN/WAF.
3. Supabase Storage buckets/policies — brak kodu i brak odczytu zewnętrznego projektu.
4. Multi-tenant A/B I/U/D/RPC — model tenant jeszcze nie istnieje.
5. Dynamiczna exploitability każdego advisory npm.
6. DAST produkcyjnego deployu i dostawców zewnętrznych.

## Podsumowanie liczb

```text
Tests executed:
  current DB assertions: 37
  Node assertions: 533
  legacy harness attempts: 3 (setup failed before assertions)

Passed assertions: 570
Failed security assertions: 0
Failed test harnesses: 3
Skipped by runner: 0
Not testable in approved local scope: 6 categories
```

**STAGE 7 RESULT: PARTIAL** — bieżące zestawy są zielone, ale trzy legacy security harnesses nie są zgodne z aktualnym baseline i nie dostarczają obecnie deklarowanego dowodu.
