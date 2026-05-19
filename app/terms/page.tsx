export default function TermsPage() {
  return (
    <main className="min-h-screen bg-zinc-950 text-white">
      <section className="mx-auto max-w-4xl px-6 py-12">
        <p className="mb-4 text-sm uppercase tracking-[0.35em] text-green-500">
          CSK Booking
        </p>

        <h1 className="mb-4 text-4xl font-bold">Regulamin i RODO</h1>

        <p className="mb-8 text-zinc-400">
          Poniżej znajduje się roboczy regulamin korzystania ze strzelnicy oraz
          link do polityki prywatności / klauzuli RODO. Przed użyciem
          produkcyjnym treść warto dopasować do oficjalnego regulaminu obiektu.
        </p>

        <div className="mb-8 grid gap-4 md:grid-cols-2">
          <a
            href="#regulamin"
            className="rounded-2xl border border-green-800 bg-green-950 p-5 transition hover:bg-green-900"
          >
            <h2 className="mb-2 text-xl font-bold text-green-300">
              Regulamin strzelnicy
            </h2>
            <p className="text-sm text-green-100">
              Zasady rezerwacji, bezpieczeństwa i korzystania z obiektu.
            </p>
          </a>

          <a
            href="/privacy"
            className="rounded-2xl border border-zinc-700 bg-zinc-900 p-5 transition hover:bg-zinc-800"
          >
            <h2 className="mb-2 text-xl font-bold">
              Polityka prywatności / RODO
            </h2>
            <p className="text-sm text-zinc-400">
              Informacje o przetwarzaniu danych osobowych użytkowników systemu.
            </p>
          </a>
        </div>

        <div
          id="regulamin"
          className="space-y-6 rounded-2xl border border-zinc-800 bg-zinc-900 p-6"
        >
          <section>
            <h2 className="mb-3 text-2xl font-semibold">1. Zasady ogólne</h2>

            <div className="space-y-2 text-zinc-300">
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

          <section>
            <h2 className="mb-3 text-2xl font-semibold">2. Rezerwacje</h2>

            <div className="space-y-2 text-zinc-300">
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

          <section>
            <h2 className="mb-3 text-2xl font-semibold">3. Bezpieczeństwo</h2>

            <div className="space-y-2 text-zinc-300">
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

          <section>
            <h2 className="mb-3 text-2xl font-semibold">
              4. Ochrona słuchu i wzroku
            </h2>

            <div className="space-y-2 text-zinc-300">
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

          <section>
            <h2 className="mb-3 text-2xl font-semibold">
              5. Stan psychofizyczny
            </h2>

            <div className="space-y-2 text-zinc-300">
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

          <section>
            <h2 className="mb-3 text-2xl font-semibold">6. Odpowiedzialność</h2>

            <div className="space-y-2 text-zinc-300">
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

          <section>
            <h2 className="mb-3 text-2xl font-semibold">
              7. Dane osobowe i RODO
            </h2>

            <div className="space-y-2 text-zinc-300">
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
                className="mt-4 inline-block rounded-xl bg-green-700 px-5 py-3 text-sm font-semibold text-white transition hover:bg-green-600"
              >
                Przejdź do Polityki prywatności / RODO
              </a>
            </div>
          </section>
        </div>

        <div className="mt-8 flex flex-col gap-3 sm:flex-row">
          <a
            href="/register"
            className="rounded-xl border border-green-800 px-5 py-3 text-center text-sm font-semibold text-green-400 transition hover:bg-green-950"
          >
            ← Wróć do rejestracji
          </a>

          <a
            href="/dashboard"
            className="rounded-xl border border-zinc-700 px-5 py-3 text-center text-sm font-semibold text-zinc-300 transition hover:bg-zinc-900"
          >
            Panel klienta
          </a>

          <a
            href="/privacy"
            className="rounded-xl border border-zinc-700 px-5 py-3 text-center text-sm font-semibold text-zinc-300 transition hover:bg-zinc-900"
          >
            Polityka prywatności / RODO
          </a>

          <a
            href="/booking"
            className="rounded-xl bg-green-700 px-5 py-3 text-center text-sm font-semibold text-white transition hover:bg-green-600"
          >
            Przejdź do rezerwacji
          </a>
        </div>
      </section>
    </main>
  );
}