export type PublicEventAvailability = {
  id: string;
  title: string;
  description: string;
  event_date: string;
  start_time: string;
  end_time: string;
  location: string;
  price: number;
  max_participants: number;
  registered_count: number;
  reserve_count: number;
  available_spots: number;
  sold_out: boolean;
};

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;
const TIME_PATTERN = /^\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?$/;
const ROW_KEYS = [
  "available_spots",
  "description",
  "end_time",
  "event_date",
  "event_id",
  "location",
  "max_participants",
  "price",
  "registered_count",
  "reserve_count",
  "sold_out",
  "start_time",
  "title",
];

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function hasExactKeys(value: Record<string, unknown>) {
  const keys = Object.keys(value).sort();
  return (
    keys.length === ROW_KEYS.length &&
    keys.every((key, index) => key === ROW_KEYS[index])
  );
}

function isNonNegativeInteger(value: unknown): value is number {
  return Number.isInteger(value) && Number(value) >= 0;
}

function parseRow(value: unknown): PublicEventAvailability | null {
  if (!isRecord(value) || !hasExactKeys(value)) {
    return null;
  }

  if (
    typeof value.event_id !== "string" ||
    !UUID_PATTERN.test(value.event_id) ||
    typeof value.title !== "string" ||
    value.title.trim().length === 0 ||
    typeof value.description !== "string" ||
    typeof value.event_date !== "string" ||
    !DATE_PATTERN.test(value.event_date) ||
    typeof value.start_time !== "string" ||
    !TIME_PATTERN.test(value.start_time) ||
    typeof value.end_time !== "string" ||
    !TIME_PATTERN.test(value.end_time) ||
    typeof value.location !== "string" ||
    typeof value.price !== "number" ||
    !Number.isFinite(value.price) ||
    value.price < 0 ||
    typeof value.max_participants !== "number" ||
    !Number.isInteger(value.max_participants) ||
    value.max_participants <= 0 ||
    !isNonNegativeInteger(value.registered_count) ||
    !isNonNegativeInteger(value.reserve_count) ||
    !isNonNegativeInteger(value.available_spots) ||
    typeof value.sold_out !== "boolean"
  ) {
    return null;
  }

  const expectedAvailableSpots = Math.max(
    value.max_participants - value.registered_count,
    0
  );

  if (
    value.available_spots !== expectedAvailableSpots ||
    value.sold_out !== (expectedAvailableSpots === 0)
  ) {
    return null;
  }

  return {
    id: value.event_id,
    title: value.title,
    description: value.description,
    event_date: value.event_date,
    start_time: value.start_time,
    end_time: value.end_time,
    location: value.location,
    price: value.price,
    max_participants: value.max_participants,
    registered_count: value.registered_count,
    reserve_count: value.reserve_count,
    available_spots: value.available_spots,
    sold_out: value.sold_out,
  };
}

export function parsePublicEventAvailability(
  value: unknown
): PublicEventAvailability[] | null {
  if (!Array.isArray(value)) {
    return null;
  }

  const events: PublicEventAvailability[] = [];
  const eventIds = new Set<string>();

  for (const item of value) {
    const event = parseRow(item);

    if (!event || eventIds.has(event.id)) {
      return null;
    }

    eventIds.add(event.id);
    events.push(event);
  }

  return events;
}

export function getPublicRegistrationAvailability(
  event: PublicEventAvailability
) {
  const hasReserveList = event.reserve_count > 0;
  const directlyAvailableSpots = hasReserveList ? 0 : event.available_spots;

  return {
    directlyAvailableSpots,
    requiresReserveList: hasReserveList || event.sold_out,
  };
}
