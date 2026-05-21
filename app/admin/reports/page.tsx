"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../../lib/supabase";

const ADMIN_EMAIL = "m.piosik94@gmail.com";

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

export default function AdminReportsPage() {
  const today = new Date().toISOString().slice(0, 10);

  const [selectedDate, setSelectedDate] = useState(today);
  const [reservations, setReservations] = useState<Reservation[]>([]);
  const [lanesCount, setLanesCount] = useState(0);
  const [loading, setLoading] = useState(true);
  const [isAdmin, setIsAdmin] = useState(false);
  const [message, setMessage] = useState("");

  useEffect(() => {
    loadReport();
  }, [selectedDate]);

  async function loadReport() {
    setLoading(true);
    setMessage("");

    const {
      data: { user },
    } = await supabase.auth.getUser();

    if (!user) {
      setMessage("Musisz być zalogowany jako administrator.");
      setLoading(false);
      return;
    }

    if (user.email !== ADMIN_EMAIL) {
      setMessage("Brak dostępu do raportów administratora.");
      setLoading(false);
      return;
    }

    setIsAdmin(true);

    const { data: lanesData } = await supabase
      .from("shooting_lanes")
      .select("id")
      .eq("is_active", true);

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
      .eq("reservation_date", selectedDate)
      .order("start_time", { ascending: true });

    if (error) {
      setMessage(`Błąd pobierania raportu: ${error.message}`);
      setLoading(false);
      return;
    }

    setLanesCount((lanesData ?? []).length);
    setReservations((data as any) ?? []);
    setLoading(false);
  }

  const activeReservations = reservations.filter(
    (reservation) =>
      reservation.reservation_status !== "cancelled" &&
      reservation.reservation_status !== "no_show"
  );

  const paidReservations = reservations.filter(
    (reservation) => reservation.payment_status === "paid_on_site"
  );

  const totalRevenue = activeReservations.reduce(
    (sum, reservation) => sum + Number(reservation.price ?? 0),
    0
  );

  const paidRevenue = paidReservations.reduce(
    (sum, reservation) => sum + Number(reservation.price ?? 0),
    0
  );

  const totalReservedMinutes = activeReservations.reduce(
    (sum, reservation) => sum + Number(reservation.duration_minutes ?? 0),
    0
  );

  const openMinutesPerLane = 12 * 60;
  const totalAvailableMinutes = lanesCount * openMinutesPerLane;

  const occupancy =
    totalAvailableMinutes > 0
      ? Math.round((totalReservedMinutes / totalAvailableMinutes) * 100)
      : 0;

  return (
    <main className="min-h-screen bg-zinc-950 text-white">
      <section className="mx-auto max-w-7xl px-6 py-12">
        <div className="mb-8">
          <p className="mb-4 text-sm uppercase tracking-[0.35em] text-green-500">
            ADMIN PANEL
          </p>

          <h1 className="text-4xl font-bold">Raport dzienny</h1>

          <p className="mt-3 text-zinc-400">
            Rezerwacje, przychód i szacowane obłożenie osi.
          </p>
        </div>

        <div className="mb-8 rounded-2xl border border-zinc-800 bg-zinc-900 p-6">
          <label className="mb-2 block text-sm text-zinc-300">
            Wybierz dzień raportu
          </label>

          <input
            type="date"
            value={selectedDate}
            onChange={(event) => setSelectedDate(event.target.value)}
            className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600 md:max-w-xs"
          />
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

        {!loading && isAdmin && (
          <>
            <div className="mb-8 grid gap-4 md:grid-cols-4">
              <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
                <p className="text-sm text-zinc-400">Rezerwacje</p>
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

            <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6">
              <h2 className="mb-5 text-2xl font-bold">Rezerwacje dnia</h2>

              {reservations.length === 0 ? (
                <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-6 text-zinc-400">
                  Brak rezerwacji w tym dniu.
                </div>
              ) : (
                <div className="overflow-x-auto">
                  <table className="w-full min-w-[900px] text-left text-sm">
                    <thead>
                      <tr className="border-b border-zinc-800 text-zinc-400">
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
                            {reservation.reservation_status}
                          </td>

                          <td className="py-4 pr-4">
                            {reservation.payment_status}
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