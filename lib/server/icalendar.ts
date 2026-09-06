import { createHash } from "node:crypto";
import { getWarsawEventStartInstant } from "../event-time.ts";

export const ICS_CONTENT_TYPE = "text/calendar; charset=utf-8";
export const ICS_CACHE_CONTROL = "private, no-store";

export type CalendarEntry = {
  recordType: "reservation" | "event-registration";
  recordId: string;
  date: string;
  startTime: string;
  endTime: string;
  summary: string;
  description: string;
  location?: string | null;
};

function formatUtc(value: Date) {
  return value
    .toISOString()
    .replace(/[-:]/g, "")
    .replace(/\.\d{3}Z$/, "Z");
}

export function escapeIcsText(value: string) {
  return value
    .replace(/\\/g, "\\\\")
    .replace(/\r\n|\r|\n/g, "\\n")
    .replace(/,/g, "\\,")
    .replace(/;/g, "\\;");
}

export function foldIcsLine(line: string) {
  const chunks: string[] = [];
  let current = "";
  let currentBytes = 0;
  let limit = 75;

  for (const character of line) {
    const characterBytes = Buffer.byteLength(character, "utf8");

    if (current && currentBytes + characterBytes > limit) {
      chunks.push(current);
      current = "";
      currentBytes = 0;
      limit = 74;
    }

    current += character;
    currentBytes += characterBytes;
  }

  chunks.push(current);
  return chunks.join("\r\n ");
}

export function getCalendarUid(recordType: CalendarEntry["recordType"], recordId: string) {
  const digest = createHash("sha256")
    .update(`csk-booking:${recordType}:${recordId}`, "utf8")
    .digest("hex");

  return `${digest}@calendar.csk-booking`;
}

export function createIcsCalendar(entry: CalendarEntry, now = new Date()) {
  const startsAt = getWarsawEventStartInstant(entry.date, entry.startTime);
  const endsAt = getWarsawEventStartInstant(entry.date, entry.endTime);

  if (!startsAt || !endsAt || endsAt.getTime() <= startsAt.getTime()) {
    return null;
  }

  const lines = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//CSK Booking//Calendar Export//PL",
    "CALSCALE:GREGORIAN",
    "METHOD:PUBLISH",
    "BEGIN:VEVENT",
    `UID:${getCalendarUid(entry.recordType, entry.recordId)}`,
    `DTSTAMP:${formatUtc(now)}`,
    `DTSTART:${formatUtc(startsAt)}`,
    `DTEND:${formatUtc(endsAt)}`,
    `SUMMARY:${escapeIcsText(entry.summary)}`,
    `DESCRIPTION:${escapeIcsText(entry.description)}`,
  ];

  const location = entry.location?.trim();
  if (location) {
    lines.push(`LOCATION:${escapeIcsText(location)}`);
  }

  lines.push("END:VEVENT", "END:VCALENDAR");
  return `${lines.map(foldIcsLine).join("\r\n")}\r\n`;
}
