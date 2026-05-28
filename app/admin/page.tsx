"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { supabase } from "../../lib/supabase";

type Role = "admin" | "pracownik" | "instruktor" | "user";

type AdminTile = {
  title: string;
  description: string;
  href: string;
  roles: Role[];
};

const adminTiles: AdminTile[] = [
  {
    title: "Rezerwacje",
    description: "Podgląd i obsługa rezerwacji klientów.",
    href: "/admin/reservations",
    roles: ["admin", "pracownik"],
  },
  {
    title: "Kalendarz",
    description: "Widok dnia i tygodnia dla osi oraz wydarzeń.",
    href: "/admin/calendar",
    roles: ["admin", "pracownik"],
  },
  {
    title: "Blokady osi",
    description: "Blokowanie osi z powodem widocznym dla klientów.",
    href: "/admin/lane-blocks",
    roles: ["admin", "pracownik"],
  },
  {
    title: "Eventy i szkolenia",
    description: "Tworzenie i zarządzanie szkoleniami oraz wydarzeniami.",
    href: "/admin/events",
    roles: ["admin", "pracownik", "instruktor"],
  },
  {
    title: "Check-in",
    description: "Obsługa obecności, no-show i zakończonych wizyt.",
    href: "/admin/check-in",
    roles: ["admin", "pracownik", "instruktor"],
  },
  {
    title: "Raporty",
    description: "Podsumowania rezerwacji, obłożenia i przychodów.",
    href: "/admin/reports",
    roles: ["admin"],
  },
  {
    title: "Użytkownicy",
    description: "Weryfikacja kont, role i notatki administratora.",
    href: "/admin/users",
    roles: ["admin", "pracownik"],
  },
];

function getRoleLabel(role: string | null) {
  switch (role) {
    case "admin":
      return "Administrator";
    case "pracownik":
      return "Pracownik";
    case "instruktor":
      return "Instruktor";
    case "user":
      return "Użytkownik";
    default:
      return "Brak roli";
  }
}

function getRoleBadgeClass(role: string | null) {
  switch (role) {
    case "admin":
      return "border-green-700 bg-green-950 text-green-300";
    case "pracownik":
      return "border-blue-700 bg-blue-950 text-blue-300";
    case "instruktor":
      return "border-purple-700 bg-purple-950 text-purple-300";
    default:
      return "border-zinc-700 bg-zinc-900 text-zinc-300";
  }
}

export default function AdminPage() {
  const [loading, setLoading] = useState(true);
  const [role, setRole] = useState<Role | null>(null);
  const [message, setMessage] = useState("");

  useEffect(() => {
    async function loadRole() {
      setLoading(true);
      setMessage("");

      const { data, error } = await supabase.rpc("get_my_role");

      setLoading(false);

      if (error) {
        setMessage(`Błąd pobierania roli: ${error.message}`);
        return;
      }

      setRole((data as Role) || "user");
    }

    loadRole();
  }, []);

  const visibleTiles = useMemo(() => {
    if (!role) return [];
    return adminTiles.filter((tile) => tile.roles.includes(role));
  }, [role]);

  return (
    <main className="min-h-screen bg-zinc-950 px-6 py-10 text-white">
      <section className="mx-auto max-w-6xl">
        <div className="mb-10 flex flex-col gap-4 md:flex-row md:items-end md:justify-between">
          <div>
            <p className="mb-3 text-sm uppercase tracking-[0.35em] text-green-500">
              CSK Booking
            </p>

            <div className="mb-4 flex flex-wrap items-center gap-3">
              <h1 className="text-4xl font-bold">Panel administracyjny</h1>

              {!loading && role && (
                <span
                  className={`rounded-full border px-4 py-2 text-sm font-bold ${getRoleBadgeClass(
                    role
                  )}`}
                >
                  {getRoleLabel(role)}
                </span>
              )}
            </div>

            <p className="max-w-2xl text-zinc-400">
              Widzisz tylko moduły dostępne dla Twojej roli.
            </p>
          </div>

          <Link
            href="/dashboard"
            className="rounded-xl border border-zinc-700 px-4 py-3 text-sm font-semibold text-zinc-300 transition hover:border-green-600 hover:text-white"
          >
            Wróć do konta
          </Link>
        </div>

        {message && (
          <div className="mb-6 rounded-xl border border-red-800 bg-red-950 p-4 text-red-300">
            {message}
          </div>
        )}

        {loading ? (
          <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-8 text-zinc-400">
            Ładowanie panelu...
          </div>
        ) : visibleTiles.length === 0 ? (
          <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-8 text-zinc-400">
            Brak dostępnych modułów dla tej roli.
          </div>
        ) : (
          <div className="grid gap-5 md:grid-cols-2 xl:grid-cols-3">
            {visibleTiles.map((tile) => (
              <Link
                key={tile.href + tile.title}
                href={tile.href}
                className="group rounded-2xl border border-zinc-800 bg-zinc-900 p-6 transition hover:border-green-700 hover:bg-zinc-900/80"
              >
                <div className="mb-5 flex h-12 w-12 items-center justify-center rounded-xl bg-green-900/40 text-xl font-bold text-green-400 transition group-hover:bg-green-800/60">
                  {tile.title.charAt(0)}
                </div>

                <h2 className="mb-2 text-xl font-bold">{tile.title}</h2>

                <p className="text-sm leading-6 text-zinc-400">
                  {tile.description}
                </p>
              </Link>
            ))}
          </div>
        )}
      </section>
    </main>
  );
}