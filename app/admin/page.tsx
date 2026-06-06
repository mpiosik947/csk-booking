"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { supabase } from "../../lib/supabase";
import {
  RESERVATION_STATUS,
  isCancelledReservationStatus,
} from "../../lib/reservation-status";
import {
  PAYMENT_STATUS,
  isPaidPaymentStatus,
} from "../../lib/payment-status";

type Role = "admin" | "pracownik" | "instruktor" | "user";

type Reservation = {
  id: string;
  user_id: string | null;
  customer_name: string | null;
  customer_email: string | null;
  customer_phone: string | null;
  reservation_date: string | null;
  start_time: string | null;
  end_time: string | null;
  duration_minutes: number | null;
  price: number | null;
  reservation_status: string | null;
  payment_status: string | null;
  attendance_status: string | null;
  shooting_lanes:
    | { name: string | null }
    | { name: string | null }[]
    | null;
};

type Profile = {
  id: string;
  verification_status: string | null;
};

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
    roles: ["admin", "pracownik", "instruktor"],
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
    roles: ["admin"],
  },
];

function getLocalDateISO(date = new Date()) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function getMonthRange(date = new Date()) {
  const firstDay = new Date(date.getFullYear(), date.getMonth(), 1);
  const lastDay = new Date(date.getFullYear(), date.getMonth() + 1, 0);

  return {
    start: getLocalDateISO(firstDay),
    end: getLocalDateISO(lastDay),
  };
}

function normalizeTime(time: string | null) {
  if (!time) return "";
  return time.slice(0, 5);
}

function getCurrentTimeHHMM() {
  const now = new Date();
  const hours = String(now.getHours()).padStart(2, "0");
  const minutes = String(now.getMinutes()).padStart(2, "0");
  return `${hours}:${minutes}`;
}



function getLaneName(reservation: Reservation) {
  const lanes = reservation.shooting_lanes;

  if (Array.isArray(lanes)) {
    return lanes[0]?.name || "Brak osi";
  }

  return lanes?.name || "Brak osi";
}

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

function hasAccess(role: Role | null, allowedRoles: Role[]) {
  if (!role) return false;
  return allowedRoles.includes(role);
}

function StatCard({
  title,
  value,
  description,
  href,
  tone = "default",
}: {
  title: string;
  value: string | number;
  description?: string;
  href?: string;
  tone?: "default" | "green" | "yellow" | "red" | "blue";
}) {
  const valueClass =
    tone === "green"
      ? "text-green-400"
      : tone === "yellow"
      ? "text-yellow-300"
      : tone === "red"
      ? "text-red-300"
      : tone === "blue"
      ? "text-blue-300"
      : "text-white";

  const content = (
    <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5 transition hover:border-green-700">
      <p className="text-sm text-zinc-400">{title}</p>
      <p className={`mt-2 text-3xl font-bold ${valueClass}`}>{value}</p>
      {description && (
        <p className="mt-2 text-xs leading-5 text-zinc-500">{description}</p>
      )}
    </div>
  );

  if (href) {
    return <Link href={href}>{content}</Link>;
  }

  return content;
}

function AdminModuleTile({
  tile,
  allowed,
}: {
  tile: AdminTile;
  allowed: boolean;
}) {
  if (!allowed) {
    return (
      <div className="rounded-2xl border border-red-900 bg-red-950/40 p-6 opacity-90">
        <div className="mb-5 flex h-12 w-12 items-center justify-center rounded-xl bg-red-900/70 text-xl font-bold text-red-300">
          !
        </div>

        <div className="mb-3 inline-flex rounded-full border border-red-800 bg-red-950 px-3 py-1 text-xs font-bold uppercase tracking-[0.2em] text-red-300">
          Brak dostępu
        </div>

        <h2 className="mb-2 text-xl font-bold text-red-100">{tile.title}</h2>

        <p className="text-sm leading-6 text-red-200/80">{tile.description}</p>
      </div>
    );
  }

  return (
    <Link
      href={tile.href}
      className="group rounded-2xl border border-zinc-800 bg-zinc-900 p-6 transition hover:border-green-700 hover:bg-zinc-900/80"
    >
      <div className="mb-5 flex h-12 w-12 items-center justify-center rounded-xl bg-green-900/40 text-xl font-bold text-green-400 transition group-hover:bg-green-800/60">
        {tile.title.charAt(0)}
      </div>

      <div className="mb-3 inline-flex rounded-full border border-green-800 bg-green-950 px-3 py-1 text-xs font-bold uppercase tracking-[0.2em] text-green-300">
        Dostęp
      </div>

      <h2 className="mb-2 text-xl font-bold">{tile.title}</h2>

      <p className="text-sm leading-6 text-zinc-400">{tile.description}</p>
    </Link>
  );
}

export default function AdminPage() {
  const today = getLocalDateISO();
  const monthRange = getMonthRange();

  const [loading, setLoading] = useState(true);
  const [role, setRole] = useState<Role | null>(null);
  const [message, setMessage] = useState("");

  const [todayReservations, setTodayReservations] = useState<Reservation[]>([]);
  const [monthReservations, setMonthReservations] = useState<Reservation[]>([]);
  const [profiles, setProfiles] = useState<Profile[]>([]);

  useEffect(() => {
    loadDashboard();
  }, []);

  async function loadDashboard() {
    setLoading(true);
    setMessage("");

    const { data: roleData, error: roleError } = await supabase.rpc(
      "get_my_role"
    );

    if (roleError) {
      setMessage(`Błąd pobierania roli: ${roleError.message}`);
      setLoading(false);
      return;
    }

    const currentRole = (roleData as Role) || "user";
    setRole(currentRole);

    const [
      todayReservationsResult,
      monthReservationsResult,
      profilesResult,
    ] = await Promise.all([
      supabase
        .from("reservations")
        .select(
          `
          id,
          user_id,
          customer_name,
          customer_email,
          customer_phone,
          reservation_date,
          start_time,
          end_time,
          duration_minutes,
          price,
          reservation_status,
          payment_status,
          attendance_status,
          shooting_lanes (
            name
          )
        `
        )
        .eq("reservation_date", today)
        .order("start_time", { ascending: true }),

      supabase
        .from("reservations")
        .select(
          `
          id,
          user_id,
          customer_name,
          customer_email,
          customer_phone,
          reservation_date,
          start_time,
          end_time,
          duration_minutes,
          price,
          reservation_status,
          payment_status,
          attendance_status,
          shooting_lanes (
            name
          )
        `
        )
        .gte("reservation_date", monthRange.start)
        .lte("reservation_date", monthRange.end)
        .order("reservation_date", { ascending: true })
        .order("start_time", { ascending: true }),

      supabase.from("profiles").select("id, verification_status"),
    ]);

    if (todayReservationsResult.error) {
      setMessage(
        `Błąd pobierania dzisiejszych rezerwacji: ${todayReservationsResult.error.message}`
      );
      setLoading(false);
      return;
    }

    if (monthReservationsResult.error) {
      setMessage(
        `Błąd pobierania rezerwacji miesięcznych: ${monthReservationsResult.error.message}`
      );
      setLoading(false);
      return;
    }

    if (profilesResult.error) {
      setMessage(`Błąd pobierania użytkowników: ${profilesResult.error.message}`);
      setLoading(false);
      return;
    }

    setTodayReservations(
      (todayReservationsResult.data ?? []) as unknown as Reservation[]
    );
    setMonthReservations(
      (monthReservationsResult.data ?? []) as unknown as Reservation[]
    );
    setProfiles((profilesResult.data ?? []) as Profile[]);

    setLoading(false);
  }

  const availableTilesCount = useMemo(() => {
    if (!role) return 0;
    return adminTiles.filter((tile) => hasAccess(role, tile.roles)).length;
  }, [role]);

  const activeTodayReservations = todayReservations.filter(
    (reservation) => !isCancelledReservationStatus(reservation.reservation_status)
  );

  const activeMonthReservations = monthReservations.filter(
    (reservation) => !isCancelledReservationStatus(reservation.reservation_status)
  );

  const uniqueTodayClients = new Set(
    activeTodayReservations.map(
      (reservation) =>
        reservation.user_id ||
        reservation.customer_email ||
        reservation.customer_phone ||
        reservation.customer_name ||
        reservation.id
    )
  ).size;

  const pendingCheckIns = activeTodayReservations.filter(
    (reservation) =>
      reservation.attendance_status === "planned" ||
      reservation.attendance_status === null
  );

  const presentToday = activeTodayReservations.filter(
    (reservation) =>
      reservation.attendance_status === "present" ||
      reservation.reservation_status === RESERVATION_STATUS.COMPLETED
  );

  const noShowToday = todayReservations.filter(
    (reservation) =>
      reservation.attendance_status === "no_show" ||
      reservation.reservation_status === RESERVATION_STATUS.NO_SHOW
  );

  const unpaidToday = activeTodayReservations.filter(
    (reservation) => reservation.payment_status === PAYMENT_STATUS.UNPAID
  );

  const payOnSiteToday = activeTodayReservations.filter(
    (reservation) => reservation.payment_status === PAYMENT_STATUS.PAY_ON_SITE
  );

  const unverifiedUsers = profiles.filter(
    (profile) => profile.verification_status !== "verified"
  );

  const todayRevenue = activeTodayReservations
    .filter((reservation) => isPaidPaymentStatus(reservation.payment_status))
    .reduce((sum, reservation) => sum + Number(reservation.price ?? 0), 0);

  const monthRevenue = activeMonthReservations
    .filter((reservation) => isPaidPaymentStatus(reservation.payment_status))
    .reduce((sum, reservation) => sum + Number(reservation.price ?? 0), 0);

  const monthPlannedRevenue = activeMonthReservations.reduce(
    (sum, reservation) => sum + Number(reservation.price ?? 0),
    0
  );

  const averageReservationValue =
    activeMonthReservations.length > 0
      ? Math.round(monthPlannedRevenue / activeMonthReservations.length)
      : 0;

  const topLane = Object.entries(
    activeMonthReservations.reduce<Record<string, number>>((acc, reservation) => {
      const laneName = getLaneName(reservation);
      acc[laneName] = (acc[laneName] ?? 0) + 1;
      return acc;
    }, {})
  ).sort((a, b) => b[1] - a[1])[0];

  const nowHHMM = getCurrentTimeHHMM();

  const upcomingReservations = activeTodayReservations
    .filter((reservation) => normalizeTime(reservation.start_time) >= nowHHMM)
    .slice(0, 5);

  return (
    <main className="min-h-screen bg-zinc-950 px-6 py-10 text-white">
      <section className="mx-auto max-w-7xl">
        <div className="mb-10 flex flex-col gap-4 md:flex-row md:items-end md:justify-between">
          <div>
            <p className="mb-3 text-sm uppercase tracking-[0.35em] text-green-500">
              CSK Booking
            </p>

            <div className="mb-4 flex flex-wrap items-center gap-3">
              <h1 className="text-4xl font-bold">Dashboard operacyjny</h1>

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

            <p className="max-w-3xl text-zinc-400">
              Szybki podgląd dzisiejszych wizyt, alertów, płatności i
              najważniejszych danych operacyjnych strzelnicy.
            </p>
          </div>

          <div className="flex flex-wrap gap-3">
            <button
              type="button"
              onClick={loadDashboard}
              disabled={loading}
              className="rounded-xl border border-zinc-700 px-4 py-3 text-sm font-semibold text-zinc-300 transition hover:border-green-600 hover:text-white disabled:cursor-not-allowed disabled:opacity-60"
            >
              {loading ? "Odświeżanie..." : "Odśwież"}
            </button>

            <Link
              href="/dashboard"
              className="rounded-xl border border-zinc-700 px-4 py-3 text-sm font-semibold text-zinc-300 transition hover:border-green-600 hover:text-white"
            >
              Wróć do konta
            </Link>
          </div>
        </div>

        {message && (
          <div className="mb-6 rounded-xl border border-red-800 bg-red-950 p-4 text-red-300">
            {message}
          </div>
        )}

        {loading ? (
          <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-8 text-zinc-400">
            Ładowanie dashboardu...
          </div>
        ) : availableTilesCount === 0 ? (
          <div className="rounded-2xl border border-red-900 bg-red-950/40 p-8 text-red-200">
            Brak dostępnych modułów dla tej roli.
          </div>
        ) : (
          <>
            <div className="mb-10">
              <div className="mb-4 flex items-center justify-between gap-4">
                <h2 className="text-2xl font-bold">Dzisiaj</h2>
                <p className="text-sm text-zinc-500">{today}</p>
              </div>

              <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
                <StatCard
                  title="Rezerwacje dzisiaj"
                  value={activeTodayReservations.length}
                  description="Aktywne rezerwacje bez anulowanych."
                  href="/admin/reservations"
                  tone="blue"
                />

                <StatCard
                  title="Klienci dzisiaj"
                  value={uniqueTodayClients}
                  description="Unikalni klienci z dzisiejszych rezerwacji."
                  href="/admin/check-in"
                />

                <StatCard
                  title="Oczekujące check-in"
                  value={pendingCheckIns.length}
                  description="Wizyty zaplanowane, jeszcze nieobsłużone."
                  href="/admin/check-in"
                  tone="yellow"
                />

                <StatCard
                  title="Klienci obsłużeni"
                  value={presentToday.length}
                  description="Wizyty oznaczone jako obecne lub zakończone."
                  href="/admin/check-in"
                  tone="green"
                />
              </div>
            </div>

            <div className="mb-10">
              <h2 className="mb-4 text-2xl font-bold">Alerty</h2>

              <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
               <StatCard
  title="Niezweryfikowani użytkownicy"
  value={unverifiedUsers.length}
  description="Konta wymagające sprawdzenia przez obsługę."
  href={hasAccess(role, ["admin"]) ? "/admin/users" : undefined}
  tone={unverifiedUsers.length > 0 ? "yellow" : "green"}
/>

                <StatCard
                  title="Nieopłacone dzisiaj"
                  value={unpaidToday.length}
                  description="Rezerwacje ze statusem nieopłacona."
                  href="/admin/check-in"
                  tone={unpaidToday.length > 0 ? "red" : "green"}
                />

                <StatCard
                  title="Płatność na miejscu"
                  value={payOnSiteToday.length}
                  description="Klienci, od których trzeba pobrać płatność."
                  href="/admin/check-in"
                  tone="yellow"
                />

                <StatCard
                  title="No-show dzisiaj"
                  value={noShowToday.length}
                  description="Klienci oznaczeni jako nieobecni."
                  href="/admin/check-in"
                  tone={noShowToday.length > 0 ? "red" : "green"}
                />
              </div>
            </div>

            <div className="mb-10">
              <h2 className="mb-4 text-2xl font-bold">Biznes</h2>

              <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
                <StatCard
                  title="Dzisiejszy przychód"
                  value={`${todayRevenue.toFixed(0)} zł`}
                  description="Tylko rezerwacje opłacone."
                  href="/admin/reports"
                  tone="green"
                />

                <StatCard
                  title="Przychód miesiąca"
                  value={`${monthRevenue.toFixed(0)} zł`}
                  description="Suma opłaconych rezerwacji w tym miesiącu."
                  href="/admin/reports"
                  tone="green"
                />

                <StatCard
                  title="Średnia wartość rezerwacji"
                  value={`${averageReservationValue} zł`}
                  description="Na podstawie aktywnych rezerwacji w miesiącu."
                  href="/admin/reports"
                />

                <StatCard
                  title="Najpopularniejsza oś"
                  value={topLane ? topLane[0] : "Brak"}
                  description={
                    topLane ? `${topLane[1]} rez. w miesiącu` : "Brak danych"
                  }
                  href="/admin/reports"
                  tone="blue"
                />
              </div>
            </div>

            <div className="mb-10 grid gap-6 xl:grid-cols-[1.2fr_0.8fr]">
              <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6">
                <div className="mb-5 flex items-center justify-between gap-4">
                  <h2 className="text-2xl font-bold">
                    Najbliższe rezerwacje
                  </h2>

                  <Link
                    href="/admin/check-in"
                    className="text-sm font-semibold text-green-400 hover:text-green-300"
                  >
                    Przejdź do check-in →
                  </Link>
                </div>

                {upcomingReservations.length === 0 ? (
                  <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-5 text-zinc-400">
                    Brak kolejnych rezerwacji na dziś.
                  </div>
                ) : (
                  <div className="overflow-x-auto">
                    <table className="w-full min-w-[650px] text-left text-sm">
                      <thead>
                        <tr className="border-b border-zinc-800 text-zinc-400">
                          <th className="py-3 pr-4">Godzina</th>
                          <th className="py-3 pr-4">Klient</th>
                          <th className="py-3 pr-4">Oś</th>
                          <th className="py-3 pr-4">Płatność</th>
                        </tr>
                      </thead>

                      <tbody>
                        {upcomingReservations.map((reservation) => (
                          <tr
                            key={reservation.id}
                            className="border-b border-zinc-800"
                          >
                            <td className="py-4 pr-4 font-bold">
                              {normalizeTime(reservation.start_time)}–
                              {normalizeTime(reservation.end_time)}
                            </td>

                            <td className="py-4 pr-4">
                              <p className="font-semibold">
                                {reservation.customer_name || "Brak danych"}
                              </p>
                              <p className="text-xs text-zinc-500">
                                {reservation.customer_phone || "brak telefonu"}
                              </p>
                            </td>

                            <td className="py-4 pr-4">
                              {getLaneName(reservation)}
                            </td>

                            <td className="py-4 pr-4">
                              {reservation.payment_status || "brak"}
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                )}
              </div>

              <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6">
                <h2 className="mb-5 text-2xl font-bold">Szybkie akcje</h2>

                <div className="grid gap-3">
  <Link
    href="/booking"
    className="rounded-xl border border-zinc-700 px-4 py-3 text-sm font-bold text-zinc-200 transition hover:border-green-700 hover:bg-green-950/30"
  >
    + Nowa rezerwacja
  </Link>

  {hasAccess(role, ["admin", "pracownik", "instruktor"]) && (
    <Link
      href="/admin/check-in"
      className="rounded-xl border border-zinc-700 px-4 py-3 text-sm font-bold text-zinc-200 transition hover:border-green-700 hover:bg-green-950/30"
    >
      Check-in klientów
    </Link>
  )}

  {hasAccess(role, ["admin", "pracownik", "instruktor"]) && (
    <Link
      href="/admin/calendar"
      className="rounded-xl border border-zinc-700 px-4 py-3 text-sm font-bold text-zinc-200 transition hover:border-green-700 hover:bg-green-950/30"
    >
      Kalendarz
    </Link>
  )}

  {hasAccess(role, ["admin"]) && (
    <Link
      href="/admin/users"
      className="rounded-xl border border-zinc-700 px-4 py-3 text-sm font-bold text-zinc-200 transition hover:border-green-700 hover:bg-green-950/30"
    >
      Użytkownicy
    </Link>
  )}

  {hasAccess(role, ["admin"]) && (
    <Link
      href="/admin/reports"
      className="rounded-xl border border-zinc-700 px-4 py-3 text-sm font-bold text-zinc-200 transition hover:border-green-700 hover:bg-green-950/30"
    >
      Raporty
    </Link>
  )}
                </div>
              </div>
            </div>

            <div>
              <div className="mb-4 flex flex-col gap-2 md:flex-row md:items-end md:justify-between">
                <div>
                  <h2 className="text-2xl font-bold">Moduły systemu</h2>
                  <p className="mt-2 text-sm text-zinc-500">
                    Zielone kafelki są dostępne dla Twojej roli. Czerwone
                    oznaczają brak dostępu.
                  </p>
                </div>

                <p className="text-sm text-zinc-500">
                  Dostępne moduły:{" "}
                  <span className="font-bold text-white">
                    {availableTilesCount}
                  </span>
                  /{adminTiles.length}
                </p>
              </div>

              <div className="grid gap-5 md:grid-cols-2 xl:grid-cols-3">
                {adminTiles.map((tile) => (
                  <AdminModuleTile
                    key={tile.href + tile.title}
                    tile={tile}
                    allowed={hasAccess(role, tile.roles)}
                  />
                ))}
              </div>
            </div>
          </>
        )}
      </section>
    </main>
  );
}
