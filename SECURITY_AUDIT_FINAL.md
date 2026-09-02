# CSK Booking — końcowy raport audytu bezpieczeństwa

Data: 2026-08-16
Zakres Git: `main` @ `c144dba`
Metoda: statyczny przegląd repozytorium i historii, odczytowy katalog lokalnej bazy, istniejące lokalne testy DB/Node, dependency audit. Bez testów produkcji i bez zmian aplikacji/bazy.

## Executive summary

CSK Booking ma dojrzałe elementy obrony: RLS jest włączone na wszystkich 14 tabelach, krytyczne mutacje przechodzą przez atomowe SECURITY DEFINER RPC z kontrolą `auth.uid()`/roli, zwykły użytkownik ma ownership-scoped odczyty, bezpośrednie writery konfiguracji są utwardzone, service role nie trafił do klienta, a bieżące testy lokalne osiągnęły 37/37 DB i 533/533 Node. Nie znaleziono sekretu w śledzonym repozytorium/historii ani potwierdzonego prostego IDOR zwykłego usera.

Audyt wykrył jednak cztery problemy HIGH. Produkcyjne zależności mają zgłoszone podatności HIGH. Domyślne ACL PostgreSQL nadają zbyt szerokie prawa przyszłym obiektom anon/authenticated. Publiczny GET tokenowy wykonuje zmianę statusu przez service role. Model danych jest single-tenant i nie zapewni izolacji drugiej firmy bez przebudowy. Dodatkowe ryzyka MEDIUM dotyczą tokenu check-in z PII, HTML e-mail, wiarygodności audit logów, zbyt szerokiego odczytu instruktora, retencji, routingu admin i pozostawionego direct DML registrations.

Trzy historyczne psql security harnesses nie są obecnie uruchamialne na nowym remote baseline; bieżące testy są zielone, lecz utracono część deklarowanego dowodu macierzy ról. Należy naprawić harnessy jako osobne zadanie, bez traktowania ich błędu setupu jako wyniku security.

```text
CRITICAL: 0
HIGH:     4
MEDIUM:   8
LOW:      4
INFO:     2
```

**Wniosek:** NO CRITICAL ISSUES FOUND IN REVIEWED SCOPE. Nie oznacza to, że aplikacja jest całkowicie bezpieczna. Obecność czterech HIGH oznacza, że rekomendowane P0 powinny być zamknięte przed kolejnym rozszerzeniem produkcji; SEC-004 jest bezwzględnym blockerem przed drugim tenantem.

## Scorecard

| Obszar | Wynik | Uzasadnienie |
| --- | --- | --- |
| Authentication | REVIEW | poprawna klasyfikacja API; zewnętrzna policy i middleware outage niezweryfikowane |
| Authorization | REVIEW | mocne RPC, ale audit direct insert, instructor scope i future-route fail-open |
| RLS | REVIEW | 14/14 enabled, ownership dobre; zbyt szerokie staff policies/default ACL |
| RPC | PASS/REVIEW | brak potwierdzonego bypassu, safe owners/search_path; GET używa service RPC do mutacji |
| Role isolation | REVIEW | user dobrze izolowany; instruktor ma szerszy dostęp eventowy |
| Secrets | PASS | brak potwierdzonego wycieku w repo/historii/bundlu |
| API security | REVIEW | allowlist/ownership dobre; mutujący GET i resend abuse |
| PII exposure | REVIEW | szerokie admin use cases, check-in bearer page i instruktor registration PII |
| Logging | REVIEW | brak sekretów/tokenów, ale część raw client errors |
| Session security | REVIEW | SSR model dobry; produkcyjne cookie/Auth settings poza zakresem |
| Storage | REVIEW | brak użycia w repo; stan zewnętrznych bucketów niezweryfikowany |
| SaaS readiness | FAIL | brak tenant model/membership |
| Tenant isolation readiness | FAIL | brak `tenant_id`, RLS/RPC są globalne |

## Rozdzielenie poziomu dowodu

- **Przeanalizowane statycznie:** całe repo, migracje/baseline, middleware, API, Auth UI, RPC, policies, service-role uses, e-mail, PII flows.
- **Przetestowane lokalnie:** 37 DB assertions, 533 Node assertions, katalog DB read-only, `npm audit --omit=dev`.
- **Niezweryfikowane:** produkcyjny deploy, remote Auth settings, cookie headers, WAF/CDN, dynamiczna reachability advisory, tenant A/B (model nie istnieje).
- **Poza repozytorium:** Vercel/Supabase/Resend secrets/logs/config i ewentualne Storage buckets.

---

## HIGH

### SEC-001 — podatne zależności produkcyjne

Severity: **HIGH**
Confidence: high
Status: **CONFIRMED**
Affected component/file/object: supply chain; `package.json:16`, `package-lock.json`; brak DB object.
Description: `npm audit --omit=dev` zgłosił 4 HIGH: `next@16.2.6`, `nanoid`, `postcss`, `sharp`. Dla Next audit obejmuje m.in. klasy middleware/proxy bypass, DoS, SSRF/cache issues; reachability każdego advisory osobno nie została dowiedziona.
Attack scenario/impact/data: exploit podatnej ścieżki może powodować bypass, disclosure lub DoS zależnie od advisory; aplikacja rzeczywiście używa Next middleware i image stack.
Evidence: faktycznie wykonany audit, 4 high; nie uruchomiono auto-fix.
Recommended remediation: zaktualizować do wersji bez advisory w kontrolowanym PR, przejrzeć breaking changes i retestować middleware/image/routes.
Recommended automated regression test: dependency policy CI blokująca HIGH plus testy auth proxy i build.

### SEC-002 — niebezpieczne default privileges

Severity: **HIGH**
Confidence: high
Status: **CONFIRMED**
Affected: PostgreSQL ACL; `supabase/migrations/20260816090000_remote_baseline.sql:11088-11111`; `pg_default_acl`.
Description: przyszłe tabele/sekwencje/funkcje tworzone przez postgres automatycznie otrzymują ALL dla anon/authenticated. Bieżące tabele zachowują też szersze niż potrzebne prawa techniczne.
Attack scenario/impact/data: pominięty REVOKE w jednej migracji może publicznie odsłonić nowe PII lub definer RPC.
Evidence: jawne default GRANT ALL i zgodny katalog lokalny.
Recommended remediation: bezpieczne defaults, minimalne jawne granty, migracyjny ACL contract test.
Regression test: nowa testowa tabela/funkcja w rollback nie może automatycznie być dostępna anon/auth.

### SEC-003 — mutacja przez publiczny GET

Severity: **HIGH**
Confidence: high
Status: **CONFIRMED**
Affected: event reserve confirmation; `app/events/confirm/[token]/page.tsx:240-275`; `confirm_event_reserve_promotion`.
Description: render GET natychmiast potwierdza uczestnictwo przez service-role RPC.
Attack scenario/impact/data: scanner/prefetch lub posiadacz wyciekłego URL potwierdza miejsce bez świadomej akcji użytkownika, zmieniając capacity/status.
Evidence: bezwarunkowe `supabase.rpc()` w server page render.
Recommended remediation: GET read-only, osobny świadomy POST, expiring one-time token i ochrona request context.
Regression test: GET/prefetch nie zmienia danych; POST potwierdza dokładnie raz.

### SEC-004 — brak tenant isolation

Severity: **HIGH**
Confidence: high
Status: **CONFIRMED**
Affected: cały schemat/RLS/RPC; brak DB tenant objects.
Description: role są globalne, nie istnieją tenants, memberships ani `tenant_id`. Stan jest akceptowalny tylko jako single-tenant.
Attack scenario/impact/data: po dodaniu tenant B istniejący Admin/Pracownik A legalnie według obecnych policies uzyskuje globalne dane B.
Evidence: 14 tabel bez tenant_id i globalne helpery/policies.
Recommended remediation: tenant/membership model, composite FK, tenant-scoped RLS/RPC/indexes/audits przed onboardingiem B.
Regression test: pełna macierz A/B SELECT/I/U/D/RPC, mixed-tenant payload atomowo DENY.

## MEDIUM

### SEC-005 — długowieczny check-in bearer token ujawnia PII

Severity: **MEDIUM**; Confidence: high; Status: **CONFIRMED**
Affected: `app/check-in/[token]/page.tsx:38-112,190-208`, `reservations.check_in_token`.
Description/scenario/impact: znajomość URL wystarcza do service-role odczytu imienia, e-maila, telefonu i statusów; brak expiry/revocation zwiększa skutek wycieku.
Evidence: lookup wyłącznie po tokenie i publiczny render PII.
Remediation/test: hashed expiring/rotating token, minimal DTO; expired/revoked token nie zwraca PII.

### SEC-006 — HTML injection w e-mailach eventowych

Severity: **MEDIUM**; Confidence: high; Status: **CONFIRMED**
Affected: `app/events/confirm/[token]/page.tsx:102-156`, `lib/server/event-reserve-promotion.ts:510-549`.
Description/scenario/impact: nieescapowane imię/title/location może zmienić HTML wiadomości i wprowadzić phishing content.
Evidence: bezpośrednia interpolacja do HTML.
Remediation/test: wspólny HTML encoder; test znaków `<>&"'`.

### SEC-007 — staff może fałszować audit logs

Severity: **MEDIUM**; Confidence: high; Status: **CONFIRMED**
Affected: `audit_logs`, policy baseline `:10560`.
Description/scenario/impact: admin/pracownik/instruktor może direct INSERT caller-controlled actor/role/action/details, podważając integralność audytu.
Evidence: `WITH CHECK is_admin_or_staff()` bez związania aktora z `auth.uid()`.
Remediation/test: audyt wyłącznie przez trusted RPC/trigger; direct INSERT wszystkich klientów DENY.

### SEC-008 — globalny instructor SELECT event registrations

Severity: **MEDIUM**; Confidence: medium; Status: **LIKELY**
Affected: `event_registrations`, policy baseline `:10536`.
Description/scenario/impact: każdy instruktor może odczytać globalne dane kontaktowe i tokeny promocji. Uzasadnienie tak szerokiego zakresu nie jest widoczne.
Evidence: `is_admin_or_staff()` obejmuje instruktora.
Remediation/test: scoped minimal RPC bez contact/token; instructor other/unassigned = DENY.

### SEC-009 — brak technicznej retencji/anonimizacji/exportu

Severity: **MEDIUM**; Confidence: high; Status: **CONFIRMED**
Affected: profiles, reservations, event registrations, audits, email metadata.
Description/scenario/impact: PII snapshots/tokens/historia są przechowywane bez repozytoryjnego lifecycle, zwiększając blast radius.
Evidence: brak ogólnego delete/anonymize/export/scheduled retention workflow.
Remediation/test: zatwierdzona policy i atomowe lifecycle jobs; test progu wieku i referencji.

### SEC-010 — możliwie słaba/niespójna polityka hasła

Severity: **MEDIUM**; Confidence: low; Status: **NOT VERIFIED**
Affected: Auth UI i zewnętrzne Supabase Auth settings.
Description/scenario/impact: register dopuszcza 6, reset/account 8; provider policy niezweryfikowana. Jeśli 6 jest akceptowane, wzrasta ryzyko credential attacks.
Evidence: statyczny UI mismatch; brak autorytatywnej remote config.
Remediation/test: zweryfikować/ustawić server Auth policy i test graniczny.

### SEC-011 — przyszłe trasy admin są middleware fail-open

Severity: **MEDIUM**; Confidence: high; Status: **CONFIRMED**
Affected: `middleware.ts:154-186`.
Description/scenario/impact: nieznana `/admin/*` jest dostępna wszystkim staff po bazowym checku; nowa admin-only strona może być omyłkowo odsłonięta.
Evidence: brak deny po pętli bez dopasowania.
Remediation/test: deny-by-default i test kompletności routingu.

### SEC-018 — direct staff DML event registrations

Severity: **MEDIUM**; Confidence: high; Status: **CONFIRMED**
Affected: `event_registrations`, policies baseline `:10524-10532`.
Description/scenario/impact: admin/pracownik mogą I/U/D poza kontrolowanymi transition/audit RPC, co stwarza alternatywny writer i ryzyko niespójności.
Evidence: jawne mutacyjne policies oraz ACL.
Remediation/test: przełączyć wszystkie call-sites na RPC, odebrać direct DML; direct A/P/I/U/anon DENY.

## LOW

### SEC-012 — brak aplikacyjnych security headers

Severity: **LOW**; Confidence: high; Status: **CONFIRMED**
Affected: `next.config.ts:1-5`.
Description/scenario/impact: aplikacja nie definiuje CSP, frame-ancestors/X-Frame-Options, Referrer-Policy ani Permissions-Policy. Hosting może część dodawać, ale nie zweryfikowano. Brak zwiększa skutki XSS/clickjacking/leaku referer.
Evidence: pusty NextConfig i brak innego header config.
Remediation/test: centralne headers/CSP dopasowane do Supabase/Resend; test odpowiedzi produkcyjnego preview.

### SEC-013 — surowe błędy w browser UI/console

Severity: **LOW**; Confidence: high; Status: **CONFIRMED**
Affected: wybrane Auth/account/admin Client Components.
Description/scenario/impact: `error.message`/error objects mogą ujawniać nazwy tabel i diagnostykę; nie znaleziono sekretów.
Evidence: statyczne raw error fallbacks/logging.
Remediation/test: stabilne kody UI i redacted logger; syntetyczny SQL detail nie trafia do DOM/console.

### SEC-014 — reason aktywnego lane block widoczny wszystkim userom

Severity: **LOW**; Confidence: medium; Status: **POTENTIAL**
Affected: `lane_blocks`, policy baseline `:10580`.
Description/scenario/impact: swobodny tekst może przypadkowo zawierać PII/operacyjne szczegóły, a authenticated ma globalny SELECT aktywnych blokad.
Evidence: policy i kolumna reason; realnej PII nie potwierdzono.
Remediation/test: public DTO bez reason; staff-only reason.

### SEC-015 — cancellation e-mail bez claim/rate limit

Severity: **LOW**; Confidence: high; Status: **CONFIRMED**
Affected: `app/api/send-reservation-cancellation/route.ts`.
Description/scenario/impact: powtarzane requesty dla cancelled reservation ponawiają wiadomość, umożliwiając spam/koszt. Ownership ogranicza user do siebie.
Evidence: brak delivery claim/unique idempotency dla tej ścieżki.
Remediation/test: idempotency/rate limit; drugi request nie wysyła.

## INFO

### SEC-016 — placeholdery w informacji prywatności

Severity: **INFO**; Confidence: high; Status: **CONFIRMED**
Affected: public privacy content.
Description: dane kontaktowe/operacyjne administratora wymagają uzupełnienia przed publikacją.
Remediation/test: review właściciela i test braku placeholderów w production content.

### SEC-017 — Storage poza zweryfikowanym zakresem

Severity: **INFO**; Confidence: low; Status: **NOT VERIFIED**
Affected: zewnętrzny Supabase Storage.
Description: repo nie używa Storage i nie zawiera policies; nie sprawdzano, czy remote project ma buckety lub public objects.
Remediation/test: odczytowy inventory dashboard/catalog i policy tests, jeśli Storage istnieje.

## Priorytet napraw

### P0 — musi być naprawione przed rozszerzeniem produkcji

1. **SEC-001** — aktualizacja podatnych zależności po kontrolowanych testach.
2. **SEC-002** — bezpieczne default ACL i katalogowe testy.
3. **SEC-003** — usunąć mutację z GET.
4. **SEC-004** — obowiązkowo przed drugim tenantem; nie onboardingować B wcześniej.

### P1 — powinno być naprawione

1. SEC-005 check-in token i minimalizacja PII.
2. SEC-006 HTML encoding e-mail.
3. SEC-007 trusted audit writes.
4. SEC-008 zawężenie instruktora po decyzji biznesowej.
5. SEC-009 lifecycle PII.
6. SEC-010 zweryfikować Auth policy.
7. SEC-011 deny-by-default middleware.
8. SEC-018 usunięcie direct DML registrations.

### P2 — hardening

SEC-012 security headers, SEC-013 redacted errors, SEC-014 minimal block DTO, SEC-015 e-mail idempotency, SEC-016 treść prywatności, SEC-017 Storage inventory oraz naprawa trzech legacy test harnesses.

## Końcowy werdykt

**NEEDS REMEDIATION. NO CRITICAL ISSUES FOUND IN REVIEWED SCOPE.**
Nie wykonano żadnej naprawy, migracji, operacji produkcyjnej, commita ani pushu.
