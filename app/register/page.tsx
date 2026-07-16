"use client";

import Image from "next/image";
import { useState } from "react";
import { supabase } from "../../lib/supabase";

type ConfirmationData = {
  fullName: string;
  email: string;
};

export default function RegisterPage() {
  const [firstName, setFirstName] = useState("");
  const [lastName, setLastName] = useState("");
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

    const trimmedFirstName = firstName.trim();
    const trimmedLastName = lastName.trim();

    if (!trimmedFirstName || !trimmedLastName || !phone || !email || !password) {
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
        emailRedirectTo: `${window.location.origin}/auth/callback`,
        data: {
          first_name: trimmedFirstName,
          last_name: trimmedLastName,
          full_name: [trimmedFirstName, trimmedLastName]
            .filter(Boolean)
            .join(" "),
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
      fullName: [trimmedFirstName, trimmedLastName].filter(Boolean).join(" "),
      email,
    });

    setFirstName("");
    setLastName("");
    setPhone("");
    setEmail("");
    setPassword("");
    setAcceptedTerms(false);
    setAcceptedPrivacy(false);
  }

  function getMessageClass(message: string) {
    return "rounded-xl border border-[#744545] bg-[#2a1b1b] p-4 text-sm font-semibold text-[#e0a0a0]";
  }

  return (
    <>
      {confirmationData && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/80 px-4">
          <div
            role="dialog"
            aria-modal="true"
            aria-labelledby="register-success-title"
            className="w-full max-w-lg rounded-[2rem] border border-[#30372c] bg-[#141814] p-6 text-[#f2efe4] shadow-2xl shadow-black/40 sm:p-9"
          >
            <div className="mb-4 rounded-full border border-[#6f5a2e] bg-[#242015] px-4 py-2 text-center text-sm font-bold uppercase tracking-[0.25em] text-[#d7c895]">
              Potwierdź e-mail
            </div>

            <h2
              id="register-success-title"
              className="mb-3 text-3xl font-bold text-[#f2efe4]"
            >
              Konto zostało utworzone
            </h2>

            <p className="mb-6 text-[#a9ada4]">
              Aby je aktywować, kliknij link potwierdzający wysłany na Twój
              adres e-mail.
            </p>

            <div className="grid gap-3 rounded-2xl border border-[#30372c] bg-[#191e19] p-5 text-sm">
              <div>
                <p className="text-[#858c7f]">Użytkownik</p>
                <p className="text-lg font-semibold text-[#f2efe4]">
                  {confirmationData.fullName}
                </p>
              </div>

              <div>
                <p className="text-[#858c7f]">E-mail</p>
                <p className="text-lg font-semibold text-[#f2efe4]">
                  {confirmationData.email}
                </p>
              </div>

              <div>
                <p className="text-[#858c7f]">Status</p>
                <p className="text-lg font-semibold text-[#d7c895]">
                  Oczekuje na potwierdzenie e-mail
                </p>
              </div>
            </div>

            <div className="mt-6 grid gap-3 sm:grid-cols-2">
              <a
                href="/login"
                className="min-h-12 rounded-xl border border-[#536143] bg-[#536143] px-5 py-3.5 text-center font-semibold text-[#f2efe4] transition hover:border-[#78865f] hover:bg-[#78865f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
              >
                Przejdź do logowania
              </a>

              <button
                type="button"
                onClick={() => setConfirmationData(null)}
                className="min-h-12 rounded-xl border border-[#30372c] bg-[#191e19] px-5 py-3.5 font-semibold text-[#a9ada4] transition hover:border-[#536143] hover:text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
              >
                Zamknij
              </button>
            </div>
          </div>
        </div>
      )}

      <main className="min-h-screen bg-[#090b09] text-[#f2efe4]">
        <section className="mx-auto flex min-h-screen w-full max-w-[560px] items-center px-4 py-6 sm:px-6 sm:py-8">
          <div className="w-full rounded-[2rem] border border-[#30372c] bg-[#141814] p-6 shadow-2xl shadow-black/30 sm:p-9">
            <div className="mb-7 flex justify-center">
              <Image
                src="/login-brand.png"
                alt="CSK - Centrum Szkolenia Krutla"
                width={1536}
                height={1024}
                priority
                className="h-auto w-full max-w-[280px] rounded-xl sm:max-w-[310px]"
              />
            </div>

            <h1 className="mb-2 text-3xl font-bold text-[#f2efe4] sm:text-4xl">
              Załóż konto
            </h1>

            <p className="mb-7 text-base text-[#a9ada4] sm:text-lg">
              Utwórz konto użytkownika systemu rezerwacji.
            </p>

            <div className="grid gap-6">
              <div className="grid gap-6 sm:grid-cols-2">
                <div>
                  <label
                    htmlFor="register-first-name"
                    className="mb-2 block text-sm text-[#a9ada4] sm:text-base"
                  >
                    Imię
                  </label>

                  <input
                    id="register-first-name"
                    type="text"
                    autoComplete="given-name"
                    required
                    value={firstName}
                    onChange={(event) => setFirstName(event.target.value)}
                    placeholder="Jan"
                    className="min-h-12 w-full rounded-xl border border-[#30372c] bg-[#191e19] px-4 py-3.5 text-base text-[#f2efe4] placeholder:text-[#858c7f] focus-visible:border-[#536143] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
                  />
                </div>

                <div>
                  <label
                    htmlFor="register-last-name"
                    className="mb-2 block text-sm text-[#a9ada4] sm:text-base"
                  >
                    Nazwisko
                  </label>

                  <input
                    id="register-last-name"
                    type="text"
                    autoComplete="family-name"
                    required
                    value={lastName}
                    onChange={(event) => setLastName(event.target.value)}
                    placeholder="Kowalski"
                    className="min-h-12 w-full rounded-xl border border-[#30372c] bg-[#191e19] px-4 py-3.5 text-base text-[#f2efe4] placeholder:text-[#858c7f] focus-visible:border-[#536143] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
                  />
                </div>
              </div>

              <div>
                <label
                  htmlFor="register-phone"
                  className="mb-2 block text-sm text-[#a9ada4] sm:text-base"
                >
                  Telefon
                </label>

                <input
                  id="register-phone"
                  type="tel"
                  value={phone}
                  onChange={(event) => setPhone(event.target.value)}
                  placeholder="500 000 000"
                  className="min-h-12 w-full rounded-xl border border-[#30372c] bg-[#191e19] px-4 py-3.5 text-base text-[#f2efe4] placeholder:text-[#858c7f] focus-visible:border-[#536143] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
                />
              </div>

              <div>
                <label
                  htmlFor="register-email"
                  className="mb-2 block text-sm text-[#a9ada4] sm:text-base"
                >
                  E-mail
                </label>

                <input
                  id="register-email"
                  type="email"
                  value={email}
                  onChange={(event) => setEmail(event.target.value)}
                  placeholder="jan@example.com"
                  className="min-h-12 w-full rounded-xl border border-[#30372c] bg-[#191e19] px-4 py-3.5 text-base text-[#f2efe4] placeholder:text-[#858c7f] focus-visible:border-[#536143] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
                />
              </div>

              <div>
                <label
                  htmlFor="register-password"
                  className="mb-2 block text-sm text-[#a9ada4] sm:text-base"
                >
                  Hasło
                </label>

                <input
                  id="register-password"
                  type="password"
                  value={password}
                  onChange={(event) => setPassword(event.target.value)}
                  placeholder="Minimum 6 znaków"
                  className="min-h-12 w-full rounded-xl border border-[#30372c] bg-[#191e19] px-4 py-3.5 text-base text-[#f2efe4] placeholder:text-[#858c7f] focus-visible:border-[#536143] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
                />
              </div>

              <div className="space-y-3 rounded-xl border border-[#30372c] bg-[#191e19] p-4">
                <label className="flex gap-3 text-sm text-[#a9ada4]">
                  <input
                    type="checkbox"
                    checked={acceptedTerms}
                    onChange={(event) => setAcceptedTerms(event.target.checked)}
                    className="mt-1 accent-[#536143] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#191e19]"
                  />

                  <span>
                    Oświadczam, że zapoznałem/am się z{" "}
                    <a
                      href="/terms"
                      target="_blank"
                      className="rounded font-semibold text-[#d7c895] transition hover:text-[#eadba6] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861]"
                    >
                      regulaminem strzelnicy
                    </a>{" "}
                    i akceptuję jego treść.
                  </span>
                </label>

                <label className="flex gap-3 text-sm text-[#a9ada4]">
                  <input
                    type="checkbox"
                    checked={acceptedPrivacy}
                    onChange={(event) =>
                      setAcceptedPrivacy(event.target.checked)
                    }
                    className="mt-1 accent-[#536143] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#191e19]"
                  />

                  <span>
                    Oświadczam, że zapoznałem/am się z{" "}
                    <a
                      href="/privacy"
                      target="_blank"
                      className="rounded font-semibold text-[#d7c895] transition hover:text-[#eadba6] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861]"
                    >
                      polityką prywatności / klauzulą RODO
                    </a>
                    .
                  </span>
                </label>
              </div>

              {message && (
                <div role="alert" className={getMessageClass(message)}>
                  {message}
                </div>
              )}

              <button
                type="button"
                onClick={handleRegister}
                disabled={loading}
                className="min-h-12 w-full rounded-xl border border-[#536143] bg-[#536143] px-4 py-3.5 text-base font-semibold text-[#f2efe4] transition hover:border-[#78865f] hover:bg-[#78865f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] disabled:cursor-not-allowed disabled:border-[#30372c] disabled:bg-[#30372c] disabled:text-[#858c7f]"
              >
                {loading ? "Tworzenie konta..." : "Utwórz konto"}
              </button>

              <a
                href="/login"
                className="rounded text-center text-sm text-[#a9ada4] transition hover:text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] sm:text-base"
              >
                Masz już konto? Zaloguj się
              </a>

              <a
                href="/"
                className="rounded text-center text-sm text-[#858c7f] transition hover:text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] sm:text-base"
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
