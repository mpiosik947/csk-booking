"use client";

import { useEffect, useState } from "react";
import { supabase } from "../lib/supabase";

type UserRole = "admin" | "pracownik" | "instruktor" | "user";

export default function Home() {
  const [email, setEmail] = useState("");
  const [role, setRole] = useState<UserRole | null>(null);

  useEffect(() => {
    async function loadUser() {
      const {
        data: { user },
      } = await supabase.auth.getUser();

      setEmail(user?.email ?? "");

      if (!user) {
        setRole(null);
        return;
      }

      const { data: roleData, error: roleError } = await supabase.rpc(
        "get_my_role"
      );

      if (roleError) {
        setRole(null);
        return;
      }

      setRole((roleData as UserRole) ?? null);
    }

    loadUser();
  }, []);

  async function handleLogout() {
    await supabase.auth.signOut();
    setEmail("");
    setRole(null);
    window.location.href = "/";
  }

  const canSeeAdminPanel =
    role === "admin" || role === "pracownik" || role === "instruktor";

  return (
    <main className="min-h-screen bg-zinc-950 text-white">
      <section className="mx-auto flex min-h-screen max-w-5xl flex-col items-center justify-center px-6 text-center">
        <div className="mb-6 rounded-full border border-yellow-700 bg-yellow-950 px-5 py-2 text-sm font-bold uppercase tracking-[0.35em] text-yellow-300">
          WERSJA TESTOWA
        </div>

        <p className="mb-4 text-sm uppercase tracking-[0.35em] text-green-500">
          Centrum Szkolenia Krutla
        </p>

        <h1 className="mb-6 text-4xl font-bold tracking-tight md:text-6xl">
          Panel Rezerwacji CSK
        </h1>

        <p className="mb-6 max-w-2xl text-lg text-zinc-300">
          Testowa wersja systemu rezerwacji osi, szkoleń i eventów. System może
          być jeszcze rozwijany i poprawiany.
        </p>

        {email ? (
          <div className="mb-8 rounded-2xl border border-zinc-800 bg-zinc-900 px-6 py-4 text-sm text-zinc-300">
            Zalogowany jako:{" "}
            <span className="font-semibold text-green-500">{email}</span>
          </div>
        ) : (
          <div className="mb-8 rounded-2xl border border-zinc-800 bg-zinc-900 px-6 py-4 text-sm text-zinc-300">
            Nie jesteś zalogowany.
          </div>
        )}

        <div className="grid w-full max-w-3xl gap-4 md:grid-cols-2">
          {email ? (
            <a
              href="/dashboard"
              className="rounded-2xl bg-green-700 px-6 py-5 text-lg font-semibold transition hover:bg-green-600 md:col-span-2"
            >
              Przejdź do panelu klienta
            </a>
          ) : (
            <>
              <a
                href="/login"
                className="rounded-2xl bg-green-700 px-6 py-5 text-lg font-semibold transition hover:bg-green-600"
              >
                Logowanie
              </a>

              <a
                href="/register"
                className="rounded-2xl border border-zinc-700 px-6 py-5 text-lg font-semibold transition hover:bg-zinc-900"
              >
                Rejestracja
              </a>
            </>
          )}

          <a
            href="/events"
            className="rounded-2xl border border-green-800 bg-green-950 px-6 py-5 text-lg font-semibold text-green-300 transition hover:bg-green-900"
          >
            Eventy / Szkolenia
          </a>

          <a
            href="/terms"
            className="rounded-2xl border border-zinc-700 px-6 py-5 text-lg font-semibold transition hover:bg-zinc-900"
          >
            Regulamin i RODO
          </a>

          {canSeeAdminPanel && (
            <a
              href="/admin"
              className="rounded-2xl border border-green-800 px-6 py-5 text-lg font-semibold text-green-400 transition hover:bg-green-950 md:col-span-2"
            >
              Panel administratora
            </a>
          )}

          {email && (
            <button
              type="button"
              onClick={handleLogout}
              className="rounded-2xl border border-red-800 px-6 py-5 text-lg font-semibold text-red-400 transition hover:bg-red-950 md:col-span-2"
            >
              Wyloguj
            </button>
          )}
        </div>

        <div className="mt-12 grid w-full max-w-3xl gap-4 text-left md:grid-cols-3">
          <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
            <h2 className="mb-2 font-semibold">Rezerwacje</h2>
            <p className="text-sm text-zinc-400">
              Testowy system rezerwacji osi strzeleckich.
            </p>
          </div>

          <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
            <h2 className="mb-2 font-semibold">Szkolenia</h2>
            <p className="text-sm text-zinc-400">
              Zapisy na eventy i szkolenia organizowane na obiekcie.
            </p>
          </div>

          <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
            <h2 className="mb-2 font-semibold">Status</h2>
            <p className="text-sm text-yellow-300">
              Wersja testowa — system w fazie sprawdzania.
            </p>
          </div>
        </div>
      </section>
    </main>
  );
}