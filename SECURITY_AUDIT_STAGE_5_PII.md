# CSK Booking — etap 5: techniczny audyt danych osobowych

To nie jest analiza prawna RODO. Ocena dotyczy zabezpieczeń, zakresu dostępu, minimalizacji, retencji i przepływów danych.

## 1. Inwentaryzacja PII

| Obiekt/pole | Klasa | Ocena minimalizacji | Uzasadnienie/uwaga |
| --- | --- | --- | --- |
| profil: imię, nazwisko, e-mail | identyfikacja/kontakt | REQUIRED | konto, potwierdzenia, obsługa |
| telefon | kontakt | JUSTIFIED | operacyjny kontakt/rezerwacja; cel powinien być udokumentowany |
| pełny adres | adres zamieszkania | QUESTIONABLE | brak dowodu, że każda funkcja systemu go wymaga |
| deklaracje uprawnień/kwalifikacji | dane zawodowe/uprawnienia | JUSTIFIED | proces kwalifikacji, ale wymaga ścisłego dostępu i retencji |
| status/notatka weryfikacji | dane administracyjne | JUSTIFIED | tylko admin; szczególnie wrażliwy swobodny tekst |
| reservation/event snapshots | imię, e-mail, telefon | JUSTIFIED | historyczna obsługa rezerwacji; duplikacja zwiększa retencję |
| daty, godziny, uczestnictwo, check-in | historia aktywności | JUSTIFIED | podstawowy proces; wrażliwe behawioralnie |
| check-in/promotion token | bearer secret/pseudonim | REQUIRED | potrzebny workflow, ale wymaga expiry/revocation/minimal exposure |
| audit actor/target/details | pseudonim/PII | JUSTIFIED | bezpieczeństwo; details powinno mieć schema allowlist |
| e-mail provider message ID/recipient UUID | pseudonim/metadata | JUSTIFIED | idempotencja i diagnostyka z retencją |
| IP HMAC + timestampy | pseudonimowe telemetry | JUSTIFIED | rate limiting; krótka retencja |
| swobodne reason/notes/descriptions | możliwe incydentalne PII | QUESTIONABLE | łatwo wpisać więcej danych niż potrzeba |

Nie znaleziono pól ewidentnie **UNNECESSARY** bez poznania wymogów operacyjnych, ale pełny adres i swobodne notatki wymagają decyzji właściciela danych.

## 2. Przepływy

### Konto i profil

```text
formularz rejestracji
→ Supabase Auth metadata
→ handle_new_user()
→ profiles
→ własny panel / admin_list_users_v1
→ ewentualna administracyjna weryfikacja i audit
```

### Rezerwacja

```text
profil + formularz Booking
→ create_reservation_v2 (auth.uid)
→ snapshot PII w reservations
→ panel user/admin/scoped profile RPC
→ confirmation/cancellation email
→ link z check_in_token
→ publiczna strona check-in z PII
→ audit/email_deliveries
```

### Event

```text
profil + register_for_event
→ snapshot PII w event_registrations
→ panel staff/instructor
→ confirmation/promotion email
→ promotion token w URL
→ publiczny confirm GET
→ audit/email metadata
```

PII jest celowo kopiowane do snapshotów rezerwacji/zapisów, co zachowuje dane historyczne po zmianie profilu. Zwiększa to liczbę miejsc wymagających anonimizacji/usunięcia.

## 3. Dostęp administracyjny

- Admin: globalny dostęp do profili, rezerwacji, zapisów eventów i audit logs.
- Pracownik: globalne rezerwacje i event registrations; profile klientów tylko przez reservation-scoped RPC.
- Instruktor: brak globalnych profiles/reservations, ale globalny `event_registrations` wraz z danymi kontaktowymi i tokenami — SEC-008.
- Calendar feed celowo nie zwraca rezerwacji instruktorowi i używa ograniczonego DTO.
- `admin_list_users_v1()` zwraca obszerny zestaw PII, ale funkcja sprawdza dokładnie rolę admin.

## 4. E-mail

- W treści występują imię, event/lane, data i czas oraz linki tokenowe. Nie znaleziono surowych UUID użytkownika ani admin notes w wiadomościach.
- Confirmation workflows mają claim/idempotencję i nie zwracają tokenu providerowi-klientowi.
- Tokeny w URL mogą trafić do logów poczty/przeglądarki/referrer; check-in token nie ma widocznego expiry — SEC-005.
- Dwa szablony nie escapują HTML — SEC-006.
- `email_deliveries` zapisuje metadane, nie pełną treść wiadomości.

## 5. Retencja i prawa techniczne

Nie znaleziono kompletnego technicznego workflow:

- samodzielnego usunięcia konta,
- anonimizacji snapshotów PII,
- okresowego usuwania starych rezerwacji/zapisów/audytów/email metadata,
- eksportu wszystkich danych użytkownika,
- wygaszania/revocation check-in tokenów.

Istnieją administracyjne/usługowe mechanizmy cząstkowe i historyczne cleanupy testów, lecz nie tworzą ogólnej polityki retencji. To finding SEC-009.

---

### SEC-005

Severity: **MEDIUM**
Status: **CONFIRMED**
Affected: `app/check-in/[token]/page.tsx:38-112,190-208`, `reservations.check_in_token`
Opis: publiczna strona przy znajomości UUID bearer tokenu używa service role i pokazuje pełne imię, e-mail, telefon, harmonogram, status/płatność. W schemacie nie ma osobnego expiry/revoked_at dla tokenu.
Attack scenario: URL wycieka z e-maila, historii, screenshotu lub logu; posiadacz może odczytywać PII tak długo, jak rekord/token istnieje. Entropia UUID ogranicza guessing, nie ogranicza skutku wycieku.
Impact/data: kontakt i historia rezerwacji klienta.
Evidence: lookup `.eq("check_in_token", token)` przez service-role i render pól kontaktowych.
Remediation: krótko żyjący, rotowalny token (najlepiej hash w DB), minimalny publiczny DTO, opcjonalne ponowne potwierdzenie tożsamości; polityka referrer/cache.
Regression test: expired/revoked/rotated token = no PII; ważny token zwraca tylko minimalny zestaw.

### SEC-009

Severity: **MEDIUM**
Status: **CONFIRMED**
Affected: `profiles`, `reservations`, `event_registrations`, `audit_logs`, `email_deliveries`
Opis: repozytorium nie zawiera ogólnego mechanizmu retencji, anonimizacji, self-delete ani pełnego eksportu użytkownika. Snapshoty PII i tokeny mogą pozostać bez jawnego limitu.
Attack scenario: incydent lub nadmierny dostęp obejmuje wieloletnią historię, choć część danych nie jest już potrzebna operacyjnie.
Impact/data: pełny katalog PII i historia aktywności.
Evidence: brak scheduled cleanup/retention fields/workflows obejmujących te zbiory; dostępne funkcje operacyjne nie realizują lifecycle.
Remediation: uzgodnić okresy, klasy danych i wyjątki audytowe; wdrożyć anonimizację/export/delete z kontrolą referencji i testami.
Regression test: fixture starszy niż próg jest anonimizowany/usuwany, bieżące wymagane dane i immutable security audit pozostają zgodnie z polityką.

### SEC-016

Severity: **INFO**
Status: **CONFIRMED**
Affected: publiczna informacja prywatności
Opis: strona prywatności zawiera informację, że część danych kontaktowych administratora należy uzupełnić przed publikacją. Jest to gotowość operacyjna, nie techniczny exploit.
Remediation: uzupełnić i zatwierdzić treść przed finalnym uruchomieniem usługi.

## Ocena

Ownership i kontrolowane RPC znacząco ograniczają ekspozycję zwykłego użytkownika. Najpilniejsze obszary PII to publiczny check-in token, zakres instruktora, retencja oraz bezpieczeństwo treści e-mail.
