"use client";

import { useEffect, useState } from "react";
import { getPaymentStatusLabel } from "../../lib/payment-status";
import { handleFreedEventPlace } from "../../lib/event-registration-actions";
import { supabase } from "../../lib/supabase";

type EventRegistration = {
  id: string;
  registration_status: string;
  payment_status: string;
  created_at: string;
  events: {
    id: string;
    title: string;
    description: string;
    event_date: string;
    start_time: string;
    end_time: string;
    location: string;
    price: number;
  } | null;
};

type ReserveRegistration = {
  id: string;
};

const WARSAW_TIME_ZONE = "Europe/Warsaw";
const ACTIVE_REGISTRATION_STATUSES = new Set([
  "registered",
  "approved",
  "reserve",
  "participant",
]);

const warsawDateTimeFormatter = new Intl.DateTimeFormat("en-GB", {
  timeZone: WARSAW_TIME_ZONE,
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hourCycle: "h23",
  numberingSystem: "latn",
});

function getWarsawDateTimeKey(date: Date) {
  const parts = warsawDateTimeFormatter.formatToParts(date);
  const values = Object.fromEntries(
    parts
      .filter((part) => part.type !== "literal")
      .map((part) => [part.type, part.value])
  );

  const { year, month, day, hour, minute, second } = values;

  if (!year || !month || !day || !hour || !minute || !second) {
    return null;
  }

  return `${year}-${month}-${day}T${hour}:${minute}:${second}`;
}

function getEventDateTimeKey(eventDate?: string, eventTime?: string) {
  const dateMatch = eventDate?.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  const timeMatch = eventTime?.match(
    /^(\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?$/
  );

  if (!dateMatch || !timeMatch) {
    return null;
  }

  const [, year, month, day] = dateMatch;
  const [, hour, minute, second = "00"] = timeMatch;
  const yearNumber = Number(year);
  const monthNumber = Number(month);
  const dayNumber = Number(day);
  const hourNumber = Number(hour);
  const minuteNumber = Number(minute);
  const secondNumber = Number(second);
  const validationDate = new Date(
    Date.UTC(yearNumber, monthNumber - 1, dayNumber)
  );

  if (
    validationDate.getUTCFullYear() !== yearNumber ||
    validationDate.getUTCMonth() !== monthNumber - 1 ||
    validationDate.getUTCDate() !== dayNumber ||
    hourNumber > 23 ||
    minuteNumber > 59 ||
    secondNumber > 59
  ) {
    return null;
  }

  return `${year}-${month}-${day}T${hour}:${minute}:${second}`;
}

function getEventTimeKeys(event: EventRegistration["events"]) {
  if (!event) {
    return null;
  }

  const startKey = getEventDateTimeKey(event.event_date, event.start_time);
  const endKey = getEventDateTimeKey(event.event_date, event.end_time);

  if (!startKey || !endKey || endKey <= startKey) {
    return null;
  }

  return { startKey, endKey };
}

function isActiveEventRegistration(
  item: EventRegistration,
  warsawNowKey: string | null
) {
  const eventTimeKeys = getEventTimeKeys(item.events);

  return Boolean(
    warsawNowKey &&
      eventTimeKeys &&
      ACTIVE_REGISTRATION_STATUSES.has(item.registration_status) &&
      eventTimeKeys.endKey > warsawNowKey
  );
}

function getEventHistoryLabel(
  item: EventRegistration,
  warsawNowKey: string | null
) {
  if (item.registration_status === "cancelled") {
    return "Zapis anulowany";
  }

  const eventTimeKeys = getEventTimeKeys(item.events);

  if (
    !warsawNowKey ||
    !eventTimeKeys ||
    !ACTIVE_REGISTRATION_STATUSES.has(item.registration_status) ||
    eventTimeKeys.endKey > warsawNowKey
  ) {
    return "Archiwalne";
  }

  if (item.registration_status === "reserve") {
    return "Lista rezerwowa — termin minął";
  }

  return "Szkolenie zakończone";
}

function translateStatus(status: string) {
  if (status === "registered") return "Zapisany";
  if (status === "approved") return "Zatwierdzony";
  if (status === "reserve") return "Rezerwowy";
  if (status === "participant") return "Uczestnik";
  if (status === "cancelled") return "Anulowany";
  return status;
}

function getStatusClass(status: string) {
  if (status === "approved" || status === "participant") {
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
  if (
    message.includes("anulowany") ||
    message.includes("przeniesiona") ||
    message.includes("przeniesiony")
  ) {
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
            id,
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

    if (error) {
      setProcessingId("");
      setMessage(`Błąd anulacji: ${error.message}`);
      return;
    }

    const shouldNotifyReserveList =
      item.registration_status === "registered" ||
      item.registration_status === "approved";

    const reserveResult = shouldNotifyReserveList
      ? await handleFreedEventPlace(item.events.id)
      : {
          reserveFound: false,
          emailsSent: 0,
          error: "",
        };

    setProcessingId("");

    if (reserveResult.error) {
      setMessage(
        `Udział został anulowany, ale nie udało się sprawdzić listy rezerwowej: ${reserveResult.error}`
      );
    } else if (reserveResult.reserveFound) {
      setMessage(
        "Udział w szkoleniu został anulowany. System wysłał powiadomienie o wolnym miejscu do osób z listy rezerwowej."
      );
    } else {
      setMessage("Udział w szkoleniu został anulowany.");
    }

    setItems((currentItems) =>
      currentItems.map((currentItem) =>
        currentItem.id === item.id
          ? { ...currentItem, registration_status: "cancelled" }
          : currentItem
      )
    );
  }

  const warsawNowKey = getWarsawDateTimeKey(new Date());
  const activeEvents = items
    .filter((item) => isActiveEventRegistration(item, warsawNowKey))
    .sort((firstItem, secondItem) => {
      const firstStartKey = getEventTimeKeys(firstItem.events)?.startKey ?? "";
      const secondStartKey = getEventTimeKeys(secondItem.events)?.startKey ?? "";

      return firstStartKey.localeCompare(secondStartKey);
    });
  const eventHistory = items
    .filter((item) => !isActiveEventRegistration(item, warsawNowKey))
    .sort((firstItem, secondItem) => {
      const firstEndKey = getEventTimeKeys(firstItem.events)?.endKey ?? "";
      const secondEndKey = getEventTimeKeys(secondItem.events)?.endKey ?? "";

      return secondEndKey.localeCompare(firstEndKey);
    });

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

        {!loading && isLoggedIn && (
          <div>
            <h2 className="mb-4 text-2xl font-bold">Aktywne szkolenia</h2>

            {activeEvents.length === 0 ? (
              <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-zinc-400">
                Nie masz obecnie aktywnych szkoleń.
              </div>
            ) : (
              <div className="space-y-4">
                {activeEvents.map((item) => {
                  const event = item.events;

                  if (!event) {
                    return null;
                  }

                  const canCancel = canCancelEvent(
                    event.event_date,
                    event.start_time
                  );
                  const isTooLateToCancel = !canCancelEvent(
                    event.event_date,
                    event.start_time
                  );

                  return (
                    <div
                      key={item.id}
                      className="rounded-2xl border border-zinc-800 bg-zinc-900 p-6"
                    >
                      <div className="flex flex-col gap-4 md:flex-row md:items-start md:justify-between">
                        <div className="w-full">
                          <span
                            className={getStatusClass(
                              item.registration_status
                            )}
                          >
                            {translateStatus(item.registration_status)}
                          </span>

                          <h3 className="mt-4 text-2xl font-bold">
                            {event.title}
                          </h3>

                          <p className="mt-2 whitespace-pre-line text-zinc-400">
                            {event.description}
                          </p>

                          <div className="mt-5 grid gap-3 text-sm text-zinc-400 md:grid-cols-2">
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
                              <p className="mb-1 text-zinc-500">
                                Cena / płatność
                              </p>
                              <p className="font-semibold text-green-500">
                                {Number(event.price).toFixed(0)} zł —{" "}
                                {getPaymentStatusLabel(item.payment_status)}
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
                              godziny do wydarzenia — skontaktuj się
                              telefonicznie z organizatorem.
                            </div>
                          )}
                        </div>
                      </div>
                    </div>
                  );
                })}
              </div>
            )}

            {eventHistory.length > 0 && (
              <section className="mt-10">
                <h2 className="mb-4 text-2xl font-bold">Historia szkoleń</h2>

                <div className="space-y-3">
                  {eventHistory.map((item) => (
                    <div
                      key={item.id}
                      className="rounded-xl border border-zinc-800 bg-zinc-900 p-4"
                    >
                      <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
                        <div>
                          <p className="text-sm text-zinc-400">
                            {item.events?.event_date ?? "Brak daty"}
                          </p>
                          <h3 className="font-semibold text-white">
                            {item.events?.title ?? "Brak danych szkolenia"}
                          </h3>
                        </div>

                        <span className="text-sm font-semibold text-zinc-300">
                          {getEventHistoryLabel(item, warsawNowKey)}
                        </span>
                      </div>
                    </div>
                  ))}
                </div>
              </section>
            )}
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
