import { CALENDAR_ENTRY_TYPES, type CalendarFeedError, type CalendarFeedQuery } from "./types";
import {
  CALENDAR_MAX_RANGE_DAYS,
  compareCalendarDates,
  countCalendarDaysInclusive,
  isValidCalendarDate,
} from "./time";

const ALLOWED_QUERY_PARAMETERS = new Set([
  "rangeStart",
  "rangeEnd",
  "laneId",
  "types",
  "includeHistoricalStatuses",
]);

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type QueryResult =
  | { ok: true; value: CalendarFeedQuery }
  | { ok: false; error: CalendarFeedError };

function error(code: CalendarFeedError["code"], message: string): QueryResult {
  return { ok: false, error: { ok: false, code, message } };
}

export function parseCalendarFeedQuery(searchParams: URLSearchParams): QueryResult {
  for (const key of searchParams.keys()) {
    if (!ALLOWED_QUERY_PARAMETERS.has(key)) {
      return error("invalid_query", "Zapytanie zawiera nieobsługiwany parametr.");
    }

    if (searchParams.getAll(key).length !== 1) {
      return error("invalid_query", "Każdy parametr może wystąpić tylko raz.");
    }
  }

  const rangeStart = searchParams.get("rangeStart") ?? "";
  const rangeEnd = searchParams.get("rangeEnd") ?? "";

  if (!isValidCalendarDate(rangeStart) || !isValidCalendarDate(rangeEnd)) {
    return error("invalid_date", "Podaj poprawny zakres dat w formacie RRRR-MM-DD.");
  }

  if (compareCalendarDates(rangeStart, rangeEnd) === 1) {
    return error("invalid_range", "Początek zakresu nie może być późniejszy niż koniec.");
  }

  const days = countCalendarDaysInclusive(rangeStart, rangeEnd);
  if (days === null || days > CALENDAR_MAX_RANGE_DAYS) {
    return error("range_too_large", `Zakres może obejmować maksymalnie ${CALENDAR_MAX_RANGE_DAYS} dni.`);
  }

  const laneIdValue = searchParams.get("laneId") ?? "all";
  if (laneIdValue !== "all" && !UUID_PATTERN.test(laneIdValue)) {
    return error("invalid_query", "Identyfikator osi jest nieprawidłowy.");
  }

  const typesValue = searchParams.get("types");
  const types = typesValue === null ? [...CALENDAR_ENTRY_TYPES] : typesValue.split(",");
  const validTypes = new Set<string>(CALENDAR_ENTRY_TYPES);

  if (
    types.length === 0 ||
    types.some((type) => !type || !validTypes.has(type)) ||
    new Set(types).size !== types.length
  ) {
    return error("invalid_types", "Lista typów wpisów kalendarza jest nieprawidłowa.");
  }

  const historicalValue = searchParams.get("includeHistoricalStatuses") ?? "false";
  if (historicalValue !== "true" && historicalValue !== "false") {
    return error("invalid_query", "Parametr historii musi mieć wartość true albo false.");
  }

  return {
    ok: true,
    value: {
      rangeStart,
      rangeEnd,
      laneId: laneIdValue,
      types: types as CalendarFeedQuery["types"],
      includeHistoricalStatuses: historicalValue === "true",
    },
  };
}
