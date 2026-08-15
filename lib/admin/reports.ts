import { buildLaneHierarchyDisplayModel } from "./lane-hierarchy.js";
import { buildEffectiveLaneCapacity } from "./lane-capacity.js";

export const REPORT_PAGE_SIZE = 500;
export const REPORT_OPEN_MINUTES_PER_DAY = 16 * 60;

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

type CompleteDatasetResult<Row> =
  | { ok: true; rows: Row[] }
  | {
      ok: false;
      code:
        | "invalid_count"
        | "invalid_page"
        | "duplicate_row"
        | "incomplete_dataset";
    };

export async function fetchCompleteReportDataset<Row extends { id: string }>(
  expectedCount: number,
  fetchPage: (from: number, to: number) => Promise<Row[] | null>,
  pageSize = REPORT_PAGE_SIZE,
): Promise<CompleteDatasetResult<Row>> {
  if (
    !Number.isSafeInteger(expectedCount) ||
    expectedCount < 0 ||
    !Number.isSafeInteger(pageSize) ||
    pageSize < 1
  ) {
    return { ok: false, code: "invalid_count" };
  }

  const rows: Row[] = [];
  const seenIds = new Set<string>();

  while (rows.length < expectedCount) {
    const page = await fetchPage(
      rows.length,
      Math.min(rows.length + pageSize, expectedCount) - 1,
    );

    if (!Array.isArray(page) || page.length === 0) {
      return { ok: false, code: "invalid_page" };
    }

    for (const row of page) {
      if (!row || typeof row.id !== "string" || seenIds.has(row.id)) {
        return { ok: false, code: "duplicate_row" };
      }

      seenIds.add(row.id);
      rows.push(row);
    }

    if (rows.length > expectedCount) {
      return { ok: false, code: "incomplete_dataset" };
    }
  }

  return rows.length === expectedCount
    ? { ok: true, rows }
    : { ok: false, code: "incomplete_dataset" };
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
    !Number.isFinite(daysInRange) ||
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
      const lane = lanesById.get(item.id);
      return {
        id: item.id,
        isActive: item.isActive,
        isParent: item.isParent,
        isPosition: item.isPosition,
        parentLaneId: item.parentLaneId,
        onlineBookable: onlineBookableByLaneId.get(item.id)!,
        wholeLaneBookable: lane!.whole_lane_bookable,
        positionsBookable: lane!.positions_bookable,
      };
    }),
  );
  if (!capacity.ok) {
    return { ok: false as const, code: "invalid_input" as const };
  }

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
  const utilizationPercent =
    availableResourceMinutes > 0
      ? Math.round(
          (occupiedResourceMinutes / availableResourceMinutes) * 100,
        )
      : 0;

  return {
    ok: true as const,
    effectiveCapacity: capacity.effectiveCapacity,
    occupiedResourceMinutes,
    availableResourceMinutes,
    utilizationPercent,
  };
}
