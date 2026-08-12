import type {
  CalendarDaySummary,
  CalendarEntry,
  CalendarEntryResource,
  CalendarEntryType,
  CalendarLane,
  CalendarLaneOccupyingEntry,
} from "@/lib/admin/calendar/types";
import {
  calendarTimeToMinutes,
  clipCalendarTimeRange,
  countCalendarDaysInclusive,
  isValidCalendarDate,
} from "@/lib/admin/calendar/time";

export const CALENDAR_HOUR_HEIGHT = 72;
export type CalendarView = "day" | "week" | "month";

export type CalendarPageState = {
  view: CalendarView;
  date: string;
  laneId: string | "all";
};

export type CalendarWeekDay = {
  date: string;
  summary: CalendarDaySummary;
  entries: CalendarEntry[];
};

export type CalendarMonthDay = {
  date: string;
  summary: CalendarDaySummary;
};

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export type CalendarEntryGeometry = {
  top: number;
  height: number;
  isClipped: boolean;
};

export type CalendarPositionedEntry = {
  entry: CalendarLaneOccupyingEntry;
  geometry: CalendarEntryGeometry;
  columnIndex: number;
  columnCount: number;
};

export type CalendarLaneFamily = {
  id: string;
  displayName: string;
  resources: CalendarLane[];
};

function isCalendarLaneEntry(
  entry: CalendarEntry
): entry is CalendarLaneOccupyingEntry {
  return entry.type !== "event" || entry.isLaneProjection;
}

export type CalendarUiFilters = {
  date: string;
  laneId: string | "all";
  types: CalendarEntryType[];
  includeHistoricalStatuses: boolean;
};

export type CalendarPreviewRole = "admin" | "pracownik" | "instruktor";

export type CalendarEntryPreviewData =
  | {
      type: "reservation";
      title: "Rezerwacja";
      time: string;
      laneName: string;
      resource: CalendarEntryResource | null;
      label: string;
      shootersCount: number;
      isHistorical: boolean;
    }
  | {
      type: "lane_block";
      title: "Blokada osi";
      time: string;
      laneName: string;
      resource: CalendarEntryResource | null;
      reason: string | null;
      isHistorical: boolean;
    }
  | {
      type: "event";
      title: "Wydarzenie";
      date: string;
      time: string;
      label: string;
      location: string | null;
      laneName: string | null;
      resources: CalendarEntryResource[];
      maxParticipants: number;
    };

export type CalendarEntryPreviewNavigation = {
  href: "/admin/reservations" | "/admin/lane-blocks" | "/admin/events";
  label: "Otwórz rezerwacje" | "Otwórz blokady" | "Otwórz eventy";
};

export function parseCalendarPreviewRole(
  value: unknown
): CalendarPreviewRole | null {
  return value === "admin" || value === "pracownik" || value === "instruktor"
    ? value
    : null;
}

export function getCalendarEntryPreviewData(
  entry: CalendarEntry
): CalendarEntryPreviewData {
  const time = `${entry.startTime}–${entry.endTime}`;
  if (entry.type === "reservation") {
    return {
      type: entry.type,
      title: "Rezerwacja",
      time,
      laneName: entry.laneName,
      resource: entry.laneResource,
      label: entry.label,
      shootersCount: entry.shootersCount,
      isHistorical: entry.isHistorical,
    };
  }
  if (entry.type === "lane_block") {
    return {
      type: entry.type,
      title: "Blokada osi",
      time,
      laneName: entry.laneName,
      resource: entry.laneResource,
      reason: entry.reason,
      isHistorical: entry.isHistorical,
    };
  }
  return {
    type: entry.type,
    title: "Wydarzenie",
    date: entry.date,
    time,
    label: entry.label,
    location: entry.location,
    laneName: entry.laneName,
    resources: entry.resources,
    maxParticipants: entry.maxParticipants,
  };
}

export function getCalendarEntryPreviewNavigation(
  entryType: string,
  role: CalendarPreviewRole | null
): CalendarEntryPreviewNavigation | null {
  if (role === null) return null;
  if (entryType === "event") {
    return { href: "/admin/events", label: "Otwórz eventy" };
  }
  if (role !== "admin" && role !== "pracownik") return null;
  if (entryType === "reservation") {
    return { href: "/admin/reservations", label: "Otwórz rezerwacje" };
  }
  if (entryType === "lane_block") {
    return { href: "/admin/lane-blocks", label: "Otwórz blokady" };
  }
  return null;
}

export function addCalendarDays(date: string, days: number) {
  if (!isValidCalendarDate(date) || !Number.isInteger(days)) return null;
  const [year, month, day] = date.split("-").map(Number);
  const shifted = new Date(Date.UTC(year, month - 1, day + days));
  return `${shifted.getUTCFullYear()}-${String(shifted.getUTCMonth() + 1).padStart(
    2,
    "0"
  )}-${String(shifted.getUTCDate()).padStart(2, "0")}`;
}

export function getCalendarWeekRange(anchorDate: string) {
  if (!isValidCalendarDate(anchorDate)) return null;
  const [year, month, day] = anchorDate.split("-").map(Number);
  const weekday = new Date(Date.UTC(year, month - 1, day)).getUTCDay();
  const mondayOffset = weekday === 0 ? -6 : 1 - weekday;
  const rangeStart = addCalendarDays(anchorDate, mondayOffset);
  const rangeEnd = rangeStart ? addCalendarDays(rangeStart, 6) : null;
  return rangeStart && rangeEnd ? { rangeStart, rangeEnd } : null;
}

export function getCalendarWeekDates(anchorDate: string) {
  const range = getCalendarWeekRange(anchorDate);
  if (!range) return null;
  return Array.from({ length: 7 }, (_, index) =>
    addCalendarDays(range.rangeStart, index)
  ).filter((date): date is string => date !== null);
}

export function getCalendarMonthRange(anchorDate: string) {
  if (!isValidCalendarDate(anchorDate)) return null;
  const [year, month] = anchorDate.split("-").map(Number);
  const monthStart = `${year}-${String(month).padStart(2, "0")}-01`;
  const lastDay = new Date(Date.UTC(year, month, 0)).getUTCDate();
  const monthEnd = `${year}-${String(month).padStart(2, "0")}-${String(
    lastDay
  ).padStart(2, "0")}`;
  const firstWeek = getCalendarWeekRange(monthStart);
  const lastWeek = getCalendarWeekRange(monthEnd);
  if (!firstWeek || !lastWeek) return null;
  const naturalDays = countCalendarDaysInclusive(
    firstWeek.rangeStart,
    lastWeek.rangeEnd
  );
  if (naturalDays === null) return null;
  const dayCount = naturalDays <= 35 ? 35 : 42;
  const rangeStart = firstWeek.rangeStart;
  const rangeEnd = addCalendarDays(rangeStart, dayCount - 1);
  if (!rangeEnd) return null;
  return { monthStart, monthEnd, rangeStart, rangeEnd, dayCount };
}

export function getCalendarMonthDates(anchorDate: string) {
  const range = getCalendarMonthRange(anchorDate);
  if (!range) return null;
  return Array.from({ length: range.dayCount }, (_, index) =>
    addCalendarDays(range.rangeStart, index)
  ).filter((date): date is string => date !== null);
}

export function addCalendarMonths(date: string, months: number) {
  if (!isValidCalendarDate(date) || !Number.isInteger(months)) return null;
  const [year, month, day] = date.split("-").map(Number);
  const target = new Date(Date.UTC(year, month - 1 + months, 1));
  const targetYear = target.getUTCFullYear();
  const targetMonth = target.getUTCMonth() + 1;
  const targetLastDay = new Date(
    Date.UTC(targetYear, targetMonth, 0)
  ).getUTCDate();
  return `${targetYear}-${String(targetMonth).padStart(2, "0")}-${String(
    Math.min(day, targetLastDay)
  ).padStart(2, "0")}`;
}

export function formatCalendarMonth(anchorDate: string) {
  if (!isValidCalendarDate(anchorDate)) return null;
  const [year, month] = anchorDate.split("-").map(Number);
  return new Intl.DateTimeFormat("pl-PL", {
    timeZone: "Europe/Warsaw",
    month: "long",
    year: "numeric",
  })
    .format(new Date(Date.UTC(year, month - 1, 1, 12)))
    .toLocaleLowerCase("pl-PL");
}

export function formatCalendarWeekRange(
  rangeStart: string,
  rangeEnd: string
) {
  if (!isValidCalendarDate(rangeStart) || !isValidCalendarDate(rangeEnd)) {
    return null;
  }
  const toDate = (value: string) => {
    const [year, month, day] = value.split("-").map(Number);
    return new Date(Date.UTC(year, month - 1, day, 12));
  };
  const start = toDate(rangeStart);
  const end = toDate(rangeEnd);
  const format = (
    date: Date,
    options: Intl.DateTimeFormatOptions
  ) =>
    new Intl.DateTimeFormat("pl-PL", {
      timeZone: "Europe/Warsaw",
      ...options,
    })
      .format(date)
      .toLocaleLowerCase("pl-PL");
  const sameYear = start.getUTCFullYear() === end.getUTCFullYear();
  const sameMonth =
    sameYear && start.getUTCMonth() === end.getUTCMonth();

  if (sameMonth) {
    return `${format(start, { day: "numeric" })}–${format(end, {
      day: "numeric",
      month: "long",
      year: "numeric",
    })}`;
  }

  return `${format(start, {
    day: "numeric",
    month: "long",
    year: sameYear ? undefined : "numeric",
  })} – ${format(end, {
    day: "numeric",
    month: "long",
    year: "numeric",
  })}`;
}

export function parseCalendarPageState(
  params: URLSearchParams,
  today: string
): CalendarPageState {
  const requestedView = params.get("view");
  const requestedDate = params.get("date");
  const requestedLane = params.get("lane");
  return {
    view:
      requestedView === "week" || requestedView === "month"
        ? requestedView
        : "day",
    date:
      requestedDate && isValidCalendarDate(requestedDate)
        ? requestedDate
        : today,
    laneId:
      requestedLane === "all" ||
      (requestedLane !== null && UUID_PATTERN.test(requestedLane))
        ? requestedLane
        : "all",
  };
}

export function buildCalendarPageUrl(state: CalendarPageState) {
  const params = new URLSearchParams({
    view: state.view,
    date: state.date,
    lane: state.laneId,
  });
  return `/admin/calendar?${params.toString()}`;
}

export function getCalendarWeekPresentation(
  laneId: string | "all",
  isMobile: boolean
) {
  return isMobile || laneId === "all" ? "cards" : "grid";
}

export function resolveCalendarLaneId(
  requestedLaneId: string | "all",
  lanes: CalendarLane[],
  view: CalendarView,
  isMobile: boolean
) {
  if (
    requestedLaneId !== "all" &&
    lanes.some((lane) => lane.id === requestedLaneId)
  ) {
    return requestedLaneId;
  }
  const firstLane = lanes.find((lane) => lane.isActive) ?? lanes[0];
  if (view === "day" && isMobile && firstLane) return firstLane.id;
  return "all";
}

export function groupCalendarWeekDays(
  dates: string[],
  entries: CalendarEntry[],
  summaries: CalendarDaySummary[]
): CalendarWeekDay[] {
  const summaryMap = new Map(summaries.map((summary) => [summary.date, summary]));
  return dates.map((date) => ({
    date,
    summary:
      summaryMap.get(date) ?? {
        date,
        reservationCount: 0,
        blockCount: 0,
        eventCount: 0,
        availableMinutes: 0,
        occupiedMinutes: 0,
        occupancyPercent: null,
        isFull: false,
        flags: [],
      },
    entries: entries
      .filter((entry) => entry.date === date)
      .sort(
        (first, second) =>
          first.startTime.localeCompare(second.startTime) ||
          first.endTime.localeCompare(second.endTime) ||
          first.id.localeCompare(second.id)
      ),
  }));
}

export function groupCalendarMonthDays(
  dates: string[],
  summaries: CalendarDaySummary[]
): CalendarMonthDay[] {
  const summaryMap = new Map(summaries.map((summary) => [summary.date, summary]));
  return dates.map((date) => ({
    date,
    summary:
      summaryMap.get(date) ?? {
        date,
        reservationCount: 0,
        blockCount: 0,
        eventCount: 0,
        availableMinutes: 0,
        occupiedMinutes: 0,
        occupancyPercent: null,
        isFull: false,
        flags: [],
      },
  }));
}

export function getCalendarEntryGeometry(
  entry: Pick<CalendarEntry, "startTime" | "endTime">,
  openingStart: string,
  openingEnd: string,
  hourHeight = CALENDAR_HOUR_HEIGHT
): CalendarEntryGeometry | null {
  const clipped = clipCalendarTimeRange(entry, openingStart, openingEnd);
  const originalStart = calendarTimeToMinutes(entry.startTime);
  const originalEnd = calendarTimeToMinutes(entry.endTime);
  const clippedStart = clipped
    ? calendarTimeToMinutes(clipped.startTime)
    : null;
  const clippedEnd = clipped ? calendarTimeToMinutes(clipped.endTime) : null;
  const openingStartMinutes = calendarTimeToMinutes(openingStart);

  if (
    !clipped ||
    originalStart === null ||
    originalEnd === null ||
    clippedStart === null ||
    clippedEnd === null ||
    openingStartMinutes === null
  ) {
    return null;
  }

  return {
    top: ((clippedStart - openingStartMinutes) / 60) * hourHeight,
    height: ((clippedEnd - clippedStart) / 60) * hourHeight,
    isClipped: originalStart !== clippedStart || originalEnd !== clippedEnd,
  };
}

export function filterCalendarEntries(
  entries: CalendarEntry[],
  filters: CalendarUiFilters
) {
  const visibleTypes = new Set(filters.types);
  return entries.filter((entry) => {
    if (entry.date !== filters.date || !visibleTypes.has(entry.type)) return false;
    if (!filters.includeHistoricalStatuses && entry.isHistorical) return false;
    if (entry.type === "event") {
      return !entry.isLaneProjection || filters.laneId === "all" || entry.laneId === filters.laneId;
    }
    return filters.laneId === "all" || entry.laneId === filters.laneId;
  });
}

export function getVisibleCalendarLanes(
  lanes: CalendarLane[],
  laneId: string | "all"
) {
  return laneId === "all" ? lanes : lanes.filter((lane) => lane.id === laneId);
}

export function getCalendarLaneFamilies(
  lanes: CalendarLane[]
): CalendarLaneFamily[] | null {
  const families = new Map<string, CalendarLaneFamily>();

  for (const lane of lanes) {
    if (
      lane.isPosition &&
      (!lane.parentLaneId || !lane.parentName || lane.depth !== 1)
    ) {
      return null;
    }
    if (!lane.isPosition && (lane.parentLaneId !== null || lane.depth !== 0)) {
      return null;
    }

    const familyId = lane.parentLaneId ?? lane.id;
    const displayName = lane.parentName ?? lane.displayName;
    const family = families.get(familyId) ?? {
      id: familyId,
      displayName,
      resources: [],
    };
    if (family.displayName !== displayName) return null;
    family.resources.push(lane);
    families.set(familyId, family);
  }

  return [...families.values()];
}

export function getCalendarResourceScopeLabel(
  resource: Pick<CalendarEntryResource, "isPosition">
) {
  return resource.isPosition ? "Stanowisko" : "Cała oś";
}

export function getCalendarLaneLabel(
  laneId: string | "all",
  lanes: CalendarLane[]
) {
  if (laneId === "all") return "Wszystkie osie";
  return lanes.find((lane) => lane.id === laneId)?.displayName ?? "Wybrana oś";
}

export function layoutCalendarLaneEntries(
  entries: CalendarEntry[],
  openingStart: string,
  openingEnd: string,
  hourHeight = CALENDAR_HOUR_HEIGHT
): CalendarPositionedEntry[] {
  const candidates = entries
    .filter(isCalendarLaneEntry)
    .map((entry) => ({
      entry,
      geometry: getCalendarEntryGeometry(
        entry,
        openingStart,
        openingEnd,
        hourHeight
      ),
    }))
    .filter(
      (candidate): candidate is {
        entry: Exclude<CalendarEntry, { type: "event" }>;
        geometry: CalendarEntryGeometry;
      } => candidate.geometry !== null
    )
    .sort(
      (first, second) =>
        first.entry.startTime.localeCompare(second.entry.startTime) ||
        first.entry.endTime.localeCompare(second.entry.endTime) ||
        first.entry.id.localeCompare(second.entry.id)
    );

  const groups: typeof candidates[] = [];
  let currentGroup: typeof candidates = [];
  let groupEnd = "";

  for (const candidate of candidates) {
    if (currentGroup.length === 0 || candidate.entry.startTime < groupEnd) {
      currentGroup.push(candidate);
      if (candidate.entry.endTime > groupEnd) groupEnd = candidate.entry.endTime;
      continue;
    }
    groups.push(currentGroup);
    currentGroup = [candidate];
    groupEnd = candidate.entry.endTime;
  }
  if (currentGroup.length > 0) groups.push(currentGroup);

  return groups.flatMap((group) => {
    const columnEnds: string[] = [];
    const assigned = group.map((candidate) => {
      let columnIndex = columnEnds.findIndex(
        (endTime) => endTime <= candidate.entry.startTime
      );
      if (columnIndex === -1) columnIndex = columnEnds.length;
      columnEnds[columnIndex] = candidate.entry.endTime;
      return { ...candidate, columnIndex };
    });
    const columnCount = Math.max(1, columnEnds.length);
    return assigned.map((candidate) => ({ ...candidate, columnCount }));
  });
}
