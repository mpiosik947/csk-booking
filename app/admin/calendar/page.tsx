"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../../lib/supabase";

type CalendarMode = "day" | "week";
type UserRole = "admin" | "pracownik" | "instruktor" | "user";

type Lane = {
  id: string;
  name: string;
};

type Reservation = {
  id: string;
  customer_name: string | null;
  customer_phone: string | null;
  reservation_date: string;
  start_time: string;
  end_time: string;
  reservation_status: string | null;
  shooting_lanes:
    | {
        name: string | null;
      }[]
    | null;
};

type LaneBlock = {
  id: string;
  lane_id: string;
  block_date: string;
  start_time: string;
  end_time: string;
  reason: string | null;
  is_active: boolean;
};

type EventItem = {
  id: string;
  title: string;
  event_date: string;
  start_time: string;
  end_time: string;
  location: string | null;
  is_active: boolean | null;
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

function rangeCoversHour(startTime: string, endTime: string, hour: string) {
  const hourStart = timeToMinutes(hour);
  const hourEnd = hourStart + 60;

  const start = timeToMinutes(startTime);
  const end = timeToMinutes(endTime);

  return start < hourEnd && end > hourStart;
}

function getLaneName(reservation: Reservation) {
  return reservation.shooting_lanes?.[0]?.name ?? "Brak osi";
}

function getRoleLabel(role: string | null) {
  switch (role) {
    case "admin":
      return "Administrator";
    case "pracownik":
      return "Pracownik";
    case "instruktor":
      return "Instruktor";
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

function isCancelledStatus(status: string | null) {
  return (
    status === "cancelled" ||
    status === "canceled" ||
    status === "cancelled_by_user" ||
    status === "cancelled_by_admin"
  );
}

export default function AdminCalendarPage() {
  const today = new Date().toISOString().slice(0, 10);

  const [mode, setMode] = useState<CalendarMode>("day");
  const [selectedDate, setSelectedDate] = useState(today);
  const [lanes, setLanes] = useState<Lane[]>([]);
  const [reservations, setReservations] = useState<Reservation[]>([]);
  const [laneBlocks, setLaneBlocks] = useState<LaneBlock[]>([]);
  const [events, setEvents] = useState<EventItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [role, setRole] = useState<UserRole | null>(null);
  const [message, setMessage] = useState("");

  const visibleDates =
    mode === "day" ? [selectedDate] : getWeekDates(selectedDate);

  const hasAccess =
    role === "admin" || role === "pracownik" || role === "instruktor";

  useEffect(() => {
    loadCalendar();
  }, [selectedDate, mode]);

  async function loadCalendar() {
    setLoading(true);
    setMessage("");

    const {
      data: { user },
      error: userError,
    } = await supabase.auth.getUser();

    if (userError || !user) {
      setMessage("Musisz być zalogowany.");
      setLoading(false);
      return;
    }

    const { data: profile, error: profileError } = await supabase
      .from("profiles")
      .select("role")
      .eq("user_id", user.id)
      .single();

    if (profileError || !profile?.role) {
      setMessage("Nie udało się pobrać roli użytkownika.");
      setLoading(false);
      return;
    }

    const currentRole = String(profile.role).trim().toLowerCase() as UserRole;
    setRole(currentRole);

    if (
      currentRole !== "admin" &&
      currentRole !== "pracownik" &&
      currentRole !== "instruktor"
    ) {
      setMessage("Brak dostępu do kalendarza.");
      setLoading(false);
      return;
    }

    const dates = mode === "day" ? [selectedDate] : getWeekDates(selectedDate);
    const dateFrom = dates[0];
    const dateTo = dates[dates.length - 1];

    const { data: lanesData, error: lanesError } = await supabase
      .from("shooting_lanes")
      .select("id, name")
      .eq("is_active", true)
      .order("name");

    if (lanesError) {
      setMessage(`Błąd pobierania osi: ${lanesError.message}`);
      setLoading(false);
      return;
    }

    const { data: reservationsData, error: reservationsError } = await supabase
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
      .gte("reservation_date", dateFrom)
      .lte("reservation_date", dateTo)
      .order("reservation_date", { ascending: true })
      .order("start_time", { ascending: true });

    if (reservationsError) {
      setMessage(`Błąd pobierania rezerwacji: ${reservationsError.message}`);
      setLoading(false);
      return;
    }

    const { data: blocksData, error: blocksError } = await supabase
      .from("lane_blocks")
      .select("id, lane_id, block_date, start_time, end_time, reason, is_active")
      .gte("block_date", dateFrom)
      .lte("block_date", dateTo)
      .eq("is_active", true)
      .order("block_date", { ascending: true })
      .order("start_time", { ascending: true });

    if (blocksError) {
      setMessage(`Błąd pobierania blokad osi: ${blocksError.message}`);
      setLoading(false);
      return;
    }

    const { data: eventsData, error: eventsError } = await supabase
      .from("events")
      .select("id, title, event_date, start_time, end_time, location, is_active")
      .gte("event_date", dateFrom)
      .lte("event_date", dateTo)
      .eq("is_active", true)
      .order("event_date", { ascending: true })
      .order("start_time", { ascending: true });

    if (eventsError) {
      setMessage(`Błąd pobierania eventów: ${eventsError.message}`);
      setLoading(false);
      return;
    }

    const activeReservations = (
      (reservationsData ?? []) as unknown as Reservation[]
    ).filter((reservation) => !isCancelledStatus(reservation.reservation_status));

    setLanes((lanesData ?? []) as Lane[]);
    setReservations(activeReservations);
    setLaneBlocks((blocksData ?? []) as LaneBlock[]);
    setEvents((eventsData ?? []) as EventItem[]);
    setLoading(false);
  }

  function getReservationsForSlot(date: string, laneName: string, hour: string) {
    return reservations.filter(
      (reservation) =>
        reservation.reservation_date === date &&
        getLaneName(reservation) === laneName &&
        rangeCoversHour(reservation.start_time, reservation.end_time, hour)
    );
  }

  function getBlocksForSlot(date: string, laneId: string, hour: string) {
    return laneBlocks.filter(
      (block) =>
        block.block_date === date &&
        block.lane_id === laneId &&
        rangeCoversHour(block.start_time, block.end_time, hour)
    );
  }

  function getEventsForDate(date: string) {
    return events.filter((event) => event.event_date === date);
  }

  function getEventsForHour(date: string, hour: string) {
    return events.filter(
      (event) =>
        event.event_date === date &&
        rangeCoversHour(event.start_time, event.end_time, hour)
    );
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-white">
      <section className="mx-auto max-w-7xl px-4 py-10 sm:px-6">
        <div className="mb-8 flex flex-col gap-4 md:flex-row md:items-end md:justify-between">
          <div>
            <p className="mb-4 text-sm uppercase tracking-[0.35em] text-green-500">
              CSK Booking
            </p>

            <div className="flex flex-wrap items-center gap-3">
              <h1 className="text-4xl font-bold">
                Kalendarz operacyjny
              </h1>

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

            <p className="mt-3 text-zinc-400">
              Rezerwacje, blokady osi oraz eventy/szkolenia w jednym widoku.
            </p>
          </div>

          <a
            href="/admin"
            className="rounded-xl border border-zinc-700 px-5 py-3 text-sm font-semibold text-zinc-300 transition hover:bg-zinc-900"
          >
            ← Panel admina
          </a>
        </div>

        <div className="mb-6 grid gap-5 rounded-2xl border border-zinc-800 bg-zinc-900 p-6 md:grid-cols-2">
          <div>
            <label className="mb-2 block text-sm text-zinc-300">
              Widok
            </label>

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

        <div className="mb-8 flex flex-wrap gap-3 rounded-2xl border border-zinc-800 bg-zinc-900 p-4 text-xs font-semibold">
          <span className="rounded-full border border-green-800 bg-green-950 px-3 py-1 text-green-300">
            Rezerwacja
          </span>
          <span className="rounded-full border border-red-800 bg-red-950 px-3 py-1 text-red-300">
            Blokada osi
          </span>
          <span className="rounded-full border border-purple-800 bg-purple-950 px-3 py-1 text-purple-300">
            Event / szkolenie
          </span>
          <span className="rounded-full border border-zinc-800 bg-zinc-950 px-3 py-1 text-zinc-500">
            Wolne
          </span>
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

        {!loading && hasAccess && !message && (
          <>
            {mode === "day" && (
              <div className="grid gap-6">
                <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
                  <div className="mb-5 flex flex-col gap-2 md:flex-row md:items-center md:justify-between">
                    <h2 className="text-2xl font-bold">
                      Osie — {formatShortDate(selectedDate)}
                    </h2>

                    <span className="text-sm text-zinc-400">
                      Rezerwacje i blokady osi
                    </span>
                  </div>

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

                              const slotBlocks = getBlocksForSlot(
                                selectedDate,
                                lane.id,
                                hour
                              );

                              return (
                                <td
                                  key={lane.id}
                                  className="py-3 pr-4 align-top"
                                >
                                  {slotReservations.length === 0 &&
                                  slotBlocks.length === 0 ? (
                                    <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-3 text-xs text-zinc-600">
                                      Wolne
                                    </div>
                                  ) : (
                                    <div className="grid gap-2">
                                      {slotBlocks.map((block) => (
                                        <div
                                          key={`${block.id}-${hour}`}
                                          className="rounded-xl border border-red-800 bg-red-950 p-3 text-xs text-red-100"
                                        >
                                          <p className="font-bold text-red-300">
                                            {block.start_time.slice(0, 5)}–
                                            {block.end_time.slice(0, 5)}
                                          </p>
                                          <p>
                                            {block.reason ||
                                              "Blokada osi"}
                                          </p>
                                        </div>
                                      ))}

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

                <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
                  <div className="mb-5 flex flex-col gap-2 md:flex-row md:items-center md:justify-between">
                    <h2 className="text-2xl font-bold">
                      Eventy / szkolenia — {formatShortDate(selectedDate)}
                    </h2>

                    <span className="text-sm text-zinc-400">
                      {getEventsForDate(selectedDate).length} wydarzenia
                    </span>
                  </div>

                  {getEventsForDate(selectedDate).length === 0 ? (
                    <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4 text-sm text-zinc-500">
                      Brak eventów lub szkoleń w tym dniu.
                    </div>
                  ) : (
                    <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
                      {getEventsForDate(selectedDate).map((event) => (
                        <div
                          key={event.id}
                          className="rounded-xl border border-purple-800 bg-purple-950 p-4"
                        >
                          <p className="font-bold text-purple-300">
                            {event.start_time.slice(0, 5)}–
                            {event.end_time.slice(0, 5)}
                          </p>

                          <p className="mt-1 font-semibold text-white">
                            {event.title}
                          </p>

                          <p className="mt-2 text-sm text-purple-200">
                            {event.location || "Brak lokalizacji"}
                          </p>
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              </div>
            )}

            {mode === "week" && (
              <div className="grid gap-5">
                {visibleDates.map((date) => {
                  const dayReservations = reservations.filter(
                    (reservation) => reservation.reservation_date === date
                  );

                  const dayBlocks = laneBlocks.filter(
                    (block) => block.block_date === date
                  );

                  const dayEvents = events.filter(
                    (event) => event.event_date === date
                  );

                  return (
                    <div
                      key={date}
                      className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5"
                    >
                      <div className="mb-4 flex flex-col gap-2 md:flex-row md:items-center md:justify-between">
                        <h2 className="text-2xl font-bold">
                          {formatShortDate(date)}
                        </h2>

                        <div className="flex flex-wrap gap-2 text-xs font-semibold">
                          <span className="rounded-full bg-green-950 px-3 py-1 text-green-400">
                            Rezerwacje: {dayReservations.length}
                          </span>

                          <span className="rounded-full bg-red-950 px-3 py-1 text-red-300">
                            Blokady: {dayBlocks.length}
                          </span>

                          <span className="rounded-full bg-purple-950 px-3 py-1 text-purple-300">
                            Eventy: {dayEvents.length}
                          </span>
                        </div>
                      </div>

                      {dayReservations.length === 0 &&
                      dayBlocks.length === 0 &&
                      dayEvents.length === 0 ? (
                        <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4 text-sm text-zinc-500">
                          Brak rezerwacji, blokad i eventów.
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
                                {getLaneName(reservation)}
                              </p>

                              <p className="mt-2 text-sm text-green-100">
                                {reservation.customer_name}
                              </p>

                              <p className="text-sm text-green-400">
                                {reservation.customer_phone}
                              </p>
                            </div>
                          ))}

                          {dayBlocks.map((block) => {
                            const lane = lanes.find(
                              (item) => item.id === block.lane_id
                            );

                            return (
                              <div
                                key={block.id}
                                className="rounded-xl border border-red-800 bg-red-950 p-4"
                              >
                                <p className="font-bold text-red-300">
                                  {block.start_time.slice(0, 5)}–
                                  {block.end_time.slice(0, 5)}
                                </p>

                                <p className="mt-1 text-white">
                                  {lane?.name || "Nieznana oś"}
                                </p>

                                <p className="mt-2 text-sm text-red-100">
                                  {block.reason || "Blokada osi"}
                                </p>
                              </div>
                            );
                          })}

                          {dayEvents.map((event) => (
                            <div
                              key={event.id}
                              className="rounded-xl border border-purple-800 bg-purple-950 p-4"
                            >
                              <p className="font-bold text-purple-300">
                                {event.start_time.slice(0, 5)}–
                                {event.end_time.slice(0, 5)}
                              </p>

                              <p className="mt-1 text-white">
                                {event.title}
                              </p>

                              <p className="mt-2 text-sm text-purple-200">
                                {event.location || "Brak lokalizacji"}
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
          </>
        )}
      </section>
    </main>
  );
}