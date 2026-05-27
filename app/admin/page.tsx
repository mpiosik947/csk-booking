import Link from "next/link";

const adminTiles = [
  {
    title: "Rezerwacje",
    description: "Podgląd i obsługa rezerwacji klientów.",
    href: "/admin",
  },
  {
    title: "Kalendarz",
    description: "Widok dnia i tygodnia dla osi oraz wydarzeń.",
    href: "/admin/calendar",
  },
  {
    title: "Blokady osi",
    description: "Blokowanie osi z powodem widocznym dla klientów.",
    href: "/admin/lane-blocks",
  },
  {
    title: "Eventy i szkolenia",
    description: "Tworzenie i zarządzanie szkoleniami oraz wydarzeniami.",
    href: "/admin/events",
  },
  {
    title: "Check-in",
    description: "Oznaczanie obecności, no-show i zakończonych wizyt.",
    href: "/admin/check-in",
  },
  {
    title: "Raporty",
    description: "Podsumowania rezerwacji, obłożenia i przychodów.",
    href: "/admin/reports",
  },
  {
    title: "Użytkownicy",
    description: "Weryfikacja kont, zmiana ról i notatki administratora.",
    href: "/admin/users",
  },
];

export default function AdminPage() {
  return (
    <main className="min-h-screen bg-zinc-950 px-6 py-10 text-white">
      <section className="mx-auto max-w-6xl">
        <div className="mb-10 flex flex-col gap-4 md:flex-row md:items-end md:justify-between">
          <div>
            <p className="mb-3 text-sm uppercase tracking-[0.35em] text-green-500">
              CSK Booking
            </p>

            <h1 className="text-4xl font-bold">
              Panel administratora
            </h1>

            <p className="mt-3 max-w-2xl text-zinc-400">
              Zarządzanie rezerwacjami, osiami, wydarzeniami, raportami i
              użytkownikami systemu.
            </p>
          </div>

          <Link
            href="/dashboard"
            className="rounded-xl border border-zinc-700 px-4 py-3 text-sm font-semibold text-zinc-300 transition hover:border-green-600 hover:text-white"
          >
            Wróć do konta
          </Link>
        </div>

        <div className="grid gap-5 md:grid-cols-2 xl:grid-cols-3">
          {adminTiles.map((tile) => (
            <Link
              key={tile.href + tile.title}
              href={tile.href}
              className="group rounded-2xl border border-zinc-800 bg-zinc-900 p-6 transition hover:border-green-700 hover:bg-zinc-900/80"
            >
              <div className="mb-5 flex h-12 w-12 items-center justify-center rounded-xl bg-green-900/40 text-xl font-bold text-green-400 transition group-hover:bg-green-800/60">
                {tile.title.charAt(0)}
              </div>

              <h2 className="mb-2 text-xl font-bold">
                {tile.title}
              </h2>

              <p className="text-sm leading-6 text-zinc-400">
                {tile.description}
              </p>
            </Link>
          ))}
        </div>
      </section>
    </main>
  );
}