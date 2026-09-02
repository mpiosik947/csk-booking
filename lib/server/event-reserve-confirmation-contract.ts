export type ConfirmEventReserveResult = {
  ok: boolean;
  code:
    | "confirmed"
    | "full"
    | "expired"
    | "not_found"
    | "event_not_found"
    | "not_reserve";
  message: string;
  event_id?: string;
  registration_id?: string;
};

export type ConfirmEventReservePayloadResult =
  | { ok: true; token: string }
  | { ok: false };

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const RESULT_CODES = new Set<ConfirmEventReserveResult["code"]>([
  "confirmed",
  "full",
  "expired",
  "not_found",
  "event_not_found",
  "not_reserve",
]);

export function parseConfirmEventReservePayload(
  value: unknown
): ConfirmEventReservePayloadResult {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return { ok: false };
  }

  if (
    Object.keys(value).length !== 1 ||
    !("token" in value) ||
    typeof value.token !== "string"
  ) {
    return { ok: false };
  }

  const token = value.token.trim();

  if (!UUID_PATTERN.test(token)) {
    return { ok: false };
  }

  return { ok: true, token };
}

export function isConfirmEventReserveResult(
  value: unknown
): value is ConfirmEventReserveResult {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }

  const result = value as Partial<ConfirmEventReserveResult>;

  if (
    typeof result.ok !== "boolean" ||
    typeof result.code !== "string" ||
    !RESULT_CODES.has(result.code as ConfirmEventReserveResult["code"]) ||
    typeof result.message !== "string" ||
    result.message.trim().length === 0
  ) {
    return false;
  }

  if (result.code === "confirmed") {
    return (
      result.ok === true &&
      typeof result.event_id === "string" &&
      UUID_PATTERN.test(result.event_id) &&
      typeof result.registration_id === "string" &&
      UUID_PATTERN.test(result.registration_id)
    );
  }

  return result.ok === false;
}

export function getConfirmEventReserveStatus(
  code: ConfirmEventReserveResult["code"]
) {
  if (code === "confirmed") {
    return 200;
  }

  if (code === "not_found" || code === "event_not_found") {
    return 404;
  }

  if (code === "expired") {
    return 410;
  }

  return 409;
}
