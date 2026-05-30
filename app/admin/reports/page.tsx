"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../../lib/supabase";

type ReportMode = "day" | "week" | "month" | "year";

type Reservation = {
  id: string;
  customer_name: string;
  customer_phone: string;
  reservation_date: string;
  start_time: string;
  end_time: string;
  duration_minutes: number;
  price: number;
  reservation_status: string;
  payment_status: string;
  shooting_lanes: {
    name: string;
  } | null;
};

function addDays(date: Date, days: number) {
  const copy = new Date(date);
  copy.setDate(copy.getDate() + days);
  return copy;
}

function formatDateInput(date: Date) {
  return date.toISOString().slice(0, 10);
}

function getDateRange(mode: ReportMode, selectedDate: string) {
  const start = new Date(`${selectedDate}T12:00:00`);

  if (mode === "day") {
    return {
      startDate: formatDateInput(start),
      endDate: formatDateInput(start),
      label: selectedDate,
    };
  }

  if (mode === "week") {
    const day = start.getDay();
    const diffToMonday = day === 0 ? -6 : 1 - day;
    const monday = addDays(start, diffToMonday);
    const sunday = addDays(monday, 6);

    return {
      startDate: formatDateInput(monday),
      endDate: formatDateInput(sunday),
      label: `${formatDateInput(monday)} – ${formatDateInput(sunday)}`,
    };
  }

  if (mode === "month") {
    const firstDay = new Date(start.getFullYear(), start.getMonth(), 1, 12);
    const lastDay = new Date(start.getFullYear(), start.getMonth() + 1, 0, 12);

    return {
      startDate: formatDateInput(firstDay),
      endDate: formatDateInput(lastDay),
      label: `${String(start.getMonth() + 1).padStart(2, "0")}.${start.getFullYear()}`,
    };
  }

  const firstDay = new Date(start.getFullYear(), 0, 1, 12);
  const lastDay = new Date(start.getFullYear(), 11, 31, 12);

  return {
    startDate: formatDateInput(firstDay),
    endDate: formatDateInput(lastDay),
    label: `${start.getFullYear()}`,
  };
}

function translateStatus(status: string) {
  if (status === "confirmed") return "Potwierdzona";
  if (status === "cancelled") return "Anulowana";
  if (status === "cancelled_by_admin") return "Anulowana przez admina";
  if (status === "cancelled_by_user") return "Anulowana przez użytkownika";
  if (status === "completed") return "Zrealizowana";
  if (status === "no_show") return "Nieobecny";
  return status;
}

function translatePayment(status: string) {
  if (status === "pay_on_site") return "Płatność na miejscu";
  if (status === "paid_on_site") return "Opłacone";
  if (status === "paid") return "Opłacone";
  if (status === "unpaid") return "Nieopłacone";
  if (status === "voucher") return "Voucher";
  if (status === "free") return "Darmowe";
  return status;
}

function isCancelled(status: string) {
  return (
    status === "cancelled" ||
    status === "canceled" ||
    status === "cancelled_by_admin" ||
    status === "cancelled_by_user"
  );
}

function isPaid(status: string) {
  return status === "paid" || status === "paid_on_site";
}

export default function AdminReportsPage() {
  const today = new Date().toISOString().slice(0, 10);

  const [reportMode, setReportMode] = useState<ReportMode>("day");
  const [selectedDate, setSelectedDate] = useState(today);
  const [reservations, setReservations] = useState<Reservation[]>([]);
  const [lanesCount, setLanesCount] = useState(0);
  const [loading, setLoading] = useState(true);
  const [hasAccess, setHasAccess] = useState(false);
  const [message, setMessage] = useState("");

  const range = getDateRange(reportMode, selectedDate);

  useEffect(() => {
    loadReport();
  }, [selectedDate, reportMode]);

  async function loadReport() {
    setLoading(true);
    setMessage("");
    setHasAccess(false);

    const {
      data: { user },
    } = await supabase.auth.getUser();

    if (!user) {
      setMessage("Musisz być zalogowany jako administrator.");
      setLoading(false);
      return;
    }

    const { data: roleData, error: roleError } = await supabase.rpc(
      "get_my_role"
    );

    if (roleError) {
      setMessage(`Błąd sprawdzania roli: ${roleError.message}`);
      setLoading(false);
      return;
    }

    if (roleData !== "admin") {
      setMessage("Brak dostępu do raportów administratora.");
      setLoading(false);
      return;
    }

    setHasAccess(true);

    const { data: lanesData, error: lanesError } = await supabase
      .from("shooting_lanes")
      .select("id")
      .eq("is_active", true);

    if (lanesError) {
      setMessage(`Błąd pobierania osi: ${lanesError.message}`);
      setLoading(false);
      return;
    }

    const { data, error } = await supabase
      .from("reservations")
      .select(
        `
        id,
        customer_name,
        customer_phone,
        reservation_date,
        start_time,
        end_time,
        duration_minutes,
        price,
        reservation_status,
        payment_status,
        shooting_lanes (
          name
        )
      `
      )
      .gte("reservation_date", range.startDate)
      .lte("reservation_date", range.endDate)
      .order("reservation_date", { ascending: true })
      .order("start_time", { ascending: true });

    if (error) {
      setMessage(`Błąd pobierania raportu: ${error.message}`);
      setLoading(false);
      return;
    }

    setLanesCount((lanesData ?? []).length);
    setReservations((data as unknown as Reservation[]) ?? []);
    setLoading(false);
  }

  const activeReservations = reservations.filter(
    (reservation) =>
      !isCancelled(reservation.reservation_status) &&
      reservation.reservation_status !== "no_show"
  );

  const paidReservations = activeReservations.filter((reservation) =>
    isPaid(reservation.payment_status)
  );

  const cancelledReservations = reservations.filter((reservation) =>
    isCancelled(reservation.reservation_status)
  );

  const noShowReservations = reservations.filter(
    (reservation) => reservation.reservation_status === "no_show"
  );

  const totalRevenue = activeReservations.reduce(
    (sum, reservation) => sum + Number(reservation.price ?? 0),
    0
  );

  const paidRevenue = paidReservations.reduce(
    (sum, reservation) => sum + Number(reservation.price ?? 0),
    0
  );

  const unpaidRevenue = activeReservations
    .filter((reservation) => !isPaid(reservation.payment_status))
    .reduce((sum, reservation) => sum + Number(reservation.price ?? 0), 0);

  const totalReservedMinutes = activeReservations.reduce(
    (sum, reservation) => sum + Number(reservation.duration_minutes ?? 0),
    0
  );

  const daysInRange =
    (new Date(`${range.endDate}T12:00:00`).getTime() -
      new Date(`${range.startDate}T12:00:00`).getTime()) /
      (1000 * 60 * 60 * 24) +
    1;

  const openMinutesPerLanePerDay = 16 * 60;
  const totalAvailableMinutes =
    lanesCount * openMinutesPerLanePerDay * daysInRange;

  const occupancy =
    totalAvailableMinutes > 0
      ? Math.round((totalReservedMinutes / totalAvailableMinutes) * 100)
      : 0;

  const bestDay = Object.entries(
    activeReservations.reduce<Record<string, number>>((acc, reservation) => {
      acc[reservation.reservation_date] =
        (acc[reservation.reservation_date] ?? 0) +
        Number(reservation.price ?? 0);
      return acc;
    }, {})
  ).sort((a, b) => b[1] - a[1])[0];

  const topLane = Object.entries(
    activeReservations.reduce<Record<string, number>>((acc, reservation) => {
      const laneName = reservation.shooting_lanes?.name ?? "Brak osi";
      acc[laneName] = (acc[laneName] ?? 0) + 1;
      return acc;
    }, {})
  ).sort((a, b) => b[1] - a[1])[0];

  return (
    <main className="min-h-screen bg-zinc-950 text-white">
      <section className="mx-auto max-w-7xl px-6 py-12">
        <div className="mb-8">
          <p className="mb-4 text-sm uppercase tracking-[0.35em] text-green-500">
            ADMIN PANEL
          </p>

          <h1 className="text-4xl font-bold">Raport</h1>

          <p className="mt-3 text-zinc-400">
            Rezerwacje, przychód i szacowane obłożenie osi.
          </p>
        </div>

        <div className="mb-8 grid gap-5 rounded-2xl border border-zinc-800 bg-zinc-900 p-6 md:grid-cols-2">
          <div>
            <label className="mb-2 block text-sm text-zinc-300">
              Zakres raportu
            </label>

            <select
              value={reportMode}
              onChange={(event) =>
                setReportMode(event.target.value as ReportMode)
              }
              className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
            >
              <option value="day">Dzień</option>
              <option value="week">Tydzień</option>
              <option value="month">Miesiąc</option>
              <option value="year">Rok</option>
            </select>
          </div>

          <div>
            <label className="mb-2 block text-sm text-zinc-300">
              Data odniesienia
            </label>

            <input
              type="date"
              value={selectedDate}
              onChange={(event) => setSelectedDate(event.target.value)}
              className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
            />
          </div>

          <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4 text-sm text-zinc-300 md:col-span-2">
            Zakres:{" "}
            <span className="font-semibold text-green-500">
              {range.startDate} – {range.endDate}
            </span>
          </div>
        </div>

        {loading && (
          <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-zinc-400">
            Ładowanie raportu...
          </div>
        )}

        {!loading && message && (
          <div className="rounded-xl border border-red-800 bg-red-950 p-4 text-sm font-semibold text-red-300">
            {message}
          </div>
        )}

        {!loading && hasAccess && (
          <>
            <div className="mb-8 grid gap-4 md:grid-cols-4">
              <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
                <p className="text-sm text-zinc-400">Rezerwacje aktywne</p>
                <p className="mt-2 text-3xl font-bold">
                  {activeReservations.length}
                </p>
              </div>

              <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
                <p className="text-sm text-zinc-400">Przychód planowany</p>
                <p className="mt-2 text-3xl font-bold text-green-500">
                  {totalRevenue.toFixed(0)} zł
                </p>
              </div>

              <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
                <p className="text-sm text-zinc-400">Przychód opłacony</p>
                <p className="mt-2 text-3xl font-bold text-green-500">
                  {paidRevenue.toFixed(0)} zł
                </p>
              </div>

              <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
                <p className="text-sm text-zinc-400">Obłożenie osi</p>
                <p className="mt-2 text-3xl font-bold text-yellow-300">
                  {occupancy}%
                </p>
              </div>
            </div>

            <div className="mb-8 grid gap-4 md:grid-cols-4">
              <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
                <p className="text-sm text-zinc-400">Nieopłacone / na miejscu</p>
                <p className="mt-2 text-3xl font-bold text-yellow-300">
                  {unpaidRevenue.toFixed(0)} zł
                </p>
              </div>

              <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
                <p className="text-sm text-zinc-400">Anulowane</p>
                <p className="mt-2 text-3xl font-bold text-red-300">
                  {cancelledReservations.length}
                </p>
              </div>

              <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
                <p className="text-sm text-zinc-400">Nieobecności</p>
                <p className="mt-2 text-3xl font-bold text-yellow-300">
                  {noShowReservations.length}
                </p>
              </div>

              <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
                <p className="text-sm text-zinc-400">Najczęściej używana oś</p>
                <p className="mt-2 text-xl font-bold">
                  {topLane ? `${topLane[0]} / ${topLane[1]} rez.` : "Brak"}
                </p>
              </div>
            </div>

            <div className="mb-8 grid gap-4 md:grid-cols-2">
              <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
                <p className="text-sm text-zinc-400">Najlepszy dzień</p>
                <p className="mt-2 text-xl font-bold">
                  {bestDay
                    ? `${bestDay[0]} / ${bestDay[1].toFixed(0)} zł`
                    : "Brak"}
                </p>
              </div>

              <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
                <p className="text-sm text-zinc-400">Założenie obłożenia</p>
                <p className="mt-2 text-xl font-bold">
                  {lanesCount} osi × 16h dziennie × {daysInRange} dni
                </p>
              </div>
            </div>

            <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6">
              <h2 className="mb-5 text-2xl font-bold">Rezerwacje w okresie</h2>

              {reservations.length === 0 ? (
                <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-6 text-zinc-400">
                  Brak rezerwacji w wybranym okresie.
                </div>
              ) : (
                <div className="overflow-x-auto">
                  <table className="w-full min-w-[1000px] text-left text-sm">
                    <thead>
                      <tr className="border-b border-zinc-800 text-zinc-400">
                        <th className="py-3 pr-4">Data</th>
                        <th className="py-3 pr-4">Godzina</th>
                        <th className="py-3 pr-4">Oś</th>
                        <th className="py-3 pr-4">Klient</th>
                        <th className="py-3 pr-4">Telefon</th>
                        <th className="py-3 pr-4">Cena</th>
                        <th className="py-3 pr-4">Status</th>
                        <th className="py-3 pr-4">Płatność</th>
                      </tr>
                    </thead>

                    <tbody>
                      {reservations.map((reservation) => (
                        <tr
                          key={reservation.id}
                          className="border-b border-zinc-800"
                        >
                          <td className="py-4 pr-4">
                            {reservation.reservation_date}
                          </td>

                          <td className="py-4 pr-4 font-semibold">
                            {reservation.start_time.slice(0, 5)}–
                            {reservation.end_time.slice(0, 5)}
                          </td>

                          <td className="py-4 pr-4">
                            {reservation.shooting_lanes?.name ?? "Brak osi"}
                          </td>

                          <td className="py-4 pr-4 font-semibold">
                            {reservation.customer_name}
                          </td>

                          <td className="py-4 pr-4">
                            {reservation.customer_phone}
                          </td>

                          <td className="py-4 pr-4 text-green-500">
                            {Number(reservation.price).toFixed(0)} zł
                          </td>

                          <td className="py-4 pr-4">
                            {translateStatus(reservation.reservation_status)}
                          </td>

                          <td className="py-4 pr-4">
                            {translatePayment(reservation.payment_status)}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </div>

            <div className="mt-8">
              <a
                href="/admin"
                className="rounded-xl border border-zinc-700 px-5 py-3 text-sm font-semibold text-zinc-300 transition hover:bg-zinc-900"
              >
                ← Panel administratora
              </a>
            </div>
          </>
        )}
      </section>
    </main>
  );
}