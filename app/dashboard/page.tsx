"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";

export default function DashboardPage() {
  const [email, setEmail] = useState("");
  const [fullName, setFullName] = useState("");
  const [loading, setLoading] = useState(true);
  const [isLoggedIn, setIsLoggedIn] = useState(false);

  useEffect(() => {
    async function loadUser() {
      const {
        data: { user },
      } = await supabase.auth.getUser();

      if (!user) {
        setIsLoggedIn(false);
        setLoading(false);
        return;
      }

      const metadata = user.user_metadata ?? {};

      setIsLoggedIn(true);
      setEmail(user.email ?? "");
      setFullName(metadata.full_name ?? metadata.name ?? "Użytkownik");
      setLoading(false);
    }

    loadUser();
  }, []);

  async function handleLogout() {
    await supabase.auth.signOut();
    window.location.href = "/";
  }

  if (loading) {
    return (
      <main className="min-h-screen bg-zinc-950 text-white">
        <section className="mx-auto max-w-5xl px-6 py-12">
          <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6 text-zinc-400">
            Ładowanie panelu klienta...
          </div>
        </section>
      </main>
    );
  }

  if (!isLoggedIn) {
    return (
      <main className="min-h-screen bg-zinc-950 text-white">
        <section className="mx-auto max-w-4xl px-6 py-12">
          <div className="rounded-2xl border border-red-800 bg-red-950 p-8 text-center">
            <h1 className="mb-3 text-2xl font-bold text-red-200">
              Logowanie wymagane
            </h1>

            <p className="mx-auto mb-6 max-w-xl text-red-100">
              Aby przejść do panelu klienta, musisz najpierw zalogować się na
              swoje konto.
            </p>

            <div className="flex flex-col gap-3 sm:flex-row sm:justify-center">
              <a
                href="/login"
                className="rounded-xl bg-green-700 px-5 py-3 font-semibold text-white transition hover:bg-green-600"
              >
                Zaloguj się
              </a>

              <a
                href="/register"
                className="rounded-xl border border-red-300 px-5 py-3 font-semibold text-red-100 transition hover:bg-red-900"
              >
                Utwórz konto
              </a>
            </div>
          </div>
        </section>
      </main>
    );
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-white">
      <section className="mx-auto max-w-6xl px-6 py-12">
        <div className="mb-10 flex flex-col gap-4 md:flex-row md:items-end md:justify-between">
          <div>
            <p className="mb-4 text-sm uppercase tracking-[0.35em] text-green-500">
              CSK Booking
            </p>

            <h1 className="text-3xl font-bold md:text-5xl">Panel klienta</h1>

            <p className="mt-3 text-zinc-400">
              Witaj,{" "}
              <span className="font-semibold text-green-500">{fullName}</span>.
              Zarządzaj swoimi rezerwacjami i szkoleniami.
            </p>
          </div>

          <div className="rounded-2xl border border-zinc-800 bg-zinc-900 px-5 py-4 text-sm text-zinc-300">
            Zalogowany jako:{" "}
            <span className="font-semibold text-green-500">{email}</span>
          </div>
        </div>

        <div className="grid gap-5 md:grid-cols-2">
          <a
            href="/booking"
            className="rounded-2xl bg-green-700 p-6 transition hover:bg-green-600"
          >
            <h2 className="mb-2 text-2xl font-bold">Zarezerwuj oś</h2>
            <p className="text-green-100">
              Wybierz datę, oś, godzinę oraz czas rezerwacji. Płatność na
              miejscu.
            </p>
          </a>

          <a
            href="/my-reservations"
            className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6 transition hover:bg-zinc-800"
          >
            <h2 className="mb-2 text-2xl font-bold">Moje rezerwacje</h2>
            <p className="text-zinc-400">
              Sprawdź swoje terminy, statusy rezerwacji oraz płatności.
            </p>
          </a>

          <a
            href="/events"
            className="rounded-2xl border border-green-800 bg-green-950 p-6 transition hover:bg-green-900"
          >
            <h2 className="mb-2 text-2xl font-bold text-green-300">
              Eventy / Szkolenia
            </h2>
            <p className="text-green-100">
              Zobacz planowane szkolenia, wydarzenia i zapisz się na wybrany
              termin.
            </p>
          </a>

          <a
            href="/my-events"
            className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6 transition hover:bg-zinc-800"
          >
            <h2 className="mb-2 text-2xl font-bold">Moje szkolenia</h2>
            <p className="text-zinc-400">
              Sprawdź szkolenia, na które jesteś zapisany oraz status
              uczestnictwa.
            </p>
          </a>

          <a
            href="/terms"
            className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6 transition hover:bg-zinc-800"
          >
            <h2 className="mb-2 text-2xl font-bold">Regulamin i RODO</h2>
            <p className="text-zinc-400">
              Regulamin strzelnicy, zasady bezpieczeństwa oraz polityka
              prywatności.
            </p>
          </a>

          <a
            href="/account"
            className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6 transition hover:bg-zinc-800"
          >
            <h2 className="mb-2 text-2xl font-bold">Moje konto</h2>
            <p className="text-zinc-400">
              Edytuj swoje dane użytkownika, imię, nazwisko oraz numer telefonu.
            </p>
          </a>
        </div>

        <div className="mt-8 flex flex-col gap-3 sm:flex-row">
          <a
            href="/"
            className="rounded-xl border border-zinc-700 px-5 py-3 text-center text-sm font-semibold text-zinc-300 transition hover:bg-zinc-900"
          >
            ← Strona główna
          </a>

          <button
            type="button"
            onClick={handleLogout}
            className="rounded-xl border border-red-800 px-5 py-3 text-sm font-semibold text-red-400 transition hover:bg-red-950"
          >
            Wyloguj
          </button>
        </div>
      </section>
    </main>
  );
}