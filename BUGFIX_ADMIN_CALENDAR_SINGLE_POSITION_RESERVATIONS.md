# BUGFIX ADMIN CALENDAR — single-position reservations

## Observed bug

Rezerwacja zapisana bezpośrednio na zasobie `position` była dostępna w bazie i w widoku `lane=all`, lecz znikała po wybraniu osi nadrzędnej. Problem był szczególnie widoczny w mobilnym widoku Dzień, ponieważ ten widok automatycznie wybiera pierwszą aktywną oś nadrzędną.

## Root cause

Filtr osi był traktowany jako filtr jednego UUID zamiast zakresu zasobów rodziny. Endpoint stosował `lane_id = parent UUID`, normalizacja ponownie porównywała `laneId` wyłącznie z UUID parenta, a filtry Day/Week robiły to po raz trzeci. Rezerwacja stanowiska poprawnie wskazywała child UUID, dlatego nie spełniała żadnego z tych ścisłych porównań.

## Affected layer

DB QUERY / NORMALIZATION / FILTER / RENDER wiring. Model danych, zapis rezerwacji i relacja `reservations.lane_id -> shooting_lanes.id` były poprawne.

## Why whole-lane worked

Rezerwacja całej osi ma `reservations.lane_id` równe UUID parenta, więc dotychczasowy warunek równości przypadkowo odpowiadał jej semantyce.

## Why child reservation failed

Rezerwacja stanowiska zachowuje UUID childa i nie powinna być spłaszczana do parenta. Przy filtrze parenta jej UUID różnił się od filtrowanego UUID, mimo że stanowisko należało do wybranej rodziny.

## Fix

Dodano jeden współdzielony resolver zakresu zasobów:

- `all` obejmuje wszystkie zwrócone zasoby,
- wybrany parent obejmuje parenta i jego bezpośrednie positions,
- wybrane position obejmuje wyłącznie to position.

Endpoint używa zakresu w zapytaniach `reservations` i `lane_blocks`. Normalizacja feedu, Day i Week używają tej samej semantyki. Każdy wpis zachowuje swój rzeczywisty `laneId`; nie powstają projekcje rezerwacji na parenta ani rodzeństwo.

## Files changed

- `app/api/admin/calendar-feed/route.ts`
- `lib/admin/calendar/feed.ts`
- `lib/admin/calendar/scope.ts`
- `app/admin/calendar/calendar-ui.ts`
- `app/admin/calendar/page.tsx`
- `app/admin/calendar/_components/WeekCalendar.tsx`
- `lib/admin/calendar/feed.test.mjs`
- `lib/admin/calendar/time.test.mjs`
- `app/admin/calendar/calendar-ui.test.mjs`
- `BUGFIX_ADMIN_CALENDAR_SINGLE_POSITION_RESERVATIONS.md`

## Verification

- Day: PASS — parent filter exposes separate parent/position columns and child entry stays on the child UUID.
- Week: PASS — selected parent uses all resource IDs in its family without duplicating entries.
- Month: PASS — child reservation contributes once to reservation count and effective-capacity occupancy.
- Filters: PASS — ALL includes child; parent includes its child; concrete child remains exact.
- Historical inactive child: PASS — referenced inactive child remains present with hierarchy label and `isHistoricalOnly=true`.
- Collision layout: PASS — existing half-open collision and column-layout tests remain green.
- Security/PII regression: NONE — reservation SELECT columns and role gate are unchanged; instructor still receives no reservation rows; local endpoint response exposed none of the prohibited PII fields.
- Local integration: PASS — real local endpoint returned one whole-lane and one single-position entry, preserved child UUID and hierarchy label, and counted 120 occupied minutes. Fixture post-check returned zero users, profiles, lanes and reservations.

## Tests

- Focused calendar tests: PASS.
- All Node tests: PASS (618/618).
- TypeScript: PASS.
- Next.js build: PASS.
- `npm audit --omit=dev`: PASS, 0 vulnerabilities.
- ESLint changed production files: PASS.
- Full ESLint: KNOWN BASELINE — 14 errors / 6 warnings; new regressions: 0.
- `git diff --check`: PASS.
- Supabase DB suite: not required; no SQL, migration, RPC, RLS or ACL changed.

## Deployment type

APP ONLY.

## Verdict

ADMIN CALENDAR SINGLE POSITION BUG: **FULLY FIXED**
