import {
  CALENDAR_FEED_ROLES,
  type CalendarEntry,
  CALENDAR_DAY_FLAGS,
  type CalendarDayFlag,
  type CalendarDaySummary,
  type CalendarFeed,
  type CalendarFeedQuery,
  type CalendarFeedRole,
  type CalendarLane,
  type CalendarReservationStatus,
} from "./types";
import { buildLaneHierarchyDisplayModel } from "../lane-hierarchy.js";
import {
  CALENDAR_OPENING_END,
  CALENDAR_OPENING_START,
  CALENDAR_TIME_ZONE,
  compareCalendarDates,
  calendarTimeRangesOverlap,
  calendarTimeToMinutes,
  clipCalendarTimeRange,
  getCalendarDatesInclusive,
  getCalendarRangeDurationMinutes,
  getCalendarTimeRangesUnionMinutes,
  isValidCalendarDate,
  isValidCalendarTime,
} from "./time";

export type CalendarLaneRow = {
  id: unknown;
  name: unknown;
  is_active: unknown;
  display_order: unknown;
  booking_step_minutes: unknown;
  resource_kind: unknown;
  parent_lane_id: unknown;
};

export type CalendarReservationRow = {
  id: unknown;
  lane_id: unknown;
  lane_name_snapshot: unknown;
  reservation_date: unknown;
  start_time: unknown;
  end_time: unknown;
  duration_minutes: unknown;
  reservation_status: unknown;
  shooters_count: unknown;
  customer_name?: unknown;
};

export type CalendarLaneBlockRow = {
  id: unknown;
  lane_id: unknown;
  block_date: unknown;
  start_time: unknown;
  end_time: unknown;
  reason: unknown;
  is_active: unknown;
};

export type CalendarEventRow = {
  id: unknown;
  title: unknown;
  event_date: unknown;
  start_time: unknown;
  end_time: unknown;
  location: unknown;
  max_participants: unknown;
  is_active: unknown;
  event_lanes?: unknown;
};

export type CalendarFeedRows = {
  lanes: CalendarLaneRow[];
  reservations: CalendarReservationRow[];
  laneBlocks: CalendarLaneBlockRow[];
  events: CalendarEventRow[];
};

export function parseCalendarFeedRole(value: unknown): CalendarFeedRole | null {
  if (typeof value !== "string") return null;
  const normalized = value.trim().toLowerCase();
  return (CALENDAR_FEED_ROLES as readonly string[]).includes(normalized)
    ? (normalized as CalendarFeedRole)
    : null;
}

export function getReservationSelectColumns(role: CalendarFeedRole) {
  const safeColumns =
    "id,lane_id,lane_name_snapshot,reservation_date,start_time,end_time,duration_minutes,shooters_count,reservation_status";
  return role === "instruktor" ? safeColumns : `${safeColumns},customer_name`;
}

function requireString(value: unknown, label: string) {
  if (typeof value !== "string" || !value.trim()) {
    throw new Error(`Invalid ${label}.`);
  }
  return value.trim();
}

function requireBoolean(value: unknown, label: string) {
  if (typeof value !== "boolean") throw new Error(`Invalid ${label}.`);
  return value;
}

function requireNonNegativeInteger(value: unknown, label: string) {
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0) {
    throw new Error(`Invalid ${label}.`);
  }
  return value;
}

function normalizeDatabaseTime(value: unknown) {
  if (typeof value !== "string") throw new Error("Invalid calendar time.");
  const normalized = value.slice(0, 5);
  if (!isValidCalendarTime(normalized)) throw new Error("Invalid calendar time.");
  return normalized;
}

function requireTimeRange(start: unknown, end: unknown) {
  const startTime = normalizeDatabaseTime(start);
  const endTime = normalizeDatabaseTime(end);
  if (getCalendarRangeDurationMinutes(startTime, endTime) === null) {
    throw new Error("Invalid calendar time range.");
  }
  return { startTime, endTime };
}

function requireDate(value: unknown) {
  const date = requireString(value, "calendar date");
  if (!isValidCalendarDate(date)) throw new Error("Invalid calendar date.");
  return date;
}

function normalizeOptionalString(value: unknown, label: string) {
  if (value === null) return null;
  if (typeof value !== "string") throw new Error(`Invalid ${label}.`);
  return value.trim() || null;
}

function getPeopleLabel(count: number) {
  if (count === 1) return "1 osoba";
  const lastTwo = count % 100;
  const last = count % 10;
  if (last >= 2 && last <= 4 && (lastTwo < 12 || lastTwo > 14)) {
    return `${count} osoby`;
  }
  return `${count} osób`;
}

export function buildCalendarReservationLabel(
  customerName: unknown,
  shootersCount: number,
  role: CalendarFeedRole
) {
  const people = getPeopleLabel(shootersCount);
  if (role === "instruktor") return `Rezerwacja — ${people}`;

  if (typeof customerName !== "string" || !customerName.trim()) {
    return `Klient — ${people}`;
  }

  const parts = customerName.trim().split(/\s+/);
  if (parts.length < 2) return `Klient — ${people}`;
  const compactName = `${parts[0]} ${parts[1][0]}.`;
  return `${compactName} — ${people}`;
}

export function getReservationCalendarState(status: unknown, includeHistorical: boolean) {
  if (status === "confirmed") {
    return { status: "confirmed" as const, occupiesLane: true, isHistorical: false };
  }
  if (includeHistorical && (status === "completed" || status === "no_show")) {
    return {
      status: status as CalendarReservationStatus,
      occupiesLane: false,
      isHistorical: true,
    };
  }
  return null;
}

export function buildCalendarDaySummaries(
  query: CalendarFeedQuery,
  lanes: CalendarLane[],
  entries: CalendarEntry[]
): CalendarDaySummary[] {
  const dates = getCalendarDatesInclusive(query.rangeStart, query.rangeEnd);
  if (!dates) throw new Error("Invalid calendar summary range.");

  const activeLaneIds = new Set(
    lanes.filter((lane) => lane.isActive).map((lane) => lane.id)
  );
  const openingMinutes = getCalendarRangeDurationMinutes(
    CALENDAR_OPENING_START,
    CALENDAR_OPENING_END
  );
  if (openingMinutes === null) throw new Error("Invalid calendar opening hours.");

  return dates.map((date) => {
    const dayEntries = entries.filter((entry) => entry.date === date);
    const intervalsByLane = new Map<
      string,
      Array<{ startTime: string; endTime: string }>
    >();
    const flags = new Set<CalendarDayFlag>();
    const activeBlocks = dayEntries.filter(
      (entry) => entry.type === "lane_block" && entry.isActive
    );

    for (const entry of dayEntries) {
      if (
        (entry.type === "reservation" ||
          (entry.type === "lane_block" && entry.isActive)) &&
        (calendarTimeToMinutes(entry.startTime) ?? 0) <
          (calendarTimeToMinutes(CALENDAR_OPENING_START) ?? 0)
      ) {
        flags.add("outside_opening_hours");
      }
      if (
        (entry.type === "reservation" ||
          (entry.type === "lane_block" && entry.isActive)) &&
        (calendarTimeToMinutes(entry.endTime) ?? 0) >
          (calendarTimeToMinutes(CALENDAR_OPENING_END) ?? 0)
      ) {
        flags.add("outside_opening_hours");
      }
      if (
        (entry.type === "reservation" || entry.type === "lane_block") &&
        !entry.laneMetadataAvailable
      ) {
        flags.add("missing_lane_metadata");
      }

      if (
        !entry.occupiesLane ||
        !entry.laneMetadataAvailable ||
        !activeLaneIds.has(entry.laneId)
      ) {
        continue;
      }

      const clipped = clipCalendarTimeRange(entry);
      if (!clipped) {
        flags.add("outside_opening_hours");
        continue;
      }
      const laneIntervals = intervalsByLane.get(entry.laneId) ?? [];
      laneIntervals.push(clipped);
      intervalsByLane.set(entry.laneId, laneIntervals);

      if (
        entry.type === "lane_block" &&
        clipped.startTime === CALENDAR_OPENING_START &&
        clipped.endTime === CALENDAR_OPENING_END
      ) {
        flags.add("full_lane_block");
      }
    }

    for (let firstIndex = 0; firstIndex < activeBlocks.length; firstIndex += 1) {
      for (
        let secondIndex = firstIndex + 1;
        secondIndex < activeBlocks.length;
        secondIndex += 1
      ) {
        const first = activeBlocks[firstIndex];
        const second = activeBlocks[secondIndex];
        if (
          first.type === "lane_block" &&
          second.type === "lane_block" &&
          first.laneId === second.laneId &&
          calendarTimeRangesOverlap(first, second)
        ) {
          flags.add("overlapping_blocks");
        }
      }
    }

    const availableMinutes = activeLaneIds.size * openingMinutes;
    const occupiedMinutes = [...intervalsByLane.values()].reduce(
      (total, intervals) => total + getCalendarTimeRangesUnionMinutes(intervals),
      0
    );
    const isFull = availableMinutes > 0 && occupiedMinutes === availableMinutes;
    const occupancyPercent =
      availableMinutes === 0
        ? null
        : Math.min(100, Math.max(0, Math.round((occupiedMinutes / availableMinutes) * 100)));
    if (isFull) flags.add("full_day");

    return {
      date,
      reservationCount: dayEntries.filter((entry) => entry.type === "reservation").length,
      blockCount: dayEntries.filter((entry) => entry.type === "lane_block").length,
      eventCount: dayEntries.filter(
        (entry) => entry.type === "event" && !entry.isLaneProjection
      ).length,
      availableMinutes,
      occupiedMinutes,
      occupancyPercent,
      isFull,
      flags: CALENDAR_DAY_FLAGS.filter((flag) => flags.has(flag)),
    };
  });
}

export function buildCalendarFeed(
  query: CalendarFeedQuery,
  role: CalendarFeedRole,
  rows: CalendarFeedRows,
  today: string
): CalendarFeed {
  if (!isValidCalendarDate(today)) throw new Error("Invalid current date.");

  const bookingStepByLaneId = new Map<string, number>();
  for (const row of rows.lanes) {
    const laneId = requireString(row.id, "lane id");
    const bookingStepMinutes = requireNonNegativeInteger(
      row.booking_step_minutes,
      "lane booking step"
    );
    if (bookingStepMinutes < 1) throw new Error("Invalid lane booking step.");
    bookingStepByLaneId.set(laneId, bookingStepMinutes);
  }

  const hierarchy = buildLaneHierarchyDisplayModel(rows.lanes);
  if (!hierarchy.ok) throw new Error("Invalid calendar lane hierarchy.");

  const laneMap = new Map<string, CalendarLane>(
    hierarchy.value.map((lane) => [
      lane.id,
      {
        id: lane.id,
        name: lane.name,
        displayName: lane.displayName,
        parentName: lane.parentName,
        isActive: lane.isActive,
        isHistoricalOnly: false,
        displayOrder: lane.displayOrder,
        bookingStepMinutes: bookingStepByLaneId.get(lane.id)!,
        resourceKind: lane.resourceKind,
        parentLaneId: lane.parentLaneId,
        depth: lane.depth,
        isParent: lane.isParent,
        isPosition: lane.isPosition,
      },
    ])
  );
  const toEntryResource = (lane: CalendarLane) => ({
    id: lane.id,
    displayName: lane.displayName,
    depth: lane.depth,
    isActive: lane.isActive,
    isPosition: lane.isPosition,
  });

  const referencedLaneIds = new Set<string>();
  const entries: CalendarEntry[] = [];

  if (role !== "instruktor" && query.types.includes("reservation")) {
    for (const row of rows.reservations) {
      const state = getReservationCalendarState(
        row.reservation_status,
        query.includeHistoricalStatuses
      );
      if (!state) continue;
      const laneId = requireString(row.lane_id, "reservation lane id");
      if (query.laneId !== "all" && laneId !== query.laneId) continue;
      const date = requireDate(row.reservation_date);
      const range = requireTimeRange(row.start_time, row.end_time);
      const durationMinutes = requireNonNegativeInteger(
        row.duration_minutes,
        "reservation duration"
      );
      if (durationMinutes < 1) throw new Error("Invalid reservation duration.");
      const shootersCount = requireNonNegativeInteger(row.shooters_count, "shooters count");
      if (shootersCount < 1) throw new Error("Invalid shooters count.");
      const lane = laneMap.get(laneId);
      const snapshot = typeof row.lane_name_snapshot === "string" ? row.lane_name_snapshot.trim() : "";
      referencedLaneIds.add(laneId);
      entries.push({
        id: requireString(row.id, "reservation id"),
        type: "reservation",
        date,
        ...range,
        laneId,
        laneName: lane?.displayName ?? (snapshot || "Nieznana oś"),
        laneMetadataAvailable: Boolean(lane),
        laneResource: lane ? toEntryResource(lane) : null,
        status: state.status,
        shootersCount,
        label: buildCalendarReservationLabel(row.customer_name, shootersCount, role),
        occupiesLane: state.occupiesLane,
        isHistorical: state.isHistorical,
        links: { primary: "/admin/reservations", checkIn: null },
      });
    }
  }

  if (query.types.includes("lane_block")) {
    for (const row of rows.laneBlocks) {
      const isActive = requireBoolean(row.is_active, "lane block status");
      const date = requireDate(row.block_date);
      const historical = !isActive && compareCalendarDates(date, today) === -1;
      if (!isActive && (!query.includeHistoricalStatuses || !historical)) continue;
      const laneId = requireString(row.lane_id, "lane block lane id");
      if (query.laneId !== "all" && laneId !== query.laneId) continue;
      const lane = laneMap.get(laneId);
      referencedLaneIds.add(laneId);
      entries.push({
        id: requireString(row.id, "lane block id"),
        type: "lane_block",
        date,
        ...requireTimeRange(row.start_time, row.end_time),
        laneId,
        laneName: lane?.displayName ?? "Nieznana oś",
        laneMetadataAvailable: Boolean(lane),
        laneResource: lane ? toEntryResource(lane) : null,
        status: isActive ? "active" : "inactive",
        reason: typeof row.reason === "string" && row.reason.trim() ? row.reason.trim() : null,
        isActive,
        label: isActive ? "Blokada osi" : "Nieaktywna blokada osi",
        occupiesLane: isActive,
        isHistorical: !isActive,
        links: { primary: "/admin/lane-blocks", checkIn: null },
      });
    }
  }

  if (query.types.includes("event")) {
    for (const row of rows.events) {
      if (!requireBoolean(row.is_active, "event status")) continue;
      const eventId = requireString(row.id, "event id");
      const eventLaneIds = new Set<string>();
      if (Array.isArray(row.event_lanes)) {
        for (const relation of row.event_lanes) {
          if (!relation || typeof relation !== "object") continue;
          const rawLaneId = (relation as { lane_id?: unknown }).lane_id;
          if (typeof rawLaneId !== "string" || !rawLaneId.trim()) continue;
          const laneId = rawLaneId.trim();
          const laneRow = (relation as { shooting_lanes?: unknown }).shooting_lanes;
          if (!laneRow || typeof laneRow !== "object") continue;
          const rawLaneName = (laneRow as { name?: unknown }).name;
          if (typeof rawLaneName !== "string" || !rawLaneName.trim()) continue;
          eventLaneIds.add(laneId);
        }
      }
      const resources = [...eventLaneIds]
        .map((laneId) => laneMap.get(laneId))
        .filter((lane): lane is CalendarLane => lane !== undefined)
        .map(toEntryResource);
      const date = requireDate(row.event_date);
      const range = requireTimeRange(row.start_time, row.end_time);
      const sharedEvent = {
        sourceEventId: eventId,
        laneIds: resources.map((resource) => resource.id),
        resources,
        date,
        ...range,
        status: "active" as const,
        location: normalizeOptionalString(row.location, "event location"),
        maxParticipants: requireNonNegativeInteger(row.max_participants, "event limit"),
        label: requireString(row.title, "event title"),
        isHistorical: false,
        links: { primary: "/admin/events" as const, checkIn: null },
      };
      entries.push({
        id: eventId,
        type: "event",
        laneId: null,
        laneName: null,
        laneMetadataAvailable: false,
        laneResource: null,
        occupiesLane: false,
        isLaneProjection: false,
        ...sharedEvent,
      });
      for (const resource of resources) {
        if (query.laneId !== "all" && resource.id !== query.laneId) continue;
        const lane = laneMap.get(resource.id)!;
        referencedLaneIds.add(resource.id);
        entries.push({
          id: `${eventId}:${resource.id}`,
          type: "event",
          laneId: resource.id,
          laneName: lane.displayName,
          laneMetadataAvailable: true,
          laneResource: resource,
          occupiesLane: true,
          isLaneProjection: true,
          ...sharedEvent,
        });
      }
    }
  }

  const lanes = hierarchy.value
    .map((lane) => laneMap.get(lane.id)!)
    .filter((lane) => {
      if (query.laneId !== "all" && lane.id !== query.laneId) return false;
      return lane.isActive || referencedLaneIds.has(lane.id);
    })
    .map((lane) => ({ ...lane, isHistoricalOnly: !lane.isActive }));

  entries.sort(
    (first, second) =>
      first.date.localeCompare(second.date) ||
      first.startTime.localeCompare(second.startTime) ||
      first.type.localeCompare(second.type) ||
      first.id.localeCompare(second.id)
  );

  const dailySummaries = buildCalendarDaySummaries(query, lanes, entries);

  return {
    ok: true,
    rangeStart: query.rangeStart,
    rangeEnd: query.rangeEnd,
    timeZone: CALENDAR_TIME_ZONE,
    openingStart: CALENDAR_OPENING_START,
    openingEnd: CALENDAR_OPENING_END,
    occupancyBasis: "current_active_lanes",
    lanes,
    entries,
    dailySummaries,
  };
}
