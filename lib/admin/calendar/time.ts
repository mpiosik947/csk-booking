export const CALENDAR_TIME_ZONE = "Europe/Warsaw" as const;
export const CALENDAR_OPENING_START = "08:00" as const;
export const CALENDAR_OPENING_END = "20:00" as const;
export const CALENDAR_MAX_RANGE_DAYS = 42;

const DATE_PATTERN = /^(\d{4})-(\d{2})-(\d{2})$/;
const TIME_PATTERN = /^(\d{2}):(\d{2})$/;
const MILLISECONDS_PER_DAY = 86_400_000;

type CalendarDateParts = {
  year: number;
  month: number;
  day: number;
};

export type CalendarTimeRange = {
  startTime: string;
  endTime: string;
};

function isLeapYear(year: number) {
  return year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
}

function daysInMonth(year: number, month: number) {
  const monthLengths = [
    31,
    isLeapYear(year) ? 29 : 28,
    31,
    30,
    31,
    30,
    31,
    31,
    30,
    31,
    30,
    31,
  ];

  return monthLengths[month - 1] ?? 0;
}

function parseCalendarDate(value: string): CalendarDateParts | null {
  const match = DATE_PATTERN.exec(value);

  if (!match) return null;

  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);

  if (month < 1 || month > 12 || day < 1 || day > daysInMonth(year, month)) {
    return null;
  }

  return { year, month, day };
}

function calendarDateToEpochDay(value: string) {
  const parts = parseCalendarDate(value);

  if (!parts) return null;

  return Math.floor(
    Date.UTC(parts.year, parts.month - 1, parts.day) / MILLISECONDS_PER_DAY
  );
}

function minutesToCalendarTime(minutes: number) {
  return `${String(Math.floor(minutes / 60)).padStart(2, "0")}:${String(
    minutes % 60
  ).padStart(2, "0")}`;
}

export function isValidCalendarDate(value: string) {
  return parseCalendarDate(value) !== null;
}

export function compareCalendarDates(first: string, second: string) {
  const firstDay = calendarDateToEpochDay(first);
  const secondDay = calendarDateToEpochDay(second);

  if (firstDay === null || secondDay === null) return null;

  return Math.sign(firstDay - secondDay);
}

export function countCalendarDaysInclusive(start: string, end: string) {
  const startDay = calendarDateToEpochDay(start);
  const endDay = calendarDateToEpochDay(end);

  if (startDay === null || endDay === null || endDay < startDay) return null;

  return endDay - startDay + 1;
}

export function getCalendarDatesInclusive(start: string, end: string) {
  const startDay = calendarDateToEpochDay(start);
  const endDay = calendarDateToEpochDay(end);

  if (startDay === null || endDay === null || endDay < startDay) return null;

  const dates: string[] = [];
  for (let epochDay = startDay; epochDay <= endDay; epochDay += 1) {
    const date = new Date(epochDay * MILLISECONDS_PER_DAY);
    dates.push(
      `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(
        2,
        "0"
      )}-${String(date.getUTCDate()).padStart(2, "0")}`
    );
  }

  return dates;
}

export function getWarsawCalendarDate(now = new Date()) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: CALENDAR_TIME_ZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(now);

  const values = new Map(parts.map((part) => [part.type, part.value]));
  const year = values.get("year");
  const month = values.get("month");
  const day = values.get("day");

  if (!year || !month || !day) {
    throw new Error("Unable to determine the Warsaw calendar date.");
  }

  return `${year}-${month}-${day}`;
}

export function isValidCalendarTime(value: string) {
  const match = TIME_PATTERN.exec(value);

  if (!match) return false;

  const hours = Number(match[1]);
  const minutes = Number(match[2]);
  return hours >= 0 && hours <= 23 && minutes >= 0 && minutes <= 59;
}

export function calendarTimeToMinutes(value: string) {
  if (!isValidCalendarTime(value)) return null;

  const [hours, minutes] = value.split(":").map(Number);
  return hours * 60 + minutes;
}

export function getCalendarRangeDurationMinutes(startTime: string, endTime: string) {
  const startMinutes = calendarTimeToMinutes(startTime);
  const endMinutes = calendarTimeToMinutes(endTime);

  if (startMinutes === null || endMinutes === null || startMinutes >= endMinutes) {
    return null;
  }

  return endMinutes - startMinutes;
}

export function calendarTimeRangesOverlap(
  first: CalendarTimeRange,
  second: CalendarTimeRange
) {
  const firstStart = calendarTimeToMinutes(first.startTime);
  const firstEnd = calendarTimeToMinutes(first.endTime);
  const secondStart = calendarTimeToMinutes(second.startTime);
  const secondEnd = calendarTimeToMinutes(second.endTime);

  if (
    firstStart === null ||
    firstEnd === null ||
    secondStart === null ||
    secondEnd === null ||
    firstStart >= firstEnd ||
    secondStart >= secondEnd
  ) {
    return false;
  }

  return firstStart < secondEnd && firstEnd > secondStart;
}

export function mergeCalendarTimeRanges(ranges: CalendarTimeRange[]) {
  const normalized = ranges
    .map((range) => {
      const start = calendarTimeToMinutes(range.startTime);
      const end = calendarTimeToMinutes(range.endTime);
      if (start === null || end === null || start >= end) {
        throw new Error("Invalid calendar time range.");
      }
      return { start, end };
    })
    .sort((first, second) => first.start - second.start || first.end - second.end);

  const merged: Array<{ start: number; end: number }> = [];
  for (const range of normalized) {
    const previous = merged.at(-1);
    if (!previous || range.start > previous.end) {
      merged.push({ ...range });
      continue;
    }
    previous.end = Math.max(previous.end, range.end);
  }

  return merged.map((range) => ({
    startTime: minutesToCalendarTime(range.start),
    endTime: minutesToCalendarTime(range.end),
  }));
}

export function getCalendarTimeRangesUnionMinutes(ranges: CalendarTimeRange[]) {
  return mergeCalendarTimeRanges(ranges).reduce(
    (total, range) =>
      total + (getCalendarRangeDurationMinutes(range.startTime, range.endTime) ?? 0),
    0
  );
}

export function clipCalendarTimeRange(
  range: CalendarTimeRange,
  openingStart: string = CALENDAR_OPENING_START,
  openingEnd: string = CALENDAR_OPENING_END
): CalendarTimeRange | null {
  const start = calendarTimeToMinutes(range.startTime);
  const end = calendarTimeToMinutes(range.endTime);
  const openingStartMinutes = calendarTimeToMinutes(openingStart);
  const openingEndMinutes = calendarTimeToMinutes(openingEnd);

  if (
    start === null ||
    end === null ||
    openingStartMinutes === null ||
    openingEndMinutes === null ||
    start >= end ||
    openingStartMinutes >= openingEndMinutes
  ) {
    return null;
  }

  const clippedStart = Math.max(start, openingStartMinutes);
  const clippedEnd = Math.min(end, openingEndMinutes);

  if (clippedStart >= clippedEnd) return null;

  return {
    startTime: minutesToCalendarTime(clippedStart),
    endTime: minutesToCalendarTime(clippedEnd),
  };
}
