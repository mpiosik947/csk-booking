import Image from "next/image";

export default function TermsPage() {
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
            Regulamin i RODO
          </h1>

          <p className="mt-4 text-left leading-7 text-[#a9ada4] sm:text-center">
            Poniżej znajdują się zasady korzystania ze strzelnicy oraz link do
            aktualnej polityki prywatności i informacji o przetwarzaniu danych.
          </p>
        </header>

        <div className="mb-8 grid gap-4 md:grid-cols-2">
          <a
            href="#regulamin"
            className="rounded-2xl border border-[#536143] bg-[#191e19] p-5 transition hover:border-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
          >
            <h2 className="mb-2 text-xl font-bold text-[#d7c895]">
              Regulamin strzelnicy
            </h2>
            <p className="text-sm leading-6 text-[#a9ada4]">
              Zasady rezerwacji, bezpieczeństwa i korzystania z obiektu.
            </p>
          </a>

          <a
            href="/privacy"
            className="rounded-2xl border border-[#30372c] bg-[#191e19] p-5 transition hover:border-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
          >
            <h2 className="mb-2 text-xl font-bold text-[#d7c895]">
              Polityka prywatności / RODO
            </h2>
            <p className="text-sm leading-6 text-[#a9ada4]">
              Informacje o przetwarzaniu danych osobowych użytkowników systemu.
            </p>
          </a>
        </div>

        <div
          id="regulamin"
          className="space-y-5"
        >
          <section className="rounded-2xl border border-[#30372c] bg-[#191e19] p-5 sm:p-6">
            <h2 className="mb-3 text-xl font-semibold text-[#d7c895] sm:text-2xl">1. Zasady ogólne</h2>

            <div className="space-y-3 leading-7 text-[#a9ada4]">
              <p>
                1. Każda osoba korzystająca ze strzelnicy zobowiązana jest do
                przestrzegania regulaminu obiektu, poleceń obsługi oraz zasad
                bezpieczeństwa.
              </p>
              <p>
                2. Wejście na teren strzelnicy oznacza akceptację regulaminu i
                obowiązujących procedur bezpieczeństwa.
              </p>
              <p>
                3. Osoby korzystające ze strzelnicy są zobowiązane do
                zachowania szczególnej ostrożności i odpowiedzialności.
              </p>
              <p>
                4. Obsługa strzelnicy ma prawo odmówić dopuszczenia do
                strzelania osobie, która narusza zasady bezpieczeństwa albo
                znajduje się w stanie uniemożliwiającym bezpieczne korzystanie z
                obiektu.
              </p>
              <p>
                5. Osoba korzystająca ze strzelnicy zobowiązana jest do
                stosowania się do poleceń prowadzącego strzelanie, instruktora
                lub osoby wyznaczonej przez obsługę.
              </p>
            </div>
          </section>

          <section className="rounded-2xl border border-[#30372c] bg-[#191e19] p-5 sm:p-6">
            <h2 className="mb-3 text-xl font-semibold text-[#d7c895] sm:text-2xl">2. Rezerwacje</h2>

            <div className="space-y-3 leading-7 text-[#a9ada4]">
              <p>
                1. Rezerwacja osi odbywa się przez system rezerwacyjny CSK
                Booking.
              </p>
              <p>
                2. Rezerwacja zostaje potwierdzona automatycznie po wybraniu
                wolnego terminu i zatwierdzeniu formularza.
              </p>
              <p>
                3. Płatność za rezerwację odbywa się na miejscu przed
                rozpoczęciem strzelania.
              </p>
              <p>
                4. Klient może anulować rezerwację samodzielnie najpóźniej 12
                godzin przed terminem.
              </p>
              <p>
                5. Po upływie tego czasu anulowanie rezerwacji możliwe jest
                wyłącznie przez kontakt z obsługą strzelnicy.
              </p>
              <p>
                6. Nieobecność bez wcześniejszego anulowania może skutkować
                ograniczeniem możliwości kolejnych rezerwacji.
              </p>
              <p>
                7. Obsługa strzelnicy ma prawo anulować lub zmienić rezerwację
                w przypadku awarii, prac technicznych, szkolenia zamkniętego,
                zawodów lub innych przyczyn organizacyjnych.
              </p>
            </div>
          </section>

          <section className="rounded-2xl border border-[#30372c] bg-[#191e19] p-5 sm:p-6">
            <h2 className="mb-3 text-xl font-semibold text-[#d7c895] sm:text-2xl">3. Bezpieczeństwo</h2>

            <div className="space-y-3 leading-7 text-[#a9ada4]">
              <p>
                1. Broń na terenie strzelnicy należy traktować zawsze jako
                załadowaną.
              </p>
              <p>
                2. Lufa broni musi być zawsze skierowana w bezpiecznym kierunku.
              </p>
              <p>
                3. Palec należy trzymać poza językiem spustowym do momentu
                oddania świadomego strzału.
              </p>
              <p>
                4. Strzelać wolno wyłącznie do wyznaczonych celów i wyłącznie
                na polecenie osoby prowadzącej strzelanie albo obsługi
                strzelnicy.
              </p>
              <p>
                5. Zabrania się kierowania broni w stronę ludzi, zwierząt,
                infrastruktury oraz miejsc niewyznaczonych jako kulochwyt.
              </p>
              <p>
                6. Obowiązuje bezwzględny zakaz manipulowania bronią poza
                wyznaczonymi miejscami.
              </p>
              <p>
                7. W przypadku komendy przerwania strzelania należy natychmiast
                przerwać czynności, zabezpieczyć broń i wykonać polecenia osoby
                prowadzącej.
              </p>
            </div>
          </section>

          <section className="rounded-2xl border border-[#30372c] bg-[#191e19] p-5 sm:p-6">
            <h2 className="mb-3 text-xl font-semibold text-[#d7c895] sm:text-2xl">
              4. Ochrona słuchu i wzroku
            </h2>

            <div className="space-y-3 leading-7 text-[#a9ada4]">
              <p>
                1. Na osi strzeleckiej obowiązuje używanie ochrony słuchu.
              </p>
              <p>
                2. Zaleca się używanie ochrony wzroku przez wszystkich
                uczestników strzelania oraz osoby przebywające w pobliżu osi.
              </p>
              <p>
                3. Osoba bez wymaganej ochrony może zostać niedopuszczona do
                strzelania.
              </p>
            </div>
          </section>

          <section className="rounded-2xl border border-[#30372c] bg-[#191e19] p-5 sm:p-6">
            <h2 className="mb-3 text-xl font-semibold text-[#d7c895] sm:text-2xl">
              5. Stan psychofizyczny
            </h2>

            <div className="space-y-3 leading-7 text-[#a9ada4]">
              <p>
                1. Zabrania się korzystania ze strzelnicy pod wpływem alkoholu,
                środków odurzających albo substancji mogących wpływać na
                bezpieczeństwo.
              </p>
              <p>
                2. Osoba korzystająca ze strzelnicy oświadcza, że jej stan
                zdrowia i stan psychofizyczny pozwalają na bezpieczny udział w
                strzelaniu.
              </p>
              <p>
                3. Obsługa ma prawo przerwać strzelanie lub odmówić udziału
                osobie, której zachowanie wzbudza wątpliwości co do
                bezpieczeństwa.
              </p>
            </div>
          </section>

          <section className="rounded-2xl border border-[#30372c] bg-[#191e19] p-5 sm:p-6">
            <h2 className="mb-3 text-xl font-semibold text-[#d7c895] sm:text-2xl">6. Odpowiedzialność</h2>

            <div className="space-y-3 leading-7 text-[#a9ada4]">
              <p>
                1. Użytkownik ponosi odpowiedzialność za swoje działania na
                terenie strzelnicy.
              </p>
              <p>
                2. Wszelkie uszkodzenia infrastruktury wynikające z naruszenia
                zasad bezpieczeństwa mogą skutkować obciążeniem kosztami
                naprawy.
              </p>
              <p>
                3. Nieprzestrzeganie regulaminu może skutkować natychmiastowym
                usunięciem z terenu strzelnicy.
              </p>
              <p>
                4. Użytkownik ponosi odpowiedzialność za prawidłowe i bezpieczne
                posługiwanie się bronią oraz przestrzeganie poleceń obsługi.
              </p>
            </div>
          </section>

          <section className="rounded-2xl border border-[#30372c] bg-[#191e19] p-5 sm:p-6">
            <h2 className="mb-3 text-xl font-semibold text-[#d7c895] sm:text-2xl">
              7. Dane osobowe i RODO
            </h2>

            <div className="space-y-3 leading-7 text-[#a9ada4]">
              <p>
                1. Dane osobowe podane w systemie rezerwacyjnym są przetwarzane
                w celu obsługi konta, rezerwacji, kontaktu z klientem oraz
                organizacji korzystania ze strzelnicy.
              </p>
              <p>
                2. Szczegółowe informacje dotyczące przetwarzania danych
                osobowych znajdują się w Polityce prywatności / RODO.
              </p>
              <p>
                3. Korzystając z systemu rezerwacji, użytkownik potwierdza
                zapoznanie się z regulaminem oraz informacją o przetwarzaniu
                danych osobowych.
              </p>

              <a
                href="/privacy"
                className="mt-4 inline-flex min-h-11 items-center rounded-xl bg-[#536143] px-5 py-3 text-sm font-semibold text-[#f2efe4] transition hover:bg-[#78865f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#191e19]"
              >
                Przejdź do Polityki prywatności / RODO
              </a>
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
            href="/register"
            className="inline-flex min-h-11 items-center justify-center rounded-xl border border-[#30372c] px-5 py-3 text-center text-sm font-semibold text-[#a9ada4] transition hover:border-[#d7c895] hover:text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
          >
            ← Wróć do rejestracji
          </a>

          <a
            href="/dashboard"
            className="inline-flex min-h-11 items-center justify-center rounded-xl border border-[#30372c] px-5 py-3 text-center text-sm font-semibold text-[#a9ada4] transition hover:border-[#d7c895] hover:text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
          >
            Panel klienta
          </a>

          <a
            href="/privacy"
            className="inline-flex min-h-11 items-center justify-center rounded-xl border border-[#30372c] px-5 py-3 text-center text-sm font-semibold text-[#a9ada4] transition hover:border-[#d7c895] hover:text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
          >
            Polityka prywatności / RODO
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
