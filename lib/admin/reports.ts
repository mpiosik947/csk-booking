import { buildLaneHierarchyDisplayModel } from "./lane-hierarchy.js";
import { buildEffectiveLaneCapacity } from "./lane-capacity.js";

export const REPORT_TIME_ZONE = "Europe/Warsaw";
export const REPORT_OPENING_START = "08:00";
export const REPORT_OPENING_END = "20:00";
export const REPORT_OPEN_MINUTES_PER_DAY = 12 * 60;
export const REPORT_DETAIL_PAGE_SIZE = 50;
export const REPORT_MAX_RANGE_DAYS = 366;

export type ReportMode = "day" | "week" | "month" | "year";

export type ReportDateRange = {
  startDate: string;
  endDate: string;
  label: string;
  days: number;
};

export type ReportLane = {
  id: string;
  name: string;
  resource_kind: "lane" | "position";
  parent_lane_id: string | null;
  display_order: number;
  is_active: boolean;
  whole_lane_bookable: boolean;
  positions_bookable: boolean;
  lane_booking_rules:
    | { online_bookable: boolean }
    | { online_bookable: boolean }[]
    | null;
};

export type ReportUtilizationReservation = {
  id: string;
  lane_id: string | null;
  duration_minutes: number | null;
};

export type ReportDetail = {
  id: string;
  laneId: string;
  laneNameSnapshot: string;
  laneDisplayName: string;
  resourceKind: "lane" | "position" | null;
  parentLaneId: string | null;
  customerName: string | null;
  customerEmail: string | null;
  customerPhone: string | null;
  reservationDate: string;
  startTime: string;
  endTime: string;
  durationMinutes: number;
  totalPrice: number;
  reservationStatus: string;
  paymentStatus: string;
};

export type AdminReservationReport = {
  range: {
    startDate: string;
    endDate: string;
    endInclusive: true;
    days: number;
    timeZone: typeof REPORT_TIME_ZONE;
    openingStart: typeof REPORT_OPENING_START;
    openingEnd: typeof REPORT_OPENING_END;
    openingMinutesPerDay: typeof REPORT_OPEN_MINUTES_PER_DAY;
  };
  summary: {
    activeReservationCount: number;
    completedReservationCount: number;
    cancelledReservationCount: number;
    noShowReservationCount: number;
    plannedRevenue: number;
    paidRevenue: number;
    outstandingRevenue: number;
    effectiveCapacity: number;
    occupiedMinutes: number;
    availableMinutes: number;
    occupancyPercent: number;
    bestDay: { date: string; plannedRevenue: number } | null;
    topResource: {
      laneId: string;
      laneName: string;
      reservationCount: number;
    } | null;
  };
  details: ReportDetail[];
  pagination: { total: number; limit: number; offset: number };
  history: {
    nameBasis: "reservation_snapshot";
    positionParentNameBasis: "current_configuration";
    capacityBasis: "current_configuration";
  };
};

const DATE_PATTERN = /^(\d{4})-(\d{2})-(\d{2})$/;
const TIME_PATTERN = /^(\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?$/;
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MILLISECONDS_PER_DAY = 86_400_000;

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function parseDate(value: unknown) {
  if (typeof value !== "string") return null;
  const match = DATE_PATTERN.exec(value);
  if (!match) return null;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const date = new Date(Date.UTC(year, month - 1, day));
  return date.getUTCFullYear() === year &&
    date.getUTCMonth() === month - 1 &&
    date.getUTCDate() === day
    ? date
    : null;
}

function formatUtcDate(date: Date) {
  return date.toISOString().slice(0, 10);
}

function addUtcDays(date: Date, days: number) {
  const result = new Date(date.getTime());
  result.setUTCDate(result.getUTCDate() + days);
  return result;
}

function isNonNegativeInteger(value: unknown): value is number {
  return Number.isSafeInteger(value) && Number(value) >= 0;
}

function isFiniteNonNegative(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0;
}

function nullableString(value: unknown): value is string | null {
  return value === null || typeof value === "string";
}

function validTime(value: unknown): value is string {
  if (typeof value !== "string") return false;
  const match = TIME_PATTERN.exec(value);
  if (!match) return false;
  const hour = Number(match[1]);
  const minute = Number(match[2]);
  const second = match[3] === undefined ? 0 : Number(match[3]);
  return hour <= 23 && minute <= 59 && second <= 59;
}

function formatTime(value: string) {
  return value.slice(0, 5);
}

export function getWarsawToday(now = new Date()) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: REPORT_TIME_ZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(now);
  const part = (type: Intl.DateTimeFormatPartTypes) =>
    parts.find((candidate) => candidate.type === type)?.value ?? "";
  return `${part("year")}-${part("month")}-${part("day")}`;
}

export function countReportDaysInclusive(startDate: string, endDate: string) {
  const start = parseDate(startDate);
  const end = parseDate(endDate);
  if (!start || !end || end < start) return null;
  return Math.round((end.getTime() - start.getTime()) / MILLISECONDS_PER_DAY) + 1;
}

export function getReportDateRange(
  mode: ReportMode,
  selectedDate: string,
): ReportDateRange | null {
  const selected = parseDate(selectedDate);
  if (!selected) return null;

  let start = selected;
  let end = selected;
  let label = selectedDate;

  if (mode === "week") {
    const day = selected.getUTCDay();
    start = addUtcDays(selected, day === 0 ? -6 : 1 - day);
    end = addUtcDays(start, 6);
    label = `${formatUtcDate(start)} - ${formatUtcDate(end)}`;
  } else if (mode === "month") {
    start = new Date(Date.UTC(selected.getUTCFullYear(), selected.getUTCMonth(), 1));
    end = new Date(Date.UTC(selected.getUTCFullYear(), selected.getUTCMonth() + 1, 0));
    label = `${String(selected.getUTCMonth() + 1).padStart(2, "0")}.${selected.getUTCFullYear()}`;
  } else if (mode === "year") {
    start = new Date(Date.UTC(selected.getUTCFullYear(), 0, 1));
    end = new Date(Date.UTC(selected.getUTCFullYear(), 11, 31));
    label = `${selected.getUTCFullYear()}`;
  }

  const startDate = formatUtcDate(start);
  const endDate = formatUtcDate(end);
  const days = countReportDaysInclusive(startDate, endDate);
  return days && days <= REPORT_MAX_RANGE_DAYS
    ? { startDate, endDate, label, days }
    : null;
}

function parseDetail(value: unknown): ReportDetail | null {
  if (!isRecord(value)) return null;
  if (
    typeof value.id !== "string" ||
    !UUID_PATTERN.test(value.id) ||
    typeof value.lane_id !== "string" ||
    !UUID_PATTERN.test(value.lane_id) ||
    typeof value.lane_name_snapshot !== "string" ||
    !value.lane_name_snapshot.trim() ||
    typeof value.lane_display_name !== "string" ||
    !value.lane_display_name.trim() ||
    (value.resource_kind !== null &&
      value.resource_kind !== "lane" &&
      value.resource_kind !== "position") ||
    (value.parent_lane_id !== null &&
      (typeof value.parent_lane_id !== "string" ||
        !UUID_PATTERN.test(value.parent_lane_id))) ||
    !nullableString(value.customer_name) ||
    !nullableString(value.customer_email) ||
    !nullableString(value.customer_phone) ||
    !parseDate(value.reservation_date) ||
    !validTime(value.start_time) ||
    !validTime(value.end_time) ||
    !isNonNegativeInteger(value.duration_minutes) ||
    value.duration_minutes < 1 ||
    !isFiniteNonNegative(value.total_price) ||
    typeof value.reservation_status !== "string" ||
    typeof value.payment_status !== "string"
  ) {
    return null;
  }

  return {
    id: value.id,
    laneId: value.lane_id,
    laneNameSnapshot: value.lane_name_snapshot,
    laneDisplayName: value.lane_display_name,
    resourceKind: value.resource_kind,
    parentLaneId: value.parent_lane_id,
    customerName: value.customer_name,
    customerEmail: value.customer_email,
    customerPhone: value.customer_phone,
    reservationDate: value.reservation_date as string,
    startTime: formatTime(value.start_time),
    endTime: formatTime(value.end_time),
    durationMinutes: value.duration_minutes,
    totalPrice: value.total_price,
    reservationStatus: value.reservation_status,
    paymentStatus: value.payment_status,
  };
}

export function parseAdminReservationReport(
  value: unknown,
): AdminReservationReport | null {
  if (!isRecord(value) || value.ok !== true || value.code !== "ok") return null;
  if (
    value.contract_version !== 1 ||
    !isRecord(value.range) ||
    !isRecord(value.summary) ||
    !Array.isArray(value.details) ||
    !isRecord(value.pagination) ||
    !isRecord(value.history)
  ) {
    return null;
  }

  const range = value.range;
  const summary = value.summary;
  const pagination = value.pagination;
  const history = value.history;
  const details = value.details.map(parseDetail);
  const countFields = [
    summary.active_reservation_count,
    summary.completed_reservation_count,
    summary.cancelled_reservation_count,
    summary.no_show_reservation_count,
    summary.effective_capacity,
    summary.occupied_minutes,
    summary.available_minutes,
    summary.occupancy_percent,
    pagination.total,
    pagination.limit,
    pagination.offset,
  ];

  if (
    !parseDate(range.start_date) ||
    !parseDate(range.end_date) ||
    range.end_inclusive !== true ||
    !isNonNegativeInteger(range.days) ||
    range.days < 1 ||
    range.days > REPORT_MAX_RANGE_DAYS ||
    range.time_zone !== REPORT_TIME_ZONE ||
    range.opening_start !== REPORT_OPENING_START ||
    range.opening_end !== REPORT_OPENING_END ||
    range.opening_minutes_per_day !== REPORT_OPEN_MINUTES_PER_DAY ||
    countReportDaysInclusive(range.start_date as string, range.end_date as string) !==
      range.days ||
    countFields.some((field) => !isNonNegativeInteger(field)) ||
    Number(summary.occupancy_percent) > 100 ||
    !isFiniteNonNegative(summary.planned_revenue) ||
    !isFiniteNonNegative(summary.paid_revenue) ||
    !isFiniteNonNegative(summary.outstanding_revenue) ||
    details.some((detail) => detail === null) ||
    details.length > Number(pagination.limit) ||
    Number(pagination.offset) + details.length > Number(pagination.total) ||
    history.name_basis !== "reservation_snapshot" ||
    history.position_parent_name_basis !== "current_configuration" ||
    history.capacity_basis !== "current_configuration"
  ) {
    return null;
  }

  const bestDay = summary.best_day;
  const topResource = summary.top_resource;
  if (
    (bestDay !== null &&
      (!isRecord(bestDay) ||
        !parseDate(bestDay.date) ||
        !isFiniteNonNegative(bestDay.planned_revenue))) ||
    (topResource !== null &&
      (!isRecord(topResource) ||
        typeof topResource.lane_id !== "string" ||
        !UUID_PATTERN.test(topResource.lane_id) ||
        typeof topResource.lane_name !== "string" ||
        !topResource.lane_name.trim() ||
        !isNonNegativeInteger(topResource.reservation_count) ||
        topResource.reservation_count < 1))
  ) {
    return null;
  }

  return {
    range: {
      startDate: range.start_date as string,
      endDate: range.end_date as string,
      endInclusive: true,
      days: range.days as number,
      timeZone: REPORT_TIME_ZONE,
      openingStart: REPORT_OPENING_START,
      openingEnd: REPORT_OPENING_END,
      openingMinutesPerDay: REPORT_OPEN_MINUTES_PER_DAY,
    },
    summary: {
      activeReservationCount: summary.active_reservation_count as number,
      completedReservationCount: summary.completed_reservation_count as number,
      cancelledReservationCount: summary.cancelled_reservation_count as number,
      noShowReservationCount: summary.no_show_reservation_count as number,
      plannedRevenue: summary.planned_revenue as number,
      paidRevenue: summary.paid_revenue as number,
      outstandingRevenue: summary.outstanding_revenue as number,
      effectiveCapacity: summary.effective_capacity as number,
      occupiedMinutes: summary.occupied_minutes as number,
      availableMinutes: summary.available_minutes as number,
      occupancyPercent: summary.occupancy_percent as number,
      bestDay:
        bestDay === null
          ? null
          : {
              date: bestDay.date as string,
              plannedRevenue: bestDay.planned_revenue as number,
            },
      topResource:
        topResource === null
          ? null
          : {
              laneId: topResource.lane_id as string,
              laneName: topResource.lane_name as string,
              reservationCount: topResource.reservation_count as number,
            },
    },
    details: details as ReportDetail[],
    pagination: {
      total: pagination.total as number,
      limit: pagination.limit as number,
      offset: pagination.offset as number,
    },
    history: {
      nameBasis: "reservation_snapshot",
      positionParentNameBasis: "current_configuration",
      capacityBasis: "current_configuration",
    },
  };
}

export function calculateHierarchyUtilization(
  lanes: ReportLane[],
  reservations: ReportUtilizationReservation[],
  daysInRange: number,
  openMinutesPerDay = REPORT_OPEN_MINUTES_PER_DAY,
) {
  const hierarchy = buildLaneHierarchyDisplayModel(lanes);
  const onlineBookableByLaneId = new Map<string, boolean>();

  for (const lane of lanes) {
    const bookingRule = Array.isArray(lane.lane_booking_rules)
      ? lane.lane_booking_rules.length === 1
        ? lane.lane_booking_rules[0]
        : null
      : lane.lane_booking_rules;
    if (!bookingRule || typeof bookingRule.online_bookable !== "boolean") {
      return { ok: false as const, code: "invalid_input" as const };
    }
    onlineBookableByLaneId.set(lane.id, bookingRule.online_bookable);
  }

  if (
    !hierarchy.ok ||
    !Number.isInteger(daysInRange) ||
    daysInRange < 1 ||
    !Number.isFinite(openMinutesPerDay) ||
    openMinutesPerDay < 1 ||
    lanes.some(
      (lane) =>
        typeof lane.whole_lane_bookable !== "boolean" ||
        typeof lane.positions_bookable !== "boolean",
    )
  ) {
    return { ok: false as const, code: "invalid_input" as const };
  }

  const lanesById = new Map(lanes.map((lane) => [lane.id, lane]));
  const capacity = buildEffectiveLaneCapacity(
    hierarchy.value.map((item) => {
      const lane = lanesById.get(item.id)!;
      return {
        id: item.id,
        isActive: item.isActive,
        isParent: item.isParent,
        isPosition: item.isPosition,
        parentLaneId: item.parentLaneId,
        onlineBookable: onlineBookableByLaneId.get(item.id)!,
        wholeLaneBookable: lane.whole_lane_bookable,
        positionsBookable: lane.positions_bookable,
      };
    }),
  );
  if (!capacity.ok) return { ok: false as const, code: "invalid_input" as const };

  let occupiedResourceMinutes = 0;
  for (const reservation of reservations) {
    const duration = Number(reservation.duration_minutes ?? 0);
    if (!Number.isFinite(duration) || duration < 0) {
      return { ok: false as const, code: "invalid_input" as const };
    }
    const weight = reservation.lane_id
      ? (capacity.unitIdsByResourceId.get(reservation.lane_id)?.length ?? 0)
      : 0;
    occupiedResourceMinutes += duration * weight;
  }

  const availableResourceMinutes =
    capacity.effectiveCapacity * openMinutesPerDay * daysInRange;
  return {
    ok: true as const,
    effectiveCapacity: capacity.effectiveCapacity,
    occupiedResourceMinutes,
    availableResourceMinutes,
    utilizationPercent:
      availableResourceMinutes > 0
        ? Math.min(
            100,
            Math.round((occupiedResourceMinutes / availableResourceMinutes) * 100),
          )
        : 0,
  };
}
