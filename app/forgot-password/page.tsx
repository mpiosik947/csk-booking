"use client";

import Link from "next/link";
import PlatformBrand from "@/app/_components/PlatformBrand";
import { useState } from "react";
import { supabase } from "../../lib/supabase";
import { PLATFORM_BASE_URL } from "@/lib/platform-domain";

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

    const redirectTo = `${PLATFORM_BASE_URL}/reset-password`;

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
    <main className="platform-ui min-h-screen bg-[#080B09] text-[#F4F3EE]">
      <section className="mx-auto flex min-h-screen w-full max-w-[480px] items-center px-4 py-6 sm:px-6 sm:py-8">
        <div className="w-full rounded-[2rem] border border-[#303A2D] bg-[#111712] p-6 shadow-2xl shadow-black/30 sm:p-9">
          <div className="mb-7 flex justify-center">
            <PlatformBrand />
          </div>

          <h1 className="mb-2 text-3xl font-bold text-[#F4F3EE] sm:text-4xl">
            Reset hasła
          </h1>

          <p className="mb-7 text-base text-[#A6ADA5] sm:text-lg">
            Podaj adres e-mail przypisany do konta. Wyślemy link do ustawienia
            nowego hasła.
          </p>

          <div className="grid gap-6">
            <div>
              <label
                htmlFor="forgot-password-email"
                className="mb-2 block text-sm text-[#A6ADA5] sm:text-base"
              >
                E-mail
              </label>

              <input
                id="forgot-password-email"
                type="email"
                value={email}
                onChange={(event) => setEmail(event.target.value)}
                placeholder="jan@example.com"
                className="min-h-12 w-full rounded-xl border border-[#303A2D] bg-[#182019] px-4 py-3.5 text-base text-[#F4F3EE] placeholder:text-[#A6ADA5] focus-visible:border-[#697A2F] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712]"
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
              className="platform-primary min-h-12 w-full rounded-xl border border-[#697A2F] bg-[#697A2F] px-4 py-3.5 text-base font-semibold text-[#F4F3EE] transition hover:border-[#7A8D36] hover:bg-[#7A8D36] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712] disabled:cursor-not-allowed disabled:border-[#303A2D] disabled:bg-[#303A2D] disabled:text-[#A6ADA5]"
            >
              {loading ? "Wysyłanie..." : "Wyślij link resetujący"}
            </button>

            <Link
              href="/login"
              className="rounded text-center text-sm text-[#A6ADA5] transition hover:text-[#F5A900] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#F5A900] focus-visible:ring-offset-2 focus-visible:ring-offset-[#111712] sm:text-base"
            >
              ← Wróć do logowania
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
