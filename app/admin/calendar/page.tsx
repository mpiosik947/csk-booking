"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import AdminShell from "@/app/admin/_components/AdminShell";
import type {
  CalendarEntryType,
  CalendarEventEntry,
  CalendarFeed,
  CalendarFeedResponse,
  CalendarLane,
} from "@/lib/admin/calendar/types";
import {
  getWarsawCalendarDate,
  isValidCalendarDate,
} from "@/lib/admin/calendar/time";
import { supabase } from "@/lib/supabase";
import CalendarEvents from "./_components/CalendarEvents";
import CalendarLegend from "./_components/CalendarLegend";
import CalendarToolbar from "./_components/CalendarToolbar";
import DayCalendar from "./_components/DayCalendar";
import {
  addCalendarDays,
  filterCalendarEntries,
  getVisibleCalendarLanes,
} from "./calendar-ui";

type ViewState = "loading" | "ready" | "error" | "forbidden";

const DEFAULT_TYPES: CalendarEntryType[] = [
  "reservation",
  "lane_block",
  "event",
];

function isCalendarFeed(value: unknown): value is CalendarFeed {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const candidate = value as Partial<CalendarFeed>;
  return (
    candidate.ok === true &&
    Array.isArray(candidate.lanes) &&
    Array.isArray(candidate.entries) &&
    Array.isArray(candidate.dailySummaries) &&
    typeof candidate.openingStart === "string" &&
    typeof candidate.openingEnd === "string"
  );
}

function formatSelectedDate(date: string) {
  const [year, month, day] = date.split("-").map(Number);
  if (!year || !month || !day) return date;
  return new Intl.DateTimeFormat("pl-PL", {
    timeZone: "Europe/Warsaw",
    weekday: "long",
    day: "numeric",
    month: "long",
    year: "numeric",
  }).format(new Date(Date.UTC(year, month - 1, day, 12)));
}

export default function AdminCalendarPage() {
  const router = useRouter();
  const [date, setDate] = useState(() => getWarsawCalendarDate());
  const [laneId, setLaneId] = useState<string | "all">("all");
  const [types, setTypes] = useState<CalendarEntryType[]>(DEFAULT_TYPES);
  const [includeHistoricalStatuses, setIncludeHistoricalStatuses] =
    useState(false);
  const [feed, setFeed] = useState<CalendarFeed | null>(null);
  const [laneOptions, setLaneOptions] = useState<CalendarLane[]>([]);
  const [viewState, setViewState] = useState<ViewState>("loading");
  const [message, setMessage] = useState("");
  const [requestVersion, setRequestVersion] = useState(0);
  const [isMobile, setIsMobile] = useState(false);
  const knownLanes = laneOptions.length > 0 ? laneOptions : feed?.lanes ?? [];
  const firstMobileLane =
    knownLanes.find((lane) => lane.isActive) ?? knownLanes[0];
  const requestLaneId =
    isMobile && laneId === "all" && firstMobileLane
      ? firstMobileLane.id
      : laneId;

  useEffect(() => {
    const media = window.matchMedia("(max-width: 767px)");
    const update = () => setIsMobile(media.matches);
    update();
    media.addEventListener("change", update);
    return () => media.removeEventListener("change", update);
  }, []);

  useEffect(() => {
    const controller = new AbortController();

    async function loadFeed() {
      setViewState("loading");
      setMessage("");

      const {
        data: { session },
        error: sessionError,
      } = await supabase.auth.getSession();

      if (controller.signal.aborted) return;
      if (sessionError || !session?.access_token) {
        router.replace("/login?redirectTo=%2Fadmin%2Fcalendar");
        return;
      }

      const params = new URLSearchParams({
        rangeStart: date,
        rangeEnd: date,
        laneId: requestLaneId,
        types: types.join(","),
        includeHistoricalStatuses: String(includeHistoricalStatuses),
      });

      try {
        const response = await fetch(`/api/admin/calendar-feed?${params}`, {
          headers: { Authorization: `Bearer ${session.access_token}` },
          cache: "no-store",
          signal: controller.signal,
        });

        if (controller.signal.aborted) return;
        if (response.status === 401) {
          router.replace("/login?redirectTo=%2Fadmin%2Fcalendar");
          return;
        }
        if (response.status === 403) {
          setViewState("forbidden");
          return;
        }

        const body: CalendarFeedResponse | unknown = await response.json();
        if (!response.ok || !isCalendarFeed(body)) {
          setViewState("error");
          setMessage("Nie udało się pobrać kalendarza.");
          return;
        }

        setFeed(body);
        if (requestLaneId === "all") setLaneOptions(body.lanes);
        setViewState("ready");
      } catch (error) {
        if (controller.signal.aborted) return;
        console.error("Calendar feed request failed", {
          name: error instanceof Error ? error.name : "unknown",
        });
        setViewState("error");
        setMessage("Nie udało się pobrać kalendarza.");
      }
    }

    loadFeed();
    return () => controller.abort();
  }, [date, includeHistoricalStatuses, requestLaneId, requestVersion, router, types]);

  const visibleEntries = useMemo(
    () =>
      feed
        ? filterCalendarEntries(feed.entries, {
            date,
            laneId: requestLaneId,
            types,
            includeHistoricalStatuses,
          })
        : [],
    [date, feed, includeHistoricalStatuses, requestLaneId, types]
  );
  const events = visibleEntries.filter(
    (entry): entry is CalendarEventEntry => entry.type === "event"
  );
  const visibleLanes = feed
    ? getVisibleCalendarLanes(feed.lanes, requestLaneId)
    : [];
  const laneEntries = visibleEntries.filter((entry) => entry.type !== "event");
  const summary = feed?.dailySummaries[0] ?? null;

  const changeDay = useCallback(
    (days: number) => {
      const nextDate = addCalendarDays(date, days);
      if (nextDate) setDate(nextDate);
    },
    [date]
  );

  function toggleType(type: CalendarEntryType) {
    setMessage("");
    setTypes((current) => {
      if (!current.includes(type)) return [...current, type];
      if (current.length === 1) {
        setMessage("Pozostaw co najmniej jeden widoczny typ wpisu.");
        return current;
      }
      return current.filter((item) => item !== type);
    });
  }

  function updateDate(nextDate: string) {
    if (isValidCalendarDate(nextDate)) setDate(nextDate);
  }

  return (
    <AdminShell
      eyebrow="CSK Booking"
      title="Kalendarz obłożenia"
      description="Planowanie zajętości osi, blokad i wydarzeń."
      badge={
        summary ? (
          <span className="rounded-full border border-[#536143] bg-[#20271e] px-3 py-1.5 text-sm font-bold text-[#d7c895]">
            Obłożenie: {summary.occupancyPercent === null ? "—" : `${summary.occupancyPercent}%`}
          </span>
        ) : undefined
      }
    >
      <CalendarToolbar
        date={date}
        laneId={requestLaneId}
        lanes={knownLanes}
        types={types}
        includeHistoricalStatuses={includeHistoricalStatuses}
        disabled={viewState === "loading"}
        onDateChange={updateDate}
        onPreviousDay={() => changeDay(-1)}
        onNextDay={() => changeDay(1)}
        onToday={() => setDate(getWarsawCalendarDate())}
        onLaneChange={setLaneId}
        onTypeToggle={toggleType}
        onHistoricalStatusesChange={setIncludeHistoricalStatuses}
      />

      <div className="mb-5 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <p className="text-lg font-bold capitalize text-[#f2efe4]">{formatSelectedDate(date)}</p>
          <p className="text-sm text-[#858c7f]">Godziny działania: {feed?.openingStart ?? "08:00"}–{feed?.openingEnd ?? "20:00"}</p>
        </div>
        <CalendarLegend />
      </div>

      <div aria-live="polite" aria-atomic="true">
        {message && viewState !== "error" && (
          <div className="mb-5 rounded-xl border border-[#806a32] bg-[#2b2618] p-3 text-sm text-[#e1c477]">
            {message}
          </div>
        )}

        {viewState === "loading" && (
          <div role="status" className="animate-pulse rounded-2xl border border-[#30372c] bg-[#151915] p-4">
            <p className="text-sm text-[#a9ada4]">Ładowanie kalendarza…</p>
            <div className="mt-4 h-[34rem] rounded-xl bg-[#202620]" />
          </div>
        )}

        {viewState === "forbidden" && (
          <div className="rounded-2xl border border-[#806a32] bg-[#2b2618] p-6 text-[#e1c477]">
            Brak uprawnień do wyświetlenia kalendarza.
          </div>
        )}

        {viewState === "error" && (
          <div className="rounded-2xl border border-[#744545] bg-[#2a1b1b] p-6 text-[#e0a0a0]">
            <p>{message || "Nie udało się pobrać kalendarza."}</p>
            <button
              type="button"
              onClick={() => setRequestVersion((version) => version + 1)}
              className="mt-4 min-h-11 rounded-xl border border-[#985d5d] px-4 py-2 font-semibold focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#e0a0a0]"
            >
              Spróbuj ponownie
            </button>
          </div>
        )}

        {viewState === "ready" && feed && (
          <>
            <CalendarEvents events={events} />

            {feed.lanes.length === 0 ? (
              <div className="rounded-2xl border border-[#806a32] bg-[#2b2618] p-6 text-[#e1c477]">
                Brak osi dostępnych dla wybranego dnia i filtrów.
              </div>
            ) : visibleLanes.length === 0 ? (
              <div className="rounded-2xl border border-[#806a32] bg-[#2b2618] p-6 text-[#e1c477]">
                Wybrana oś nie jest dostępna w tym zakresie.
              </div>
            ) : (
              <>
                {laneEntries.length === 0 && (
                  <p className="mb-3 rounded-xl border border-[#30372c] bg-[#191e19] p-3 text-sm text-[#a9ada4]">
                    Brak wpisów dla wybranych filtrów. Siatka pokazuje wolne terminy.
                  </p>
                )}
                <DayCalendar
                  lanes={visibleLanes}
                  entries={laneEntries}
                  openingStart={feed.openingStart}
                  openingEnd={feed.openingEnd}
                />
              </>
            )}
          </>
        )}
      </div>
    </AdminShell>
  );
}
