import type {
  CalendarEntry,
  CalendarEntryType,
  CalendarLane,
} from "@/lib/admin/calendar/types";
import {
  calendarTimeToMinutes,
  clipCalendarTimeRange,
  isValidCalendarDate,
} from "@/lib/admin/calendar/time";

export const CALENDAR_HOUR_HEIGHT = 72;

export type CalendarEntryGeometry = {
  top: number;
  height: number;
  isClipped: boolean;
};

export type CalendarPositionedEntry = {
  entry: Exclude<CalendarEntry, { type: "event" }>;
  geometry: CalendarEntryGeometry;
  columnIndex: number;
  columnCount: number;
};

export type CalendarUiFilters = {
  date: string;
  laneId: string | "all";
  types: CalendarEntryType[];
  includeHistoricalStatuses: boolean;
};

export function addCalendarDays(date: string, days: number) {
  if (!isValidCalendarDate(date) || !Number.isInteger(days)) return null;
  const [year, month, day] = date.split("-").map(Number);
  const shifted = new Date(Date.UTC(year, month - 1, day + days));
  return `${shifted.getUTCFullYear()}-${String(shifted.getUTCMonth() + 1).padStart(
    2,
    "0"
  )}-${String(shifted.getUTCDate()).padStart(2, "0")}`;
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
    if (entry.type === "event") return true;
    return filters.laneId === "all" || entry.laneId === filters.laneId;
  });
}

export function getVisibleCalendarLanes(
  lanes: CalendarLane[],
  laneId: string | "all"
) {
  return laneId === "all" ? lanes : lanes.filter((lane) => lane.id === laneId);
}

export function layoutCalendarLaneEntries(
  entries: CalendarEntry[],
  openingStart: string,
  openingEnd: string,
  hourHeight = CALENDAR_HOUR_HEIGHT
): CalendarPositionedEntry[] {
  const candidates = entries
    .filter(
      (entry): entry is Exclude<CalendarEntry, { type: "event" }> =>
        entry.type !== "event"
    )
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
