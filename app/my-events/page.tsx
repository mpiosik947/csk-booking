"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";

type EventRegistration = {
  id: string;
  registration_status: string;
  payment_status: string;
  created_at: string;
  events: {
    title: string;
    description: string;
    event_date: string;
    start_time: string;
    end_time: string;
    location: string;
    price: number;
  } | null;
};

function translateStatus(status: string) {
  if (status === "registered") return "Zapisany";
  if (status === "approved") return "Zatwierdzony";
  if (status === "reserve") return "Rezerwowy";
  if (status === "cancelled") return "Anulowany";
  return status;
}

function translatePayment(status: string) {
  if (status === "pay_on_site") return "Płatność na miejscu";
  if (status === "paid_on_site") return "Opłacone";
  return status;
}

function getStatusClass(status: string) {
  if (status === "approved") {
    return "rounded-full bg-green-950 px-3 py-1 text-xs font-semibold text-green-400";
  }

  if (status === "registered") {
    return "rounded-full bg-blue-950 px-3 py-1 text-xs font-semibold text-blue-300";
  }

  if (status === "reserve") {
    return "rounded-full bg-yellow-950 px-3 py-1 text-xs font-semibold text-yellow-300";
  }

  if (status === "cancelled") {
    return "rounded-full bg-red-950 px-3 py-1 text-xs font-semibold text-red-300";
  }

  return "rounded-full bg-zinc-950 px-3 py-1 text-xs font-semibold text-zinc-300";
}

function canCancelEvent(eventDate: string, startTime: string) {
  const eventDateTime = new Date(`${eventDate}T${startTime.slice(0, 5)}:00`);
  const now = new Date();

  const differenceInMilliseconds = eventDateTime.getTime() - now.getTime();
  const differenceInHours = differenceInMilliseconds / (1000 * 60 * 60);

  return differenceInHours >= 72;
}

function getMessageClass(message: string) {
  if (message.includes("anulowany") || message.includes("anulowany")) {
    return "mb-6 rounded-xl border border-green-800 bg-green-950 p-4 text-sm font-semibold text-green-300";
  }

  return "mb-6 rounded-xl border border-red-800 bg-red-950 p-4 text-sm font-semibold text-red-300";
}

export default function MyEventsPage() {
  const [items, setItems] = useState<EventRegistration[]>([]);
  const [loading, setLoading] = useState(true);
  const [isLoggedIn, setIsLoggedIn] = useState(false);
  const [message, setMessage] = useState("");
  const [processingId, setProcessingId] = useState("");

  useEffect(() => {
    async function loadMyEvents() {
      const {
        data: { user },
      } = await supabase.auth.getUser();

      if (!user) {
        setIsLoggedIn(false);
        setLoading(false);
        return;
      }

      setIsLoggedIn(true);

      const { data, error } = await supabase
        .from("event_registrations")
        .select(
          `
          id,
          registration_status,
          payment_status,
          created_at,
          events (
            title,
            description,
            event_date,
            start_time,
            end_time,
            location,
            price
          )
        `
        )
        .eq("user_id", user.id)
        .order("created_at", { ascending: false });

      if (error) {
        setMessage(`Błąd pobierania szkoleń: ${error.message}`);
        setLoading(false);
        return;
      }

      setItems((data as any) ?? []);
      setLoading(false);
    }

    loadMyEvents();
  }, []);

  async function cancelRegistration(item: EventRegistration) {
    setMessage("");

    if (!item.events) {
      setMessage("Brak danych szkolenia.");
      return;
    }

    if (!canCancelEvent(item.events.event_date, item.events.start_time)) {
      setMessage(
        "Anulacja online możliwa tylko do 72h przed szkoleniem. Skontaktuj się telefonicznie z organizatorem."
      );
      return;
    }

    const confirmed = window.confirm(
      "Czy na pewno chcesz anulować udział w tym szkoleniu?"
    );

    if (!confirmed) {
      return;
    }

    setProcessingId(item.id);

    const { error } = await supabase
      .from("event_registrations")
      .update({
        registration_status: "cancelled",
      })
      .eq("id", item.id);

    setProcessingId("");

    if (error) {
      setMessage(`Błąd anulacji: ${error.message}`);
      return;
    }

    setItems((currentItems) =>
      currentItems.map((currentItem) =>
        currentItem.id === item.id
          ? { ...currentItem, registration_status: "cancelled" }
          : currentItem
      )
    );

    setMessage("Udział w szkoleniu został anulowany.");
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-white">
      <section className="mx-auto max-w-5xl px-6 py-12">
        <p className="mb-4 text-sm uppercase tracking-[0.35em] text-green-500">
          CSK Booking
        </p>

        <h1 className="mb-3 text-3xl font-bold">Moje szkolenia</h1>

        <p className="mb-8 text-zinc-400">
          Tutaj widzisz szkolenia i eventy, na które jesteś zapisany. Udział
          możesz anulować samodzielnie najpóźniej 72 godziny przed terminem.
        </p>

        {loading && (
          <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-zinc-400">
            Ładowanie szkoleń...
          </div>
        )}

        {!loading && !isLoggedIn && (
          <div className="rounded-2xl border border-red-800 bg-red-950 p-8 text-center">
            <h2 className="mb-3 text-2xl font-bold text-red-200">
              Logowanie wymagane
            </h2>

            <p className="mx-auto mb-6 max-w-xl text-red-100">
              Aby zobaczyć swoje szkolenia, musisz najpierw zalogować się na
              konto użytkownika.
            </p>

            <div className="flex flex-col gap-3 sm:flex-row sm:justify-center">
              <a
                href="/login"
                className="rounded-xl bg-green-700 px-5 py-3 font-semibold text-white transition hover:bg-green-600"
              >
                Zaloguj się
              </a>

              <a
                href="/register"
                className="rounded-xl border border-red-300 px-5 py-3 font-semibold text-red-100 transition hover:bg-red-900"
              >
                Utwórz konto
              </a>
            </div>
          </div>
        )}

        {!loading && isLoggedIn && message && (
          <div className={getMessageClass(message)}>{message}</div>
        )}

        {!loading && isLoggedIn && !message && items.length === 0 && (
          <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-zinc-400">
            Nie jesteś jeszcze zapisany na żadne szkolenie.
          </div>
        )}

        {!loading && isLoggedIn && items.length > 0 && (
          <div className="space-y-4">
            {items.map((item) => {
              const event = item.events;
              const canCancel =
                event &&
                item.registration_status !== "cancelled" &&
                canCancelEvent(event.event_date, event.start_time);

              const isTooLateToCancel =
                event &&
                item.registration_status !== "cancelled" &&
                !canCancelEvent(event.event_date, event.start_time);

              return (
                <div
                  key={item.id}
                  className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6"
                >
                  <div className="flex flex-col gap-4 md:flex-row md:items-start md:justify-between">
                    <div className="w-full">
                      <span className={getStatusClass(item.registration_status)}>
                        {translateStatus(item.registration_status)}
                      </span>

                      <h2 className="mt-4 text-2xl font-bold">
                        {event?.title ?? "Brak danych szkolenia"}
                      </h2>

                      <p className="mt-2 whitespace-pre-line text-zinc-400">
                        {event?.description}
                      </p>

                      <div className="mt-5 grid gap-3 text-sm text-zinc-400 md:grid-cols-2">
                        <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                          <p className="mb-1 text-zinc-500">Data</p>
                          <p className="font-semibold text-white">
                            {event?.event_date}
                          </p>
                        </div>

                        <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                          <p className="mb-1 text-zinc-500">Godzina</p>
                          <p className="font-semibold text-white">
                            {event?.start_time?.slice(0, 5)} -{" "}
                            {event?.end_time?.slice(0, 5)}
                          </p>
                        </div>

                        <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                          <p className="mb-1 text-zinc-500">Miejsce</p>
                          <p className="font-semibold text-white">
                            {event?.location}
                          </p>
                        </div>

                        <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4">
                          <p className="mb-1 text-zinc-500">Cena / płatność</p>
                          <p className="font-semibold text-green-500">
                            {Number(event?.price ?? 0).toFixed(0)} zł —{" "}
                            {translatePayment(item.payment_status)}
                          </p>
                        </div>
                      </div>

                      {canCancel && (
                        <div className="mt-6">
                          <button
                            type="button"
                            disabled={processingId === item.id}
                            onClick={() => cancelRegistration(item)}
                            className="rounded-xl border border-red-700 bg-red-950 px-5 py-3 text-sm font-semibold text-red-300 transition hover:bg-red-900 disabled:cursor-not-allowed disabled:opacity-60"
                          >
                            {processingId === item.id
                              ? "Anulowanie..."
                              : "Anuluj udział"}
                          </button>
                        </div>
                      )}

                      {isTooLateToCancel && (
                        <div className="mt-6 rounded-xl border border-yellow-700 bg-yellow-950 p-4 text-sm font-semibold text-yellow-300">
                          Anulacja online niedostępna. Zostało mniej niż 72
                          godziny do wydarzenia — skontaktuj się telefonicznie z
                          organizatorem.
                        </div>
                      )}

                      {item.registration_status === "cancelled" && (
                        <div className="mt-6 rounded-xl border border-red-800 bg-red-950 p-4 text-sm font-semibold text-red-300">
                          Ten zapis został anulowany.
                        </div>
                      )}
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
            href="/events"
            className="rounded-xl bg-green-700 px-5 py-3 text-center text-sm font-semibold text-white transition hover:bg-green-600"
          >
            Zobacz szkolenia
          </a>
        </div>
      </section>
    </main>
  );
}