"use client";

import { useState } from "react";
import { supabase } from "../../lib/supabase";

type ConfirmationData = {
  fullName: string;
  email: string;
};

export default function RegisterPage() {
  const [fullName, setFullName] = useState("");
  const [phone, setPhone] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");

  const [acceptedTerms, setAcceptedTerms] = useState(false);
  const [acceptedPrivacy, setAcceptedPrivacy] = useState(false);

  const [loading, setLoading] = useState(false);
  const [message, setMessage] = useState("");
  const [confirmationData, setConfirmationData] =
    useState<ConfirmationData | null>(null);

  async function handleRegister() {
    setMessage("");

    if (!fullName || !phone || !email || !password) {
      setMessage("Uzupełnij wszystkie pola.");
      return;
    }

    if (password.length < 6) {
      setMessage("Hasło musi mieć minimum 6 znaków.");
      return;
    }

    if (!acceptedTerms) {
      setMessage("Musisz zaakceptować regulamin strzelnicy.");
      return;
    }

    if (!acceptedPrivacy) {
      setMessage(
        "Musisz potwierdzić zapoznanie się z polityką prywatności / RODO."
      );
      return;
    }

    setLoading(true);

    const { error } = await supabase.auth.signUp({
      email,
      password,
      options: {
        data: {
          full_name: fullName,
          phone,
          accepted_terms: true,
          accepted_privacy: true,
          accepted_terms_at: new Date().toISOString(),
          accepted_privacy_at: new Date().toISOString(),
        },
      },
    });

    setLoading(false);

    if (error) {
      setMessage(`Błąd rejestracji: ${error.message}`);
      return;
    }

    setConfirmationData({
      fullName,
      email,
    });

    setFullName("");
    setPhone("");
    setEmail("");
    setPassword("");
    setAcceptedTerms(false);
    setAcceptedPrivacy(false);
  }

  function getMessageClass(message: string) {
    return "rounded-xl border border-red-800 bg-red-950 p-4 text-sm font-semibold text-red-300";
  }

  return (
    <>
      {confirmationData && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/80 px-4">
          <div className="w-full max-w-lg rounded-2xl border border-green-800 bg-zinc-950 p-6 text-white shadow-2xl">
            <div className="mb-4 rounded-full border border-green-800 bg-green-950 px-4 py-2 text-center text-sm font-bold uppercase tracking-[0.25em] text-green-300">
              Potwierdź e-mail
            </div>

            <h2 className="mb-3 text-3xl font-bold">
              Konto zostało utworzone
            </h2>

            <p className="mb-6 text-zinc-400">
              Aby je aktywować, kliknij link potwierdzający wysłany na Twój
              adres e-mail.
            </p>

            <div className="grid gap-3 rounded-2xl border border-zinc-800 bg-zinc-900 p-5 text-sm">
              <div>
                <p className="text-zinc-500">Użytkownik</p>
                <p className="text-lg font-semibold text-white">
                  {confirmationData.fullName}
                </p>
              </div>

              <div>
                <p className="text-zinc-500">E-mail</p>
                <p className="text-lg font-semibold text-white">
                  {confirmationData.email}
                </p>
              </div>

              <div>
                <p className="text-zinc-500">Status</p>
                <p className="text-lg font-semibold text-green-500">
                  Oczekuje na potwierdzenie e-mail
                </p>
              </div>
            </div>

            <div className="mt-6 grid gap-3 sm:grid-cols-2">
              <a
                href="/login"
                className="rounded-xl bg-green-700 px-5 py-3 text-center font-semibold transition hover:bg-green-600"
              >
                Przejdź do logowania
              </a>

              <button
                type="button"
                onClick={() => setConfirmationData(null)}
                className="rounded-xl border border-zinc-700 px-5 py-3 font-semibold text-zinc-300 transition hover:bg-zinc-900"
              >
                Zamknij
              </button>
            </div>
          </div>
        </div>
      )}

      <main className="min-h-screen bg-zinc-950 text-white">
        <section className="mx-auto flex min-h-screen max-w-md items-center px-6 py-12">
          <div className="w-full rounded-2xl border border-zinc-800 bg-zinc-900 p-8">
            <p className="mb-4 text-sm uppercase tracking-[0.35em] text-green-500">
              CSK Booking
            </p>

            <h1 className="mb-2 text-3xl font-bold">Rejestracja</h1>

            <p className="mb-8 text-zinc-400">
              Utwórz konto użytkownika systemu rezerwacji.
            </p>

            <div className="grid gap-5">
              <div>
                <label className="mb-2 block text-sm text-zinc-300">
                  Imię i nazwisko
                </label>

                <input
                  type="text"
                  value={fullName}
                  onChange={(event) => setFullName(event.target.value)}
                  placeholder="Jan Kowalski"
                  className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                />
              </div>

              <div>
                <label className="mb-2 block text-sm text-zinc-300">
                  Telefon
                </label>

                <input
                  type="tel"
                  value={phone}
                  onChange={(event) => setPhone(event.target.value)}
                  placeholder="500 000 000"
                  className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                />
              </div>

              <div>
                <label className="mb-2 block text-sm text-zinc-300">
                  E-mail
                </label>

                <input
                  type="email"
                  value={email}
                  onChange={(event) => setEmail(event.target.value)}
                  placeholder="jan@example.com"
                  className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                />
              </div>

              <div>
                <label className="mb-2 block text-sm text-zinc-300">
                  Hasło
                </label>

                <input
                  type="password"
                  value={password}
                  onChange={(event) => setPassword(event.target.value)}
                  placeholder="Minimum 6 znaków"
                  className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
                />
              </div>

              <div className="space-y-3 rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                <label className="flex gap-3 text-sm text-zinc-300">
                  <input
                    type="checkbox"
                    checked={acceptedTerms}
                    onChange={(event) => setAcceptedTerms(event.target.checked)}
                    className="mt-1"
                  />

                  <span>
                    Oświadczam, że zapoznałem/am się z{" "}
                    <a
                      href="/terms"
                      target="_blank"
                      className="font-semibold text-green-500 hover:text-green-400"
                    >
                      regulaminem strzelnicy
                    </a>{" "}
                    i akceptuję jego treść.
                  </span>
                </label>

                <label className="flex gap-3 text-sm text-zinc-300">
                  <input
                    type="checkbox"
                    checked={acceptedPrivacy}
                    onChange={(event) =>
                      setAcceptedPrivacy(event.target.checked)
                    }
                    className="mt-1"
                  />

                  <span>
                    Oświadczam, że zapoznałem/am się z{" "}
                    <a
                      href="/privacy"
                      target="_blank"
                      className="font-semibold text-green-500 hover:text-green-400"
                    >
                      polityką prywatności / klauzulą RODO
                    </a>
                    .
                  </span>
                </label>
              </div>

              {message && (
                <div className={getMessageClass(message)}>{message}</div>
              )}

              <button
                type="button"
                onClick={handleRegister}
                disabled={loading}
                className="rounded-xl bg-green-700 px-4 py-3 font-semibold transition hover:bg-green-600 disabled:cursor-not-allowed disabled:opacity-60"
              >
                {loading ? "Tworzenie konta..." : "Utwórz konto"}
              </button>

              <a
                href="/login"
                className="text-center text-sm text-zinc-400 hover:text-white"
              >
                Masz już konto? Zaloguj się
              </a>

              <a
                href="/"
                className="text-center text-sm text-zinc-500 hover:text-white"
              >
                ← Strona główna
              </a>
            </div>
          </div>
        </section>
      </main>
    </>
  );
}
