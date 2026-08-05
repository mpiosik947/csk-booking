import {
  CALENDAR_FEED_ROLES,
  type CalendarEntry,
  type CalendarFeed,
  type CalendarFeedQuery,
  type CalendarFeedRole,
  type CalendarLane,
  type CalendarReservationStatus,
} from "./types";
import {
  CALENDAR_OPENING_END,
  CALENDAR_OPENING_START,
  CALENDAR_TIME_ZONE,
  compareCalendarDates,
  getCalendarRangeDurationMinutes,
  isValidCalendarDate,
  isValidCalendarTime,
} from "./time";

export type CalendarLaneRow = {
  id: unknown;
  name: unknown;
  is_active: unknown;
  display_order: unknown;
  booking_step_minutes: unknown;
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

export function buildCalendarFeed(
  query: CalendarFeedQuery,
  role: CalendarFeedRole,
  rows: CalendarFeedRows,
  today: string
): CalendarFeed {
  if (!isValidCalendarDate(today)) throw new Error("Invalid current date.");

  const laneMap = new Map<string, CalendarLane>();
  for (const row of rows.lanes) {
    const lane: CalendarLane = {
      id: requireString(row.id, "lane id"),
      name: requireString(row.name, "lane name"),
      isActive: requireBoolean(row.is_active, "lane status"),
      isHistoricalOnly: false,
      displayOrder: requireNonNegativeInteger(row.display_order, "lane display order"),
      bookingStepMinutes: requireNonNegativeInteger(
        row.booking_step_minutes,
        "lane booking step"
      ),
    };
    if (lane.bookingStepMinutes < 1) throw new Error("Invalid lane booking step.");
    laneMap.set(lane.id, lane);
  }

  const referencedLaneIds = new Set<string>();
  const entries: CalendarEntry[] = [];

  if (query.types.includes("reservation")) {
    for (const row of rows.reservations) {
      const state = getReservationCalendarState(
        row.reservation_status,
        query.includeHistoricalStatuses
      );
      if (!state) continue;
      const laneId = requireString(row.lane_id, "reservation lane id");
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
        laneName: lane?.name ?? (snapshot || "Nieznana oś"),
        laneMetadataAvailable: Boolean(lane),
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
      const lane = laneMap.get(laneId);
      referencedLaneIds.add(laneId);
      entries.push({
        id: requireString(row.id, "lane block id"),
        type: "lane_block",
        date,
        ...requireTimeRange(row.start_time, row.end_time),
        laneId,
        laneName: lane?.name ?? "Nieznana oś",
        laneMetadataAvailable: Boolean(lane),
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
      entries.push({
        id: requireString(row.id, "event id"),
        type: "event",
        date: requireDate(row.event_date),
        ...requireTimeRange(row.start_time, row.end_time),
        laneId: null,
        laneName: null,
        status: "active",
        location: requireString(row.location, "event location"),
        maxParticipants: requireNonNegativeInteger(row.max_participants, "event limit"),
        label: requireString(row.title, "event title"),
        occupiesLane: false,
        isHistorical: false,
        links: { primary: "/admin/events", checkIn: null },
      });
    }
  }

  const lanes = [...laneMap.values()]
    .filter((lane) => {
      if (query.laneId !== "all" && lane.id !== query.laneId) return false;
      return lane.isActive || referencedLaneIds.has(lane.id);
    })
    .map((lane) => ({ ...lane, isHistoricalOnly: !lane.isActive }))
    .sort((first, second) => first.displayOrder - second.displayOrder || first.name.localeCompare(second.name, "pl"));

  entries.sort(
    (first, second) =>
      first.date.localeCompare(second.date) ||
      first.startTime.localeCompare(second.startTime) ||
      first.type.localeCompare(second.type) ||
      first.id.localeCompare(second.id)
  );

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
  };
}
