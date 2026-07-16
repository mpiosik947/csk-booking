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
            Zaloguj się
          </h1>

          <p className="mb-7 text-base text-[#a9ada4] sm:text-lg">
            Zaloguj się do systemu rezerwacji.
          </p>

          <div className="grid gap-6">
            <div>
              <label
                htmlFor="login-email"
                className="mb-2 block text-sm text-[#a9ada4] sm:text-base"
              >
                E-mail
              </label>

              <input
                id="login-email"
                type="email"
                value={email}
                onChange={(event) => setEmail(event.target.value)}
                placeholder="jan@example.com"
                className="min-h-12 w-full rounded-xl border border-[#30372c] bg-[#191e19] px-4 py-3.5 text-base text-[#f2efe4] placeholder:text-[#858c7f] focus-visible:border-[#536143] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
              />
            </div>

            <div>
              <div className="mb-2 flex items-center justify-between gap-4">
                <label
                  htmlFor="login-password"
                  className="block text-sm text-[#a9ada4] sm:text-base"
                >
                  Hasło
                </label>

                <a
                  href="/forgot-password"
                  className="rounded text-sm font-semibold text-[#d7c895] transition hover:text-[#eadba6] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
                >
                  Nie pamiętasz hasła?
                </a>
              </div>

              <input
                id="login-password"
                type="password"
                value={password}
                onChange={(event) => setPassword(event.target.value)}
                placeholder="••••••••"
                className="min-h-12 w-full rounded-xl border border-[#30372c] bg-[#191e19] px-4 py-3.5 text-base text-[#f2efe4] placeholder:text-[#858c7f] focus-visible:border-[#536143] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
              />
            </div>

            {confirmationError && (
              <div
                role="alert"
                className="rounded-xl border border-[#744545] bg-[#2a1b1b] p-4 text-sm font-semibold text-[#e0a0a0]"
              >
                Link aktywacyjny jest nieważny lub został już wykorzystany.
                Jeżeli konto zostało aktywowane, spróbuj się zalogować.
              </div>
            )}

            {message && (
              <div className="rounded-xl border border-[#744545] bg-[#2a1b1b] p-4 text-sm font-semibold text-[#e0a0a0]">
                {message}
              </div>
            )}

            <button
              type="button"
              onClick={handleLogin}
              disabled={loading}
              className="min-h-12 w-full rounded-xl border border-[#536143] bg-[#536143] px-4 py-3.5 text-base font-semibold text-[#f2efe4] transition hover:border-[#78865f] hover:bg-[#78865f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] disabled:cursor-not-allowed disabled:border-[#30372c] disabled:bg-[#30372c] disabled:text-[#858c7f]"
            >
              {loading ? "Logowanie..." : "Zaloguj się"}
            </button>

            <a
              href="/register"
              className="rounded text-center text-sm text-[#a9ada4] transition hover:text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] sm:text-base"
            >
              Nie masz konta? Utwórz konto
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
  );
}






