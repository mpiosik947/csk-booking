export const LANE_BLOCK_GENERIC_ERROR =
  "Nie udało się wykonać operacji. Spróbuj ponownie.";

export type LaneBlockRpcCode =
  | "created"
  | "activated"
  | "deactivated"
  | "no_change"
  | "not_allowed"
  | "invalid_input"
  | "block_not_found"
  | "invalid_lane"
  | "inactive_lane"
  | "conflict_reservation"
  | "conflict_event"
  | "invalid_hierarchy"
  | "internal_error";

export type LaneBlockRpcResult = {
  ok: boolean;
  changed: boolean;
  code: LaneBlockRpcCode;
  lane_block_id: string | null;
};

export type LaneBlockRpcValidationResult =
  | { ok: true; value: LaneBlockRpcResult }
  | { ok: false };

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const SUCCESS_CODES = new Set<LaneBlockRpcCode>([
  "created",
  "activated",
  "deactivated",
]);

const ERROR_CODES = new Set<LaneBlockRpcCode>([
  "not_allowed",
  "invalid_input",
  "block_not_found",
  "invalid_lane",
  "inactive_lane",
  "conflict_reservation",
  "conflict_event",
  "invalid_hierarchy",
  "internal_error",
]);

const KNOWN_CODES = new Set<LaneBlockRpcCode>([
  ...SUCCESS_CODES,
  "no_change",
  ...ERROR_CODES,
]);

const ERROR_MESSAGES: Readonly<Record<string, string>> = {
  not_allowed: "Nie masz uprawnień do wykonania tej operacji.",
  invalid_input: "Sprawdź wprowadzone dane.",
  block_not_found: "Nie znaleziono tej blokady.",
  invalid_lane: "Wybrana oś jest niedostępna.",
  inactive_lane: "Wybrana oś nie jest obecnie aktywna.",
  conflict_reservation:
    "Nie można utworzyć blokady, ponieważ w tym czasie istnieje rezerwacja.",
  conflict_event:
    "Nie można utworzyć blokady, ponieważ w tym czasie odbywa się szkolenie lub wydarzenie.",
  invalid_hierarchy:
    "Nie można wykonać operacji z powodu nieprawidłowej konfiguracji osi.",
  internal_error: LANE_BLOCK_GENERIC_ERROR,
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isLaneBlockRpcCode(value: unknown): value is LaneBlockRpcCode {
  return typeof value === "string" && KNOWN_CODES.has(value as LaneBlockRpcCode);
}

function isUuidOrNull(value: unknown): value is string | null {
  return value === null || (typeof value === "string" && UUID_PATTERN.test(value));
}

export function validateLaneBlockRpcResult(
  value: unknown
): LaneBlockRpcValidationResult {
  if (
    !isRecord(value) ||
    typeof value.ok !== "boolean" ||
    typeof value.changed !== "boolean" ||
    !isLaneBlockRpcCode(value.code) ||
    !isUuidOrNull(value.lane_block_id)
  ) {
    return { ok: false };
  }

  const successWithChange = SUCCESS_CODES.has(value.code);
  const noChange = value.code === "no_change";
  const controlledError = ERROR_CODES.has(value.code);

  if (
    (successWithChange &&
      (!value.ok || !value.changed || value.lane_block_id === null)) ||
    (noChange &&
      (!value.ok || value.changed || value.lane_block_id === null)) ||
    (controlledError && (value.ok || value.changed))
  ) {
    return { ok: false };
  }

  return {
    ok: true,
    value: {
      ok: value.ok,
      changed: value.changed,
      code: value.code,
      lane_block_id: value.lane_block_id,
    },
  };
}

export function getLaneBlockErrorMessage(code: string): string {
  return ERROR_MESSAGES[code] ?? LANE_BLOCK_GENERIC_ERROR;
}
