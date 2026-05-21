"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";

type EventRegistration = {
  id: string;
  registration_status: string;
};

type Event = {
  id: string;
  title: string;
  description: string;
  event_date: string;
  start_time: string;
  end_time: string;
  location: string;
  price: number;
  max_participants: number;
  event_registrations: EventRegistration[];
};

export default function EventsPage() {
  const [events, setEvents] = useState<Event[]>([]);
  const [selectedEventId, setSelectedEventId] = useState("");
  const [loading, setLoading] = useState(true);
  const [message, setMessage] = useState("");

  const [userId, setUserId] = useState("");
  const [customerName, setCustomerName] = useState("");
  const [customerEmail, setCustomerEmail] = useState("");
  const [customerPhone, setCustomerPhone] = useState("");

  useEffect(() => {
    async function loadData() {
      const {
        data: { user },
      } = await supabase.auth.getUser();

      if (user) {
        const metadata = user.user_metadata ?? {};

        setUserId(user.id);
        setCustomerName(metadata.full_name ?? metadata.name ?? "");
        setCustomerEmail(user.email ?? "");
        setCustomerPhone(
          metadata.phone ??
            metadata.telefon ??
            metadata.phone_number ??
            metadata.phoneNumber ??
            ""
        );
      }

      const { data, error } = await supabase
        .from("events")
        .select(
          `
          id,
          title,
          description,
          event_date,
          start_time,
          end_time,
          location,
          price,
          max_participants,
          event_registrations (
            id,
            registration_status
          )
        `
        )
        .eq("is_active", true)
        .order("event_date", { ascending: true });

      setLoading(false);

      if (error) {
        setMessage(`Błąd pobierania szkoleń: ${error.message}`);
        return;
      }

      setEvents((data as any) ?? []);
    }

    loadData();
  }, []);

  function getParticipantsCount(eventItem: Event) {
    return eventItem.event_registrations.filter(
      (registration) =>
        registration.registration_status !== "cancelled" &&
        registration.registration_status !== "reserve"
    ).length;
  }

  function getReserveCount(eventItem: Event) {
    return eventItem.event_registrations.filter(
      (registration) => registration.registration_status === "reserve"
    ).length;
  }

  function getEventStatus(eventItem: Event) {
    const participantsCount = getParticipantsCount(eventItem);
    const freePlaces = eventItem.max_participants - participantsCount;

    if (freePlaces <= 0) {
      return {
        label: "Pełne",
        className:
          "rounded-full bg-red-950 px-3 py-1 text-xs font-semibold text-red-300",
      };
    }

    if (freePlaces <= 3) {
      return {
        label: "Ostatnie miejsca",
        className:
          "rounded-full bg-yellow-950 px-3 py-1 text-xs font-semibold text-yellow-300",
      };
    }

    return {
      label: "Wolne miejsca",
      className:
        "rounded-full bg-green-950 px-3 py-1 text-xs font-semibold text-green-400",
    };
  }

  function formatDate(dateString: string) {
    const date = new Date(`${dateString}T12:00:00`);

    return new Intl.DateTimeFormat("pl-PL", {
      day: "2-digit",
      month: "2-digit",
      year: "numeric",
    }).format(date);
  }

  async function registerForEvent(eventItem: Event, asReserve = false) {
    setMessage("");

    if (!userId) {
      setMessage("Musisz być zalogowany, aby zapisać się na szkolenie.");
      return;
    }

    if (!customerPhone) {
      setMessage("Brakuje numeru telefonu w Twoim koncie.");
      return;
    }

    const { data: existingRegistration } = await supabase
      .from("event_registrations")
      .select("id")
      .eq("event_id", eventItem.id)
      .eq("user_id", userId)
      .neq("registration_status", "cancelled")
      .maybeSingle();

    if (existingRegistration) {
      setMessage("Jesteś już zapisany na to szkolenie lub listę rezerwową.");
      return;
    }

    const participantsCount = getParticipantsCount(eventItem);
    const isFull = participantsCount >= eventItem.max_participants;

    const registrationStatus = asReserve || isFull ? "reserve" : "registered";

    const { error } = await supabase.from("event_registrations").insert({
      event_id: eventItem.id,
      user_id: userId,
      customer_name: customerName,
      customer_email: customerEmail,
      customer_phone: customerPhone,
      registration_status: registrationStatus,
      payment_status: "pay_on_site",
    });

    if (error) {
      setMessage(`Błąd zapisu: ${error.message}`);
      return;
    }

    setMessage(
      registrationStatus === "reserve"
        ? "Zostałeś dodany do listy rezerwowej."
        : "Zostałeś zapisany na szkolenie."
    );

    setEvents((currentEvents) =>
      currentEvents.map((event) =>
        event.id === eventItem.id
          ? {
              ...event,
              event_registrations: [
                ...event.event_registrations,
                {
                  id: crypto.randomUUID(),
                  registration_status: registrationStatus,
                },
              ],
            }
          : event
      )
    );
  }

  function getMessageClass(message: string) {
    if (message.includes("Zostałeś")) {
      return "mb-6 rounded-xl border border-green-800 bg-green-950 p-4 text-sm font-semibold text-green-300";
    }

    return "mb-6 rounded-xl border border-red-800 bg-red-950 p-4 text-sm font-semibold text-red-300";
  }

  const selectedEvent = events.find((event) => event.id === selectedEventId);

  function EventDetails({ event }: { event: Event }) {
    const participantsCount = getParticipantsCount(event);
    const reserveCount = getReserveCount(event);
    const freePlaces = event.max_participants - participantsCount;
    const isFull = freePlaces <= 0;
    const status = getEventStatus(event);

    return (
      <div>
        <span className={status.className}>{status.label}</span>

        <h2 className="mt-4 text-2xl font-bold sm:text-3xl">{event.title}</h2>

        <div className="mt-5 grid gap-3 text-sm">
          <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
            <p className="text-zinc-500">Termin</p>
            <p className="font-semibold text-white">
              {formatDate(event.event_date)} | {event.start_time.slice(0, 5)}–
              {event.end_time.slice(0, 5)}
            </p>
          </div>

          <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
            <p className="text-zinc-500">Miejsce</p>
            <p className="font-semibold text-white">{event.location}</p>
          </div>

          <div className="grid gap-3 sm:grid-cols-2">
            <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
              <p className="text-zinc-500">Koszt</p>
              <p className="font-semibold text-green-500">
                {Number(event.price).toFixed(0)} zł
              </p>
            </div>

            <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
              <p className="text-zinc-500">Miejsca</p>
              <p className="font-semibold text-white">
                {participantsCount} / {event.max_participants}
              </p>
            </div>
          </div>

          <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
            <p className="text-zinc-500">Wolne miejsca</p>
            <p
              className={
                isFull
                  ? "font-semibold text-red-400"
                  : "font-semibold text-green-500"
              }
            >
              {Math.max(freePlaces, 0)}
            </p>

            {reserveCount > 0 && (
              <p className="mt-2 text-yellow-300">
                Lista rezerwowa: {reserveCount}
              </p>
            )}
          </div>
        </div>

        <div className="mt-6 rounded-2xl border border-zinc-800 bg-zinc-950 p-5">
          <h3 className="mb-3 text-xl font-bold">Opis</h3>

          <p className="whitespace-pre-line text-zinc-300">
            {event.description}
          </p>
        </div>

        <div className="mt-6">
          {isFull ? (
            <button
              type="button"
              onClick={() => registerForEvent(event, true)}
              className="w-full rounded-xl border border-yellow-700 bg-yellow-950 px-5 py-3 font-semibold text-yellow-300 transition hover:bg-yellow-900"
            >
              Dołącz do listy rezerwowej
            </button>
          ) : (
            <button
              type="button"
              onClick={() => registerForEvent(event, false)}
              className="w-full rounded-xl bg-green-700 px-5 py-3 font-semibold text-white transition hover:bg-green-600"
            >
              Zapisz się
            </button>
          )}
        </div>
      </div>
    );
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-white">
      <section className="mx-auto max-w-7xl px-4 py-10 sm:px-6 sm:py-12">
        <div className="mb-8 sm:mb-10">
          <p className="mb-4 text-xs uppercase tracking-[0.3em] text-green-500 sm:text-sm sm:tracking-[0.35em]">
            CSK Booking
          </p>

          <h1 className="text-3xl font-bold sm:text-4xl">
            Eventy i szkolenia
          </h1>

          <p className="mt-3 max-w-3xl text-sm text-zinc-400 sm:text-base">
            Wybierz szkolenie z listy, sprawdź szczegóły i zapisz się na
            wydarzenie albo listę rezerwową.
          </p>
        </div>

        {message && <div className={getMessageClass(message)}>{message}</div>}

        {loading && (
          <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-zinc-400">
            Ładowanie szkoleń...
          </div>
        )}

        {!loading && events.length === 0 && (
          <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-zinc-400">
            Brak dostępnych szkoleń.
          </div>
        )}

        {!loading && events.length > 0 && (
          <>
            {/* MOBILE */}
            <div className="grid gap-4 lg:hidden">
              {events.map((event) => {
                const participantsCount = getParticipantsCount(event);
                const reserveCount = getReserveCount(event);
                const status = getEventStatus(event);
                const isOpen = selectedEventId === event.id;

                return (
                  <div
                    key={event.id}
                    className={
                      isOpen
                        ? "rounded-2xl border border-green-800 bg-green-950/30 p-4"
                        : "rounded-2xl border border-zinc-800 bg-zinc-900 p-4"
                    }
                  >
                    <button
                      type="button"
                      onClick={() =>
                        setSelectedEventId(isOpen ? "" : event.id)
                      }
                      className="w-full text-left"
                    >
                      <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
                        <span className={status.className}>
                          {status.label}
                        </span>

                        <span className="text-sm font-semibold text-green-500">
                          {Number(event.price).toFixed(0)} zł
                        </span>
                      </div>

                      <h2 className="text-xl font-bold">{event.title}</h2>

                      <div className="mt-4 grid gap-2 text-sm text-zinc-300">
                        <div className="flex justify-between gap-3 border-b border-zinc-800 pb-2">
                          <span className="text-zinc-500">Termin</span>
                          <span className="font-semibold text-white">
                            {formatDate(event.event_date)}
                          </span>
                        </div>

                        <div className="flex justify-between gap-3 border-b border-zinc-800 pb-2">
                          <span className="text-zinc-500">Godzina</span>
                          <span className="font-semibold text-white">
                            {event.start_time.slice(0, 5)}–
                            {event.end_time.slice(0, 5)}
                          </span>
                        </div>

                        <div className="flex justify-between gap-3 border-b border-zinc-800 pb-2">
                          <span className="text-zinc-500">Miejsca</span>
                          <span className="font-semibold text-white">
                            {participantsCount} / {event.max_participants}
                          </span>
                        </div>

                        {reserveCount > 0 && (
                          <div className="flex justify-between gap-3 border-b border-zinc-800 pb-2">
                            <span className="text-zinc-500">
                              Lista rezerwowa
                            </span>
                            <span className="font-semibold text-yellow-300">
                              {reserveCount}
                            </span>
                          </div>
                        )}
                      </div>

                      <p className="mt-4 text-sm font-semibold text-green-400">
                        {isOpen ? "Ukryj szczegóły ↑" : "Pokaż szczegóły ↓"}
                      </p>
                    </button>

                    {isOpen && (
                      <div className="mt-5 border-t border-zinc-800 pt-5">
                        <EventDetails event={event} />
                      </div>
                    )}
                  </div>
                );
              })}
            </div>

            {/* DESKTOP */}
            <div className="hidden gap-6 lg:grid lg:grid-cols-[1.3fr_1fr]">
              <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
                <h2 className="mb-5 text-2xl font-bold">Lista szkoleń</h2>

                <div className="overflow-x-auto">
                  <table className="w-full min-w-[850px] border-collapse text-left text-sm">
                    <thead>
                      <tr className="border-b border-zinc-800 text-zinc-400">
                        <th className="py-3 pr-4">Temat</th>
                        <th className="py-3 pr-4">Termin</th>
                        <th className="py-3 pr-4">Godzina</th>
                        <th className="py-3 pr-4">Koszt</th>
                        <th className="py-3 pr-4">Miejsca</th>
                        <th className="py-3 pr-4">Status</th>
                      </tr>
                    </thead>

                    <tbody>
                      {events.map((event) => {
                        const participantsCount = getParticipantsCount(event);
                        const reserveCount = getReserveCount(event);
                        const status = getEventStatus(event);
                        const isSelected = selectedEventId === event.id;

                        return (
                          <tr
                            key={event.id}
                            onClick={() => setSelectedEventId(event.id)}
                            className={
                              isSelected
                                ? "cursor-pointer border-b border-green-800 bg-green-950/40"
                                : "cursor-pointer border-b border-zinc-800 hover:bg-zinc-800"
                            }
                          >
                            <td className="py-4 pr-4 font-semibold">
                              {event.title}
                              {reserveCount > 0 && (
                                <span className="mt-1 block text-xs text-yellow-300">
                                  Lista rezerwowa: {reserveCount}
                                </span>
                              )}
                            </td>

                            <td className="py-4 pr-4">
                              {formatDate(event.event_date)}
                            </td>

                            <td className="py-4 pr-4">
                              {event.start_time.slice(0, 5)}–
                              {event.end_time.slice(0, 5)}
                            </td>

                            <td className="py-4 pr-4">
                              <span className="font-semibold text-green-500">
                                {Number(event.price).toFixed(0)} zł
                              </span>
                            </td>

                            <td className="py-4 pr-4">
                              {participantsCount} / {event.max_participants}
                            </td>

                            <td className="py-4 pr-4">
                              <span className={status.className}>
                                {status.label}
                              </span>
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>

                <p className="mt-4 text-sm text-zinc-500">
                  Kliknij wybrane szkolenie, aby zobaczyć pełny opis i możliwość
                  zapisu.
                </p>
              </div>

              <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6">
                {!selectedEvent && (
                  <div className="text-zinc-400">
                    <h2 className="mb-3 text-2xl font-bold text-white">
                      Szczegóły szkolenia
                    </h2>

                    <p>Wybierz szkolenie z tabeli po lewej stronie.</p>
                  </div>
                )}

                {selectedEvent && <EventDetails event={selectedEvent} />}
              </div>
            </div>
          </>
        )}

        <div className="mt-8 flex flex-col gap-3 sm:flex-row">
          <a
            href="/dashboard"
            className="rounded-xl border border-zinc-700 px-5 py-3 text-center text-sm font-semibold text-zinc-300 transition hover:bg-zinc-900"
          >
            ← Panel klienta
          </a>

          <a
            href="/booking"
            className="rounded-xl bg-green-700 px-5 py-3 text-center text-sm font-semibold text-white transition hover:bg-green-600"
          >
            Przejdź do rezerwacji osi
          </a>
        </div>
      </section>
    </main>
  );
}