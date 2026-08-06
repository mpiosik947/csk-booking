export type AdminEventLane = {
  id: string;
  name: string;
  type: string;
  is_active: boolean;
  display_order: number;
};

export type AdminEvent = {
  id: string;
  title: string;
  description: string | null;
  event_date: string;
  start_time: string;
  end_time: string;
  location: string | null;
  price: number;
  max_participants: number;
  is_active: boolean;
  created_at: string;
  laneIds: string[];
  lanes: AdminEventLane[];
};

export type EventFormInput = {
  title: string;
  description: string;
  eventDate: string;
  startTime: string;
  endTime: string;
  location: string;
  price: string;
  maxParticipants: string;
  laneIds: string[];
};

export type EventRpcConflictType = "reservation" | "lane_block" | "event";

export type EventRpcResult = {
  ok: boolean;
  changed: boolean;
  code: string;
  event_id: string | null;
  conflict_type?: EventRpcConflictType;
  conflict_lane_id?: string | null;
};

export type EventMessageKind = "success" | "neutral" | "error";

export type EventManagementMessage = {
  kind: EventMessageKind;
  message: string;
};

export type EventFormErrorCode =
  | "invalid_title"
  | "invalid_date"
  | "invalid_time"
  | "invalid_time_range"
  | "invalid_price"
  | "invalid_max_participants"
  | "invalid_lane_ids"
  | "outside_booking_hours";

type NormalizationResult =
  | { ok: true; value: AdminEvent }
  | { ok: false; code: "invalid_event"; message: string };

export type ValidatedEventForm = {
  title: string;
  description: string;
  eventDate: string;
  startTime: string;
  endTime: string;
  location: string;
  price: number;
  maxParticipants: number;
  laneIds: string[];
};

export type EventFormValidationResult =
  | { ok: true; value: ValidatedEventForm }
  | {
      ok: false;
      code: EventFormErrorCode;
      message: string;
    };

export type CreateEventRpcPayload = {
  p_title: string;
  p_description: string;
  p_event_date: string;
  p_start_time: string;
  p_end_time: string;
  p_location: string;
  p_price: number;
  p_max_participants: number;
  p_lane_ids: string[];
};

export type UpdateEventRpcPayload = CreateEventRpcPayload & {
  p_event_id: string;
};

export type SetEventActiveRpcPayload = {
  p_event_id: string;
  p_is_active: boolean;
};

export type EventPayloadBuildResult<T> =
  | { ok: true; value: T }
  | {
      ok: false;
      code: "invalid_event_id";
      message: string;
    };

export type EventRpcValidationResult =
  | { ok: true; value: EventRpcResult }
  | {
      ok: false;
      code: "invalid_rpc_response";
      message: string;
    };

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TIME_PATTERN = /^(?:[01]\d|2[0-3]):[0-5]\d$/;
const DATABASE_TIME_PATTERN =
  /^(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d(?:\.\d{1,6})?)?$/;
const DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function isUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_PATTERN.test(value);
}

function isValidIsoDate(value: unknown): value is string {
  if (typeof value !== "string" || !DATE_PATTERN.test(value)) {
    return false;
  }

  const [year, month, day] = value.split("-").map(Number);
  const normalized = new Date(Date.UTC(year, month - 1, day));
  return (
    normalized.getUTCFullYear() === year &&
    normalized.getUTCMonth() === month - 1 &&
    normalized.getUTCDate() === day
  );
}

function normalizeFiniteNumber(value: unknown): number | null {
  if (typeof value === "number") {
    return Number.isFinite(value) ? value : null;
  }

  if (typeof value !== "string" || !value.trim()) {
    return null;
  }

  const normalized = Number(value);
  return Number.isFinite(normalized) ? normalized : null;
}

function normalizeLane(value: unknown): AdminEventLane | null {
  if (!isRecord(value)) {
    return null;
  }

  if (
    !isUuid(value.id) ||
    !isNonEmptyString(value.name) ||
    !isNonEmptyString(value.type) ||
    typeof value.is_active !== "boolean" ||
    typeof value.display_order !== "number" ||
    !Number.isInteger(value.display_order)
  ) {
    return null;
  }

  return {
    id: value.id,
    name: value.name,
    type: value.type,
    is_active: value.is_active,
    display_order: value.display_order,
  };
}

function compareLanes(first: AdminEventLane, second: AdminEventLane) {
  if (first.display_order !== second.display_order) {
    return first.display_order - second.display_order;
  }

  const nameComparison = first.name.localeCompare(second.name, "pl");
  return nameComparison !== 0 ? nameComparison : first.id.localeCompare(second.id);
}

function compareLaneCandidates(first: AdminEventLane, second: AdminEventLane) {
  const displayComparison = compareLanes(first, second);
  if (displayComparison !== 0) {
    return displayComparison;
  }

  const typeComparison = first.type.localeCompare(second.type, "pl");
  return typeComparison !== 0
    ? typeComparison
    : Number(second.is_active) - Number(first.is_active);
}

export function normalizeActiveEventLanes(
  value: unknown
): AdminEventLane[] | null {
  if (!Array.isArray(value)) {
    return null;
  }

  const lanes: AdminEventLane[] = [];
  const laneIds = new Set<string>();

  for (const candidate of value) {
    const lane = normalizeLane(candidate);

    if (!lane || !lane.is_active || laneIds.has(lane.id)) {
      return null;
    }

    laneIds.add(lane.id);
    lanes.push(lane);
  }

  return lanes.sort(compareLanes);
}

export function getEditableEventLanes(
  activeLanes: readonly AdminEventLane[],
  assignedLanes: readonly AdminEventLane[]
): AdminEventLane[] {
  const lanesById = new Map<string, AdminEventLane>();

  for (const lane of activeLanes) {
    lanesById.set(lane.id, lane);
  }

  for (const lane of assignedLanes) {
    if (!lane.is_active && !lanesById.has(lane.id)) {
      lanesById.set(lane.id, lane);
    }
  }

  return [...lanesById.values()].sort(compareLanes);
}

export function normalizeAdminEvent(value: unknown): NormalizationResult {
  if (!isRecord(value)) {
    return {
      ok: false,
      code: "invalid_event",
      message: "Nieprawidłowy rekord szkolenia.",
    };
  }

  const price = normalizeFiniteNumber(value.price);

  if (
    !isUuid(value.id) ||
    !isNonEmptyString(value.title) ||
    (value.description !== null && typeof value.description !== "string") ||
    !isValidIsoDate(value.event_date) ||
    typeof value.start_time !== "string" ||
    !DATABASE_TIME_PATTERN.test(value.start_time) ||
    typeof value.end_time !== "string" ||
    !DATABASE_TIME_PATTERN.test(value.end_time) ||
    (value.location !== null && typeof value.location !== "string") ||
    price === null ||
    typeof value.max_participants !== "number" ||
    !Number.isInteger(value.max_participants) ||
    value.max_participants <= 0 ||
    typeof value.is_active !== "boolean" ||
    !isNonEmptyString(value.created_at)
  ) {
    return {
      ok: false,
      code: "invalid_event",
      message: "Nieprawidłowy rekord szkolenia.",
    };
  }

  const relations = Array.isArray(value.event_lanes) ? value.event_lanes : [];
  const laneCandidates: AdminEventLane[] = [];

  for (const relation of relations) {
    if (!isRecord(relation) || !isUuid(relation.lane_id)) {
      continue;
    }

    const relatedLane = Array.isArray(relation.shooting_lanes)
      ? relation.shooting_lanes.length === 1
        ? relation.shooting_lanes[0]
        : null
      : relation.shooting_lanes;
    const lane = normalizeLane(relatedLane);

    if (!lane || lane.id !== relation.lane_id) {
      continue;
    }

    laneCandidates.push(lane);
  }

  laneCandidates.sort(compareLaneCandidates);
  const seenLaneIds = new Set<string>();
  const lanes = laneCandidates.filter((lane) => {
    if (seenLaneIds.has(lane.id)) {
      return false;
    }

    seenLaneIds.add(lane.id);
    return true;
  });

  return {
    ok: true,
    value: {
      id: value.id,
      title: value.title,
      description: value.description,
      event_date: value.event_date,
      start_time: value.start_time,
      end_time: value.end_time,
      location: value.location,
      price,
      max_participants: value.max_participants,
      is_active: value.is_active,
      created_at: value.created_at,
      laneIds: lanes.map((lane) => lane.id),
      lanes,
    },
  };
}

function timeToMinutes(value: string) {
  const [hours, minutes] = value.split(":").map(Number);
  return hours * 60 + minutes;
}

function validationError(
  code: EventFormErrorCode,
  message: string
): EventFormValidationResult {
  return { ok: false, code, message };
}

export function validateEventForm(
  input: EventFormInput
): EventFormValidationResult {
  if (!input.title.trim()) {
    return validationError("invalid_title", "Podaj nazwę szkolenia.");
  }

  if (!isValidIsoDate(input.eventDate.trim())) {
    return validationError("invalid_date", "Wybierz datę szkolenia.");
  }

  if (!TIME_PATTERN.test(input.startTime) || !TIME_PATTERN.test(input.endTime)) {
    return validationError("invalid_time", "Podaj poprawne godziny szkolenia.");
  }

  const startMinutes = timeToMinutes(input.startTime);
  const endMinutes = timeToMinutes(input.endTime);

  if (endMinutes <= startMinutes) {
    return validationError(
      "invalid_time_range",
      "Godzina zakończenia musi być późniejsza niż rozpoczęcia."
    );
  }

  if (!input.price.trim()) {
    return validationError("invalid_price", "Podaj poprawną cenę szkolenia.");
  }

  const price = Number(input.price);
  if (!Number.isFinite(price) || price < 0) {
    return validationError("invalid_price", "Podaj poprawną cenę szkolenia.");
  }

  if (!input.maxParticipants.trim()) {
    return validationError(
      "invalid_max_participants",
      "Podaj poprawną liczbę miejsc."
    );
  }

  const maxParticipants = Number(input.maxParticipants);
  if (
    !Number.isFinite(maxParticipants) ||
    !Number.isInteger(maxParticipants) ||
    maxParticipants <= 0
  ) {
    return validationError(
      "invalid_max_participants",
      "Podaj poprawną liczbę miejsc."
    );
  }

  if (
    !Array.isArray(input.laneIds) ||
    input.laneIds.some((laneId) => !isUuid(laneId)) ||
    new Set(input.laneIds).size !== input.laneIds.length
  ) {
    return validationError("invalid_lane_ids", "Sprawdź wybrane osie.");
  }

  if (
    input.laneIds.length > 0 &&
    (startMinutes < timeToMinutes("08:00") ||
      endMinutes > timeToMinutes("20:00"))
  ) {
    return validationError(
      "outside_booking_hours",
      "Event zajmujący oś musi mieścić się w godzinach 08:00–20:00."
    );
  }

  return {
    ok: true,
    value: {
      title: input.title.trim(),
      description: input.description.trim(),
      eventDate: input.eventDate.trim(),
      startTime: input.startTime,
      endTime: input.endTime,
      location: input.location.trim(),
      price,
      maxParticipants,
      laneIds: [...input.laneIds].sort(),
    },
  };
}

export function buildCreateEventPayload(
  value: ValidatedEventForm
): CreateEventRpcPayload {
  return {
    p_title: value.title,
    p_description: value.description,
    p_event_date: value.eventDate,
    p_start_time: value.startTime,
    p_end_time: value.endTime,
    p_location: value.location,
    p_price: value.price,
    p_max_participants: value.maxParticipants,
    p_lane_ids: [...value.laneIds].sort(),
  };
}

export function buildUpdateEventPayload(
  eventId: string,
  value: ValidatedEventForm
): EventPayloadBuildResult<UpdateEventRpcPayload> {
  if (!isUuid(eventId)) {
    return {
      ok: false,
      code: "invalid_event_id",
      message: "Nieprawidłowy identyfikator szkolenia.",
    };
  }

  return {
    ok: true,
    value: {
      p_event_id: eventId,
      ...buildCreateEventPayload(value),
    },
  };
}

export function buildSetEventActivePayload(
  eventId: string,
  isActive: boolean
): EventPayloadBuildResult<SetEventActiveRpcPayload> {
  if (!isUuid(eventId)) {
    return {
      ok: false,
      code: "invalid_event_id",
      message: "Nieprawidłowy identyfikator szkolenia.",
    };
  }

  return {
    ok: true,
    value: {
      p_event_id: eventId,
      p_is_active: isActive,
    },
  };
}

function invalidRpcResponse(): EventRpcValidationResult {
  return {
    ok: false,
    code: "invalid_rpc_response",
    message: "Nie udało się potwierdzić wyniku operacji.",
  };
}

const SUCCESS_CODES = new Set([
  "created",
  "updated",
  "activated",
  "deactivated",
]);

const ERROR_CODES = new Set([
  "not_allowed",
  "invalid_input",
  "invalid_time_range",
  "outside_booking_hours",
  "invalid_lane",
  "inactive_lane",
  "reservation_conflict",
  "lane_block_conflict",
  "event_conflict",
  "event_not_found",
]);

export function validateEventRpcResult(
  value: unknown
): EventRpcValidationResult {
  if (
    !isRecord(value) ||
    typeof value.ok !== "boolean" ||
    typeof value.changed !== "boolean" ||
    !isNonEmptyString(value.code) ||
    (value.event_id !== null && !isUuid(value.event_id))
  ) {
    return invalidRpcResponse();
  }

  const conflictType = value.conflict_type;
  if (
    conflictType !== undefined &&
    conflictType !== "reservation" &&
    conflictType !== "lane_block" &&
    conflictType !== "event"
  ) {
    return invalidRpcResponse();
  }

  const conflictLaneId = value.conflict_lane_id;
  if (
    conflictLaneId !== undefined &&
    conflictLaneId !== null &&
    !isUuid(conflictLaneId)
  ) {
    return invalidRpcResponse();
  }

  const expectedConflictTypes: Readonly<Record<string, EventRpcConflictType>> = {
    reservation_conflict: "reservation",
    lane_block_conflict: "lane_block",
    event_conflict: "event",
  };
  const expectedConflictType = expectedConflictTypes[value.code];

  if (
    expectedConflictType !== undefined &&
    (conflictType !== expectedConflictType || !isUuid(conflictLaneId))
  ) {
    return invalidRpcResponse();
  }

  if (
    expectedConflictType === undefined &&
    (conflictType !== undefined ||
      ((value.code === "invalid_lane" || value.code === "inactive_lane")
        ? !isUuid(conflictLaneId)
        : conflictLaneId !== undefined && conflictLaneId !== null))
  ) {
    return invalidRpcResponse();
  }

  if (
    (value.code === "created" ||
      value.code === "updated" ||
      value.code === "activated" ||
      value.code === "deactivated") &&
    !isUuid(value.event_id)
  ) {
    return invalidRpcResponse();
  }

  if (
    (SUCCESS_CODES.has(value.code) && (!value.ok || !value.changed)) ||
    (value.code === "no_change" && (!value.ok || value.changed)) ||
    (ERROR_CODES.has(value.code) && (value.ok || value.changed))
  ) {
    return invalidRpcResponse();
  }

  return {
    ok: true,
    value: {
      ok: value.ok,
      changed: value.changed,
      code: value.code,
      event_id: value.event_id,
      ...(conflictType === undefined ? {} : { conflict_type: conflictType }),
      ...(conflictLaneId === undefined
        ? {}
        : { conflict_lane_id: conflictLaneId }),
    },
  };
}

const CODE_MESSAGES: Readonly<Record<string, string>> = {
  created: "Szkolenie zostało dodane.",
  updated: "Szkolenie zostało zaktualizowane.",
  activated: "Szkolenie zostało aktywowane.",
  deactivated: "Szkolenie zostało ukryte.",
  no_change: "Nie wprowadzono żadnych zmian.",
  not_allowed: "Nie masz uprawnień do zarządzania szkoleniami.",
  invalid_input: "Sprawdź poprawność danych szkolenia.",
  invalid_time_range:
    "Godzina zakończenia musi być późniejsza niż rozpoczęcia.",
  outside_booking_hours:
    "Event zajmujący oś musi mieścić się w godzinach 08:00–20:00.",
  invalid_lane: "Wybrana oś nie istnieje.",
  inactive_lane: "Wybrana oś jest nieaktywna.",
  reservation_conflict: "Termin koliduje z istniejącą rezerwacją",
  lane_block_conflict: "Termin koliduje z blokadą osi",
  event_conflict: "Termin koliduje z innym szkoleniem",
  event_not_found: "Nie znaleziono szkolenia. Odśwież listę.",
  invalid_rpc_response: "Nie udało się wykonać operacji. Spróbuj ponownie.",
};

function resolveLaneName(
  laneId: string | null | undefined,
  laneNames: ReadonlyMap<string, string> | Readonly<Record<string, string>>
) {
  if (!laneId) {
    return null;
  }

  const name =
    laneNames instanceof Map
      ? laneNames.get(laneId)
      : (laneNames as Readonly<Record<string, string>>)[laneId];
  return typeof name === "string" && name.trim() ? name.trim() : null;
}

export function getEventManagementMessage(
  result: Pick<EventRpcResult, "code" | "conflict_lane_id"> | {
    code: "invalid_rpc_response";
  },
  laneNames: ReadonlyMap<string, string> | Readonly<Record<string, string>> = {}
): EventManagementMessage {
  const code = result.code;
  const baseMessage = CODE_MESSAGES[code];

  if (!baseMessage) {
    return {
      kind: "error",
      message: "Nie udało się wykonać operacji. Spróbuj ponownie.",
    };
  }

  if (
    code === "reservation_conflict" ||
    code === "lane_block_conflict" ||
    code === "event_conflict"
  ) {
    const laneName = resolveLaneName(result.conflict_lane_id, laneNames);
    return {
      kind: "error",
      message: laneName ? `${baseMessage} na osi: ${laneName}.` : `${baseMessage}.`,
    };
  }

  return {
    kind: SUCCESS_CODES.has(code)
      ? "success"
      : code === "no_change"
        ? "neutral"
        : "error",
    message: baseMessage,
  };
}
