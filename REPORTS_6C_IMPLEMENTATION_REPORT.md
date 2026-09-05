# REPORTS-6C — Mobile UX + final polish

Data weryfikacji: 5 września 2026 r.

## Zakres

Zmiana dotyczy wyłącznie prezentacji i obsługi `/admin/reports`. Kontrakty RPC, autoryzacja, filtry, paginacja, CSV, semantyka KPI oraz model historyczny REPORTS-6A/6B nie zostały zmienione. Nie dodano SQL ani migracji.

## Wprowadzone usprawnienia

- KPI mają responsywny układ, bez wymuszonej szerokości i z bezpiecznym zawijaniem długich wartości.
- Filtry, reset i eksport zajmują pełną szerokość na telefonie, zachowując istniejące query params i reset strony po zmianie filtra.
- Telefony i tablety otrzymały karty szczegółów zawierające wyłącznie dane operacyjne: datę, godzinę, zasób, typ, status, płatność i kwotę. Karty nie renderują danych klienta.
- Szeroka tabela pozostaje dostępna na desktopie w lokalnym, fokusowalnym obszarze przewijania.
- Paginacja pokazuje bieżącą i łączną liczbę stron. Przyciski mają pełne cele dotykowe, jednoznaczne nazwy i nie powodują overflow.
- Eksport ma czytelny stan ładowania, pozostaje zabezpieczony limitem 5000 i jest wyłączony wraz z objaśnieniem, gdy aktywne filtry nie zwracają danych.
- Loading korzysta z komunikatu `aria-live`; pusty wynik odnosi się do aktywnych filtrów; retry błędu odczytu nie ujawnia surowych błędów backendu.
- Dodano widoczne stany focus dla nowych i poprawionych akcji.

## Testy

| Kontrola | Wynik |
|---|---|
| Focused Reports UI + helpers | PASS — 33/33 |
| Playwright Reports responsive | PASS — 5/5 |
| Mobile 320 px | PASS — brak poziomego overflow strony |
| Mobile 375 px | PASS — brak poziomego overflow strony |
| Mobile 430 px | PASS — brak poziomego overflow strony |
| Desktop 1440 px | PASS — tabela widoczna, widok kart ukryty |
| Filtry i query params | PASS — interakcja i odtworzenie filtra |
| Paginacja | PASS — przejście strona 1 → 2 |
| Empty/error | PASS — kontrolowane komunikaty i retry |
| Wszystkie testy Node | PASS — 641/641 |
| TypeScript `tsc --noEmit` | PASS |
| Next.js build | PASS |
| `npm audit --omit=dev` | PASS — 0 podatności |
| ESLint zmienionych plików | PASS — 0 problemów |
| Pełny ESLint | KNOWN BASELINE — 13 errors / 6 warnings; nowe regresje: 0 |
| `git diff --check` | PASS |

Test Playwright użył wyłącznie lokalnego Supabase `127.0.0.1:54321`, syntetycznego administratora i mockowanego kontraktu raportowego. Konto testowe zostało usunięte przez cleanup testu; żadne żądanie nie mogło trafić do `*.supabase.co`.

## Regresja i deployment

- REPORTS-6A: agregacyjny RPC, 720 minut, DST, hierarchy i brak double-count pozostają bez zmian.
- REPORTS-6B: filtry backendowe, page size 50, eksport do 5000 rekordów, ochrona CSV i admin-only access pozostają bez zmian.
- DB CHANGE REQUIRED: NO.
- DEPLOYMENT MODEL: APP ONLY.
- HISTORICAL SNAPSHOT RESIDUAL: UNCHANGED.

## Wynik końcowy

REPORTS-6C: FULLY IMPLEMENTED

MOBILE 320: PASS

MOBILE 375: PASS

MOBILE 430: PASS

TABLE / CARD UX: PASS

FILTER UX: PASS

PAGINATION UX: PASS

EXPORT UX: PASS

LOADING / EMPTY / ERROR: PASS

ACCESSIBILITY: PASS

REPORTS-6A REGRESSION: PASS

REPORTS-6B REGRESSION: PASS

DB CHANGE REQUIRED: NO

DEPLOYMENT MODEL: APP ONLY

HISTORICAL SNAPSHOT RESIDUAL: UNCHANGED

FILES CHANGED:

- `app/admin/reports/page.tsx`
- `app/admin/reports/page.test.mjs`
- `tests/e2e/reports-responsive.spec.ts`
- `REPORTS_6C_IMPLEMENTATION_REPORT.md`
