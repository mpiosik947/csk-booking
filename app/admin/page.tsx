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
import AdminShell from "./_components/AdminShell";

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

type EventRegistrationSummary = {
  registration_status: string | null;
};

type EventSummary = {
  id: string;
  title: string;
  event_date: string | null;
  start_time: string | null;
  end_time: string | null;
  max_participants: number | null;
  is_active: boolean | null;
  event_registrations: EventRegistrationSummary[] | null;
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
    roles: ["admin", "pracownik"],
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
      return "border-[#3f6848] bg-[#1b2a1d] text-[#a9d4ad]";
    case "pracownik":
      return "border-[#806a32] bg-[#2b2618] text-[#e1c477]";
    case "instruktor":
      return "border-[#343a31] bg-[#171a17] text-[#d7c895]";
    default:
      return "border-[#343a31] bg-[#171a17] text-[#a9ada4]";
  }
}

function getPaymentStatusLabel(status: string | null) {
  if (isPaidPaymentStatus(status)) return "Opłacone";
  if (status === PAYMENT_STATUS.PAY_ON_SITE) return "Płatność na miejscu";
  if (status === PAYMENT_STATUS.UNPAID) return "Nieopłacone";
  return status || "Brak danych";
}

function formatDisplayDate(date: string | null) {
  if (!date) return "Brak daty";

  const [year, month, day] = date.split("-");

  if (!year || !month || !day) {
    return date;
  }

  return `${day}.${month}.${year}`;
}

function getEventRegistrations(event: EventSummary) {
  return Array.isArray(event.event_registrations)
    ? event.event_registrations
    : [];
}

function getEventParticipantsCount(event: EventSummary) {
  return getEventRegistrations(event).filter(
    (registration) =>
      registration.registration_status === "registered" ||
      registration.registration_status === "approved"
  ).length;
}

function getEventReserveCount(event: EventSummary) {
  return getEventRegistrations(event).filter(
    (registration) => registration.registration_status === "reserve"
  ).length;
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
  variant = "default",
}: {
  title: string;
  value: string | number;
  description?: string;
  href?: string;
  tone?: "default" | "green" | "yellow" | "red" | "blue";
  variant?: "default" | "alert";
}) {
  const valueClass =
    tone === "green"
      ? "text-[#a9d4ad]"
      : tone === "yellow"
      ? "text-[#e1c477]"
      : tone === "red"
      ? "text-[#e0a0a0]"
      : tone === "blue"
      ? "text-[#d7c895]"
      : "text-[#f2efe4]";

  const cardClass =
    variant === "alert" && tone === "red"
      ? "border-[#744545] bg-[#2a1b1b]"
      : variant === "alert" && tone === "yellow"
      ? "border-[#806a32] bg-[#2b2618]"
      : "border-[#30372c] bg-[#191e19]";

  const content = (
    <div
      className={`h-full min-h-12 rounded-2xl border p-5 transition hover:border-[#536143] ${cardClass}`}
    >
      <p className="text-sm text-[#a9ada4]">{title}</p>
      <p className={`mt-2 text-3xl font-bold ${valueClass}`}>{value}</p>
      {description && (
        <p className="mt-2 text-xs leading-5 text-[#858c7f]">{description}</p>
      )}
    </div>
  );

  if (href) {
    return (
      <Link
        href={href}
        className="block min-h-12 rounded-2xl focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
      >
        {content}
      </Link>
    );
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
      <div className="rounded-2xl border border-[#343a31] bg-[#171a17] p-6 text-[#858c7f]">
        <div className="mb-5 flex h-12 w-12 items-center justify-center rounded-xl border border-[#343a31] bg-[#141814] text-xl font-bold text-[#858c7f]">
          !
        </div>

        <div className="mb-3 inline-flex rounded-full border border-[#343a31] bg-[#141814] px-3 py-1 text-xs font-bold uppercase tracking-[0.2em] text-[#858c7f]">
          Brak dostępu
        </div>

        <h3 className="mb-2 text-xl font-bold text-[#a9ada4]">{tile.title}</h3>

        <p className="text-sm leading-6 text-[#858c7f]">{tile.description}</p>
      </div>
    );
  }

  return (
    <Link
      href={tile.href}
      className="group rounded-2xl border border-[#30372c] bg-[#191e19] p-6 transition hover:border-[#536143] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
    >
      <div className="mb-5 flex h-12 w-12 items-center justify-center rounded-xl border border-[#536143] bg-[#141814] text-xl font-bold text-[#d7c895] transition group-hover:border-[#78865f]">
        {tile.title.charAt(0)}
      </div>

      <div className="mb-3 inline-flex rounded-full border border-[#536143] bg-[#141814] px-3 py-1 text-xs font-bold uppercase tracking-[0.2em] text-[#d7c895]">
        Dostęp
      </div>

      <h3 className="mb-2 text-xl font-bold text-[#f2efe4]">{tile.title}</h3>

      <p className="text-sm leading-6 text-[#a9ada4]">{tile.description}</p>
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
  const [upcomingEvents, setUpcomingEvents] = useState<EventSummary[]>([]);

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
      upcomingEventsResult,
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

      supabase
        .from("events")
        .select(
          `
          id,
          title,
          event_date,
          start_time,
          end_time,
          max_participants,
          is_active,
          event_registrations (
            registration_status
          )
        `
        )
        .eq("is_active", true)
        .gte("event_date", today)
        .order("event_date", { ascending: true })
        .order("start_time", { ascending: true })
        .limit(4),
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

    if (upcomingEventsResult.error) {
      setMessage(
        `Błąd pobierania najbliższych szkoleń: ${upcomingEventsResult.error.message}`
      );
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
    setUpcomingEvents(
      (upcomingEventsResult.data ?? []) as unknown as EventSummary[]
    );

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

  const pendingCheckIns = activeTodayReservations.filter(
    (reservation) =>
      reservation.attendance_status === "planned" ||
      reservation.attendance_status === null
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
    .slice(0, 6);

  const nextReservation = upcomingReservations[0] ?? null;

  const paymentToCollectToday = payOnSiteToday.reduce(
    (sum, reservation) => sum + Number(reservation.price ?? 0),
    0
  );

  const unverifiedProfileIds = new Set(
    unverifiedUsers.map((profile) => profile.id)
  );

  const unverifiedTodayReservations = activeTodayReservations.filter(
    (reservation) =>
      reservation.user_id && unverifiedProfileIds.has(reservation.user_id)
  );

  const upcomingEventsWithReserve = upcomingEvents.filter(
    (eventItem) => getEventReserveCount(eventItem) > 0
  );

  const upcomingEventsReserveCount = upcomingEventsWithReserve.reduce(
    (sum, eventItem) => sum + getEventReserveCount(eventItem),
    0
  );

  return (
    <AdminShell
      eyebrow="CSK Booking"
      title="Dashboard operacyjny"
      description="Szybki podgląd dzisiejszych wizyt, alertów, płatności i najważniejszych danych operacyjnych strzelnicy."
      badge={
        !loading && role ? (
          <span
            className={`rounded-full border px-4 py-2 text-sm font-bold ${getRoleBadgeClass(
              role
            )}`}
          >
            {getRoleLabel(role)}
          </span>
        ) : undefined
      }
      actions={
        <>
          <button
            type="button"
            onClick={loadDashboard}
            disabled={loading}
            className="min-h-11 rounded-xl border border-[#536143] bg-[#536143] px-4 py-3 text-sm font-semibold text-[#f2efe4] transition hover:border-[#78865f] hover:bg-[#78865f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] disabled:cursor-not-allowed disabled:opacity-60"
          >
            {loading ? "Odświeżanie..." : "Odśwież"}
          </button>

          <Link
            href="/dashboard"
            className="inline-flex min-h-11 items-center justify-center rounded-xl border border-[#30372c] px-4 py-3 text-sm font-semibold text-[#a9ada4] transition hover:border-[#536143] hover:text-[#f2efe4] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
          >
            Wróć do konta
          </Link>
        </>
      }
    >
      {message && (
        <div className="mb-6 rounded-xl border border-[#744545] bg-[#2a1b1b] p-4 text-[#e0a0a0]">
          {message}
        </div>
      )}

        {loading ? (
          <div className="rounded-2xl border border-[#30372c] bg-[#191e19] p-8 text-[#a9ada4]">
            Ładowanie dashboardu...
          </div>
        ) : availableTilesCount === 0 ? (
          <div className="rounded-2xl border border-[#806a32] bg-[#2b2618] p-8 text-[#e1c477]">
            Brak dostępnych modułów dla tej roli.
          </div>
        ) : (
          <>
            <section>
              <h2 className="text-xl font-bold text-[#f2efe4] sm:text-2xl">
                Wymaga uwagi
              </h2>
              <p className="mt-1 text-sm text-[#a9ada4]">
                Najważniejsze sprawy operacyjne wymagające sprawdzenia.
              </p>

              <div className="mt-4 grid gap-4 md:grid-cols-2">
                <StatCard
                  title="Niezweryfikowani dziś"
                  value={unverifiedTodayReservations.length}
                  description="Klienci z dzisiejszą rezerwacją i niepełną weryfikacją."
                  href={hasAccess(role, ["admin", "pracownik"]) ? "/admin/users" : "/admin/check-in"}
                  tone={unverifiedTodayReservations.length > 0 ? "yellow" : "green"}
                  variant="alert"
                />

                <StatCard
                  title="Nieopłacone dziś"
                  value={unpaidToday.length}
                  description="Rezerwacje ze statusem nieopłacona."
                  href="/admin/check-in"
                  tone={unpaidToday.length > 0 ? "red" : "green"}
                  variant="alert"
                />

                <StatCard
                  title="Lista rezerwowa szkoleń"
                  value={upcomingEventsReserveCount}
                  description={
                    upcomingEventsWithReserve.length > 0
                      ? `${upcomingEventsWithReserve.length} najbliższe szkolenia z rezerwą.`
                      : "Brak rezerwy w najbliższych szkoleniach."
                  }
                  href="/admin/events"
                  tone={upcomingEventsReserveCount > 0 ? "yellow" : "green"}
                  variant="alert"
                />

                <StatCard
                  title="No-show dzisiaj"
                  value={noShowToday.length}
                  description="Klienci oznaczeni jako nieobecni."
                  href="/admin/check-in"
                  tone={noShowToday.length > 0 ? "red" : "green"}
                  variant="alert"
                />
              </div>
            </section>

            <section className="mt-8">
              <div className="flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
                <div>
                  <h2 className="text-xl font-bold text-[#f2efe4] sm:text-2xl">
                    Dzisiaj — najważniejsze
                  </h2>
                  <p className="mt-1 text-sm text-[#a9ada4]">
                    Operacyjny skrót dnia dla obsługi strzelnicy.
                  </p>
                </div>
                <p className="text-sm text-[#858c7f]">{today}</p>
              </div>

              <div className="mt-4 grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
                <StatCard
                  title="Rezerwacje dziś"
                  value={activeTodayReservations.length}
                  description="Aktywne rezerwacje bez anulowanych."
                  href="/admin/reservations"
                  tone="blue"
                />

                <StatCard
                  title="Najbliższy przyjazd"
                  value={
                    nextReservation
                      ? normalizeTime(nextReservation.start_time)
                      : "Brak"
                  }
                  description={
                    nextReservation
                      ? `${nextReservation.customer_name || "Klient"} · ${getLaneName(nextReservation)}`
                      : "Brak kolejnych rezerwacji na dziś."
                  }
                  href="/admin/check-in"
                  tone={nextReservation ? "yellow" : "green"}
                />

                <StatCard
                  title="Do check-in"
                  value={pendingCheckIns.length}
                  description="Wizyty zaplanowane, jeszcze nieobsłużone."
                  href="/admin/check-in"
                  tone={pendingCheckIns.length > 0 ? "yellow" : "green"}
                />

                <StatCard
                  title="Do pobrania"
                  value={`${paymentToCollectToday.toFixed(0)} zł`}
                  description={`${payOnSiteToday.length} wizyt z płatnością na miejscu.`}
                  href="/admin/check-in"
                  tone={payOnSiteToday.length > 0 ? "yellow" : "green"}
                />
              </div>
            </section>

            <section className="mt-8 rounded-2xl border border-[#30372c] bg-[#191e19] p-5 sm:p-6">
                <div className="mb-5 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
                  <div>
                    <h2 className="text-xl font-bold text-[#f2efe4] sm:text-2xl">
                      Najbliższe rezerwacje
                    </h2>
                    <p className="mt-1 text-sm text-[#a9ada4]">
                      Najważniejsza lista dla bieżącej obsługi recepcji.
                    </p>
                  </div>

                  <Link
                    href="/admin/check-in"
                    className="inline-flex min-h-11 items-center rounded-lg px-2 text-sm font-semibold text-[#d7c895] hover:text-[#f2efe4] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#191e19]"
                  >
                    Check-in →
                  </Link>
                </div>

                {upcomingReservations.length === 0 ? (
                  <div className="rounded-xl border border-[#30372c] bg-[#141814] p-5 text-[#a9ada4]">
                    Brak kolejnych rezerwacji na dziś.
                  </div>
                ) : (
                  <div className="max-w-full overflow-x-auto rounded-xl border border-[#30372c] bg-[#141814] px-4">
                    <table className="w-full min-w-[760px] text-left text-sm">
                      <thead>
                        <tr className="border-b border-[#30372c] text-[#a9ada4]">
                          <th className="py-3 pr-4">Godzina</th>
                          <th className="py-3 pr-4">Klient</th>
                          <th className="py-3 pr-4">Oś</th>
                          <th className="py-3 pr-4">Płatność</th>
                          <th className="py-3 pr-4">Akcja</th>
                        </tr>
                      </thead>

                      <tbody>
                        {upcomingReservations.map((reservation) => (
                          <tr
                            key={reservation.id}
                            className="border-b border-[#30372c] text-[#f2efe4] last:border-b-0"
                          >
                            <td className="py-4 pr-4 font-bold">
                              {normalizeTime(reservation.start_time)}–
                              {normalizeTime(reservation.end_time)}
                            </td>

                            <td className="py-4 pr-4">
                              <p className="font-semibold">
                                {reservation.customer_name || "Brak danych"}
                              </p>
                              <p className="text-xs text-[#858c7f]">
                                {reservation.customer_phone || "brak telefonu"}
                              </p>
                            </td>

                            <td className="py-4 pr-4">
                              {getLaneName(reservation)}
                            </td>

                            <td className="py-4 pr-4">
                              <span className="rounded-full border border-[#30372c] bg-[#191e19] px-3 py-1 text-xs font-semibold text-[#a9ada4]">
                                {getPaymentStatusLabel(reservation.payment_status)}
                              </span>
                            </td>

                            <td className="py-4 pr-4">
                              <Link
                                href="/admin/check-in"
                                className="inline-flex min-h-11 items-center rounded-lg border border-[#536143] bg-[#191e19] px-3 py-2 text-xs font-bold text-[#d7c895] transition hover:border-[#78865f] hover:text-[#f2efe4] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
                              >
                                Check-in
                              </Link>
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                )}
            </section>

            {hasAccess(role, ["admin", "pracownik", "instruktor"]) && (
              <section className="mt-8 rounded-2xl border border-[#30372c] bg-[#191e19] p-5 sm:p-6">
                <div className="mb-5 flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
                  <div>
                    <h2 className="text-xl font-bold text-[#f2efe4] sm:text-2xl">
                      Najbliższe szkolenia
                    </h2>
                    <p className="mt-1 text-sm text-[#a9ada4]">
                      Podgląd najbliższych wydarzeń, miejsc i listy rezerwowej.
                    </p>
                  </div>

                  <Link
                    href="/admin/events"
                    className="inline-flex min-h-11 items-center rounded-lg px-2 text-sm font-semibold text-[#d7c895] hover:text-[#f2efe4] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#191e19]"
                  >
                    Zarządzaj szkoleniami →
                  </Link>
                </div>

                {upcomingEvents.length === 0 ? (
                  <div className="rounded-xl border border-[#30372c] bg-[#141814] p-5 text-[#a9ada4]">
                    Brak zaplanowanych aktywnych szkoleń.
                  </div>
                ) : (
                  <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
                    {upcomingEvents.map((eventItem) => {
                      const participantsCount =
                        getEventParticipantsCount(eventItem);
                      const reserveCount = getEventReserveCount(eventItem);
                      const maxParticipants = Number(
                        eventItem.max_participants ?? 0
                      );
                      const isFull =
                        maxParticipants > 0 &&
                        participantsCount >= maxParticipants;

                      return (
                        <Link
                          key={eventItem.id}
                          href="/admin/events"
                          className="rounded-xl border border-[#30372c] bg-[#141814] p-5 transition hover:border-[#536143] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#191e19]"
                        >
                          <div className="mb-3 flex items-start justify-between gap-3">
                            <h3 className="min-w-0 break-words font-bold text-[#f2efe4]">
                              {eventItem.title}
                            </h3>

                            <span
                              className={
                                isFull
                                  ? "shrink-0 rounded-full border border-[#806a32] bg-[#2b2618] px-3 py-1 text-xs font-semibold text-[#e1c477]"
                                  : "shrink-0 rounded-full border border-[#3f6848] bg-[#1b2a1d] px-3 py-1 text-xs font-semibold text-[#a9d4ad]"
                              }
                            >
                              {isFull ? "Pełne" : "Aktywne"}
                            </span>
                          </div>

                          <p className="text-sm text-[#a9ada4]">
                            {formatDisplayDate(eventItem.event_date)} ·{" "}
                            {normalizeTime(eventItem.start_time)}–
                            {normalizeTime(eventItem.end_time)}
                          </p>

                          <div className="mt-4 grid gap-2 text-sm">
                            <div className="flex items-center justify-between rounded-lg border border-[#30372c] bg-[#191e19] px-3 py-2">
                              <span className="text-[#858c7f]">Uczestnicy</span>
                              <span className="font-bold text-[#f2efe4]">
                                {participantsCount} / {maxParticipants}
                              </span>
                            </div>

                            <div className="flex items-center justify-between rounded-lg border border-[#30372c] bg-[#191e19] px-3 py-2">
                              <span className="text-[#858c7f]">Rezerwa</span>
                              <span
                                className={
                                  reserveCount > 0
                                    ? "font-bold text-[#e1c477]"
                                    : "font-bold text-[#a9ada4]"
                                }
                              >
                                {reserveCount}
                              </span>
                            </div>
                          </div>
                        </Link>
                      );
                    })}
                  </div>
                )}
              </section>
            )}

            {hasAccess(role, ["admin"]) && (
              <section className="mt-8">
                <h2 className="text-xl font-bold text-[#f2efe4] sm:text-2xl">
                  Biznes
                </h2>

                <div className="mt-4 grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
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
              </section>
            )}

            <section className="mt-8">
              <div className="mb-4 flex flex-col gap-2 md:flex-row md:items-end md:justify-between">
                <div>
                  <h2 className="text-xl font-bold text-[#f2efe4] sm:text-2xl">
                    Moduły administracyjne
                  </h2>
                  <p className="mt-2 text-sm text-[#a9ada4]">
                    Kafelki są dostępne zgodnie z uprawnieniami Twojej roli.
                  </p>
                </div>

                <p className="text-sm text-[#858c7f]">
                  Dostępne moduły:{" "}
                  <span className="font-bold text-[#f2efe4]">
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
            </section>
          </>
        )}
    </AdminShell>
  );
}
