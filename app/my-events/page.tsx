"use client";

import { useEffect, useRef, useState } from "react";
import {
  EVENT_REGISTRATION_STATUS,
  getEventRegistrationStatusBadgeClass,
  getEventRegistrationStatusPresentation,
} from "../../lib/event-registration-status";
import {
  EVENT_CANCELLATION_CUTOFF_HOURS,
  formatWarsawCancellationDeadline,
  isEventCancellationBeforeCutoff,
} from "../../lib/event-time";
import { getPaymentStatusLabel } from "../../lib/payment-status";
import { supabase } from "../../lib/supabase";
import { reportClientError } from "../../lib/safe-client-error";
import {
  buildEventSearchParams,
  EVENT_LIST_PAGE_SIZE,
  parseMyEventList,
  parsePageNumber,
  type MyEventRegistration,
  type MyEventScope,
} from "../../lib/event-read-contracts";
import { AddToCalendarButton } from "../_components/AddToCalendarButton";

type EventRegistration = MyEventRegistration;

type CancellationResponse = {
  success?: boolean;
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
      getEventRegistrationStatusPresentation(item.registration_status)
        .userCanCancel &&
      eventTimeKeys.endKey > warsawNowKey
  );
}

function getEventHistoryLabel(
  item: EventRegistration,
  warsawNowKey: string | null
) {
  if (item.registration_status === EVENT_REGISTRATION_STATUS.CANCELLED) {
    return "Zapis anulowany";
  }

  const eventTimeKeys = getEventTimeKeys(item.events);

  if (
    !warsawNowKey ||
    !eventTimeKeys ||
    !getEventRegistrationStatusPresentation(item.registration_status)
      .userCanCancel ||
    eventTimeKeys.endKey > warsawNowKey
  ) {
    return "Archiwalne";
  }

  if (item.registration_status === EVENT_REGISTRATION_STATUS.RESERVE) {
    return "Lista rezerwowa — termin minął";
  }

  return "Szkolenie zakończone";
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
  if (status === EVENT_REGISTRATION_STATUS.CANCELLED) {
    return "border-[#744545] bg-[#2a1b1b] text-[#e0a0a0]";
  }

  if (status === EVENT_REGISTRATION_STATUS.RESERVE) {
    return "border-[#806a32] bg-[#2b2618] text-[#e1c477]";
  }

  return "border-[#343a31] bg-[#171a17] text-[#858c7f]";
}

export default function MyEventsPage() {
  const [items, setItems] = useState<EventRegistration[]>([]);
  const [filtersReady, setFiltersReady] = useState(false);
  const [scope, setScope] = useState<MyEventScope>("upcoming");
  const [statusFilter, setStatusFilter] = useState("");
  const [page, setPage] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState(false);
  const [reloadKey, setReloadKey] = useState(0);
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
    const applyUrl = () => {
      const params = new URLSearchParams(window.location.search);
      const parsedScope = params.get("scope") ?? "upcoming";
      const parsedStatus = params.get("status") ?? "";
      const parsedPage = parsePageNumber(params.get("page"));
      if (!(["upcoming", "history", "all"] as string[]).includes(parsedScope) ||
          !["", "registered", "approved", "reserve", "cancelled"].includes(parsedStatus) || parsedPage === null) {
        setMessage("Nieprawidłowe filtry szkoleń w adresie strony.");
        setLoading(false);
        setFiltersReady(false);
        return;
      }
      setScope(parsedScope as MyEventScope);
      setStatusFilter(parsedStatus);
      setPage(parsedPage);
      setFiltersReady(true);
    };
    applyUrl();
    window.addEventListener("popstate", applyUrl);
    return () => window.removeEventListener("popstate", applyUrl);
  }, []);

  useEffect(() => {
    if (!filtersReady) return;
    let active = true;
    async function loadMyEvents() {
      setLoading(true);
      setLoadError(false);
      const {
        data: { user },
      } = await supabase.auth.getUser();

      if (!active) return;
      if (!user) {
        setIsLoggedIn(false);
        setLoading(false);
        return;
      }

      setIsLoggedIn(true);

      const { data, error } = await supabase.rpc("get_my_event_registrations_v1", {
        p_scope: scope, p_status: statusFilter || null, p_page: page, p_page_size: EVENT_LIST_PAGE_SIZE,
      });

      if (!active) return;
      if (error) {
        reportClientError("My events read failed", error);
        setMessage("Nie udało się pobrać zapisów na szkolenia. Spróbuj ponownie.");
        setLoadError(true);
        setLoading(false);
        return;
      }

      const parsed = parseMyEventList(data);
      if (!parsed) {
        setMessage("Nie udało się poprawnie wczytać zapisów na szkolenia.");
        setLoadError(true);
        setLoading(false);
        return;
      }
      setItems(parsed.items);
      setTotalItems(parsed.total);
      setMessage("");
      setLoading(false);
    }

    void loadMyEvents();
    return () => { active = false; };
  }, [filtersReady, page, reloadKey, scope, statusFilter]);

  function updateFilters(nextScope: MyEventScope, nextStatus: string, nextPage = 1) {
    const params = buildEventSearchParams({ scope: nextScope === "upcoming" ? null : nextScope, status: nextStatus, page: nextPage });
    const query = params.toString();
    window.history.pushState(null, "", `${window.location.pathname}${query ? `?${query}` : ""}`);
    setScope(nextScope);
    setStatusFilter(nextStatus);
    setPage(nextPage);
  }

  async function cancelRegistration(item: EventRegistration) {
    if (cancellingRegistrationIds.current.has(item.id)) {
      return;
    }

    setMessage("");

    if (!item.events) {
      setMessage("Brak danych szkolenia.");
      return;
    }

    if (
      !getEventRegistrationStatusPresentation(item.registration_status)
        .userCanCancel ||
      !isEventCancellationBeforeCutoff(
        item.events.event_date,
        item.events.start_time
      )
    ) {
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
          response.status === 409
            ? "Zapis można anulować najpóźniej 72 godziny przed rozpoczęciem szkolenia."
            : "Nie udało się anulować udziału w szkoleniu."
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

      setMessage("Udział jest anulowany.");
    } catch {
      setMessage("Nie udało się anulować udziału w szkoleniu. Spróbuj ponownie.");
    } finally {
      cancellingRegistrationIds.current.delete(item.id);
      setProcessingId("");
    }
  }

  const now = new Date();
  const warsawNowKey = getWarsawDateTimeKey(now);
  const activeEvents = (scope === "upcoming" || scope === "all" ? items : [])
    .filter((item) => isActiveEventRegistration(item, warsawNowKey))
    .sort((firstItem, secondItem) => {
      const firstStartKey = getEventTimeKeys(firstItem.events)?.startKey ?? "";
      const secondStartKey = getEventTimeKeys(secondItem.events)?.startKey ?? "";

      return firstStartKey.localeCompare(secondStartKey);
    });
  const eventHistory = (scope === "history" || scope === "all" ? items : [])
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

        <section className="mt-6 grid gap-4 rounded-2xl border border-[#30372c] bg-[#191e19] p-4 sm:grid-cols-2" aria-label="Filtry moich szkoleń">
          <div>
            <label htmlFor="my-events-scope" className="mb-2 block text-sm font-semibold">Zakres</label>
            <select id="my-events-scope" value={scope} onChange={(event) => updateFilters(event.target.value as MyEventScope, statusFilter, 1)} className="min-h-11 w-full rounded-xl border border-[#3b4237] bg-[#090b09] px-4 py-3">
              <option value="upcoming">Nadchodzące</option><option value="history">Historia</option><option value="all">Wszystkie</option>
            </select>
          </div>
          <div>
            <label htmlFor="my-events-status" className="mb-2 block text-sm font-semibold">Status</label>
            <select id="my-events-status" value={statusFilter} onChange={(event) => updateFilters(scope, event.target.value, 1)} className="min-h-11 w-full rounded-xl border border-[#3b4237] bg-[#090b09] px-4 py-3">
              <option value="">Wszystkie statusy</option><option value="registered">Zapisany</option><option value="approved">Zatwierdzony</option><option value="reserve">Lista rezerwowa</option><option value="cancelled">Anulowany</option>
            </select>
          </div>
        </section>

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
            {loadError && (
              <button
                type="button"
                onClick={() => setReloadKey((current) => current + 1)}
                className="mt-4 min-h-12 w-full rounded-xl border border-[#a45f5f] px-5 py-3 font-semibold transition hover:bg-[#382323] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#e0a0a0] sm:w-auto"
              >
                Spróbuj ponownie
              </button>
            )}
          </div>
        )}

        {!loading && isLoggedIn && (
          <div className="mt-8">
            {scope !== "history" && (
              <>
            <h2 className="text-2xl font-bold">
              {scope === "all" ? "Nadchodzące szkolenia" : "Aktywne szkolenia"}
            </h2>

            {activeEvents.length === 0 ? (
              <div className="mt-4 rounded-2xl border border-[#30372c] bg-[#191e19] p-6 text-[#a9ada4]">
                {statusFilter
                  ? "Brak szkoleń o wybranym statusie w tym zakresie."
                  : "Nie masz obecnie aktywnych szkoleń."}
              </div>
            ) : (
              <div className="mt-4 space-y-4">
                {activeEvents.map((item) => {
                  const event = item.events;

                  if (!event) {
                    return null;
                  }

                  const hasCancellableStatus =
                    getEventRegistrationStatusPresentation(
                      item.registration_status
                    ).userCanCancel;
                  const cancellationDeadline = hasCancellableStatus
                    ? formatWarsawCancellationDeadline(
                        event.event_date,
                        event.start_time,
                        EVENT_CANCELLATION_CUTOFF_HOURS
                      )
                    : null;
                  const canCancel = Boolean(
                    hasCancellableStatus &&
                      cancellationDeadline &&
                      isEventCancellationBeforeCutoff(
                        event.event_date,
                        event.start_time,
                        now
                      )
                  );
                  const isTooLateToCancel = Boolean(
                    hasCancellableStatus && cancellationDeadline && !canCancel
                  );
                  const isExpanded = expandedEventId === item.id;
                  const canAddToCalendar =
                    item.registration_status ===
                      EVENT_REGISTRATION_STATUS.REGISTERED ||
                    item.registration_status ===
                      EVENT_REGISTRATION_STATUS.APPROVED;

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
                                className={getEventRegistrationStatusBadgeClass(
                                  item.registration_status
                                )}
                              >
                                {
                                  getEventRegistrationStatusPresentation(
                                    item.registration_status
                                  ).label
                                }
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

                          {canCancel && cancellationDeadline && (
                            <div className="mt-6 break-words rounded-xl border border-[#806a32] bg-[#2b2618] p-4 text-sm font-semibold text-[#e1c477]">
                              Samodzielne anulowanie możliwe do: {cancellationDeadline}.
                            </div>
                          )}

                          {(canAddToCalendar || canCancel) && (
                            <div className="mt-6 flex flex-wrap items-start gap-3">
                              {canAddToCalendar && (
                                <AddToCalendarButton
                                  endpoint={`/api/calendar/event-registrations/${item.id}`}
                                  filename="csk-szkolenie.ics"
                                />
                              )}

                              {canCancel && (
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
                              )}
                            </div>
                          )}

                          {isTooLateToCancel && (
                            <div className="mt-6 break-words rounded-xl border border-[#806a32] bg-[#2b2618] p-4 text-sm font-semibold text-[#e1c477]">
                              Termin samodzielnego anulowania minął ({cancellationDeadline}).
                              Skontaktuj się telefonicznie z organizatorem.
                            </div>
                          )}
                        </div>
                      )}
                    </article>
                  );
                })}
              </div>
            )}
              </>
            )}

            {(scope === "history" || eventHistory.length > 0) && (
              <section className="mt-10" aria-labelledby="event-history-heading">
                <h2
                  id="event-history-heading"
                  className="text-2xl font-bold"
                >
                  Historia szkoleń
                </h2>

                {eventHistory.length === 0 ? (
                  <div className="mt-4 rounded-2xl border border-[#30372c] bg-[#191e19] p-6 text-[#a9ada4]">
                    {statusFilter
                      ? "Brak historycznych szkoleń o wybranym statusie."
                      : "Historia szkoleń jest pusta."}
                  </div>
                ) : (
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
                )}
              </section>
            )}

            {!loading && isLoggedIn && (
              <nav className="mt-8 grid grid-cols-2 gap-3 sm:flex sm:flex-wrap sm:items-center sm:justify-between" aria-label="Stronicowanie moich szkoleń">
                <span className="col-span-2 text-center text-sm text-[#a9ada4] sm:order-2">Strona {page} z {Math.max(1,Math.ceil(totalItems/EVENT_LIST_PAGE_SIZE))} · {totalItems} zapisów</span>
                <button type="button" disabled={page<=1} onClick={() => updateFilters(scope,statusFilter,page-1)} className="min-h-12 w-full rounded-xl border border-[#495044] px-4 py-2 font-semibold disabled:opacity-50 sm:order-1 sm:w-auto">Poprzednia</button>
                <button type="button" disabled={page*EVENT_LIST_PAGE_SIZE>=totalItems} onClick={() => updateFilters(scope,statusFilter,page+1)} className="min-h-12 w-full rounded-xl border border-[#495044] px-4 py-2 font-semibold disabled:opacity-50 sm:order-3 sm:w-auto">Następna</button>
              </nav>
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
