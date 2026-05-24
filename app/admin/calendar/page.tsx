"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../../lib/supabase";

const ADMIN_EMAIL = "m.piosik94@gmail.com";

type CalendarMode = "day" | "week";

type Lane = {
  id: string;
  name: string;
};

type Reservation = {
  id: string;
  customer_name: string;
  customer_phone: string;
  reservation_date: string;
  start_time: string;
  end_time: string;
  reservation_status: string;
  shooting_lanes: {
    name: string;
  } | null;
};

const hours = [
  "08:00",
  "09:00",
  "10:00",
  "11:00",
  "12:00",
  "13:00",
  "14:00",
  "15:00",
  "16:00",
  "17:00",
  "18:00",
  "19:00",
];

function addDays(date: Date, days: number) {
  const copy = new Date(date);
  copy.setDate(copy.getDate() + days);
  return copy;
}

function formatDateInput(date: Date) {
  return date.toISOString().slice(0, 10);
}

function getWeekDates(selectedDate: string) {
  const base = new Date(`${selectedDate}T12:00:00`);
  const day = base.getDay();
  const diffToMonday = day === 0 ? -6 : 1 - day;
  const monday = addDays(base, diffToMonday);

  return Array.from({ length: 7 }, (_, index) =>
    formatDateInput(addDays(monday, index))
  );
}

function formatShortDate(dateString: string) {
  const date = new Date(`${dateString}T12:00:00`);

  return new Intl.DateTimeFormat("pl-PL", {
    weekday: "short",
    day: "2-digit",
    month: "2-digit",
  }).format(date);
}

function timeToMinutes(time: string) {
  const [hour, minutes] = time.slice(0, 5).split(":").map(Number);
  return hour * 60 + minutes;
}

function reservationCoversHour(reservation: Reservation, hour: string) {
  const hourStart = timeToMinutes(hour);
  const hourEnd = hourStart + 60;

  const reservationStart = timeToMinutes(reservation.start_time);
  const reservationEnd = timeToMinutes(reservation.end_time);

  return reservationStart < hourEnd && reservationEnd > hourStart;
}

export default function AdminCalendarPage() {
  const today = new Date().toISOString().slice(0, 10);

  const [mode, setMode] = useState<CalendarMode>("day");
  const [selectedDate, setSelectedDate] = useState(today);
  const [lanes, setLanes] = useState<Lane[]>([]);
  const [reservations, setReservations] = useState<Reservation[]>([]);
  const [loading, setLoading] = useState(true);
  const [isAdmin, setIsAdmin] = useState(false);
  const [message, setMessage] = useState("");

  const visibleDates = mode === "day" ? [selectedDate] : getWeekDates(selectedDate);

  useEffect(() => {
    loadCalendar();
  }, [selectedDate, mode]);

  async function loadCalendar() {
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
      setMessage("Brak dostępu do kalendarza administratora.");
      setLoading(false);
      return;
    }

    setIsAdmin(true);

    const dates = mode === "day" ? [selectedDate] : getWeekDates(selectedDate);

    const { data: lanesData } = await supabase
      .from("shooting_lanes")
      .select("id, name")
      .eq("is_active", true)
      .order("name");

    const { data: reservationsData, error } = await supabase
      .from("reservations")
      .select(
        `
        id,
        customer_name,
        customer_phone,
        reservation_date,
        start_time,
        end_time,
        reservation_status,
        shooting_lanes (
          name
        )
      `
      )
      .gte("reservation_date", dates[0])
      .lte("reservation_date", dates[dates.length - 1])
      .neq("reservation_status", "cancelled")
      .order("reservation_date", { ascending: true })
      .order("start_time", { ascending: true });

    if (error) {
      setMessage(`Błąd pobierania kalendarza: ${error.message}`);
      setLoading(false);
      return;
    }

    setLanes((lanesData as any) ?? []);
    setReservations((reservationsData as any) ?? []);
    setLoading(false);
  }

  function getReservationsForSlot(date: string, laneName: string, hour: string) {
    return reservations.filter(
      (reservation) =>
        reservation.reservation_date === date &&
        reservation.shooting_lanes?.name === laneName &&
        reservationCoversHour(reservation, hour)
    );
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-white">
      <section className="mx-auto max-w-7xl px-4 py-10 sm:px-6">
        <div className="mb-8">
          <p className="mb-4 text-sm uppercase tracking-[0.35em] text-green-500">
            ADMIN PANEL
          </p>

          <h1 className="text-4xl font-bold">Kalendarz administratora</h1>

          <p className="mt-3 text-zinc-400">
            Widok rezerwacji osi w układzie dnia albo tygodnia.
          </p>
        </div>

        <div className="mb-8 grid gap-5 rounded-2xl border border-zinc-800 bg-zinc-900 p-6 md:grid-cols-2">
          <div>
            <label className="mb-2 block text-sm text-zinc-300">Widok</label>

            <select
              value={mode}
              onChange={(event) => setMode(event.target.value as CalendarMode)}
              className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white outline-none focus:border-green-600"
            >
              <option value="day">Dzień</option>
              <option value="week">Tydzień</option>
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
        </div>

        {loading && (
          <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-zinc-400">
            Ładowanie kalendarza...
          </div>
        )}

        {!loading && message && (
          <div className="rounded-xl border border-red-800 bg-red-950 p-4 text-sm font-semibold text-red-300">
            {message}
          </div>
        )}

        {!loading && isAdmin && (
          <>
            {mode === "day" && (
              <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
                <h2 className="mb-5 text-2xl font-bold">
                  {formatShortDate(selectedDate)}
                </h2>

                <div className="overflow-x-auto">
                  <table className="w-full min-w-[900px] border-collapse text-left text-sm">
                    <thead>
                      <tr className="border-b border-zinc-800 text-zinc-400">
                        <th className="py-3 pr-4">Godzina</th>
                        {lanes.map((lane) => (
                          <th key={lane.id} className="py-3 pr-4">
                            {lane.name}
                          </th>
                        ))}
                      </tr>
                    </thead>

                    <tbody>
                      {hours.map((hour) => (
                        <tr key={hour} className="border-b border-zinc-800">
                          <td className="py-4 pr-4 font-semibold text-zinc-300">
                            {hour}
                          </td>

                          {lanes.map((lane) => {
                            const slotReservations = getReservationsForSlot(
                              selectedDate,
                              lane.name,
                              hour
                            );

                            return (
                              <td key={lane.id} className="py-3 pr-4 align-top">
                                {slotReservations.length === 0 ? (
                                  <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-3 text-xs text-zinc-600">
                                    Wolne
                                  </div>
                                ) : (
                                  <div className="grid gap-2">
                                    {slotReservations.map((reservation) => (
                                      <div
                                        key={`${reservation.id}-${hour}`}
                                        className="rounded-xl border border-green-800 bg-green-950 p-3 text-xs text-green-100"
                                      >
                                        <p className="font-bold text-green-300">
                                          {reservation.start_time.slice(0, 5)}–
                                          {reservation.end_time.slice(0, 5)}
                                        </p>
                                        <p>{reservation.customer_name}</p>
                                        <p className="text-green-400">
                                          {reservation.customer_phone}
                                        </p>
                                      </div>
                                    ))}
                                  </div>
                                )}
                              </td>
                            );
                          })}
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
            )}

            {mode === "week" && (
              <div className="grid gap-5">
                {visibleDates.map((date) => {
                  const dayReservations = reservations.filter(
                    (reservation) => reservation.reservation_date === date
                  );

                  return (
                    <div
                      key={date}
                      className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5"
                    >
                      <div className="mb-4 flex items-center justify-between gap-3">
                        <h2 className="text-2xl font-bold">
                          {formatShortDate(date)}
                        </h2>

                        <span className="rounded-full bg-green-950 px-3 py-1 text-xs font-semibold text-green-400">
                          {dayReservations.length} rezerwacje
                        </span>
                      </div>

                      {dayReservations.length === 0 ? (
                        <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4 text-sm text-zinc-500">
                          Brak rezerwacji.
                        </div>
                      ) : (
                        <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
                          {dayReservations.map((reservation) => (
                            <div
                              key={reservation.id}
                              className="rounded-xl border border-green-800 bg-green-950 p-4"
                            >
                              <p className="font-bold text-green-300">
                                {reservation.start_time.slice(0, 5)}–
                                {reservation.end_time.slice(0, 5)}
                              </p>

                              <p className="mt-1 text-white">
                                {reservation.shooting_lanes?.name ?? "Brak osi"}
                              </p>

                              <p className="mt-2 text-sm text-green-100">
                                {reservation.customer_name}
                              </p>

                              <p className="text-sm text-green-400">
                                {reservation.customer_phone}
                              </p>
                            </div>
                          ))}
                        </div>
                      )}
                    </div>
                  );
                })}
              </div>
            )}

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