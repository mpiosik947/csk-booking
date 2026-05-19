"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";
import AdminReservationsTable from "./AdminReservationsTable";

const ADMIN_EMAIL = "m.piosik94@gmail.com";

type Reservation = {
  id: string;
  customer_name: string;
  customer_email: string;
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

export default function AdminPage() {
  const [reservations, setReservations] = useState<Reservation[]>([]);
  const [eventsCount, setEventsCount] = useState(0);
  const [registrationsCount, setRegistrationsCount] = useState(0);
  const [loading, setLoading] = useState(true);
  const [isAdmin, setIsAdmin] = useState(false);
  const [message, setMessage] = useState("");

  useEffect(() => {
    async function loadAdminPanel() {
      const {
        data: { user },
      } = await supabase.auth.getUser();

      if (!user) {
        setMessage("Musisz być zalogowany, aby wejść do panelu administratora.");
        setLoading(false);
        return;
      }

      if (user.email !== ADMIN_EMAIL) {
        setMessage("Brak dostępu. To konto nie ma uprawnień administratora.");
        setLoading(false);
        return;
      }

      setIsAdmin(true);

      const { data: reservationsData, error: reservationsError } = await supabase
        .from("reservations")
        .select(
          `
          id,
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
          shooting_lanes (
            name
          )
        `
        )
        .order("reservation_date", { ascending: true })
        .order("start_time", { ascending: true });

      if (reservationsError) {
        setMessage(`Błąd pobierania rezerwacji: ${reservationsError.message}`);
        setLoading(false);
        return;
      }

      const { count: eventsTotal } = await supabase
        .from("events")
        .select("*", { count: "exact", head: true });

      const { count: registrationsTotal } = await supabase
        .from("event_registrations")
        .select("*", { count: "exact", head: true });

      setReservations((reservationsData as any) ?? []);
      setEventsCount(eventsTotal ?? 0);
      setRegistrationsCount(registrationsTotal ?? 0);
      setLoading(false);
    }

    loadAdminPanel();
  }, []);

  const today = new Date().toISOString().slice(0, 10);

  const todayReservations = reservations.filter(
    (reservation) => reservation.reservation_date === today
  );

  const confirmedReservations = reservations.filter(
    (reservation) => reservation.reservation_status === "confirmed"
  );

  const noShowReservations = reservations.filter(
    (reservation) => reservation.reservation_status === "no_show"
  );

  return (
    <main className="min-h-screen bg-zinc-950 text-white">
      <section className="mx-auto max-w-7xl px-6 py-10">
        <div className="mb-8 flex flex-col gap-4 md:flex-row md:items-end md:justify-between">
          <div>
            <p className="mb-4 text-sm uppercase tracking-[0.35em] text-green-500">
              CSK Booking
            </p>

            <h1 className="text-3xl font-bold">Panel administratora</h1>

            <p className="mt-2 text-zinc-400">
              Zarządzanie rezerwacjami, płatnościami, eventami i szkoleniami.
            </p>
          </div>

          <a
            href="/"
            className="rounded-xl border border-zinc-700 px-4 py-3 text-sm font-semibold transition hover:bg-zinc-900"
          >
            ← Strona główna
          </a>
        </div>

        {loading && (
          <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-zinc-400">
            Ładowanie panelu administratora...
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
                <p className="text-sm text-zinc-400">Dzisiejsze rezerwacje</p>
                <p className="mt-2 text-3xl font-bold">
                  {todayReservations.length}
                </p>
              </div>

              <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
                <p className="text-sm text-zinc-400">Wszystkie rezerwacje</p>
                <p className="mt-2 text-3xl font-bold">
                  {reservations.length}
                </p>
              </div>

              <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
                <p className="text-sm text-zinc-400">Potwierdzone</p>
                <p className="mt-2 text-3xl font-bold">
                  {confirmedReservations.length}
                </p>
              </div>

              <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
                <p className="text-sm text-zinc-400">Nieobecności</p>
                <p className="mt-2 text-3xl font-bold">
                  {noShowReservations.length}
                </p>
              </div>
            </div>

            <div className="mb-8 grid gap-5 md:grid-cols-2">
              <a
                href="/admin/events"
                className="rounded-2xl border border-green-800 bg-green-950 p-6 transition hover:bg-green-900"
              >
                <h2 className="mb-2 text-2xl font-bold text-green-300">
                  Eventy / Szkolenia
                </h2>

                <p className="mb-5 text-green-100">
                  Dodawaj szkolenia, sprawdzaj listę chętnych i zarządzaj
                  zapisami uczestników.
                </p>

                <div className="grid gap-3 sm:grid-cols-2">
                  <div className="rounded-xl border border-green-800 bg-zinc-950 p-4">
                    <p className="text-sm text-zinc-400">Liczba szkoleń</p>
                    <p className="mt-1 text-3xl font-bold text-green-400">
                      {eventsCount}
                    </p>
                  </div>

                  <div className="rounded-xl border border-green-800 bg-zinc-950 p-4">
                    <p className="text-sm text-zinc-400">Zapisane osoby</p>
                    <p className="mt-1 text-3xl font-bold text-green-400">
                      {registrationsCount}
                    </p>
                  </div>
                </div>
              </a>

              <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6">
                <h2 className="mb-2 text-2xl font-bold">
                  Rezerwacje osi
                </h2>

                <p className="mb-5 text-zinc-400">
                  Podgląd wszystkich rezerwacji osi, płatności oraz statusów
                  klientów.
                </p>

                <div className="grid gap-3 sm:grid-cols-2">
                  <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                    <p className="text-sm text-zinc-400">Aktywne</p>
                    <p className="mt-1 text-3xl font-bold">
                      {confirmedReservations.length}
                    </p>
                  </div>

                  <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                    <p className="text-sm text-zinc-400">Dzisiaj</p>
                    <p className="mt-1 text-3xl font-bold">
                      {todayReservations.length}
                    </p>
                  </div>
                </div>
              </div>
            </div>

            <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6">
              <h2 className="mb-4 text-xl font-semibold">Rezerwacje</h2>

              <AdminReservationsTable reservations={reservations} />
            </div>
          </>
        )}
      </section>
    </main>
  );
}