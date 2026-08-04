export const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;
const TIME_PATTERN = /^(?:[01]\d|2[0-3]):[0-5]\d$/;

export const CREATE_RESERVATION_CODES = [
  "created",
  "already_created",
  "unauthorized",
  "not_allowed",
  "profile_not_found",
  "profile_incomplete",
  "profile_rejected",
  "verification_limit_reached",
  "invalid_request",
  "invalid_request_id",
  "invalid_date",
  "reservation_already_started",
  "invalid_start_time",
  "outside_booking_hours",
  "invalid_duration",
  "invalid_shooters_count",
  "capacity_exceeded",
  "lane_not_found",
  "lane_inactive",
  "pricing_not_configured",
  "lane_blocked",
  "slot_unavailable",
  "idempotency_conflict",
  "internal_error",
] as const;

export type CreateReservationCode =
  (typeof CREATE_RESERVATION_CODES)[number];

export type CreateReservationPayload = {
  laneId: string;
  reservationDate: string;
  startTime: string;
  durationMinutes: number;
  shootersCount: number;
  creationRequestId: string;
  reservationNote: string | null;
};

export type CreateReservationRpcResult = {
  ok: boolean;
  changed: boolean;
  code: CreateReservationCode;
  reservation_id?: string;
  reservation_status?: string;
  lane_name?: string;
  shooters_count?: number;
  duration_minutes?: number;
  pricing_day_group?: "mon_thu" | "fri_sun";
  price_per_hour?: number;
  total_price?: number;
  currency_code?: string;
};

const CODE_SET = new Set<string>(CREATE_RESERVATION_CODES);
const SUCCESS_CODES = new Set<CreateReservationCode>([
  "created",
  "already_created",
]);

const ALLOWED_BODY_KEYS = new Set([
  "laneId",
  "reservationDate",
  "startTime",
  "durationMinutes",
  "shootersCount",
  "creationRequestId",
  "reservationNote",
]);

const REQUIRED_BODY_KEYS = [
  "laneId",
  "reservationDate",
  "startTime",
  "durationMinutes",
  "shootersCount",
  "creationRequestId",
] as const;

function isRealDate(value: string) {
  if (!DATE_PATTERN.test(value)) {
    return false;
  }

  const [year, month, day] = value.split("-").map(Number);
  const date = new Date(Date.UTC(year, month - 1, day));

  return (
    date.getUTCFullYear() === year &&
    date.getUTCMonth() === month - 1 &&
    date.getUTCDate() === day
  );
}

export function parseCreateReservationPayload(
  value: unknown
): CreateReservationPayload | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }

  const body = value as Record<string, unknown>;
  const keys = Object.keys(body);

  if (
    keys.some((key) => !ALLOWED_BODY_KEYS.has(key)) ||
    REQUIRED_BODY_KEYS.some((key) => !(key in body))
  ) {
    return null;
  }

  const laneId = typeof body.laneId === "string" ? body.laneId.trim() : "";
  const reservationDate =
    typeof body.reservationDate === "string"
      ? body.reservationDate.trim()
      : "";
  const startTime =
    typeof body.startTime === "string" ? body.startTime.trim() : "";
  const creationRequestId =
    typeof body.creationRequestId === "string"
      ? body.creationRequestId.trim()
      : "";
  const reservationNote =
    body.reservationNote === undefined || body.reservationNote === null
      ? null
      : typeof body.reservationNote === "string"
        ? body.reservationNote.trim() || null
        : undefined;

  if (
    !UUID_PATTERN.test(laneId) ||
    !UUID_PATTERN.test(creationRequestId) ||
    !isRealDate(reservationDate) ||
    !TIME_PATTERN.test(startTime) ||
    !Number.isInteger(body.durationMinutes) ||
    (body.durationMinutes as number) <= 0 ||
    !Number.isInteger(body.shootersCount) ||
    (body.shootersCount as number) <= 0 ||
    reservationNote === undefined ||
    (reservationNote?.length ?? 0) > 1000
  ) {
    return null;
  }

  return {
    laneId,
    reservationDate,
    startTime,
    durationMinutes: body.durationMinutes as number,
    shootersCount: body.shootersCount as number,
    creationRequestId,
    reservationNote,
  };
}

export function isCreateReservationRpcResult(
  value: unknown
): value is CreateReservationRpcResult {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }

  const result = value as Partial<CreateReservationRpcResult>;

  if (
    typeof result.ok !== "boolean" ||
    typeof result.changed !== "boolean" ||
    typeof result.code !== "string" ||
    !CODE_SET.has(result.code)
  ) {
    return false;
  }

  if (!SUCCESS_CODES.has(result.code as CreateReservationCode)) {
    return result.ok === false && result.changed === false;
  }

  return (
    result.ok === true &&
    result.changed === (result.code === "created") &&
    typeof result.reservation_id === "string" &&
    UUID_PATTERN.test(result.reservation_id) &&
    typeof result.reservation_status === "string" &&
    typeof result.lane_name === "string" &&
    typeof result.shooters_count === "number" &&
    typeof result.duration_minutes === "number" &&
    (result.pricing_day_group === "mon_thu" ||
      result.pricing_day_group === "fri_sun") &&
    typeof result.price_per_hour === "number" &&
    typeof result.total_price === "number" &&
    typeof result.currency_code === "string"
  );
}

export function getCreateReservationHttpStatus(code: CreateReservationCode) {
  if (SUCCESS_CODES.has(code)) {
    return 200;
  }

  if (code === "unauthorized") {
    return 401;
  }

  if (
    code === "not_allowed" ||
    code === "profile_rejected"
  ) {
    return 403;
  }

  if (
    code === "verification_limit_reached" ||
    code === "lane_blocked" ||
    code === "slot_unavailable" ||
    code === "idempotency_conflict"
  ) {
    return 409;
  }

  if (
    code === "profile_not_found" ||
    code === "profile_incomplete" ||
    code === "lane_inactive" ||
    code === "pricing_not_configured"
  ) {
    return 422;
  }

  if (code === "internal_error") {
    return 500;
  }

  return 400;
}

export const CREATE_RESERVATION_MESSAGES: Record<
  CreateReservationCode,
  string
> = {
  created: "Rezerwacja została utworzona.",
  already_created: "Ta rezerwacja została już utworzona.",
  unauthorized: "Musisz zalogować się ponownie.",
  not_allowed: "To konto nie może tworzyć rezerwacji.",
  profile_not_found: "Nie znaleziono profilu użytkownika.",
  profile_incomplete: "Uzupełnij imię i nazwisko, e-mail oraz telefon w profilu.",
  profile_rejected: "Konto zostało odrzucone. Skontaktuj się z obsługą CSK.",
  verification_limit_reached:
    "Konto oczekuje na weryfikację i ma już aktywną rezerwację.",
  invalid_request: "Nieprawidłowe dane rezerwacji.",
  invalid_request_id: "Nieprawidłowy identyfikator żądania.",
  invalid_date: "Wybierz prawidłową datę rezerwacji.",
  reservation_already_started: "Wybrany termin już się rozpoczął.",
  invalid_start_time: "Wybrana godzina rozpoczęcia jest niedostępna.",
  outside_booking_hours: "Rezerwacja musi mieścić się w godzinach 08:00–20:00.",
  invalid_duration: "Wybrana długość rezerwacji nie jest już dostępna.",
  invalid_shooters_count: "Wybierz prawidłową liczbę strzelców.",
  capacity_exceeded: "Liczba strzelców przekracza pojemność osi.",
  lane_not_found: "Nie znaleziono wybranej osi.",
  lane_inactive: "Wybrana oś nie jest obecnie aktywna.",
  pricing_not_configured: "Cennik osi nie jest skonfigurowany.",
  lane_blocked: "Oś jest zablokowana w wybranym terminie.",
  slot_unavailable: "Termin został właśnie zajęty. Wybierz inną godzinę.",
  idempotency_conflict:
    "Identyfikator próby został użyty dla innych danych rezerwacji.",
  internal_error: "Nie udało się utworzyć rezerwacji. Spróbuj ponownie.",
};
