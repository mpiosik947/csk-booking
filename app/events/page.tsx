"use client";

import { useEffect, useRef, useState } from "react";
import { supabase } from "../../lib/supabase";
import { reportClientError } from "../../lib/safe-client-error";
import {
  getPublicRegistrationAvailability,
  parsePublicEventAvailability,
  type PublicEventAvailability,
} from "../../lib/public-event-availability";
import { getEventRegistrationStatusPresentation } from "../../lib/event-registration-status";
import { hasWarsawEventStarted } from "../../lib/event-time";

type Event = PublicEventAvailability;

type RegistrationSuccess = {
  title: string;
  date: string;
  startTime: string;
  endTime: string;
  location: string;
  price: number;
  status: string;
};

type RegisterEventResponse = {
  ok: boolean;
  changed: boolean;
  code: string;
  registrationId: string;
  registrationStatus: string;
  message?: string;
};

type EventRegistrationConfirmationResponse = {
  ok: boolean;
  code: string;
};

function isRegisterEventResponse(value: unknown): value is RegisterEventResponse {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }

  const result = value as Partial<RegisterEventResponse>;

  return (
    result.ok === true &&
    typeof result.changed === "boolean" &&
    typeof result.code === "string" &&
    typeof result.registrationId === "string" &&
    typeof result.registrationStatus === "string"
  );
}

function isEventRegistrationConfirmationResponse(
  value: unknown
): value is EventRegistrationConfirmationResponse {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }

  const result = value as Partial<EventRegistrationConfirmationResponse>;

  return typeof result.ok === "boolean" && typeof result.code === "string";
}

function getAlreadyRegisteredMessage(code: string) {
  if (code === "already_registered") {
    return "Jesteś już zapisany na to szkolenie.";
  }

  if (code === "already_reserve") {
    return "Jesteś już na liście rezerwowej tego szkolenia.";
  }

  return "Masz już aktywny zapis na to szkolenie.";
}

async function fetchPublicEvents() {
  const { data, error } = await supabase.rpc(
    "get_public_event_availability_v1"
  );

  if (error) {
    return { events: null, error };
  }

  const events = parsePublicEventAvailability(data);

  return events
    ? { events, error: null }
    : { events: null, error: new Error("Invalid public event response") };
}

export default function EventsPage() {
  const [events, setEvents] = useState<Event[]>([]);
  const [selectedEventId, setSelectedEventId] = useState("");
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState(false);
  const [message, setMessage] = useState("");
  const [messageIsInformation, setMessageIsInformation] = useState(false);
  const [registrationSuccess, setRegistrationSuccess] =
    useState<RegistrationSuccess | null>(null);
  const [registrationConfirmation, setRegistrationConfirmation] = useState<{
    eventItem: Event;
    asReserve: boolean;
  } | null>(null);
  const [registeringEventId, setRegisteringEventId] = useState("");
  const registrationRequestsRef = useRef(new Set<string>());

  const [userId, setUserId] = useState("");

  useEffect(() => {
    if (!registrationSuccess) return;

    function handleKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") {
        setRegistrationSuccess(null);
      }
    }

    document.addEventListener("keydown", handleKeyDown);

    return () => {
      document.removeEventListener("keydown", handleKeyDown);
    };
  }, [registrationSuccess]);

  useEffect(() => {
    async function loadData() {
      const {
        data: { user },
      } = await supabase.auth.getUser();

      if (user) {
        setUserId(user.id);
      }

      const { events: publicEvents, error } = await fetchPublicEvents();

      setLoading(false);

      if (error) {
        reportClientError("Public events read failed", error);
        setLoadError(true);
        return;
      }

      setEvents(publicEvents ?? []);
    }

    loadData();
  }, []);

  function getEventStatus(eventItem: Event) {
    if (hasWarsawEventStarted(eventItem.event_date, eventItem.start_time)) {
      return {
        label: "Zapisy zakończone",
        className:
          "inline-flex rounded-full border border-[#343a31] bg-[#171a17] px-3 py-1 text-xs font-semibold text-[#a9ada4]",
      };
    }

    const { directlyAvailableSpots } =
      getPublicRegistrationAvailability(eventItem);

    if (eventItem.reserve_count > 0) {
      return {
        label: "Lista rezerwowa",
        className:
          "inline-flex rounded-full border border-[#806a32] bg-[#2b2618] px-3 py-1 text-xs font-semibold text-[#e1c477]",
      };
    }

    if (directlyAvailableSpots <= 0) {
      return {
        label: "Pełne",
        className:
          "inline-flex rounded-full border border-[#744545] bg-[#2a1b1b] px-3 py-1 text-xs font-semibold text-[#e0a0a0]",
      };
    }

    if (directlyAvailableSpots <= 3) {
      return {
        label: "Ostatnie miejsca",
        className:
          "inline-flex rounded-full border border-[#806a32] bg-[#2b2618] px-3 py-1 text-xs font-semibold text-[#e1c477]",
      };
    }

    return {
      label: "Wolne miejsca",
      className:
        "inline-flex rounded-full border border-[#3f6848] bg-[#1b2a1d] px-3 py-1 text-xs font-semibold text-[#a9d4ad]",
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
    setMessageIsInformation(false);

    if (!userId) {
      setMessage("Musisz być zalogowany, aby zapisać się na szkolenie.");
      return;
    }

    if (registrationRequestsRef.current.has(eventItem.id)) {
      return;
    }

    registrationRequestsRef.current.add(eventItem.id);
    setRegisteringEventId(eventItem.id);

    try {
      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (!session?.access_token) {
        setRegistrationConfirmation(null);
        setMessage("Sesja wygasła. Zaloguj się ponownie.");
        return;
      }

      const registrationResponse = await fetch("/api/register-event", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${session.access_token}`,
        },
        body: JSON.stringify({
          eventId: eventItem.id,
          asReserve,
        }),
      });

      const registrationResult: unknown = await registrationResponse
        .json()
        .catch(() => null);

      if (!registrationResponse.ok) {
        const errorMessage =
          registrationResult &&
          typeof registrationResult === "object" &&
          "error" in registrationResult &&
          typeof registrationResult.error === "string"
            ? registrationResult.error
            : "Nie udało się zapisać na szkolenie.";

        setRegistrationConfirmation(null);
        setMessage(errorMessage);
        return;
      }

      if (!isRegisterEventResponse(registrationResult)) {
        setRegistrationConfirmation(null);
        setMessage("Nie udało się potwierdzić wyniku zapisu.");
        return;
      }

      if (!registrationResult.changed) {
        setRegistrationConfirmation(null);
        setMessageIsInformation(true);
        setMessage(getAlreadyRegisteredMessage(registrationResult.code));
        return;
      }

      const registrationStatus = registrationResult.registrationStatus;

      let confirmationEmailSent = false;

      try {
        const emailResponse = await fetch(
          "/api/send-event-registration-confirmation",
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              Authorization: `Bearer ${session.access_token}`,
            },
            body: JSON.stringify({
              registrationId: registrationResult.registrationId,
            }),
          }
        );
        const emailResult: unknown = await emailResponse.json().catch(() => null);

        confirmationEmailSent =
          emailResponse.ok &&
          isEventRegistrationConfirmationResponse(emailResult) &&
          emailResult.ok === true &&
          emailResult.code === "sent";
      } catch {
        console.error("Event registration confirmation request failed");
      }

      const { events: refreshedEvents, error: refreshError } =
        await fetchPublicEvents();

      if (refreshError || !refreshedEvents) {
        reportClientError("Public event availability refresh failed", refreshError);
        setLoadError(true);
      } else {
        setEvents(refreshedEvents);
      }

      setRegistrationConfirmation(null);
      setRegistrationSuccess({
        title: eventItem.title,
        date: eventItem.event_date,
        startTime: eventItem.start_time,
        endTime: eventItem.end_time,
        location: eventItem.location,
        price: Number(eventItem.price),
        status: getEventRegistrationStatusPresentation(registrationStatus).label,
      });

      if (!confirmationEmailSent) {
        setMessage(
          "Zapis został utworzony, ale wiadomość e-mail nie została wysłana."
        );
      }
    } catch {
      reportClientError("Event registration request failed");
      setRegistrationConfirmation(null);
      setMessage("Nie udało się zapisać na szkolenie. Spróbuj ponownie.");
    } finally {
      registrationRequestsRef.current.delete(eventItem.id);
      setRegisteringEventId((currentId) =>
        currentId === eventItem.id ? "" : currentId
      );
    }
  }

  function getMessageClass(message: string) {
    if (message.includes("Zostałeś")) {
      return "mb-6 rounded-xl border border-green-800 bg-green-950 p-4 text-sm font-semibold text-green-300";
    }

    return "mb-6 rounded-xl border border-red-800 bg-red-950 p-4 text-sm font-semibold text-red-300";
  }

  function toggleSelectedEvent(eventId: string) {
    setSelectedEventId((currentId) =>
      currentId === eventId ? "" : eventId
    );
  }

  const isLoggedIn = Boolean(userId);
  const selectedEvent = events.find((event) => event.id === selectedEventId);

  function EventDetails({ event }: { event: Event }) {
    const participantsCount = event.registered_count;
    const reserveCount = event.reserve_count;
    const { directlyAvailableSpots, requiresReserveList } =
      getPublicRegistrationAvailability(event);
    const publicFreePlaces = directlyAvailableSpots;
    const isFull = requiresReserveList;
    const eventStarted = hasWarsawEventStarted(
      event.event_date,
      event.start_time
    );
    const status = getEventStatus(event);

    return (
      <div className="min-w-0">
        <span className={status.className}>{status.label}</span>

        <h2 className="mt-4 break-words text-2xl font-bold text-[#f2efe4] sm:text-3xl">
          {event.title}
        </h2>

        <div className="mt-5 grid gap-3 text-sm sm:grid-cols-2 lg:grid-cols-4">
          <div>
            <p className="text-[#858c7f]">Termin</p>
            <p className="mt-1 font-semibold text-[#d7c895]">
              {formatDate(event.event_date)} | {event.start_time.slice(0, 5)}–
              {event.end_time.slice(0, 5)}
            </p>
          </div>

          <div className="min-w-0">
            <p className="text-[#858c7f]">Miejsce</p>
            <p className="mt-1 break-words font-semibold text-[#f2efe4]">
              {event.location}
            </p>
          </div>

          <div>
            <p className="text-[#858c7f]">Koszt</p>
            <p className="mt-1 font-semibold text-[#d7c895]">
              {Number(event.price).toFixed(0)} zł
            </p>
          </div>

          <div>
            <p className="text-[#858c7f]">Miejsca</p>
            <p className="mt-1 font-semibold text-[#f2efe4]">
              {participantsCount} / {event.max_participants}
            </p>
          </div>
        </div>

        <div className="mt-5">
          <div className="rounded-xl border border-[#30372c] bg-[#141814] p-4">
            <p className="text-[#858c7f]">Wolne miejsca</p>
            <p
              className={
                isFull
                  ? "font-semibold text-[#e0a0a0]"
                  : "font-semibold text-[#a9d4ad]"
              }
            >
              {publicFreePlaces}
            </p>

            {reserveCount > 0 && (
              <p className="mt-2 text-[#e1c477]">
                Lista rezerwowa: {reserveCount}
              </p>
            )}
          </div>
        </div>

        <div className="mt-6 border-t border-[#30372c] pt-5">
          <h3 className="mb-3 text-xl font-bold text-[#f2efe4]">Opis</h3>

          <p className="whitespace-pre-line break-words leading-7 text-[#a9ada4]">
            {event.description}
          </p>
        </div>

        <div className="mt-6">
          {loading ? null : eventStarted ? (
            <div className="rounded-xl border border-[#343a31] bg-[#171a17] p-4 text-center font-semibold text-[#a9ada4]">
              Zapisy na to szkolenie są zakończone.
            </div>
          ) : !isLoggedIn ? (
            <div className="grid gap-3 sm:grid-cols-2">
              <a
                href="/login?redirectTo=%2Fevents"
                className="min-h-12 rounded-xl bg-[#536143] px-5 py-3 text-center font-semibold text-[#f2efe4] transition hover:bg-[#78865f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#191e19]"
              >
                Zaloguj się, aby się zapisać
              </a>

              <a
                href="/register"
                className="min-h-12 rounded-xl border border-[#30372c] bg-[#141814] px-5 py-3 text-center font-semibold text-[#f2efe4] transition hover:border-[#78865f] hover:bg-[#191e19] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#191e19]"
              >
                Załóż konto
              </a>
            </div>
          ) : isFull ? (
            <button
              type="button"
              disabled={registeringEventId === event.id}
              onClick={() => setRegistrationConfirmation({ eventItem: event, asReserve: true })}
              className="min-h-12 w-full rounded-xl border border-[#806a32] bg-[#2b2618] px-5 py-3 font-semibold text-[#e1c477] transition hover:bg-[#3a321f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#191e19] disabled:cursor-not-allowed disabled:opacity-60"
            >
              {registeringEventId === event.id
                ? "Zapisywanie..."
                : "Dołącz do listy rezerwowej"}
            </button>
          ) : (
            <button
              type="button"
              disabled={registeringEventId === event.id}
              onClick={() => setRegistrationConfirmation({ eventItem: event, asReserve: false })}
              className="min-h-12 w-full rounded-xl bg-[#536143] px-5 py-3 font-semibold text-[#f2efe4] transition hover:bg-[#78865f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#191e19] disabled:cursor-not-allowed disabled:opacity-60"
            >
              {registeringEventId === event.id
                ? "Zapisywanie..."
                : "Zapisz się"}
            </button>
          )}
        </div>
      </div>
    );
  }

  return (
    <main className="min-h-screen bg-[#090b09] px-4 py-6 text-[#f2efe4] sm:px-6 sm:py-8">
      <section className="mx-auto max-w-6xl rounded-[2rem] border border-[#30372c] bg-[#141814] p-5 shadow-2xl shadow-black/20 sm:p-8">
        <header className="mb-8 sm:mb-10">
          <p className="mb-3 text-xs font-semibold uppercase tracking-[0.24em] text-[#d7c895] sm:text-sm">
            CSK BOOKING
          </p>

          <h1 className="text-3xl font-bold text-[#f2efe4] sm:text-4xl">
            Eventy i szkolenia
          </h1>

          <p className="mt-3 max-w-3xl text-sm leading-6 text-[#a9ada4] sm:text-base">
            Wybierz szkolenie z listy, sprawdź szczegóły i zapisz się na
            wydarzenie albo listę rezerwową.
          </p>
        </header>

        {registrationConfirmation && (
          <div className="fixed inset-0 z-50 flex items-center justify-center overflow-y-auto bg-black/85 px-4 py-6">
            <div
              role="dialog"
              aria-modal="true"
              aria-labelledby="event-registration-confirmation-title"
              aria-describedby="event-registration-confirmation-description"
              className="max-h-[calc(100vh-3rem)] w-full max-w-xl overflow-y-auto rounded-[2rem] border border-[#30372c] bg-[#141814] p-5 text-[#f2efe4] shadow-2xl shadow-black/40 sm:p-7"
            >
              <div
                className={`mb-4 rounded-full border px-4 py-2 text-center text-sm font-bold uppercase tracking-[0.2em] ${
                  registrationConfirmation.asReserve
                    ? "border-[#806a32] bg-[#2b2618] text-[#e1c477]"
                    : "border-[#3f6848] bg-[#1b2a1d] text-[#a9d4ad]"
                }`}
              >
                Potwierdzenie zapisu
              </div>

              <h2
                id="event-registration-confirmation-title"
                className="mb-3 text-2xl font-bold text-[#f2efe4] sm:text-3xl"
              >
                Czy na pewno chcesz się zapisać?
              </h2>

              <p
                id="event-registration-confirmation-description"
                className="mb-6 leading-6 text-[#a9ada4]"
              >
                Potwierdź zapis na wybrane szkolenie. Po zapisaniu otrzymasz potwierdzenie na adres e-mail.
              </p>

              <div className="grid gap-4 rounded-2xl border border-[#30372c] bg-[#191e19] p-5 text-sm sm:grid-cols-2">
                <div className="min-w-0 sm:col-span-2">
                  <p className="text-[#858c7f]">Szkolenie</p>
                  <p className="mt-1 break-words text-lg font-semibold text-[#f2efe4]">
                    {registrationConfirmation.eventItem.title}
                  </p>
                </div>

                <div>
                  <p className="text-[#858c7f]">Data</p>
                  <p className="mt-1 text-lg font-semibold text-[#d7c895]">
                    {formatDate(registrationConfirmation.eventItem.event_date)}
                  </p>
                </div>

                <div>
                  <p className="text-[#858c7f]">Godzina</p>
                  <p className="mt-1 text-lg font-semibold text-[#f2efe4]">
                    {registrationConfirmation.eventItem.start_time.slice(0, 5)} -{" "}
                    {registrationConfirmation.eventItem.end_time.slice(0, 5)}
                  </p>
                </div>

                <div className="sm:col-span-2">
                  <p className="text-[#858c7f]">Tryb zapisu</p>
                  <p
                    className={`mt-1 text-lg font-semibold ${
                      registrationConfirmation.asReserve
                        ? "text-[#e1c477]"
                        : "text-[#a9d4ad]"
                    }`}
                  >
                    {registrationConfirmation.asReserve
                      ? "Lista rezerwowa"
                      : "Uczestnik szkolenia"}
                  </p>
                </div>
              </div>

              <div className="mt-6 grid gap-3 sm:grid-cols-2">
                <button
                  type="button"
                  disabled={
                    registeringEventId ===
                    registrationConfirmation.eventItem.id
                  }
                  onClick={() => setRegistrationConfirmation(null)}
                  className="min-h-12 w-full rounded-xl border border-[#30372c] bg-[#191e19] px-5 py-3 font-semibold text-[#a9ada4] transition hover:border-[#78865f] hover:text-[#f2efe4] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] disabled:cursor-not-allowed disabled:opacity-60"
                >
                  Wróć do szkoleń
                </button>

                <button
                  type="button"
                  disabled={
                    registeringEventId ===
                    registrationConfirmation.eventItem.id
                  }
                  onClick={() =>
                    void registerForEvent(
                      registrationConfirmation.eventItem,
                      registrationConfirmation.asReserve
                    )
                  }
                  className={`min-h-12 w-full rounded-xl px-5 py-3 font-semibold transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] disabled:cursor-not-allowed disabled:opacity-60 ${
                    registrationConfirmation.asReserve
                      ? "border border-[#806a32] bg-[#6f5a2e] text-[#f2efe4] hover:bg-[#9a7c3e]"
                      : "bg-[#536143] text-[#f2efe4] hover:bg-[#78865f]"
                  }`}
                >
                  {registeringEventId ===
                  registrationConfirmation.eventItem.id
                    ? "Zapisywanie..."
                    : "Zapisz się"}
                </button>
              </div>
            </div>
          </div>
        )}
        {registrationSuccess && (
          <div className="fixed inset-0 z-50 flex items-center justify-center overflow-y-auto bg-black/85 px-4 py-6">
            <div
              role="dialog"
              aria-modal="true"
              aria-labelledby="event-registration-success-title"
              aria-describedby="event-registration-success-description"
              className="max-h-[calc(100vh-3rem)] w-full max-w-xl overflow-y-auto rounded-[2rem] border border-[#30372c] bg-[#141814] p-5 text-[#f2efe4] shadow-2xl shadow-black/40 sm:p-7"
            >
              <div className="mb-4 rounded-full border border-[#3f6848] bg-[#1b2a1d] px-4 py-2 text-center text-sm font-bold uppercase tracking-[0.2em] text-[#a9d4ad]">
                Zapis potwierdzony
              </div>

              <h2
                id="event-registration-success-title"
                className="mb-3 text-2xl font-bold text-[#f2efe4] sm:text-3xl"
              >
                Udało się zapisać na szkolenie
              </h2>

              <p
                id="event-registration-success-description"
                className="mb-6 text-[#a9ada4]"
              >
                Poniżej znajduje się podsumowanie zapisu.
              </p>

              <div className="grid gap-4 rounded-2xl border border-[#30372c] bg-[#191e19] p-5 text-sm sm:grid-cols-2">
                <div className="min-w-0 sm:col-span-2">
                  <p className="text-[#858c7f]">Szkolenie</p>
                  <p className="mt-1 break-words text-lg font-semibold text-[#f2efe4]">
                    {registrationSuccess.title}
                  </p>
                </div>

                <div>
                  <p className="text-[#858c7f]">Data</p>
                  <p className="mt-1 text-lg font-semibold text-[#d7c895]">
                    {formatDate(registrationSuccess.date)}
                  </p>
                </div>

                <div>
                  <p className="text-[#858c7f]">Godzina</p>
                  <p className="mt-1 text-lg font-semibold text-[#f2efe4]">
                    {registrationSuccess.startTime.slice(0, 5)} -{" "}
                    {registrationSuccess.endTime.slice(0, 5)}
                  </p>
                </div>

                <div className="min-w-0 sm:col-span-2">
                  <p className="text-[#858c7f]">Miejsce</p>
                  <p className="mt-1 break-words text-lg font-semibold text-[#f2efe4]">
                    {registrationSuccess.location}
                  </p>
                </div>

                <div>
                  <p className="text-[#858c7f]">Status</p>
                  <p className="mt-1 text-lg font-semibold text-[#a9d4ad]">
                    {registrationSuccess.status}
                  </p>
                </div>

                <div>
                  <p className="text-[#858c7f]">Płatność</p>
                  <p className="mt-1 text-lg font-semibold text-[#a9d4ad]">
                    Na miejscu
                  </p>
                </div>
              </div>

              <div className="mt-6 grid gap-3">
                <button
                  type="button"
                  onClick={() => {
                    window.location.href = "/my-events";
                  }}
                  className="min-h-12 w-full rounded-xl bg-[#536143] px-5 py-3 font-semibold text-[#f2efe4] transition hover:bg-[#78865f] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
                >
                  Gotowe
                </button>
              </div>
            </div>
          </div>
        )}

        {message && (
          <div className="fixed inset-0 z-50 flex items-center justify-center overflow-y-auto bg-black/85 px-4 py-6">
            <div
              role="dialog"
              aria-modal="true"
              aria-labelledby="event-registration-error-title"
              aria-describedby="event-registration-error-description"
              className="max-h-[calc(100vh-3rem)] w-full max-w-lg overflow-y-auto rounded-[2rem] border border-[#30372c] bg-[#141814] p-5 text-[#f2efe4] shadow-2xl shadow-black/40 sm:p-7"
            >
              <div
                className={`mb-4 rounded-full border px-4 py-2 text-center text-sm font-bold uppercase tracking-[0.2em] ${
                  messageIsInformation
                    ? "border-[#806a32] bg-[#2b2618] text-[#e1c477]"
                    : "border-[#744545] bg-[#2a1b1b] text-[#e0a0a0]"
                }`}
              >
                {messageIsInformation ? "Informacja" : "Komunikat"}
              </div>

              <h2
                id="event-registration-error-title"
                className="mb-3 text-2xl font-bold text-[#f2efe4]"
              >
                {messageIsInformation
                  ? "Informacja o zapisie"
                  : "Nie można wykonać zapisu"}
              </h2>

              <p
                id="event-registration-error-description"
                role="alert"
                className={`break-words rounded-2xl border p-4 leading-6 ${
                  messageIsInformation
                    ? "border-[#806a32] bg-[#2b2618] text-[#e1c477]"
                    : "border-[#744545] bg-[#2a1b1b] text-[#e0a0a0]"
                }`}
              >
                {message}
              </p>

              <div className="mt-6 flex justify-end">
                <button
                  type="button"
                  onClick={() => {
                    setMessage("");
                    setMessageIsInformation(false);
                  }}
                  className="min-h-12 w-full rounded-xl border border-[#30372c] bg-[#191e19] px-5 py-3 font-semibold text-[#a9ada4] transition hover:border-[#78865f] hover:text-[#f2efe4] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814] sm:w-auto"
                >
                  Zamknij
                </button>
              </div>
            </div>
          </div>
        )}

        {loading && (
          <div
            role="status"
            aria-live="polite"
            className="rounded-2xl border border-[#30372c] bg-[#191e19] p-6 text-[#a9ada4]"
          >
            Ładowanie szkoleń...
          </div>
        )}

        {!loading && loadError && (
          <div
            role="alert"
            className="rounded-2xl border border-[#744545] bg-[#2a1b1b] p-6 text-[#e0a0a0]"
          >
            Nie udało się pobrać szkoleń. Spróbuj ponownie później.
          </div>
        )}

        {!loading && !loadError && events.length === 0 && (
          <div className="rounded-2xl border border-[#30372c] bg-[#191e19] p-6 text-[#a9ada4]">
            Brak dostępnych szkoleń.
          </div>
        )}

        {!loading && !loadError && events.length > 0 && (
          <section aria-labelledby="events-list-title">
            <div className="mb-5 flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
              <div>
                <h2
                  id="events-list-title"
                  className="text-2xl font-bold text-[#f2efe4]"
                >
                  Lista szkoleń
                </h2>
                <p className="mt-1 text-sm text-[#858c7f]">
                  Kliknij wybrane szkolenie, aby zobaczyć pełny opis i możliwość
                  zapisu.
                </p>
              </div>
            </div>

            <div className="grid gap-3">
              {events.map((event) => {
                const participantsCount = event.registered_count;
                const reserveCount = event.reserve_count;
                const status = getEventStatus(event);
                const isSelected = selectedEventId === event.id;
                const detailsId = `event-details-${event.id}`;
                const summaryId = `event-summary-${event.id}`;

                return (
                  <button
                    key={event.id}
                    id={summaryId}
                    type="button"
                    onClick={() => toggleSelectedEvent(event.id)}
                    aria-expanded={isSelected}
                    aria-controls={detailsId}
                    className={`min-h-12 w-full rounded-2xl border p-4 text-left transition sm:p-5 ${
                      isSelected
                        ? "border-[#78865f] bg-[#1d231c] shadow-sm shadow-black/20"
                        : "border-[#30372c] bg-[#191e19] hover:border-[#536143] hover:bg-[#1d221d]"
                    } focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]`}
                  >
                    <span className="grid min-w-0 gap-4 md:grid-cols-[minmax(0,1.5fr)_minmax(150px,0.8fr)_minmax(140px,0.8fr)_auto] md:items-center">
                      <span className="min-w-0">
                        <span
                          className={`block break-words text-lg font-bold sm:text-xl ${
                            isSelected ? "text-[#d7c895]" : "text-[#f2efe4]"
                          }`}
                        >
                          {event.title}
                        </span>
                        <span className="mt-2 block break-words text-sm text-[#a9ada4]">
                          {event.location}
                        </span>
                      </span>

                      <span className="grid gap-1 text-sm">
                        <span className="text-[#858c7f]">Termin</span>
                        <span className="font-semibold text-[#f2efe4]">
                          {formatDate(event.event_date)}
                        </span>
                        <span className="text-[#a9ada4]">
                          {event.start_time.slice(0, 5)}–
                          {event.end_time.slice(0, 5)}
                        </span>
                      </span>

                      <span className="grid gap-1 text-sm">
                        <span className="text-[#858c7f]">Koszt i miejsca</span>
                        <span className="font-semibold text-[#d7c895]">
                          {Number(event.price).toFixed(0)} zł
                        </span>
                        <span className="text-[#a9ada4]">
                          {participantsCount} / {event.max_participants}
                        </span>
                      </span>

                      <span className="flex min-w-0 items-center justify-between gap-3 md:justify-end">
                        <span className="min-w-0">
                          <span className={status.className}>
                            {status.label}
                          </span>

                          {reserveCount > 0 && (
                            <span className="mt-2 block text-xs font-semibold text-[#e1c477]">
                              Lista rezerwowa: {reserveCount}
                            </span>
                          )}
                        </span>

                        <span
                          aria-hidden="true"
                          className={`shrink-0 text-xl text-[#d7c895] transition-transform ${
                            isSelected ? "rotate-180" : ""
                          }`}
                        >
                          ↓
                        </span>
                      </span>
                    </span>
                  </button>
                );
              })}
            </div>

            {selectedEvent && (
              <section
                id={`event-details-${selectedEvent.id}`}
                aria-labelledby={`event-summary-${selectedEvent.id}`}
                className="mt-6 rounded-2xl border border-[#30372c] bg-[#191e19] p-5 sm:p-6"
              >
                <EventDetails event={selectedEvent} />
              </section>
            )}
          </section>
        )}

        <nav className="mt-8 border-t border-[#30372c] pt-5" aria-label="Nawigacja strony szkoleń">
          <a
            href="/"
            className="inline-flex min-h-11 items-center rounded-xl border border-[#30372c] bg-[#191e19] px-5 py-3 text-center text-sm font-semibold text-[#a9ada4] transition hover:border-[#78865f] hover:text-[#f2efe4] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#c5a861] focus-visible:ring-offset-2 focus-visible:ring-offset-[#141814]"
          >
            ← Powrót do strony głównej
          </a>
        </nav>
      </section>
    </main>
  );
}
