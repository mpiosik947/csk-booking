"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";

type Role = "admin" | "pracownik" | "instruktor" | "user";

export default function DashboardPage() {
  const [email, setEmail] = useState("");
  const [fullName, setFullName] = useState("");
  const [role, setRole] = useState<Role>("user");

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
      setFullName(metadata.full_name ?? metadata.name ?? "U�ytkownik");

      const { data: profile } = await supabase
        .from("profiles")
        .select("role")
        .eq("user_id", user.id)
        .single();

      if (profile?.role) {
        setRole(profile.role as Role);
      }

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
            �adowanie panelu klienta...
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
              Aby przej�� do panelu klienta, musisz najpierw zalogowa� si� na
              swoje konto.
            </p>

            <div className="flex flex-col gap-3 sm:flex-row sm:justify-center">
              <a
                href="/login"
                className="rounded-xl bg-green-700 px-5 py-3 font-semibold text-white transition hover:bg-green-600"
              >
                Zaloguj si�
              </a>

              <a
                href="/register"
                className="rounded-xl border border-red-300 px-5 py-3 font-semibold text-red-100 transition hover:bg-red-900"
              >
                Utw�rz konto
              </a>
            </div>
          </div>
        </section>
      </main>
    );
  }

  const canAccessAdmin =
    role === "admin" ||
    role === "pracownik" ||
    role === "instruktor";

  return (
    <main className="min-h-screen bg-zinc-950 text-white">
      <section className="mx-auto max-w-6xl px-6 py-12">
        <div className="mb-10 flex flex-col gap-4 md:flex-row md:items-end md:justify-between">
          <div>
            <p className="mb-4 text-sm uppercase tracking-[0.35em] text-green-500">
              CSK Booking
            </p>

            <h1 className="text-3xl font-bold md:text-5xl">
              Panel klienta
            </h1>

            <p className="mt-3 text-zinc-400">
              Witaj,{" "}
              <span className="font-semibold text-green-500">
                {fullName}
              </span>
              . Zarz�dzaj swoimi rezerwacjami i szkoleniami.
            </p>
          </div>

          <div className="rounded-2xl border border-zinc-800 bg-zinc-900 px-5 py-4 text-sm text-zinc-300">
            Zalogowany jako:{" "}
            <span className="font-semibold text-green-500">
              {email}
            </span>
          </div>
        </div>

        <div className="grid gap-5 md:grid-cols-2">

          {canAccessAdmin && (
            <a
              href="/admin"
              className="rounded-2xl border border-green-700 bg-green-950 p-6 transition hover:bg-green-900"
            >
              <h2 className="mb-2 text-2xl font-bold text-green-300">
                Panel administracyjny
              </h2>

              <p className="text-green-100">
                Zarz�dzanie rezerwacjami, eventami, check-in oraz obs�ug� systemu.
              </p>
            </a>
          )}

          <a
            href="/booking"
            className="rounded-2xl bg-green-700 p-6 transition hover:bg-green-600"
          >
            <h2 className="mb-2 text-2xl font-bold">
              Zarezerwuj o�
            </h2>

            <p className="text-green-100">
              Wybierz dat�, o�, godzin� oraz czas rezerwacji.
              P�atno�� na miejscu.
            </p>
          </a>

          <a
            href="/my-reservations"
            className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6 transition hover:bg-zinc-800"
          >
            <h2 className="mb-2 text-2xl font-bold">
              Moje rezerwacje
            </h2>

            <p className="text-zinc-400">
              Sprawd� swoje terminy, statusy rezerwacji oraz p�atno�ci.
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
              Zobacz planowane szkolenia, wydarzenia i zapisz si� na wybrany
              termin.
            </p>
          </a>

          <a
            href="/my-events"
            className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6 transition hover:bg-zinc-800"
          >
            <h2 className="mb-2 text-2xl font-bold">
              Moje szkolenia
            </h2>

            <p className="text-zinc-400">
              Sprawd� szkolenia, na kt�re jeste� zapisany oraz status
              uczestnictwa.
            </p>
          </a>

          <a
            href="/terms"
            className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6 transition hover:bg-zinc-800"
          >
            <h2 className="mb-2 text-2xl font-bold">
              Regulamin i RODO
            </h2>

            <p className="text-zinc-400">
              Regulamin strzelnicy, zasady bezpiecze�stwa oraz polityka
              prywatno�ci.
            </p>
          </a>

          <a
            href="/account"
            className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6 transition hover:bg-zinc-800"
          >
            <h2 className="mb-2 text-2xl font-bold">
              Moje konto
            </h2>

            <p className="text-zinc-400">
              Edytuj swoje dane u�ytkownika, imi�, nazwisko oraz numer telefonu.
            </p>
          </a>
        </div>

        <div className="mt-8 flex flex-col gap-3 sm:flex-row">
          <a
            href="/"
            className="rounded-xl border border-zinc-700 px-5 py-3 text-center text-sm font-semibold text-zinc-300 transition hover:bg-zinc-900"
          >
            � Strona g��wna
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