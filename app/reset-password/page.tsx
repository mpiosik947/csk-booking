"use client";

import Link from "next/link";
import PlatformBrand from "@/app/_components/PlatformBrand";
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
    <main className="platform-ui min-h-screen bg-[#080B09] text-[#F4F3EE]">
      <section className="mx-auto flex min-h-screen w-full max-w-[480px] items-center px-4 py-6 sm:px-6 sm:py-8">
        <div className="w-full rounded-[2rem] border border-[#303A2D] bg-[#111712] p-6 shadow-2xl shadow-black/30 sm:p-9">
          <div className="mb-7 flex justify-center">
            <PlatformBrand />
          </div>

          <h1 className="mb-2 text-3xl font-bold text-[#F4F3EE] sm:text-4xl">
            Ustaw nowe hasło
          </h1>

          <p className="mb-7 text-base text-[#A6ADA5] sm:text-lg">
            Wprowadź nowe hasło do swojego konta.
          </p>

          {checkingSession ? (
            <div
              role="status"
              aria-live="polite"
              className="rounded-xl border border-[#303A2D] bg-[#182019] p-4 text-sm text-[#A6ADA5]"
            >
              Sprawdzanie linku resetującego...
            </div>
          ) : (
            <div className="grid gap-6">
              <div>
                <label
                  htmlFor="reset-password-new"
                  className="mb-2 block text-sm text-[#A6ADA5] sm:text-base"
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
                  className="min-h-12 w-full rounded-xl border border-[#303A2D] bg-[#182019] px-4 py-3.5 text-base text-[#F4F3EE] placeholder:text-[#A6ADA5] focus-visible:border-[#697A2F] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712] disabled:cursor-not-allowed disabled:bg-[#171a17] disabled:text-[#A6ADA5]"
                />
              </div>

              <div>
                <label
                  htmlFor="reset-password-repeat"
                  className="mb-2 block text-sm text-[#A6ADA5] sm:text-base"
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
                  className="min-h-12 w-full rounded-xl border border-[#303A2D] bg-[#182019] px-4 py-3.5 text-base text-[#F4F3EE] placeholder:text-[#A6ADA5] focus-visible:border-[#697A2F] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712] disabled:cursor-not-allowed disabled:bg-[#171a17] disabled:text-[#A6ADA5]"
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
                className="platform-primary min-h-12 w-full rounded-xl border border-[#697A2F] bg-[#697A2F] px-4 py-3.5 text-base font-semibold text-[#F4F3EE] transition hover:border-[#7A8D36] hover:bg-[#7A8D36] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712] disabled:cursor-not-allowed disabled:border-[#303A2D] disabled:bg-[#303A2D] disabled:text-[#A6ADA5]"
              >
                {loading ? "Zapisywanie..." : "Zmień hasło"}
              </button>

              <Link prefetch={false}
                href="/forgot-password"
                className="rounded text-center text-sm text-[#A6ADA5] transition hover:text-[#F5A900] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712] sm:text-base"
              >
                Wygeneruj nowy link resetujący
              </Link>

              <Link prefetch={false}
                href="/login"
                className="rounded text-center text-sm text-[#A6ADA5] transition hover:text-[#F5A900] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712] sm:text-base"
              >
                ← Wróć do logowania
              </Link>
            </div>
          )}
        </div>
      </section>
    </main>
  );
}
