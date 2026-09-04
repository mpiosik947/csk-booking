"use client";

import Image from "next/image";
import { useEffect, useState } from "react";
import {
  getPasswordLengthError,
  PASSWORD_MAX_LENGTH,
  PASSWORD_MIN_LENGTH,
} from "../../lib/password-policy";
import { getPasswordUpdateErrorMessage } from "../../lib/safe-client-error";
import { supabase } from "../../lib/supabase";

export default function ResetPasswordPage() {
  const [password, setPassword] = useState("");
  const [passwordRepeat, setPasswordRepeat] = useState("");

  const [checkingSession, setCheckingSession] = useState(true);
  const [hasSession, setHasSession] = useState(false);

  const [loading, setLoading] = useState(false);
  const [message, setMessage] = useState("");
  const [messageType, setMessageType] = useState<"success" | "error" | "">("");

  useEffect(() => {
    async function prepareSession() {
      setCheckingSession(true);
      setMessage("");
      setMessageType("");

      const params = new URLSearchParams(window.location.search);
      const code = params.get("code");

      if (code) {
        const { error } = await supabase.auth.exchangeCodeForSession(code);

        if (error) {
          setHasSession(false);
          setMessage(
            "Link resetujący jest nieprawidłowy albo wygasł. Wygeneruj nowy link."
          );
          setMessageType("error");
          setCheckingSession(false);
          return;
        }

        window.history.replaceState({}, document.title, "/reset-password");
      }

      const {
        data: { session },
      } = await supabase.auth.getSession();

      setHasSession(Boolean(session));
      setCheckingSession(false);

      if (!session) {
        setMessage(
          "Brak aktywnej sesji resetowania hasła. Wejdź tutaj z linku otrzymanego w wiadomości e-mail."
        );
        setMessageType("error");
      }
    }

    prepareSession();
  }, []);

  async function handleUpdatePassword() {
    setMessage("");
    setMessageType("");

    if (!password || !passwordRepeat) {
      setMessage("Podaj nowe hasło i powtórz je.");
      setMessageType("error");
      return;
    }

    const passwordLengthError = getPasswordLengthError(password);
    if (passwordLengthError) {
      setMessage(passwordLengthError);
      setMessageType("error");
      return;
    }

    if (password !== passwordRepeat) {
      setMessage("Hasła nie są takie same.");
      setMessageType("error");
      return;
    }

    setLoading(true);

    const { error } = await supabase.auth.updateUser({
      password,
    });

    setLoading(false);

    if (error) {
      setMessage(getPasswordUpdateErrorMessage(error, "reset"));
      setMessageType("error");
      return;
    }

    setMessage("Hasło zostało zmienione. Możesz się teraz zalogować.");
    setMessageType("success");

    await supabase.auth.signOut();

    setTimeout(() => {
      window.location.href = "/login";
    }, 1500);
  }

  return (
    <main className="min-h-screen bg-[#090b09] text-[#f2efe4]">
      <section className="mx-auto flex min-h-screen w-full max-w-[480px] items-center px-4 py-6 sm:px-6 sm:py-8">
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
            Ustaw nowe hasło
          </h1>

          <p className="mb-7 text-base text-[#a9ada4] sm:text-lg">
            Wprowadź nowe hasło do swojego konta.
          </p>

          {checkingSession ? (
            <div
              role="status"
              aria-live="polite"
              className="rounded-xl border border-[#30372c] bg-[#191e19] p-4 text-sm text-[#a9ada4]"
            >
              Sprawdzanie linku resetującego...
            </div>
          ) : (
            <div className="grid gap-6">
              <div>
                <label
                  htmlFor="reset-password-new"
                  className="mb-2 block text-sm text-[#a9ada4] sm:text-base"
                >
                  Nowe hasło
                </label>

                <input
                  id="reset-password-new"
                  type="password"
                  value={password}
                  onChange={(event) => setPassword(event.target.value)}
                  minLength={PASSWORD_MIN_LENGTH}
                  maxLength={PASSWORD_MAX_LENGTH}
                  placeholder={`Minimum ${PASSWORD_MIN_LENGTH} znaków`}
                  disabled={!hasSession}
                  className="min-h-12 w-full rounded-xl border border-[#30372c] bg-[#191e19] px-4 py-3.5 text-base text-[#f2efe4] placeholder:text-[#858c7f] focus-visible:border-[#536143] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] disabled:cursor-not-allowed disabled:bg-[#171a17] disabled:text-[#858c7f]"
                />
              </div>

              <div>
                <label
                  htmlFor="reset-password-repeat"
                  className="mb-2 block text-sm text-[#a9ada4] sm:text-base"
                >
                  Powtórz nowe hasło
                </label>

                <input
                  id="reset-password-repeat"
                  type="password"
                  value={passwordRepeat}
                  onChange={(event) => setPasswordRepeat(event.target.value)}
                  minLength={PASSWORD_MIN_LENGTH}
                  maxLength={PASSWORD_MAX_LENGTH}
                  placeholder="Powtórz hasło"
                  disabled={!hasSession}
                  className="min-h-12 w-full rounded-xl border border-[#30372c] bg-[#191e19] px-4 py-3.5 text-base text-[#f2efe4] placeholder:text-[#858c7f] focus-visible:border-[#536143] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] disabled:cursor-not-allowed disabled:bg-[#171a17] disabled:text-[#858c7f]"
                />
              </div>

              {message && (
                <div
                  role={messageType === "success" ? "status" : "alert"}
                  className={
                    messageType === "success"
                      ? "rounded-xl border border-[#3f6848] bg-[#1b2a1d] p-4 text-sm font-semibold text-[#a9d4ad]"
                      : "rounded-xl border border-[#744545] bg-[#2a1b1b] p-4 text-sm font-semibold text-[#e0a0a0]"
                  }
                >
                  {message}
                </div>
              )}

              <button
                type="button"
                onClick={handleUpdatePassword}
                disabled={loading || !hasSession}
                className="min-h-12 w-full rounded-xl border border-[#536143] bg-[#536143] px-4 py-3.5 text-base font-semibold text-[#f2efe4] transition hover:border-[#78865f] hover:bg-[#78865f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] disabled:cursor-not-allowed disabled:border-[#30372c] disabled:bg-[#30372c] disabled:text-[#858c7f]"
              >
                {loading ? "Zapisywanie..." : "Zmień hasło"}
              </button>

              <a
                href="/forgot-password"
                className="rounded text-center text-sm text-[#a9ada4] transition hover:text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] sm:text-base"
              >
                Wygeneruj nowy link resetujący
              </a>

              <a
                href="/login"
                className="rounded text-center text-sm text-[#858c7f] transition hover:text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] sm:text-base"
              >
                ← Wróć do logowania
              </a>
            </div>
          )}
        </div>
      </section>
    </main>
  );
}
