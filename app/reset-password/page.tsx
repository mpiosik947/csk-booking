"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";

function translatePasswordError(message: string) {
  const normalizedMessage = message.toLowerCase();

  if (
    normalizedMessage.includes("same password") ||
    normalizedMessage.includes("different from the old password") ||
    normalizedMessage.includes("new password should be different")
  ) {
    return "Nowe hasło musi być inne niż poprzednie.";
  }

  if (
    normalizedMessage.includes("password should be at least") ||
    normalizedMessage.includes("weak password")
  ) {
    return "Hasło jest za słabe. Użyj minimum 8 znaków.";
  }

  if (
    normalizedMessage.includes("session") ||
    normalizedMessage.includes("expired") ||
    normalizedMessage.includes("invalid")
  ) {
    return "Link resetujący jest nieprawidłowy albo wygasł. Wygeneruj nowy link.";
  }

  return "Nie udało się zmienić hasła. Spróbuj ponownie.";
}

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

    if (password.length < 8) {
      setMessage("Hasło musi mieć minimum 8 znaków.");
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
      setMessage(translatePasswordError(error.message));
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
    <main className="min-h-screen bg-zinc-950 text-white">
      <section className="mx-auto flex min-h-screen max-w-md items-center px-6 py-12">
        <div className="w-full rounded-2xl border border-zinc-800 bg-zinc-900 p-8">
          <p className="mb-4 text-sm uppercase tracking-[0.35em] text-green-500">
            CSK Booking
          </p>

          <h1 className="mb-2 text-3xl font-bold">Ustaw nowe hasło</h1>

          <p className="mb-8 text-zinc-400">
            Wprowadź nowe hasło do swojego konta.
          </p>

          {checkingSession ? (
            <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4 text-sm text-zinc-300">
              Sprawdzanie linku resetującego...
            </div>
          ) : (
            <div className="grid gap-5">
              <div>
                <label className="mb-2 block text-sm text-zinc-300">
                  Nowe hasło
                </label>

                <input
                  type="password"
                  value={password}
                  onChange={(event) => setPassword(event.target.value)}
                  placeholder="Minimum 8 znaków"
                  disabled={!hasSession}
                  className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600 disabled:cursor-not-allowed disabled:opacity-60"
                />
              </div>

              <div>
                <label className="mb-2 block text-sm text-zinc-300">
                  Powtórz nowe hasło
                </label>

                <input
                  type="password"
                  value={passwordRepeat}
                  onChange={(event) => setPasswordRepeat(event.target.value)}
                  placeholder="Powtórz hasło"
                  disabled={!hasSession}
                  className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600 disabled:cursor-not-allowed disabled:opacity-60"
                />
              </div>

              {message && (
                <div
                  className={
                    messageType === "success"
                      ? "rounded-xl border border-green-800 bg-green-950 p-4 text-sm font-semibold text-green-300"
                      : "rounded-xl border border-red-800 bg-red-950 p-4 text-sm font-semibold text-red-300"
                  }
                >
                  {message}
                </div>
              )}

              <button
                type="button"
                onClick={handleUpdatePassword}
                disabled={loading || !hasSession}
                className="rounded-xl bg-green-700 px-4 py-3 font-semibold transition hover:bg-green-600 disabled:cursor-not-allowed disabled:opacity-60"
              >
                {loading ? "Zapisywanie..." : "Zmień hasło"}
              </button>

              <a
                href="/forgot-password"
                className="text-center text-sm text-zinc-400 hover:text-white"
              >
                Wygeneruj nowy link resetujący
              </a>

              <a
                href="/login"
                className="text-center text-sm text-zinc-500 hover:text-white"
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
