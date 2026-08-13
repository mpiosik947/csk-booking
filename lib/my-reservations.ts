export const MY_RESERVATIONS_PAGE_SIZE = 500;

export type MyReservation = {
  id: string;
  reservation_date: string;
  start_time: string;
  end_time: string;
  price: number;
  reservation_status: string;
  payment_status: string;
  check_in_token: string | null;
  attendance_status: string | null;
  checked_in_at: string | null;
  lane_display_name: string | null;
};

type PageResult = {
  data: unknown;
  error: unknown;
};

export type MyReservationsLoadResult =
  | { ok: true; value: MyReservation[] }
  | {
      ok: false;
      code: "page_error" | "invalid_response" | "duplicate_id";
    };

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;
const TIME_PATTERN = /^\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?$/;
const ROW_KEYS = [
  "attendance_status",
  "check_in_token",
  "checked_in_at",
  "end_time",
  "id",
  "lane_display_name",
  "payment_status",
  "price",
  "reservation_date",
  "reservation_status",
  "start_time",
];

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function hasExactKeys(value: Record<string, unknown>) {
  const keys = Object.keys(value).sort();
  return (
    keys.length === ROW_KEYS.length &&
    keys.every((key, index) => key === ROW_KEYS[index])
  );
}

function isNullableString(value: unknown): value is string | null {
  return value === null || typeof value === "string";
}

function parseReservation(value: unknown): MyReservation | null {
  if (!isRecord(value) || !hasExactKeys(value)) {
    return null;
  }

  if (
    typeof value.id !== "string" ||
    !UUID_PATTERN.test(value.id) ||
    typeof value.reservation_date !== "string" ||
    !DATE_PATTERN.test(value.reservation_date) ||
    typeof value.start_time !== "string" ||
    !TIME_PATTERN.test(value.start_time) ||
    typeof value.end_time !== "string" ||
    !TIME_PATTERN.test(value.end_time) ||
    typeof value.price !== "number" ||
    !Number.isFinite(value.price) ||
    typeof value.reservation_status !== "string" ||
    typeof value.payment_status !== "string" ||
    (value.check_in_token !== null &&
      (typeof value.check_in_token !== "string" ||
        !UUID_PATTERN.test(value.check_in_token))) ||
    !isNullableString(value.attendance_status) ||
    !isNullableString(value.checked_in_at) ||
    !isNullableString(value.lane_display_name)
  ) {
    return null;
  }

  return {
    id: value.id,
    reservation_date: value.reservation_date,
    start_time: value.start_time,
    end_time: value.end_time,
    price: value.price,
    reservation_status: value.reservation_status,
    payment_status: value.payment_status,
    check_in_token: value.check_in_token,
    attendance_status: value.attendance_status,
    checked_in_at: value.checked_in_at,
    lane_display_name: value.lane_display_name,
  };
}

export async function loadAllMyReservations(
  loadPage: (from: number, to: number) => Promise<PageResult>,
  pageSize = MY_RESERVATIONS_PAGE_SIZE
): Promise<MyReservationsLoadResult> {
  if (!Number.isInteger(pageSize) || pageSize <= 0) {
    return { ok: false, code: "invalid_response" };
  }

  const reservations: MyReservation[] = [];
  const reservationIds = new Set<string>();

  for (let from = 0; ; from += pageSize) {
    let pageResult: PageResult;

    try {
      pageResult = await loadPage(from, from + pageSize - 1);
    } catch {
      return { ok: false, code: "page_error" };
    }

    if (pageResult.error || !Array.isArray(pageResult.data)) {
      return {
        ok: false,
        code: pageResult.error ? "page_error" : "invalid_response",
      };
    }

    for (const candidate of pageResult.data) {
      const reservation = parseReservation(candidate);

      if (!reservation) {
        return { ok: false, code: "invalid_response" };
      }

      if (reservationIds.has(reservation.id)) {
        return { ok: false, code: "duplicate_id" };
      }

      reservationIds.add(reservation.id);
      reservations.push(reservation);
    }

    if (pageResult.data.length < pageSize) {
      return { ok: true, value: reservations };
    }
  }
}

export function getMyReservationLaneDisplayName(
  reservation: Pick<MyReservation, "lane_display_name">
) {
  return reservation.lane_display_name?.trim() || "Nieznana oś";
}
