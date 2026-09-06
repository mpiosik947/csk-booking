export const EVENT_TIME_ZONE = "Europe/Warsaw" as const;
export const EVENT_CANCELLATION_CUTOFF_HOURS = 72 as const;
export const RESERVATION_CANCELLATION_CUTOFF_HOURS = 12 as const;

const DATE_PATTERN = /^(\d{4})-(\d{2})-(\d{2})$/;
const TIME_PATTERN = /^(\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?$/;
const MILLISECONDS_PER_HOUR = 60 * 60 * 1000;

const warsawPartsFormatter = new Intl.DateTimeFormat("en-GB", {
  timeZone: EVENT_TIME_ZONE,
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hourCycle: "h23",
  numberingSystem: "latn",
});

const cancellationDeadlineFormatter = new Intl.DateTimeFormat("pl-PL", {
  timeZone: EVENT_TIME_ZONE,
  year: "numeric",
  month: "long",
  day: "numeric",
  hour: "2-digit",
  minute: "2-digit",
  hourCycle: "h23",
});

type DateTimeParts = {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
  second: number;
};

function parseEventDateTime(eventDate: string, startTime: string) {
  const dateMatch = DATE_PATTERN.exec(eventDate);
  const timeMatch = TIME_PATTERN.exec(startTime);

  if (!dateMatch || !timeMatch) return null;

  const parts: DateTimeParts = {
    year: Number(dateMatch[1]),
    month: Number(dateMatch[2]),
    day: Number(dateMatch[3]),
    hour: Number(timeMatch[1]),
    minute: Number(timeMatch[2]),
    second: Number(timeMatch[3] ?? "0"),
  };
  const validationDate = new Date(
    Date.UTC(parts.year, parts.month - 1, parts.day)
  );

  if (
    validationDate.getUTCFullYear() !== parts.year ||
    validationDate.getUTCMonth() !== parts.month - 1 ||
    validationDate.getUTCDate() !== parts.day ||
    parts.hour > 23 ||
    parts.minute > 59 ||
    parts.second > 59
  ) {
    return null;
  }

  return parts;
}

function getWarsawParts(value: Date): DateTimeParts | null {
  const values = new Map(
    warsawPartsFormatter
      .formatToParts(value)
      .filter((part) => part.type !== "literal")
      .map((part) => [part.type, Number(part.value)])
  );
  const parts = {
    year: values.get("year"),
    month: values.get("month"),
    day: values.get("day"),
    hour: values.get("hour"),
    minute: values.get("minute"),
    second: values.get("second"),
  };

  if (Object.values(parts).some((part) => part === undefined)) return null;

  return parts as DateTimeParts;
}

function partsToUtcMilliseconds(parts: DateTimeParts) {
  return Date.UTC(
    parts.year,
    parts.month - 1,
    parts.day,
    parts.hour,
    parts.minute,
    parts.second
  );
}

function sameParts(first: DateTimeParts, second: DateTimeParts) {
  return (
    first.year === second.year &&
    first.month === second.month &&
    first.day === second.day &&
    first.hour === second.hour &&
    first.minute === second.minute &&
    first.second === second.second
  );
}

export function getWarsawEventStartInstant(
  eventDate: string,
  startTime: string
) {
  const requestedParts = parseEventDateTime(eventDate, startTime);
  if (!requestedParts) return null;

  const wallClockUtc = partsToUtcMilliseconds(requestedParts);
  const initialInstant = new Date(wallClockUtc);
  const initialWarsawParts = getWarsawParts(initialInstant);
  if (!initialWarsawParts) return null;

  const initialOffset = partsToUtcMilliseconds(initialWarsawParts) - wallClockUtc;
  const firstCandidate = wallClockUtc - initialOffset;
  const firstCandidateWarsawParts = getWarsawParts(new Date(firstCandidate));
  if (!firstCandidateWarsawParts) return null;

  const correctedOffset =
    partsToUtcMilliseconds(firstCandidateWarsawParts) - firstCandidate;
  const candidate = wallClockUtc - correctedOffset;
  const candidateDate = new Date(candidate);
  const candidateWarsawParts = getWarsawParts(candidateDate);

  return candidateWarsawParts && sameParts(candidateWarsawParts, requestedParts)
    ? candidateDate
    : null;
}

export function hasWarsawEventStarted(
  eventDate: string,
  startTime: string,
  now = new Date()
) {
  const eventStart = getWarsawEventStartInstant(eventDate, startTime);
  return !eventStart || now.getTime() >= eventStart.getTime();
}

export function getWarsawCancellationDeadline(
  eventDate: string,
  startTime: string,
  cutoffHours: number
) {
  const eventStart = getWarsawEventStartInstant(eventDate, startTime);

  if (!eventStart || !Number.isFinite(cutoffHours) || cutoffHours < 0) {
    return null;
  }

  return new Date(
    eventStart.getTime() - cutoffHours * MILLISECONDS_PER_HOUR
  );
}

export function formatWarsawCancellationDeadline(
  eventDate: string,
  startTime: string,
  cutoffHours: number
) {
  const deadline = getWarsawCancellationDeadline(
    eventDate,
    startTime,
    cutoffHours
  );

  return deadline
    ? `${cancellationDeadlineFormatter.format(deadline)} (Europe/Warsaw)`
    : null;
}

export function isBeforeWarsawCancellationCutoff(
  eventDate: string,
  startTime: string,
  cutoffHours: number,
  now = new Date()
) {
  const deadline = getWarsawCancellationDeadline(
    eventDate,
    startTime,
    cutoffHours
  );

  return Boolean(
    deadline &&
      Number.isFinite(now.getTime()) &&
      now.getTime() <= deadline.getTime()
  );
}

export function isEventCancellationBeforeCutoff(
  eventDate: string,
  startTime: string,
  now = new Date()
) {
  return isBeforeWarsawCancellationCutoff(
    eventDate,
    startTime,
    EVENT_CANCELLATION_CUTOFF_HOURS,
    now
  );
}
