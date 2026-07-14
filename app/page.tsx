"use client";

import Image from "next/image";
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
      <section className="mx-auto flex min-h-screen max-w-5xl flex-col items-center justify-center px-6 py-10 text-center sm:py-12">
        <div className="mb-8 flex justify-center">
          <Image
            src="/login-brand.png"
            alt="CSK - Centrum Szkolenia Krutla"
            width={1536}
            height={1024}
            priority
            className="h-auto w-full max-w-[360px] rounded-xl"
          />
        </div>

        <h1 className="mb-6 text-4xl font-bold tracking-tight md:text-6xl">
          Centrum Szkolenia Krutla
        </h1>

        <p className="mb-6 max-w-2xl text-lg text-zinc-300">
          System rezerwacji osi strzeleckich, szkoleń i eventów.
        </p>

        {email && (
          <p className="mb-6 text-sm text-zinc-300">
            Zalogowany jako:{" "}
            <span className="font-semibold text-green-500">{email}</span>
          </p>
        )}

        <div className="mb-4 grid w-full max-w-3xl gap-4 md:grid-cols-2">
          <a
            href="/booking"
            className="rounded-2xl border border-green-800 bg-green-950 p-6 text-left transition hover:bg-green-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-green-400 focus-visible:ring-offset-2 focus-visible:ring-offset-zinc-950"
          >
            <h2 className="text-2xl font-bold text-green-300">
              Zarezerwuj oś
            </h2>
            <p className="mt-2 text-green-100">
              Wybierz oś, termin i godzinę rezerwacji.
            </p>
          </a>

          <a
            href="/events"
            className="rounded-2xl border border-green-800 bg-green-950 p-6 text-left transition hover:bg-green-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-green-400 focus-visible:ring-offset-2 focus-visible:ring-offset-zinc-950"
          >
            <h2 className="text-2xl font-bold text-green-300">Szkolenia</h2>
            <p className="mt-2 text-green-100">
              Sprawdź dostępne szkolenia i zapisz się online.
            </p>
          </a>
        </div>

        {email ? (
          <div className="mb-4 flex w-full max-w-3xl flex-col gap-3 sm:flex-row sm:flex-wrap sm:justify-center">
            <a
              href="/dashboard"
              className="w-full rounded-xl border border-zinc-700 bg-zinc-900 px-4 py-3 text-sm font-semibold transition hover:bg-zinc-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-green-400 focus-visible:ring-offset-2 focus-visible:ring-offset-zinc-950 sm:w-auto"
            >
              Panel klienta
            </a>

            <a
              href="/my-reservations"
              className="w-full rounded-xl border border-zinc-700 px-4 py-3 text-sm font-semibold text-zinc-300 transition hover:bg-zinc-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-green-400 focus-visible:ring-offset-2 focus-visible:ring-offset-zinc-950 sm:w-auto"
            >
              Moje rezerwacje
            </a>

            <a
              href="/my-events"
              className="w-full rounded-xl border border-zinc-700 px-4 py-3 text-sm font-semibold text-zinc-300 transition hover:bg-zinc-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-green-400 focus-visible:ring-offset-2 focus-visible:ring-offset-zinc-950 sm:w-auto"
            >
              Moje szkolenia
            </a>
          </div>
        ) : (
          <div className="mb-4 flex w-full max-w-3xl flex-col gap-3 sm:flex-row sm:justify-center">
            <a
              href="/login"
              className="w-full rounded-xl border border-zinc-700 bg-zinc-900 px-4 py-3 text-sm font-semibold transition hover:bg-zinc-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-green-400 focus-visible:ring-offset-2 focus-visible:ring-offset-zinc-950 sm:w-auto"
            >
              Zaloguj się
            </a>

            <a
              href="/register"
              className="w-full rounded-xl border border-zinc-700 px-4 py-3 text-sm font-semibold text-zinc-300 transition hover:bg-zinc-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-green-400 focus-visible:ring-offset-2 focus-visible:ring-offset-zinc-950 sm:w-auto"
            >
              Załóż konto
            </a>
          </div>
        )}

        <div className="mt-12 grid w-full max-w-3xl gap-4 text-left">
          <div className="rounded-2xl border border-blue-800 bg-blue-950/40 p-5 opacity-70">
            <div className="mb-2 flex items-center justify-between gap-3">
              <h2 className="font-semibold">Strzelanie z instruktorem</h2>

              <span className="rounded-full border border-blue-700 px-2 py-1 text-xs font-bold text-blue-300">
                WKRÓTCE
              </span>
            </div>

            <p className="text-sm text-zinc-400">
              Dla osób nieposiadających pozwolenia na broń. Broń, amunicja i
              instruktor zapewnione na miejscu.
            </p>
          </div>
        </div>

        <div className="mt-6 flex w-full max-w-3xl flex-col items-center gap-3 text-sm sm:flex-row sm:flex-wrap sm:justify-center">
          <a
            href="/terms"
            className="rounded-lg px-3 py-2 text-zinc-400 transition hover:text-zinc-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-green-400 focus-visible:ring-offset-2 focus-visible:ring-offset-zinc-950"
          >
            Regulamin i RODO
          </a>

          {canSeeAdminPanel && (
            <a
              href="/admin"
              className="rounded-xl border border-zinc-700 px-4 py-2 font-semibold text-green-400 transition hover:bg-zinc-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-green-400 focus-visible:ring-offset-2 focus-visible:ring-offset-zinc-950"
            >
              Panel administratora
            </a>
          )}

          {email && (
            <button
              type="button"
              onClick={handleLogout}
              className="rounded-lg px-3 py-2 font-semibold text-red-400 transition hover:text-red-300 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-red-400 focus-visible:ring-offset-2 focus-visible:ring-offset-zinc-950"
            >
              Wyloguj
            </button>
          )}
        </div>

        <p className="mt-6 text-xs font-medium text-zinc-400">
          WERSJA TESTOWA
        </p>
      </section>
    </main>
  );
}


