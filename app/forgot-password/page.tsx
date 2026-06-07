"use client";

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
      setMessage(`Błąd wysyłki linku resetującego: ${error.message}`);
      setMessageType("error");
      return;
    }

    setMessage(
      "Jeżeli konto z tym adresem e-mail istnieje, wysłaliśmy link do ustawienia nowego hasła."
    );
    setMessageType("success");
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-white">
      <section className="mx-auto flex min-h-screen max-w-md items-center px-6 py-12">
        <div className="w-full rounded-2xl border border-zinc-800 bg-zinc-900 p-8">
          <p className="mb-4 text-sm uppercase tracking-[0.35em] text-green-500">
            CSK Booking
          </p>

          <h1 className="mb-2 text-3xl font-bold">Reset hasła</h1>

          <p className="mb-8 text-zinc-400">
            Podaj adres e-mail przypisany do konta. Wyślemy link do ustawienia
            nowego hasła.
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
              onClick={handleResetPassword}
              disabled={loading}
              className="rounded-xl bg-green-700 px-4 py-3 font-semibold transition hover:bg-green-600 disabled:cursor-not-allowed disabled:opacity-60"
            >
              {loading ? "Wysyłanie..." : "Wyślij link resetujący"}
            </button>

            <a
              href="/login"
              className="text-center text-sm text-zinc-400 hover:text-white"
            >
              ← Wróć do logowania
            </a>
          </div>
        </div>
      </section>
    </main>
  );
}
