import Image from "next/image";

const sectionClass =
  "rounded-2xl border border-[#30372c] bg-[#191e19] p-5 sm:p-6";

export default function PrivacyPage() {
  return (
    <main className="min-h-screen bg-[#090b09] px-4 py-6 text-[#f2efe4] sm:px-6 sm:py-8">
      <article className="mx-auto max-w-4xl rounded-[2rem] border border-[#30372c] bg-[#141814] p-5 shadow-2xl shadow-black/20 sm:p-8 lg:p-10">
        <header className="mb-8 text-center">
          <Image
            src="/login-brand.png"
            alt="Centrum Szkolenia Krutla"
            width={1536}
            height={1024}
            className="mx-auto h-auto w-full max-w-[220px] sm:max-w-[260px]"
            priority
          />
          <h1 className="mt-5 text-3xl font-bold sm:text-4xl">
            Polityka prywatności i klauzula RODO
          </h1>
          <p className="mt-4 text-left leading-7 text-[#a9ada4] sm:text-center">
            Dokument opisuje kategorie danych i procesy związane z korzystaniem
            z systemu rezerwacji CSK Booking.
          </p>
          <p className="mt-2 text-sm text-[#858c7f]">
            Ostatnia aktualizacja: 4 września 2026 r.
          </p>
        </header>

        <div className="space-y-5">
          <section className={sectionClass}>
            <h2 className="mb-3 text-xl font-semibold text-[#d7c895] sm:text-2xl">
              1. Administrator danych
            </h2>
            <div className="space-y-3 leading-7 text-[#a9ada4]">
              <p>
                Dane identyfikujące administratora zostaną uzupełnione przed
                formalnym uruchomieniem usługi.
              </p>
              <div className="overflow-hidden rounded-xl border border-[#6f5a2e] bg-[#201d15] p-4 text-sm leading-7 text-[#d7c895]">
                <p className="font-semibold">
                  DO UZUPEŁNIENIA PRZED FORMALNYM URUCHOMIENIEM USŁUGI
                </p>
                <p>Nazwa / imię i nazwisko: [DO UZUPEŁNIENIA]</p>
                <p>Forma prawna: [DO UZUPEŁNIENIA]</p>
                <p>Adres: [DO UZUPEŁNIENIA]</p>
                <p>Kontakt w sprawach prywatności: [DO UZUPEŁNIENIA]</p>
              </div>
            </div>
          </section>

          <section className={sectionClass}>
            <h2 className="mb-3 text-xl font-semibold text-[#d7c895] sm:text-2xl">
              2. Jakie dane przetwarza system
            </h2>
            <div className="space-y-3 leading-7 text-[#a9ada4]">
              <p>W zależności od używanych funkcji system przetwarza:</p>
              <ul className="list-disc space-y-1 pl-6">
                <li>
                  dane konta i profilu, w tym identyfikator konta, imię,
                  nazwisko, adres e-mail, numer telefonu i podany adres,
                </li>
                <li>
                  deklarowane uprawnienia i kwalifikacje oraz informacje o ich
                  weryfikacji przez obsługę,
                </li>
                <li>
                  dane rezerwacji, w tym zasób, termin, czas trwania, liczbę
                  osób, cenę, status rezerwacji i status płatności,
                </li>
                <li>
                  dane zapisów na wydarzenia i szkolenia, ich status, obecność
                  oraz status płatności,
                </li>
                <li>statusy związane z obsługą obecności i check-in,</li>
                <li>
                  informacje techniczne o dostarczeniu wiadomości e-mail, bez
                  przechowywania treści wiadomości w rejestrze dostarczenia,
                </li>
                <li>
                  dane bezpieczeństwa i sesji, identyfikatory techniczne, dane
                  potrzebne do ograniczania nadużyć oraz logi audytowe operacji.
                </li>
              </ul>
            </div>
          </section>

          <section className={sectionClass}>
            <h2 className="mb-3 text-xl font-semibold text-[#d7c895] sm:text-2xl">
              3. Cele przetwarzania
            </h2>
            <div className="space-y-3 leading-7 text-[#a9ada4]">
              <p>Dane są wykorzystywane w celu:</p>
              <ul className="list-disc space-y-1 pl-6">
                <li>utworzenia, uwierzytelniania i obsługi konta,</li>
                <li>przyjmowania i realizacji rezerwacji,</li>
                <li>obsługi wydarzeń, szkoleń, anulowań i list rezerwowych,</li>
                <li>obsługi obecności, check-in i płatności na miejscu,</li>
                <li>wysyłania wiadomości związanych z usługą,</li>
                <li>zapewnienia bezpieczeństwa i wykrywania nadużyć,</li>
                <li>prowadzenia audytu istotnych operacji,</li>
                <li>obsługi eksportu danych i żądania usunięcia konta.</li>
              </ul>
            </div>
          </section>

          <section className={sectionClass}>
            <h2 className="mb-3 text-xl font-semibold text-[#d7c895] sm:text-2xl">
              4. Podstawy przetwarzania
            </h2>
            <div className="space-y-3 leading-7 text-[#a9ada4]">
              <p>
                W zależności od celu przetwarzanie może być niezbędne do
                wykonania umowy lub podjęcia działań przed jej zawarciem,
                wykonania obowiązku prawnego, realizacji uzasadnionych interesów
                związanych z organizacją, bezpieczeństwem i ochroną roszczeń
                albo odbywać się na podstawie zgody, gdy jest ona wymagana.
              </p>
            </div>
          </section>

          <section className={sectionClass}>
            <h2 className="mb-3 text-xl font-semibold text-[#d7c895] sm:text-2xl">
              5. Dostawcy techniczni i odbiorcy danych
            </h2>
            <div className="space-y-3 leading-7 text-[#a9ada4]">
              <p>
                W działaniu systemu uczestniczą dostawcy techniczni wspierający
                realizację usługi:
              </p>
              <ul className="list-disc space-y-1 pl-6">
                <li>Supabase — baza danych i uwierzytelnianie,</li>
                <li>Vercel — hosting aplikacji,</li>
                <li>Resend — wysyłka wiadomości e-mail.</li>
              </ul>
              <p>
                Dane mogą być również dostępne upoważnionej obsłudze systemu
                oraz podmiotom uprawnionym na podstawie przepisów prawa. Dane
                nie są sprzedawane ani wykorzystywane do reklamy w aplikacji.
              </p>
            </div>
          </section>

          <section className={sectionClass}>
            <h2 className="mb-3 text-xl font-semibold text-[#d7c895] sm:text-2xl">
              6. Okres przechowywania
            </h2>
            <div className="space-y-3 leading-7 text-[#a9ada4]">
              <p>
                Dane są przechowywane tak długo, jak jest to potrzebne do
                realizacji celów operacyjnych, bezpieczeństwa, obowiązków
                organizacyjnych oraz do czasu anonimizacji lub usunięcia zgodnie
                z obowiązującym procesem.
              </p>
              <p>
                Konkretne okresy przechowywania dla poszczególnych kategorii
                danych wymagają odrębnego zatwierdzenia. Do tego czasu system
                zachowuje dane zgodnie z aktualnymi procesami operacyjnymi i
                bezpieczeństwa.
              </p>
            </div>
          </section>

          <section className={sectionClass}>
            <h2 className="mb-3 text-xl font-semibold text-[#d7c895] sm:text-2xl">
              7. Eksport danych i usunięcie konta
            </h2>
            <div className="space-y-3 leading-7 text-[#a9ada4]">
              <p>
                Z poziomu konta funkcja „Pobierz moje dane” pozwala pobrać
                wersjonowany eksport danych użytkownika objętych aktualnym
                kontraktem aplikacji. Eksport nie zawiera haseł, tokenów,
                notatek administracyjnych, danych bezpieczeństwa ani danych
                innych użytkowników.
              </p>
              <p>
                Użytkownik może również zażądać usunięcia własnego konta.
                Bezpośrednie dane osobowe są wtedy usuwane lub anonimizowane, a
                aktywne tokeny związane z kontem są unieważniane.
              </p>
              <p>
                Historyczne rekordy rezerwacji i zapisów na wydarzenia mogą
                zostać zachowane jako nieidentyfikujące dane operacyjne i
                statystyczne. Rejestry audytowe i bezpieczeństwa mogą pozostać
                w formie pseudonimizowanej, bez bezpośrednich danych osobowych.
              </p>
            </div>
          </section>

          <section className={sectionClass}>
            <h2 className="mb-3 text-xl font-semibold text-[#d7c895] sm:text-2xl">
              8. Bezpieczeństwo i audyt
            </h2>
            <div className="space-y-3 leading-7 text-[#a9ada4]">
              <p>
                System wykorzystuje uwierzytelnianie, kontrolę dostępu,
                ograniczanie częstotliwości wybranych operacji oraz logi
                audytowe. Mechanizmy te służą ochronie kont, danych i historii
                operacji oraz ograniczaniu nadużyć.
              </p>
              <p>
                Dostęp do danych operacyjnych jest uzależniony od roli i celu
                dostępu. Po usunięciu konta powiązane dane audytowe są
                pseudonimizowane zgodnie z procesem anonimizacji.
              </p>
            </div>
          </section>

          <section className={sectionClass}>
            <h2 className="mb-3 text-xl font-semibold text-[#d7c895] sm:text-2xl">
              9. Sesja i niezbędne pliki cookies
            </h2>
            <div className="space-y-3 leading-7 text-[#a9ada4]">
              <p>
                System korzysta z mechanizmów sesji Supabase Auth i niezbędnych
                danych przechowywanych przez przeglądarkę w celu logowania,
                utrzymania sesji oraz ochrony dostępu do funkcji konta.
              </p>
              <p>
                Aplikacja nie wykorzystuje reklamowych ani marketingowych
                plików cookies.
              </p>
            </div>
          </section>

          <section className={sectionClass}>
            <h2 className="mb-3 text-xl font-semibold text-[#d7c895] sm:text-2xl">
              10. Prawa użytkownika
            </h2>
            <div className="space-y-3 leading-7 text-[#a9ada4]">
              <p>
                W zakresie wynikającym z obowiązujących przepisów użytkownik
                może:
              </p>
              <ul className="list-disc space-y-1 pl-6">
                <li>uzyskać dostęp do swoich danych i je poprawić,</li>
                <li>pobrać dane przez funkcję „Pobierz moje dane”,</li>
                <li>zażądać usunięcia konta i anonimizacji danych,</li>
                <li>żądać ograniczenia przetwarzania lub wnieść sprzeciw,</li>
                <li>cofnąć zgodę, jeżeli przetwarzanie opiera się na zgodzie,</li>
                <li>wnieść skargę do Prezesa Urzędu Ochrony Danych Osobowych,</li>
                <li>skontaktować się w sprawie swoich danych.</li>
              </ul>
            </div>
          </section>

          <section className={sectionClass}>
            <h2 className="mb-3 text-xl font-semibold text-[#d7c895] sm:text-2xl">
              11. Dobrowolność podania danych
            </h2>
            <div className="space-y-3 leading-7 text-[#a9ada4]">
              <p>
                Podanie danych jest dobrowolne, ale dane oznaczone jako wymagane
                są niezbędne do utworzenia konta lub skorzystania z wybranych
                funkcji rezerwacyjnych i wydarzeń.
              </p>
            </div>
          </section>

          <section className={sectionClass}>
            <h2 className="mb-3 text-xl font-semibold text-[#d7c895] sm:text-2xl">
              12. Kontakt i zmiany dokumentu
            </h2>
            <div className="space-y-3 leading-7 text-[#a9ada4]">
              <p>
                Kontakt w sprawach prywatności: [DO UZUPEŁNIENIA PRZED
                FORMALNYM URUCHOMIENIEM USŁUGI]
              </p>
              <p>
                Dokument może być aktualizowany w przypadku zmian w systemie,
                sposobie przetwarzania danych lub obowiązujących wymaganiach.
                Aktualna wersja jest publikowana w systemie CSK Booking.
              </p>
            </div>
          </section>
        </div>

        <nav
          aria-label="Nawigacja dokumentu"
          className="mt-8 flex flex-col gap-3 border-t border-[#30372c] pt-6 sm:flex-row sm:flex-wrap"
        >
          <a
            href="/"
            className="inline-flex min-h-11 items-center justify-center rounded-xl border border-[#30372c] px-5 py-3 text-center text-sm font-semibold text-[#d7c895] transition hover:border-[#d7c895] hover:bg-[#191e19] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
          >
            ← Powrót do strony głównej
          </a>
          <a
            href="/dashboard"
            className="inline-flex min-h-11 items-center justify-center rounded-xl border border-[#30372c] px-5 py-3 text-center text-sm font-semibold text-[#a9ada4] transition hover:border-[#d7c895] hover:text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
          >
            ← Panel klienta
          </a>
          <a
            href="/terms"
            className="inline-flex min-h-11 items-center justify-center rounded-xl border border-[#30372c] px-5 py-3 text-center text-sm font-semibold text-[#a9ada4] transition hover:border-[#d7c895] hover:text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
          >
            Regulamin
          </a>
          <a
            href="/booking"
            className="inline-flex min-h-11 items-center justify-center rounded-xl bg-[#536143] px-5 py-3 text-center text-sm font-semibold text-[#f2efe4] transition hover:bg-[#78865f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
          >
            Przejdź do rezerwacji
          </a>
        </nav>
      </article>
    </main>
  );
}
