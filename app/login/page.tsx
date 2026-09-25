"use client";

import PlatformBrand from "@/app/_components/PlatformBrand";
import Link from "next/link";
import { useEffect, useState } from "react";
import { getLoginErrorMessage } from "../../lib/safe-client-error";
import { getSafeLoginRedirect } from "../../lib/safe-login-redirect";
import { supabase } from "../../lib/supabase";

export default function LoginPage() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");

  const [loading, setLoading] = useState(false);
  const [message, setMessage] = useState("");
  const [confirmationError, setConfirmationError] = useState(false);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      const params = new URLSearchParams(window.location.search);
      setConfirmationError(params.get("confirmationError") === "1");
    }, 0);
    return () => window.clearTimeout(timer);
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
      setMessage(getLoginErrorMessage(error));
      return;
    }

    const params = new URLSearchParams(window.location.search);
    const redirectTo = getSafeLoginRedirect(params.get("redirectTo"));

    window.location.href = redirectTo;
  }

  return (
    <main className="platform-ui min-h-screen bg-[#080B09] text-[#F4F3EE]">
      <section className="mx-auto flex min-h-screen w-full max-w-[480px] items-center px-4 py-6 sm:px-6 sm:py-8">
        <div className="w-full rounded-[2rem] border border-[#303A2D] bg-[#111712] p-6 shadow-2xl shadow-black/30 sm:p-9">
          <div className="mb-7 flex justify-center">
            <PlatformBrand />
          </div>

          <h1 className="mb-2 text-3xl font-bold text-[#F4F3EE] sm:text-4xl">
            Zaloguj się do konta
          </h1>

          <p className="mb-7 text-base text-[#A6ADA5] sm:text-lg">
            Jedno konto do rezerwacji na wszystkich strzelnicach.
          </p>

          <div className="grid gap-6">
            <div>
              <label
                htmlFor="login-email"
                className="mb-2 block text-sm text-[#A6ADA5] sm:text-base"
              >
                E-mail
              </label>

              <input
                id="login-email"
                type="email"
                value={email}
                onChange={(event) => setEmail(event.target.value)}
                placeholder="jan@example.com"
                className="min-h-12 w-full rounded-xl border border-[#303A2D] bg-[#182019] px-4 py-3.5 text-base text-[#F4F3EE] placeholder:text-[#A6ADA5] focus-visible:border-[#697A2F] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712]"
              />
            </div>

            <div>
              <div className="mb-2 flex items-center justify-between gap-4">
                <label
                  htmlFor="login-password"
                  className="block text-sm text-[#A6ADA5] sm:text-base"
                >
                  Hasło
                </label>

                <Link
                  href="/forgot-password"
                  className="rounded text-sm font-semibold text-[#F5A900] transition hover:text-[#FFB61A] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712]"
                >
                  Nie pamiętasz hasła?
                </Link>
              </div>

              <input
                id="login-password"
                type="password"
                value={password}
                onChange={(event) => setPassword(event.target.value)}
                placeholder="••••••••"
                className="min-h-12 w-full rounded-xl border border-[#303A2D] bg-[#182019] px-4 py-3.5 text-base text-[#F4F3EE] placeholder:text-[#A6ADA5] focus-visible:border-[#697A2F] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712]"
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
              className="platform-primary min-h-12 w-full rounded-xl border border-[#697A2F] bg-[#697A2F] px-4 py-3.5 text-base font-semibold text-[#F4F3EE] transition hover:border-[#7A8D36] hover:bg-[#7A8D36] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712] disabled:cursor-not-allowed disabled:border-[#303A2D] disabled:bg-[#303A2D] disabled:text-[#A6ADA5]"
            >
              {loading ? "Logowanie..." : "Zaloguj się"}
            </button>

            <Link
              href="/register"
              className="rounded text-center text-sm text-[#A6ADA5] transition hover:text-[#F5A900] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712] sm:text-base"
            >
              Nie masz konta? Załóż konto
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
  );
}





