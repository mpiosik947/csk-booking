export default function PrivacyPage() {
  return (
    <main className="min-h-screen bg-zinc-950 text-white">
      <section className="mx-auto max-w-4xl px-6 py-12">
        <p className="mb-4 text-sm uppercase tracking-[0.35em] text-green-500">
          CSK Booking
        </p>

        <h1 className="mb-4 text-4xl font-bold">
          Polityka prywatności i klauzula RODO
        </h1>

        <p className="mb-8 text-zinc-400">
          Poniższy dokument jest roboczą wersją polityki prywatności dla
          systemu rezerwacji CSK Booking. Przed wdrożeniem produkcyjnym warto
          dopasować dane administratora oraz skonsultować treść z prawnikiem.
        </p>

        <div className="space-y-6 rounded-2xl border border-zinc-800 bg-zinc-900 p-6">
          <section>
            <h2 className="mb-3 text-2xl font-semibold">
              1. Administrator danych
            </h2>

            <div className="space-y-2 text-zinc-300">
              <p>
                Administratorem danych osobowych użytkowników systemu
                rezerwacyjnego jest właściciel lub zarządca obiektu
                strzeleckiego Centrum Szkolenia Krutla.
              </p>

              <p>
                Dane kontaktowe administratora zostaną uzupełnione przed
                uruchomieniem systemu produkcyjnego.
              </p>

              <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4 text-sm text-zinc-400">
                <p>Do uzupełnienia:</p>
                <p>Nazwa podmiotu: ........................................</p>
                <p>Adres: ................................................</p>
                <p>E-mail kontaktowy: .....................................</p>
                <p>Telefon: ...............................................</p>
              </div>
            </div>
          </section>

          <section>
            <h2 className="mb-3 text-2xl font-semibold">
              2. Zakres przetwarzanych danych
            </h2>

            <div className="space-y-2 text-zinc-300">
              <p>
                W ramach systemu CSK Booking mogą być przetwarzane następujące
                dane osobowe użytkownika:
              </p>

              <ul className="list-disc space-y-1 pl-6">
                <li>imię i nazwisko,</li>
                <li>adres e-mail,</li>
                <li>numer telefonu,</li>
                <li>informacje o rezerwacjach,</li>
                <li>wybrana oś lub stanowisko strzeleckie,</li>
                <li>data i godzina rezerwacji,</li>
                <li>status rezerwacji,</li>
                <li>status płatności na miejscu,</li>
                <li>dane techniczne związane z korzystaniem z aplikacji.</li>
              </ul>
            </div>
          </section>

          <section>
            <h2 className="mb-3 text-2xl font-semibold">
              3. Cele przetwarzania danych
            </h2>

            <div className="space-y-2 text-zinc-300">
              <p>Dane osobowe są przetwarzane w celu:</p>

              <ul className="list-disc space-y-1 pl-6">
                <li>utworzenia i obsługi konta użytkownika,</li>
                <li>obsługi rezerwacji osi strzeleckich,</li>
                <li>kontaktu z użytkownikiem w sprawie rezerwacji,</li>
                <li>prowadzenia historii rezerwacji,</li>
                <li>obsługi płatności realizowanej na miejscu,</li>
                <li>zapewnienia organizacji i bezpieczeństwa korzystania z obiektu,</li>
                <li>ochrony praw administratora i dochodzenia ewentualnych roszczeń.</li>
              </ul>
            </div>
          </section>

          <section>
            <h2 className="mb-3 text-2xl font-semibold">
              4. Podstawa prawna przetwarzania
            </h2>

            <div className="space-y-2 text-zinc-300">
              <p>
                Dane są przetwarzane na podstawie przepisów RODO, w
                szczególności:
              </p>

              <ul className="list-disc space-y-1 pl-6">
                <li>
                  art. 6 ust. 1 lit. b RODO — wykonanie umowy lub podjęcie
                  działań przed jej zawarciem, czyli obsługa rezerwacji,
                </li>
                <li>
                  art. 6 ust. 1 lit. c RODO — wypełnienie obowiązków prawnych,
                  jeżeli takie obowiązki dotyczą administratora,
                </li>
                <li>
                  art. 6 ust. 1 lit. f RODO — prawnie uzasadniony interes
                  administratora, w tym organizacja pracy obiektu,
                  bezpieczeństwo, kontakt z klientem oraz dochodzenie roszczeń,
                </li>
                <li>
                  art. 6 ust. 1 lit. a RODO — zgoda użytkownika, jeżeli w
                  określonym zakresie będzie wymagana.
                </li>
              </ul>
            </div>
          </section>

          <section>
            <h2 className="mb-3 text-2xl font-semibold">
              5. Okres przechowywania danych
            </h2>

            <div className="space-y-2 text-zinc-300">
              <p>
                Dane użytkownika będą przechowywane przez okres niezbędny do
                obsługi konta, realizacji rezerwacji oraz zabezpieczenia
                ewentualnych roszczeń.
              </p>

              <p>
                Dane dotyczące historii rezerwacji mogą być przechowywane przez
                czas wymagany przepisami prawa lub przez okres uzasadniony
                organizacją i bezpieczeństwem korzystania ze strzelnicy.
              </p>

              <p>
                Po usunięciu konta dane mogą być nadal przechowywane w zakresie
                wymaganym przez przepisy prawa lub niezbędnym do ochrony praw
                administratora.
              </p>
            </div>
          </section>

          <section>
            <h2 className="mb-3 text-2xl font-semibold">
              6. Odbiorcy danych
            </h2>

            <div className="space-y-2 text-zinc-300">
              <p>
                Dane mogą być udostępniane wyłącznie podmiotom, które
                uczestniczą w obsłudze systemu lub obiektu, w szczególności:
              </p>

              <ul className="list-disc space-y-1 pl-6">
                <li>obsłudze i administratorom strzelnicy,</li>
                <li>dostawcom usług informatycznych,</li>
                <li>dostawcom hostingu i bazy danych,</li>
                <li>podmiotom uprawnionym na podstawie przepisów prawa.</li>
              </ul>

              <p>
                Dane nie będą sprzedawane ani udostępniane podmiotom trzecim w
                celach niezwiązanych z obsługą systemu rezerwacji.
              </p>
            </div>
          </section>

          <section>
            <h2 className="mb-3 text-2xl font-semibold">
              7. Prawa użytkownika
            </h2>

            <div className="space-y-2 text-zinc-300">
              <p>Użytkownik ma prawo do:</p>

              <ul className="list-disc space-y-1 pl-6">
                <li>dostępu do swoich danych,</li>
                <li>sprostowania danych,</li>
                <li>usunięcia danych, jeżeli pozwalają na to przepisy prawa,</li>
                <li>ograniczenia przetwarzania,</li>
                <li>wniesienia sprzeciwu wobec przetwarzania,</li>
                <li>przenoszenia danych, jeżeli ma to zastosowanie,</li>
                <li>cofnięcia zgody, jeżeli przetwarzanie odbywa się na podstawie zgody,</li>
                <li>wniesienia skargi do Prezesa Urzędu Ochrony Danych Osobowych.</li>
              </ul>
            </div>
          </section>

          <section>
            <h2 className="mb-3 text-2xl font-semibold">
              8. Dobrowolność podania danych
            </h2>

            <div className="space-y-2 text-zinc-300">
              <p>
                Podanie danych jest dobrowolne, ale niezbędne do utworzenia
                konta i dokonania rezerwacji w systemie CSK Booking.
              </p>

              <p>
                Brak podania wymaganych danych może uniemożliwić korzystanie z
                systemu rezerwacyjnego.
              </p>
            </div>
          </section>

          <section>
            <h2 className="mb-3 text-2xl font-semibold">
              9. Dane techniczne i cookies
            </h2>

            <div className="space-y-2 text-zinc-300">
              <p>
                System może przetwarzać podstawowe dane techniczne związane z
                korzystaniem z aplikacji, takie jak informacje o sesji
                logowania, identyfikatory techniczne, adres IP, dane przeglądarki
                oraz informacje niezbędne do prawidłowego działania systemu.
              </p>

              <p>
                Aplikacja może korzystać z plików cookies lub podobnych
                technologii w celu utrzymania sesji logowania oraz zapewnienia
                prawidłowego działania systemu.
              </p>
            </div>
          </section>

          <section>
            <h2 className="mb-3 text-2xl font-semibold">
              10. Zmiany polityki prywatności
            </h2>

            <div className="space-y-2 text-zinc-300">
              <p>
                Administrator może aktualizować politykę prywatności w przypadku
                zmian w systemie, przepisach prawa lub sposobie przetwarzania
                danych.
              </p>

              <p>
                Aktualna wersja polityki prywatności będzie dostępna w systemie
                CSK Booking.
              </p>
            </div>
          </section>
        </div>

        <div className="mt-8 flex flex-col gap-3 sm:flex-row">
          <a
            href="/dashboard"
            className="rounded-xl border border-zinc-700 px-5 py-3 text-center text-sm font-semibold text-zinc-300 transition hover:bg-zinc-900"
          >
            ← Panel klienta
          </a>

          <a
            href="/terms"
            className="rounded-xl border border-zinc-700 px-5 py-3 text-center text-sm font-semibold text-zinc-300 transition hover:bg-zinc-900"
          >
            Regulamin
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