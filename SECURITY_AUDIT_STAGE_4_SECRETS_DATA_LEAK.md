# CSK Booking — etap 4: sekrety, konfiguracja i wycieki

## Wykonane kontrole

- Przeszukano śledzone pliki i historię Git pod kątem nazw sekretów, prefiksów Supabase, JWT-like values, connection strings, private keys i wysokiej entropii.
- Sprawdzono `.gitignore`, śledzenie `.env*`, PEM, `supabase/.temp` i backupów.
- Sprawdzono miejsca użycia service role i Resend.
- Sprawdzono wygenerowany `.next/static` pod kątem literalnych identyfikatorów sekretów.
- Nie wyświetlano żadnej wartości środowiskowej ani sekretu.

## Wyniki

### Service role

`SUPABASE_SERVICE_ROLE_KEY` występuje wyłącznie w server-only miejscach: publiczne strony tokenowe renderowane na serwerze, server helpers promocji/e-mail oraz cancellation route. Nie występuje jako `NEXT_PUBLIC_*`, w Client Component ani w wygenerowanym statycznym bundlu. Nie znaleziono wartości klucza w repozytorium.

### Git i pliki środowiskowe

- Żaden `.env*` nie jest śledzony.
- `.gitignore` obejmuje `.env*`, PEM, temp Supabase i backupy.
- Historia nie zawierała śledzonych plików env ani rozpoznanych `sb_secret_*`, JWT-like secretów czy PostgreSQL connection string z hasłem.
- Wystąpienia słów `service_role`, `RESEND_API_KEY`, `DATABASE_URL` są identyfikatorami konfiguracji/testami, nie wartościami.

Wniosek: **NO CONFIRMED SECRET LEAK FOUND IN REVIEWED REPOSITORY/HISTORY**. Nie jest to potwierdzenie braku sekretów w historii zewnętrznych forków, logach CI, Vercel ani dashboardzie Supabase.

### Bundle klienta

W `.next/static` nie znaleziono literalnego `SUPABASE_SERVICE_ROLE_KEY`, `RESEND_API_KEY` ani pasującej wartości secret. Publiczny anon key z natury jest przeznaczony dla klienta i wymaga poprawnego RLS/ACL.

### Logi i error handling

- Nie znaleziono logowania Authorization header, cookies, pełnego request body, service key, tokenów check-in/promotion ani haseł.
- Serwerowe API zazwyczaj loguje tylko kontrolowany kod błędu.
- Część klienta loguje surowe obiekty Supabase lub pokazuje `error.message` — SEC-013.
- Nie znaleziono stack trace zwracanego jawnie z route handlerów.

## Konfiguracja zewnętrzna — NOT VERIFIED

- Wartości i rotacja sekretów w Vercel/Supabase/Resend.
- Ochrona branch/deployment secrets i logi CI.
- Supabase Auth settings, SMTP i JWT expiry.
- Bucket policies Storage (brak kodu Storage w repo).
- Nagłówki dodawane przez hosting/CDN.

## Powiązane findings

- **SEC-013 LOW CONFIRMED** — surowe komunikaty/obiekty błędów w wybranych klientach.
- **SEC-012 LOW CONFIRMED** — aplikacja sama nie definiuje kompletu security headers; stan platformy niezweryfikowany.

## Werdykt etapu

Nie znaleziono potwierdzonego sekretu w kodzie, historii ani statycznym bundlu. Konfiguracja i logi usług zewnętrznych wymagają osobnego audytu operatora.
