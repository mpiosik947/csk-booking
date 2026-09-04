"use client";

import Image from "next/image";
import { useState } from "react";
import { supabase } from "../../lib/supabase";

export default function ForgotPasswordPage() {
  const [email, setEmail] = useState("");
  const [loading, setLoading] = useState(false);
  const [message, setMessage] = useState("");
  const [messageType, setMessageType] = useState<"success" | "error" | "">("");

  async function handleResetPassword() {
    setMessage("");
    setMessageType("");

    if (!email) {
      setMessage("Podaj adres e-mail.");
      setMessageType("error");
      return;
    }

    setLoading(true);

    const redirectTo = `${window.location.origin}/reset-password`;

    const { error } = await supabase.auth.resetPasswordForEmail(email, {
      redirectTo,
    });

    setLoading(false);

    if (error) {
      setMessage("Nie udało się wysłać linku resetującego. Spróbuj ponownie.");
      setMessageType("error");
      return;
    }

    setMessage(
      "Jeżeli konto z tym adresem e-mail istnieje, wysłaliśmy link do ustawienia nowego hasła."
    );
    setMessageType("success");
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
            Reset hasła
          </h1>

          <p className="mb-7 text-base text-[#a9ada4] sm:text-lg">
            Podaj adres e-mail przypisany do konta. Wyślemy link do ustawienia
            nowego hasła.
          </p>

          <div className="grid gap-6">
            <div>
              <label
                htmlFor="forgot-password-email"
                className="mb-2 block text-sm text-[#a9ada4] sm:text-base"
              >
                E-mail
              </label>

              <input
                id="forgot-password-email"
                type="email"
                value={email}
                onChange={(event) => setEmail(event.target.value)}
                placeholder="jan@example.com"
                className="min-h-12 w-full rounded-xl border border-[#30372c] bg-[#191e19] px-4 py-3.5 text-base text-[#f2efe4] placeholder:text-[#858c7f] focus-visible:border-[#536143] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
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
              onClick={handleResetPassword}
              disabled={loading}
              className="min-h-12 w-full rounded-xl border border-[#536143] bg-[#536143] px-4 py-3.5 text-base font-semibold text-[#f2efe4] transition hover:border-[#78865f] hover:bg-[#78865f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] disabled:cursor-not-allowed disabled:border-[#30372c] disabled:bg-[#30372c] disabled:text-[#858c7f]"
            >
              {loading ? "Wysyłanie..." : "Wyślij link resetujący"}
            </button>

            <a
              href="/login"
              className="rounded text-center text-sm text-[#a9ada4] transition hover:text-[#d7c895] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] sm:text-base"
            >
              ← Wróć do logowania
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
