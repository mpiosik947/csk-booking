"use client";

import { Suspense, useEffect, useMemo, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import AdminShell from "@/app/admin/_components/AdminShell";
import type {
  CalendarEntryType,
  CalendarEventEntry,
  CalendarFeed,
  CalendarFeedResponse,
  CalendarLane,
} from "@/lib/admin/calendar/types";
import { getWarsawCalendarDate } from "@/lib/admin/calendar/time";
import { supabase } from "@/lib/supabase";
import CalendarEvents from "./_components/CalendarEvents";
import CalendarLegend from "./_components/CalendarLegend";
import CalendarToolbar from "./_components/CalendarToolbar";
import CalendarViewSwitch from "./_components/CalendarViewSwitch";
import DayCalendar from "./_components/DayCalendar";
import WeekCalendar from "./_components/WeekCalendar";
import WeekSummary from "./_components/WeekSummary";
import {
  addCalendarDays,
  buildCalendarPageUrl,
  filterCalendarEntries,
  formatCalendarWeekRange,
  getCalendarWeekDates,
  getCalendarWeekPresentation,
  getCalendarWeekRange,
  getVisibleCalendarLanes,
  groupCalendarWeekDays,
  parseCalendarPageState,
  resolveCalendarLaneId,
  type CalendarPageState,
  type CalendarView,
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

function calendarDate(date: string) {
  const [year, month, day] = date.split("-").map(Number);
  return new Date(Date.UTC(year, month - 1, day, 12));
}

function formatSelectedDate(date: string) {
  return new Intl.DateTimeFormat("pl-PL", {
    timeZone: "Europe/Warsaw",
    weekday: "long",
    day: "numeric",
    month: "long",
    year: "numeric",
  }).format(calendarDate(date));
}

function LoadingCalendar() {
  return (
    <AdminShell eyebrow="CSK Booking" title="Kalendarz obłożenia" description="Planowanie zajętości osi, blokad i wydarzeń.">
      <div role="status" className="animate-pulse rounded-2xl border border-[#30372c] bg-[#151915] p-4 text-[#a9ada4]">Ładowanie kalendarza…</div>
    </AdminShell>
  );
}

function AdminCalendarContent() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const today = getWarsawCalendarDate();
  const pageState = parseCalendarPageState(searchParams, today);
  const { view, date, laneId } = pageState;
  const weekRange = getCalendarWeekRange(date);
  const rangeStart = view === "week" ? weekRange?.rangeStart ?? date : date;
  const rangeEnd = view === "week" ? weekRange?.rangeEnd ?? date : date;

  const [types, setTypes] = useState<CalendarEntryType[]>(DEFAULT_TYPES);
  const [includeHistoricalStatuses, setIncludeHistoricalStatuses] = useState(false);
  const [feed, setFeed] = useState<CalendarFeed | null>(null);
  const [laneOptions, setLaneOptions] = useState<CalendarLane[]>([]);
  const [viewState, setViewState] = useState<ViewState>("loading");
  const [message, setMessage] = useState("");
  const [requestVersion, setRequestVersion] = useState(0);
  const [isMobile, setIsMobile] = useState(false);

  const knownLanes = laneOptions.length > 0 ? laneOptions : feed?.lanes ?? [];
  const requestLaneId =
    knownLanes.length > 0
      ? resolveCalendarLaneId(laneId, knownLanes, view, isMobile)
      : laneId;

  function navigate(updates: Partial<CalendarPageState>) {
    router.replace(buildCalendarPageUrl({ ...pageState, ...updates }), {
      scroll: false,
    });
  }

  useEffect(() => {
    const canonicalUrl = buildCalendarPageUrl(pageState);
    const canonicalQuery = canonicalUrl.slice(canonicalUrl.indexOf("?") + 1);
    if (searchParams.toString() !== canonicalQuery) {
      router.replace(canonicalUrl, { scroll: false });
    }
  }, [pageState, router, searchParams]);

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
        rangeStart,
        rangeEnd,
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
        if (response.status === 404 && requestLaneId !== "all") {
          router.replace(
            buildCalendarPageUrl({ view, date, laneId: "all" }),
            { scroll: false }
          );
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
  }, [date, includeHistoricalStatuses, rangeEnd, rangeStart, requestLaneId, requestVersion, router, types, view]);

  const dayEntries = useMemo(
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
  const dayEvents = dayEntries.filter(
    (entry): entry is CalendarEventEntry => entry.type === "event"
  );
  const visibleLanes = feed
    ? getVisibleCalendarLanes(feed.lanes, requestLaneId)
    : [];
  const dayLaneEntries = dayEntries.filter((entry) => entry.type !== "event");
  const daySummary = feed?.dailySummaries[0] ?? null;
  const weekDates = getCalendarWeekDates(date) ?? [];
  const weekDays = feed
    ? groupCalendarWeekDays(weekDates, feed.entries, feed.dailySummaries)
    : [];
  const weekPresentation = getCalendarWeekPresentation(requestLaneId, isMobile);
  const periodLabel =
    view === "week"
      ? formatCalendarWeekRange(rangeStart, rangeEnd) ?? `${rangeStart} – ${rangeEnd}`
      : formatSelectedDate(date);

  function changePeriod(direction: -1 | 1) {
    const shifted = addCalendarDays(date, direction * (view === "week" ? 7 : 1));
    if (shifted) navigate({ date: shifted });
  }

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

  function selectDay(selectedDate: string) {
    navigate({ view: "day", date: selectedDate, laneId });
  }

  return (
    <AdminShell
      eyebrow="CSK Booking"
      title="Kalendarz obłożenia"
      description="Planowanie zajętości osi, blokad i wydarzeń."
      badge={
        view === "day" && daySummary ? (
          <span className="rounded-full border border-[#536143] bg-[#20271e] px-3 py-1.5 text-sm font-bold text-[#d7c895]">
            Obłożenie: {daySummary.occupancyPercent === null ? "—" : `${daySummary.occupancyPercent}%`}
          </span>
        ) : undefined
      }
    >
      <div className="mb-3 md:hidden">
        <CalendarViewSwitch
          view={view}
          onChange={(nextView: CalendarView) => navigate({ view: nextView })}
        />
      </div>

      <CalendarToolbar
        date={date}
        view={view}
        periodLabel={periodLabel}
        laneId={requestLaneId}
        lanes={knownLanes}
        types={types}
        includeHistoricalStatuses={includeHistoricalStatuses}
        disabled={viewState === "loading"}
        onViewChange={(nextView: CalendarView) => navigate({ view: nextView })}
        onDateChange={(nextDate) => navigate({ date: nextDate })}
        onPreviousDay={() => changePeriod(-1)}
        onNextDay={() => changePeriod(1)}
        onToday={() => navigate({ date: getWarsawCalendarDate() })}
        onLaneChange={(nextLane) => navigate({ laneId: nextLane })}
        onTypeToggle={toggleType}
        onHistoricalStatusesChange={setIncludeHistoricalStatuses}
      />

      <div className="mb-5 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <p className="text-lg font-bold text-[#f2efe4]">{periodLabel}</p>
          <p className="text-sm text-[#858c7f]">{view === "week" ? "Poniedziałek–niedziela" : `Godziny działania: ${feed?.openingStart ?? "08:00"}–${feed?.openingEnd ?? "20:00"}`}</p>
        </div>
        <CalendarLegend />
      </div>

      <div aria-live="polite" aria-atomic="true">
        {message && viewState !== "error" && <div className="mb-5 rounded-xl border border-[#806a32] bg-[#2b2618] p-3 text-sm text-[#e1c477]">{message}</div>}
        {viewState === "loading" && <div role="status" className="animate-pulse rounded-2xl border border-[#30372c] bg-[#151915] p-4"><p className="text-sm text-[#a9ada4]">Ładowanie kalendarza…</p><div className="mt-4 h-[34rem] rounded-xl bg-[#202620]" /></div>}
        {viewState === "forbidden" && <div className="rounded-2xl border border-[#806a32] bg-[#2b2618] p-6 text-[#e1c477]">Brak uprawnień do wyświetlenia kalendarza.</div>}
        {viewState === "error" && <div className="rounded-2xl border border-[#744545] bg-[#2a1b1b] p-6 text-[#e0a0a0]"><p>{message || "Nie udało się pobrać kalendarza."}</p><button type="button" onClick={() => setRequestVersion((version) => version + 1)} className="mt-4 min-h-11 rounded-xl border border-[#985d5d] px-4 py-2 font-semibold focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#e0a0a0]">Spróbuj ponownie</button></div>}

        {viewState === "ready" && feed && view === "day" && (
          <>
            <CalendarEvents events={dayEvents} />
            {feed.lanes.length === 0 ? (
              <div className="rounded-2xl border border-[#806a32] bg-[#2b2618] p-6 text-[#e1c477]">Brak osi dostępnych dla wybranego dnia i filtrów.</div>
            ) : visibleLanes.length === 0 ? (
              <div className="rounded-2xl border border-[#806a32] bg-[#2b2618] p-6 text-[#e1c477]">Wybrana oś nie jest dostępna w tym zakresie.</div>
            ) : (
              <>
                {dayLaneEntries.length === 0 && <p className="mb-3 rounded-xl border border-[#30372c] bg-[#191e19] p-3 text-sm text-[#a9ada4]">Brak wpisów dla wybranych filtrów. Siatka pokazuje wolne terminy.</p>}
                <DayCalendar lanes={visibleLanes} entries={dayLaneEntries} openingStart={feed.openingStart} openingEnd={feed.openingEnd} />
              </>
            )}
          </>
        )}

        {viewState === "ready" && feed && view === "week" && (
          <>
            {feed.lanes.length === 0 && <p className="mb-3 rounded-xl border border-[#806a32] bg-[#2b2618] p-3 text-sm text-[#e1c477]">Brak aktywnych osi. Podsumowanie tygodnia pozostaje dostępne.</p>}
            {feed.entries.length === 0 && <p className="mb-3 rounded-xl border border-[#30372c] bg-[#191e19] p-3 text-sm text-[#a9ada4]">Brak wpisów w tym tygodniu. Kalendarz pokazuje wszystkie siedem pustych dni.</p>}
            {weekPresentation === "cards" ? (
              <WeekSummary days={weekDays} laneId={requestLaneId} today={today} onSelectDay={selectDay} />
            ) : requestLaneId !== "all" ? (
              <div className="hidden md:block"><WeekCalendar days={weekDays} laneId={requestLaneId} openingStart={feed.openingStart} openingEnd={feed.openingEnd} today={today} onSelectDay={selectDay} /></div>
            ) : null}
          </>
        )}
      </div>
    </AdminShell>
  );
}

export default function AdminCalendarPage() {
  return (
    <Suspense fallback={<LoadingCalendar />}>
      <AdminCalendarContent />
    </Suspense>
  );
}
