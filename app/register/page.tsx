"use client";

import Link from "next/link";
import PlatformBrand from "@/app/_components/PlatformBrand";
import { useState } from "react";
import {
  getPasswordLengthError,
  PASSWORD_MAX_LENGTH,
  PASSWORD_MIN_LENGTH,
} from "../../lib/password-policy";
import { getRegistrationErrorMessage } from "../../lib/safe-client-error";
import { supabase } from "../../lib/supabase";
import { PLATFORM_BASE_URL } from "@/lib/platform-domain";

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

    const passwordLengthError = getPasswordLengthError(password);
    if (passwordLengthError) {
      setMessage(passwordLengthError);
      return;
    }

    if (!acceptedTerms) {
      setMessage("Musisz zaakceptować regulamin serwisu StrzelajTu.pl.");
      return;
    }

    if (!acceptedPrivacy) {
      setMessage(
        "Musisz potwierdzić zapoznanie się z polityką prywatności."
      );
      return;
    }

    setLoading(true);

    const { data, error } = await supabase.auth.signUp({
      email,
      password,
      options: {
        emailRedirectTo: `${PLATFORM_BASE_URL}/auth/callback`,
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
      setMessage(getRegistrationErrorMessage(error));
      return;
    }

    void data;

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
            className="w-full max-w-lg rounded-[2rem] border border-[#303A2D] bg-[#111712] p-6 text-[#F4F3EE] shadow-2xl shadow-black/40 sm:p-9"
          >
            <div className="mb-4 rounded-full border border-[#6f5a2e] bg-[#242015] px-4 py-2 text-center text-sm font-bold uppercase tracking-[0.25em] text-[#F5A900]">
              Potwierdź e-mail
            </div>

            <h2
              id="register-success-title"
              className="mb-3 text-3xl font-bold text-[#F4F3EE]"
            >
              Sprawdź skrzynkę e-mail
            </h2>

            <p className="mb-6 text-[#A6ADA5]">
              Jeżeli rejestracja była możliwa, wysłaliśmy wiadomość z dalszymi
              instrukcjami. Jeśli masz już konto, zaloguj się lub skorzystaj z
              odzyskiwania hasła.
            </p>

            <div className="grid gap-3 rounded-2xl border border-[#303A2D] bg-[#182019] p-5 text-sm">
              <div>
                <p className="text-[#A6ADA5]">Użytkownik</p>
                <p className="text-lg font-semibold text-[#F4F3EE]">
                  {confirmationData.fullName}
                </p>
              </div>

              <div>
                <p className="text-[#A6ADA5]">E-mail</p>
                <p className="text-lg font-semibold text-[#F4F3EE]">
                  {confirmationData.email}
                </p>
              </div>

              <div>
                <p className="text-[#A6ADA5]">Status</p>
                <p className="text-lg font-semibold text-[#F5A900]">
                  Sprawdź skrzynkę e-mail
                </p>
              </div>
            </div>

            <div className="mt-6 grid gap-3 sm:grid-cols-2">
              <Link
                href="/login"
                className="platform-primary min-h-12 rounded-xl border border-[#697A2F] bg-[#697A2F] px-5 py-3.5 text-center font-semibold text-[#F4F3EE] transition hover:border-[#7A8D36] hover:bg-[#7A8D36] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712]"
              >
                Przejdź do logowania
              </Link>

              <button
                type="button"
                onClick={() => setConfirmationData(null)}
                className="min-h-12 rounded-xl border border-[#303A2D] bg-[#182019] px-5 py-3.5 font-semibold text-[#A6ADA5] transition hover:border-[#697A2F] hover:text-[#F5A900] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712]"
              >
                Zamknij
              </button>
            </div>
          </div>
        </div>
      )}

      <main className="platform-ui min-h-screen bg-[#080B09] text-[#F4F3EE]">
        <section className="mx-auto flex min-h-screen w-full max-w-[560px] items-center px-4 py-6 sm:px-6 sm:py-8">
          <div className="w-full rounded-[2rem] border border-[#303A2D] bg-[#111712] p-6 shadow-2xl shadow-black/30 sm:p-9">
            <div className="mb-7 flex justify-center">
              <PlatformBrand />
            </div>

            <h1 className="mb-2 text-3xl font-bold text-[#F4F3EE] sm:text-4xl">
              Utwórz konto
            </h1>

            <p className="mb-7 text-base text-[#A6ADA5] sm:text-lg">
              Jedno konto pozwala korzystać ze wszystkich strzelnic dostępnych w StrzelajTu.pl.
            </p>

            <div className="grid gap-6">
              <div className="grid gap-6 sm:grid-cols-2">
                <div>
                  <label
                    htmlFor="register-first-name"
                    className="mb-2 block text-sm text-[#A6ADA5] sm:text-base"
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
                    className="min-h-12 w-full rounded-xl border border-[#303A2D] bg-[#182019] px-4 py-3.5 text-base text-[#F4F3EE] placeholder:text-[#A6ADA5] focus-visible:border-[#697A2F] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712]"
                  />
                </div>

                <div>
                  <label
                    htmlFor="register-last-name"
                    className="mb-2 block text-sm text-[#A6ADA5] sm:text-base"
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
                    className="min-h-12 w-full rounded-xl border border-[#303A2D] bg-[#182019] px-4 py-3.5 text-base text-[#F4F3EE] placeholder:text-[#A6ADA5] focus-visible:border-[#697A2F] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712]"
                  />
                </div>
              </div>

              <div>
                <label
                  htmlFor="register-phone"
                  className="mb-2 block text-sm text-[#A6ADA5] sm:text-base"
                >
                  Telefon
                </label>

                <input
                  id="register-phone"
                  type="tel"
                  value={phone}
                  onChange={(event) => setPhone(event.target.value)}
                  placeholder="500 000 000"
                  className="min-h-12 w-full rounded-xl border border-[#303A2D] bg-[#182019] px-4 py-3.5 text-base text-[#F4F3EE] placeholder:text-[#A6ADA5] focus-visible:border-[#697A2F] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712]"
                />
              </div>

              <div>
                <label
                  htmlFor="register-email"
                  className="mb-2 block text-sm text-[#A6ADA5] sm:text-base"
                >
                  E-mail
                </label>

                <input
                  id="register-email"
                  type="email"
                  value={email}
                  onChange={(event) => setEmail(event.target.value)}
                  placeholder="jan@example.com"
                  className="min-h-12 w-full rounded-xl border border-[#303A2D] bg-[#182019] px-4 py-3.5 text-base text-[#F4F3EE] placeholder:text-[#A6ADA5] focus-visible:border-[#697A2F] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712]"
                />
              </div>

              <div>
                <label
                  htmlFor="register-password"
                  className="mb-2 block text-sm text-[#A6ADA5] sm:text-base"
                >
                  Hasło
                </label>

                <input
                  id="register-password"
                  type="password"
                  value={password}
                  onChange={(event) => setPassword(event.target.value)}
                  minLength={PASSWORD_MIN_LENGTH}
                  maxLength={PASSWORD_MAX_LENGTH}
                  placeholder={`Minimum ${PASSWORD_MIN_LENGTH} znaków`}
                  className="min-h-12 w-full rounded-xl border border-[#303A2D] bg-[#182019] px-4 py-3.5 text-base text-[#F4F3EE] placeholder:text-[#A6ADA5] focus-visible:border-[#697A2F] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712]"
                />
              </div>

              <div className="space-y-3 rounded-xl border border-[#303A2D] bg-[#182019] p-4">
                <label className="flex gap-3 text-sm text-[#A6ADA5]">
                  <input
                    type="checkbox"
                    checked={acceptedTerms}
                    onChange={(event) => setAcceptedTerms(event.target.checked)}
                    className="mt-1 accent-[#697A2F] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#182019]"
                  />

                  <span>
                    Oświadczam, że zapoznałem/am się z{" "}
                    <Link prefetch={false}
                      href="/terms"
                      target="_blank"
                      className="rounded font-semibold text-[#F5A900] transition hover:text-[#FFB61A] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900]"
                    >
                      regulaminem serwisu StrzelajTu.pl
                    </Link>{" "}
                    i akceptuję jego treść.
                  </span>
                </label>

                <label className="flex gap-3 text-sm text-[#A6ADA5]">
                  <input
                    type="checkbox"
                    checked={acceptedPrivacy}
                    onChange={(event) =>
                      setAcceptedPrivacy(event.target.checked)
                    }
                    className="mt-1 accent-[#697A2F] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#182019]"
                  />

                  <span>
                    Oświadczam, że zapoznałem/am się z{" "}
                    <Link prefetch={false}
                      href="/privacy"
                      target="_blank"
                      className="rounded font-semibold text-[#F5A900] transition hover:text-[#FFB61A] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900]"
                    >
                      polityką prywatności
                    </Link>
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
                className="platform-primary min-h-12 w-full rounded-xl border border-[#697A2F] bg-[#697A2F] px-4 py-3.5 text-base font-semibold text-[#F4F3EE] transition hover:border-[#7A8D36] hover:bg-[#7A8D36] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712] disabled:cursor-not-allowed disabled:border-[#303A2D] disabled:bg-[#303A2D] disabled:text-[#A6ADA5]"
              >
                {loading ? "Tworzenie konta..." : "Utwórz konto"}
              </button>

              <Link
                href="/login"
                className="rounded text-center text-sm text-[#A6ADA5] transition hover:text-[#F5A900] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712] sm:text-base"
              >
                Masz już konto? Zaloguj się
              </Link>

              <Link
                href="/"
                className="rounded text-center text-sm text-[#A6ADA5] transition hover:text-[#F5A900] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712] sm:text-base"
              >
                ← Wróć do StrzelajTu.pl
              </Link>
            </div>
          </div>
        </section>
      </main>
    </>
  );
}
