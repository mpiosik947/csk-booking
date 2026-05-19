"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";

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
  event_registrations: { id: string }[];
};

export default function EventsPage() {
  const [events, setEvents] = useState<Event[]>([]);
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
            id
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

      setEvents((data ?? []) as Event[]);
    }

    loadData();
  }, []);

  async function registerForEvent(eventItem: Event) {
    setMessage("");

    if (!userId) {
      setMessage("Musisz być zalogowany, aby zapisać się na szkolenie.");
      return;
    }

    if (!customerPhone) {
      setMessage("Brakuje numeru telefonu w Twoim koncie.");
      return;
    }

    const currentParticipants = eventItem.event_registrations.length;

    if (currentParticipants >= eventItem.max_participants) {
      setMessage("Brak wolnych miejsc na to szkolenie.");
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
      setMessage("Jesteś już zapisany na to szkolenie.");
      return;
    }

    const { error } = await supabase.from("event_registrations").insert({
      event_id: eventItem.id,
      user_id: userId,
      customer_name: customerName,
      customer_email: customerEmail,
      customer_phone: customerPhone,
      registration_status: "registered",
      payment_status: "pay_on_site",
    });

    if (error) {
      setMessage(`Błąd zapisu: ${error.message}`);
      return;
    }

    setMessage("Zostałeś zapisany na szkolenie.");

    setEvents((currentEvents) =>
      currentEvents.map((event) =>
        event.id === eventItem.id
          ? {
              ...event,
              event_registrations: [
                ...event.event_registrations,
                { id: crypto.randomUUID() },
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

  return (
    <main className="min-h-screen bg-zinc-950 text-white">
      <section className="mx-auto max-w-6xl px-6 py-12">
        <div className="mb-10">
          <p className="mb-4 text-sm uppercase tracking-[0.35em] text-green-500">
            CSK Booking
          </p>

          <h1 className="text-4xl font-bold">Eventy i szkolenia</h1>

          <p className="mt-3 max-w-3xl text-zinc-400">
            Lista aktualnych szkoleń, treningów i wydarzeń organizowanych na
            strzelnicy.
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
          <div className="grid gap-6">
            {events.map((event) => {
              const participantsCount = event.event_registrations.length;
              const freePlaces = event.max_participants - participantsCount;
              const isFull = freePlaces <= 0;

              return (
                <div
                  key={event.id}
                  className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6"
                >
                  <div className="flex flex-col gap-6 lg:flex-row lg:items-start lg:justify-between">
                    <div className="max-w-3xl">
                      <div
                        className={
                          isFull
                            ? "mb-3 inline-block rounded-full bg-red-950 px-3 py-1 text-xs font-semibold text-red-400"
                            : "mb-3 inline-block rounded-full bg-green-950 px-3 py-1 text-xs font-semibold text-green-400"
                        }
                      >
                        {isFull ? "BRAK MIEJSC" : "ZAPISY OTWARTE"}
                      </div>

                      <h2 className="mb-3 text-3xl font-bold">
                        {event.title}
                      </h2>

                      <p className="mb-5 whitespace-pre-line text-zinc-300">
                        {event.description}
                      </p>

                      <div className="grid gap-3 text-sm text-zinc-400 md:grid-cols-2">
                        <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                          <p className="mb-1 text-zinc-500">Data</p>
                          <p className="font-semibold text-white">
                            {event.event_date}
                          </p>
                        </div>

                        <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                          <p className="mb-1 text-zinc-500">Godzina</p>
                          <p className="font-semibold text-white">
                            {event.start_time.slice(0, 5)} -{" "}
                            {event.end_time.slice(0, 5)}
                          </p>
                        </div>

                        <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                          <p className="mb-1 text-zinc-500">Miejsce</p>
                          <p className="font-semibold text-white">
                            {event.location}
                          </p>
                        </div>

                        <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                          <p className="mb-1 text-zinc-500">Cena</p>
                          <p className="font-semibold text-green-500">
                            {Number(event.price).toFixed(0)} zł
                          </p>
                        </div>
                      </div>
                    </div>

                    <div className="min-w-[260px] rounded-2xl border border-zinc-800 bg-zinc-950 p-5">
                      <div className="mb-5 grid gap-3">
                        <div>
                          <p className="mb-1 text-sm text-zinc-500">
                            Limit miejsc
                          </p>
                          <p className="text-3xl font-bold text-white">
                            {event.max_participants}
                          </p>
                        </div>

                        <div>
                          <p className="mb-1 text-sm text-zinc-500">
                            Zapisane osoby
                          </p>
                          <p className="text-3xl font-bold text-green-500">
                            {participantsCount}
                          </p>
                        </div>

                        <div>
                          <p className="mb-1 text-sm text-zinc-500">
                            Wolne miejsca
                          </p>
                          <p
                            className={
                              isFull
                                ? "text-3xl font-bold text-red-400"
                                : "text-3xl font-bold text-green-500"
                            }
                          >
                            {Math.max(freePlaces, 0)}
                          </p>
                        </div>
                      </div>

                      <button
                        type="button"
                        disabled={isFull}
                        onClick={() => registerForEvent(event)}
                        className={
                          isFull
                            ? "w-full cursor-not-allowed rounded-xl border border-red-900 bg-zinc-900 px-4 py-3 font-semibold text-zinc-600"
                            : "w-full rounded-xl bg-green-700 px-4 py-3 font-semibold transition hover:bg-green-600"
                        }
                      >
                        {isFull ? "Brak miejsc" : "Zapisz się"}
                      </button>
                    </div>
                  </div>
                </div>
              );
            })}
          </div>
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