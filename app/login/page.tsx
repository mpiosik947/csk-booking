"use client";

import Image from "next/image";
import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";

const ALLOWED_LOGIN_REDIRECTS: ReadonlySet<string> = new Set([
  "/dashboard",
  "/booking",
  "/events",
  "/my-reservations",
  "/my-events",
  "/admin",
  "/admin/users",
  "/admin/check-in",
  "/admin/events",
  "/admin/reservations",
  "/admin/reports",
  "/admin/calendar",
  "/admin/lane-blocks",
]);

function getSafeLoginRedirect(redirectTo: string | null) {
  return redirectTo && ALLOWED_LOGIN_REDIRECTS.has(redirectTo)
    ? redirectTo
    : "/dashboard";
}

export default function LoginPage() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");

  const [loading, setLoading] = useState(false);
  const [message, setMessage] = useState("");
  const [confirmationError, setConfirmationError] = useState(false);

  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    setConfirmationError(params.get("confirmationError") === "1");
  }, []);

  async function handleLogin() {
    setMessage("");

    if (!email || !password) {
      setMessage("Podaj e-mail i hasło.");
      return;
    }

    setLoading(true);

    const { error } = await supabase.auth.signInWithPassword({
      email,
      password,
    });

    setLoading(false);

    if (error) {
      if (error.message === "Email not confirmed") {
        setMessage(
          "Wymagana jest weryfikacja adresu e-mail. Sprawdź skrzynkę pocztową i kliknij link aktywacyjny wysłany podczas rejestracji."
        );
        return;
      }

      if (error.message === "Invalid login credentials") {
        setMessage("Nieprawidłowy adres e-mail lub hasło.");
        return;
      }

      setMessage(`Błąd logowania: ${error.message}`);
      return;
    }

    const params = new URLSearchParams(window.location.search);
    const redirectTo = getSafeLoginRedirect(params.get("redirectTo"));

    window.location.href = redirectTo;
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-white">
      <section className="mx-auto flex min-h-screen max-w-md items-center px-6 py-12">
        <div className="w-full rounded-2xl border border-zinc-800 bg-zinc-900 p-8">
          <div className="mb-8 flex justify-center">
  <Image
    src="/login-brand.png"
    alt="CSK - Centrum Szkolenia Krutla"
    width={420}
    height={220}
    priority
    className="h-auto w-full max-w-[280px] rounded-xl"
  />
</div>

          <h1 className="mb-2 text-3xl font-bold">Logowanie</h1>

          <p className="mb-8 text-zinc-400">
            Zaloguj się do systemu rezerwacji.
          </p>

          <div className="grid gap-5">
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
              <div className="mb-2 flex items-center justify-between gap-4">
                <label className="block text-sm text-zinc-300">
                  Hasło
                </label>

                <a
                  href="/forgot-password"
                  className="text-xs font-semibold text-green-500 hover:text-green-400"
                >
                  Nie pamiętasz hasła?
                </a>
              </div>

              <input
                type="password"
                value={password}
                onChange={(event) => setPassword(event.target.value)}
                placeholder="••••••••"
                className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
              />
            </div>

            {confirmationError && (
              <div
                role="alert"
                className="rounded-xl border border-red-800 bg-red-950 p-4 text-sm font-semibold text-red-300"
              >
                Nie udało się potwierdzić adresu e-mail. Link mógł wygasnąć
                lub zostać już wykorzystany.
              </div>
            )}

            {message && (
              <div className="rounded-xl border border-red-800 bg-red-950 p-4 text-sm font-semibold text-red-300">
                {message}
              </div>
            )}

            <button
              type="button"
              onClick={handleLogin}
              disabled={loading}
              className="rounded-xl bg-green-700 px-4 py-3 font-semibold transition hover:bg-green-600 disabled:cursor-not-allowed disabled:opacity-60"
            >
              {loading ? "Logowanie..." : "Zaloguj się"}
            </button>

            <a
              href="/register"
              className="text-center text-sm text-zinc-400 hover:text-white"
            >
              Nie masz konta? Utwórz konto
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
  );
}






