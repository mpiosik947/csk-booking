"use client";

import { useEffect, useRef, useState } from "react";
import { getPaymentStatusLabel } from "../../lib/payment-status";
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

type CancellationResponse = {
  success?: boolean;
  error?: string;
  message?: string;
  cancellation?: {
    registrationId: string;
    eventId: string;
    changed: boolean;
    previousStatus: string;
    newStatus: string;
    freedParticipantPlace: boolean;
  };
  promotion?: {
    attempted: boolean;
    succeeded: boolean;
    warning: boolean;
  };
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
  if (
    status === "registered" ||
    status === "approved" ||
    status === "participant"
  ) {
    return "rounded-full border border-[#3f6848] bg-[#1b2a1d] px-3 py-1 text-xs font-semibold text-[#a9d4ad]";
  }

  if (status === "reserve") {
    return "rounded-full border border-[#806a32] bg-[#2b2618] px-3 py-1 text-xs font-semibold text-[#e1c477]";
  }

  if (status === "cancelled") {
    return "rounded-full border border-[#744545] bg-[#2a1b1b] px-3 py-1 text-xs font-semibold text-[#e0a0a0]";
  }

  return "rounded-full border border-[#343a31] bg-[#171a17] px-3 py-1 text-xs font-semibold text-[#858c7f]";
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
    return "rounded-xl border border-[#3f6848] bg-[#1b2a1d] p-4 text-sm font-semibold text-[#a9d4ad]";
  }

  return "rounded-xl border border-[#744545] bg-[#2a1b1b] p-4 text-sm font-semibold text-[#e0a0a0]";
}

function getEventHistoryClass(status: string) {
  if (status === "cancelled") {
    return "border-[#744545] bg-[#2a1b1b] text-[#e0a0a0]";
  }

  if (status === "reserve") {
    return "border-[#806a32] bg-[#2b2618] text-[#e1c477]";
  }

  return "border-[#343a31] bg-[#171a17] text-[#858c7f]";
}

export default function MyEventsPage() {
  const [items, setItems] = useState<EventRegistration[]>([]);
  const [loading, setLoading] = useState(true);
  const [isLoggedIn, setIsLoggedIn] = useState(false);
  const [message, setMessage] = useState("");
  const [processingId, setProcessingId] = useState("");
  const cancellingRegistrationIds = useRef(new Set<string>());
  const [expandedEventId, setExpandedEventId] = useState<string | null>(null);

  function toggleExpandedEvent(eventId: string) {
    setExpandedEventId((currentId) =>
      currentId === eventId ? null : eventId
    );
  }

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
    if (cancellingRegistrationIds.current.has(item.id)) {
      return;
    }

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

    cancellingRegistrationIds.current.add(item.id);
    setProcessingId(item.id);

    try {
      const {
        data: { session },
        error: sessionError,
      } = await supabase.auth.getSession();

      if (sessionError || !session?.access_token) {
        setMessage("Brak aktywnej sesji. Zaloguj się ponownie.");
        return;
      }

      const response = await fetch("/api/cancel-event-registration", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${session.access_token}`,
        },
        body: JSON.stringify({ registrationId: item.id }),
      });
      const data = (await response.json().catch(() => null)) as
        | CancellationResponse
        | null;

      if (!response.ok || !data?.success || !data.cancellation) {
        setMessage(
          data?.error ??
            (response.status === 409
              ? "Zapis można anulować najpóźniej 72 godziny przed rozpoczęciem szkolenia."
              : "Nie udało się anulować udziału w szkoleniu.")
        );
        return;
      }

      setItems((currentItems) =>
        currentItems.map((currentItem) =>
          currentItem.id === item.id
            ? {
                ...currentItem,
                registration_status: data.cancellation?.newStatus ?? "cancelled",
              }
            : currentItem
        )
      );

      setMessage(data.message ?? "Udział jest anulowany.");
    } catch {
      setMessage("Nie udało się anulować udziału w szkoleniu. Spróbuj ponownie.");
    } finally {
      cancellingRegistrationIds.current.delete(item.id);
      setProcessingId("");
    }
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
    <main className="min-h-screen bg-[#090b09] px-4 py-6 text-[#f2efe4] sm:px-6 sm:py-8">
      <section className="mx-auto max-w-5xl rounded-[2rem] border border-[#30372c] bg-[#141814] p-5 shadow-2xl shadow-black/20 sm:p-8">
        <header>
          <p className="mb-3 text-xs font-semibold uppercase tracking-[0.22em] text-[#858c7f]">
            CSK Booking
          </p>

          <h1 className="text-3xl font-bold sm:text-4xl">Moje szkolenia</h1>

          <p className="mt-3 max-w-3xl leading-7 text-[#a9ada4]">
            Tutaj widzisz szkolenia i eventy, na które jesteś zapisany. Udział
            możesz anulować samodzielnie najpóźniej 72 godziny przed terminem.
          </p>
        </header>

        {loading && (
          <div
            role="status"
            aria-live="polite"
            className="mt-8 rounded-2xl border border-[#30372c] bg-[#191e19] p-6 text-[#a9ada4]"
          >
            Ładowanie szkoleń...
          </div>
        )}

        {!loading && !isLoggedIn && (
          <div className="mt-8 rounded-2xl border border-[#744545] bg-[#2a1b1b] p-6 text-center sm:p-8">
            <h2 className="text-2xl font-bold text-[#e0a0a0]">
              Logowanie wymagane
            </h2>

            <p role="alert" className="mx-auto mt-3 max-w-xl text-[#e0a0a0]">
              Aby zobaczyć swoje szkolenia, musisz najpierw zalogować się na
              konto użytkownika.
            </p>

            <div className="mt-6 flex flex-col gap-3 sm:flex-row sm:justify-center">
              <a
                href="/login"
                className="inline-flex min-h-12 items-center justify-center rounded-xl bg-[#536143] px-5 py-3 font-semibold text-[#f2efe4] transition hover:bg-[#78865f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#2a1b1b]"
              >
                Zaloguj się
              </a>

              <a
                href="/register"
                className="inline-flex min-h-12 items-center justify-center rounded-xl border border-[#744545] px-5 py-3 font-semibold text-[#e0a0a0] transition hover:bg-[#382323] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#e0a0a0] focus-visible:ring-offset-2 focus-visible:ring-offset-[#2a1b1b]"
              >
                Utwórz konto
              </a>
            </div>
          </div>
        )}

        {!loading && isLoggedIn && message && (
          <div
            role={
              message.includes("anulowany") ||
              message.includes("przeniesiona") ||
              message.includes("przeniesiony")
                ? "status"
                : "alert"
            }
            className={`mt-8 ${getMessageClass(message)}`}
          >
            {message}
          </div>
        )}

        {!loading && isLoggedIn && (
          <div className="mt-8">
            <h2 className="text-2xl font-bold">Aktywne szkolenia</h2>

            {activeEvents.length === 0 ? (
              <div className="mt-4 rounded-2xl border border-[#30372c] bg-[#191e19] p-6 text-[#a9ada4]">
                Nie masz obecnie aktywnych szkoleń.
              </div>
            ) : (
              <div className="mt-4 space-y-4">
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
                  const isExpanded = expandedEventId === item.id;

                  return (
                    <article
                      key={item.id}
                      className="overflow-hidden rounded-2xl border border-[#3b4436] bg-[#191e19]"
                    >
                      <button
                        type="button"
                        onClick={() => toggleExpandedEvent(item.id)}
                        aria-expanded={isExpanded}
                        aria-controls={`event-details-${item.id}`}
                        className="block w-full p-5 text-left transition hover:bg-[#20251d] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-[#d7c895] sm:p-6"
                      >
                        <span className="flex items-start justify-between gap-4">
                          <span className="min-w-0">
                            <span className="block break-words text-lg font-bold text-[#f2efe4] sm:text-xl">
                              {event.title}
                            </span>
                            <span className="mt-2 inline-flex">
                              <span
                                className={getStatusClass(
                                  item.registration_status
                                )}
                              >
                                {translateStatus(item.registration_status)}
                              </span>
                            </span>
                          </span>

                          <span
                            aria-hidden="true"
                            className={`shrink-0 text-xl text-[#d7c895] transition-transform ${
                              isExpanded ? "rotate-180" : ""
                            }`}
                          >
                            ↓
                          </span>
                        </span>

                        <span className="mt-4 grid gap-3 text-sm sm:grid-cols-2 lg:grid-cols-4">
                          <span className="min-w-0">
                            <span className="block text-[#858c7f]">Data</span>
                            <span className="mt-1 block break-words font-semibold text-[#f2efe4]">
                              {event.event_date}
                            </span>
                          </span>

                          <span className="min-w-0">
                            <span className="block text-[#858c7f]">
                              Godzina
                            </span>
                            <span className="mt-1 block break-words font-semibold text-[#f2efe4]">
                              {event.start_time.slice(0, 5)} -{" "}
                              {event.end_time.slice(0, 5)}
                            </span>
                          </span>

                          <span className="min-w-0">
                            <span className="block text-[#858c7f]">
                              Miejsce
                            </span>
                            <span className="mt-1 block break-words font-semibold text-[#f2efe4]">
                              {event.location}
                            </span>
                          </span>

                          <span className="min-w-0">
                            <span className="block text-[#858c7f]">Cena</span>
                            <span className="mt-1 block break-words font-semibold text-[#d7c895]">
                              {Number(event.price).toFixed(0)} zł
                            </span>
                          </span>
                        </span>
                      </button>

                      {isExpanded && (
                        <div
                          id={`event-details-${item.id}`}
                          className="border-t border-[#30372c] p-5 sm:p-6"
                        >
                          <p className="whitespace-pre-line break-words leading-7 text-[#a9ada4]">
                            {event.description}
                          </p>

                          <div className="mt-5 grid gap-3 text-sm md:grid-cols-2">
                            <div className="rounded-xl border border-[#30372c] bg-[#171a17] p-4">
                              <p className="mb-1 text-[#858c7f]">Data</p>
                              <p className="break-words font-semibold text-[#f2efe4]">
                                {event.event_date}
                              </p>
                            </div>

                            <div className="rounded-xl border border-[#30372c] bg-[#171a17] p-4">
                              <p className="mb-1 text-[#858c7f]">Godzina</p>
                              <p className="break-words font-semibold text-[#f2efe4]">
                                {event.start_time.slice(0, 5)} -{" "}
                                {event.end_time.slice(0, 5)}
                              </p>
                            </div>

                            <div className="rounded-xl border border-[#30372c] bg-[#171a17] p-4">
                              <p className="mb-1 text-[#858c7f]">Miejsce</p>
                              <p className="break-words font-semibold text-[#f2efe4]">
                                {event.location}
                              </p>
                            </div>

                            <div className="rounded-xl border border-[#30372c] bg-[#171a17] p-4">
                              <p className="mb-1 text-[#858c7f]">
                                Cena / płatność
                              </p>
                              <p className="break-words font-semibold text-[#f2efe4]">
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
                                className="inline-flex min-h-12 items-center justify-center rounded-xl border border-[#744545] px-5 py-3 text-sm font-semibold text-[#e0a0a0] transition hover:bg-[#2a1b1b] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#e0a0a0] focus-visible:ring-offset-2 focus-visible:ring-offset-[#191e19] disabled:cursor-not-allowed disabled:opacity-60"
                              >
                                {processingId === item.id
                                  ? "Anulowanie..."
                                  : "Anuluj udział"}
                              </button>
                            </div>
                          )}

                          {isTooLateToCancel && (
                            <div className="mt-6 rounded-xl border border-[#806a32] bg-[#2b2618] p-4 text-sm font-semibold text-[#e1c477]">
                              Anulacja online niedostępna. Zostało mniej niż 72
                              godziny do wydarzenia — skontaktuj się
                              telefonicznie z organizatorem.
                            </div>
                          )}
                        </div>
                      )}
                    </article>
                  );
                })}
              </div>
            )}

            {eventHistory.length > 0 && (
              <section className="mt-10" aria-labelledby="event-history-heading">
                <h2
                  id="event-history-heading"
                  className="text-2xl font-bold"
                >
                  Historia szkoleń
                </h2>

                <div className="mt-4 space-y-3">
                  {eventHistory.map((item) => (
                    <article
                      key={item.id}
                      className="rounded-xl border border-[#30372c] bg-[#171a17] p-4"
                    >
                      <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
                        <div className="min-w-0">
                          <p className="text-sm text-[#858c7f]">
                            {item.events?.event_date ?? "Brak daty"}
                          </p>
                          <h3 className="break-words font-semibold text-[#f2efe4]">
                            {item.events?.title ?? "Brak danych szkolenia"}
                          </h3>
                        </div>

                        <span
                          className={`self-start rounded-full border px-3 py-1 text-xs font-semibold sm:self-auto ${getEventHistoryClass(
                            item.registration_status
                          )}`}
                        >
                          {getEventHistoryLabel(item, warsawNowKey)}
                        </span>
                      </div>
                    </article>
                  ))}
                </div>
              </section>
            )}
          </div>
        )}

        <nav
          aria-label="Nawigacja szkoleń"
          className="mt-8 flex flex-col gap-3 border-t border-[#30372c] pt-6 sm:flex-row"
        >
          <a
            href="/dashboard"
            className="inline-flex min-h-12 items-center justify-center rounded-xl border border-[#30372c] px-5 py-3 text-center text-sm font-semibold text-[#a9ada4] transition hover:border-[#536143] hover:text-[#f2efe4] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
          >
            ← Panel klienta
          </a>

          <a
            href="/events"
            className="inline-flex min-h-12 items-center justify-center rounded-xl bg-[#536143] px-5 py-3 text-center text-sm font-semibold text-[#f2efe4] transition hover:bg-[#78865f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#d7c895] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
          >
            Zobacz szkolenia
          </a>
        </nav>
      </section>
    </main>
  );
}
