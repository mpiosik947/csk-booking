import assert from "node:assert/strict";
import test from "node:test";
import {
  createIcsCalendar,
  escapeIcsText,
  foldIcsLine,
  getCalendarUid,
} from "./icalendar.ts";

const RECORD_ID = "10000000-0000-4000-8000-000000000001";

function calendar(overrides = {}) {
  return createIcsCalendar(
    {
      recordType: "reservation",
      recordId: RECORD_ID,
      date: "2026-01-15",
      startTime: "10:00:00",
      endTime: "12:00:00",
      summary: "CSK — Rezerwacja strzelnicy",
      description: "Rezerwacja: Oś 50 m — Stanowisko 2",
      location: "CSK",
      ...overrides,
    },
    new Date("2026-01-01T00:00:00Z"),
  );
}

test("generates a standards-shaped CRLF calendar with correct winter UTC", () => {
  const result = calendar();
  assert.ok(result);
  assert.match(result, /^BEGIN:VCALENDAR\r\nVERSION:2\.0\r\n/u);
  assert.match(result, /\r\nCALSCALE:GREGORIAN\r\n/u);
  assert.match(result, /\r\nBEGIN:VEVENT\r\n/u);
  assert.match(result, /\r\nDTSTART:20260115T090000Z\r\n/u);
  assert.match(result, /\r\nDTEND:20260115T110000Z\r\n/u);
  assert.match(result, /\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n$/u);
  assert.doesNotMatch(result, /(?<!\r)\n/u);
});

test("uses Europe/Warsaw summer time instead of a fixed offset", () => {
  const result = calendar({ date: "2026-07-15" });
  assert.match(result ?? "", /DTSTART:20260715T080000Z/u);
  assert.match(result ?? "", /DTEND:20260715T100000Z/u);
});

test("handles DST spring fail-closed and valid post-transition wall time", () => {
  assert.equal(
    calendar({ date: "2026-03-29", startTime: "02:30:00", endTime: "03:30:00" }),
    null,
  );
  const result = calendar({ date: "2026-03-29", startTime: "03:30:00", endTime: "04:30:00" });
  assert.match(result ?? "", /DTSTART:20260329T013000Z/u);
  assert.match(result ?? "", /DTEND:20260329T023000Z/u);
});

test("handles the DST autumn overlap deterministically in Warsaw", () => {
  const result = calendar({ date: "2026-10-25", startTime: "02:30:00", endTime: "03:30:00" });
  assert.match(result ?? "", /DTSTART:20261025T013000Z/u);
  assert.match(result ?? "", /DTEND:20261025T023000Z/u);
});

test("rejects invalid and non-positive time ranges", () => {
  assert.equal(calendar({ startTime: "12:00", endTime: "10:00" }), null);
  assert.equal(calendar({ date: "not-a-date" }), null);
});

test("escapes all iCalendar text delimiters and newline variants", () => {
  assert.equal(
    escapeIcsText("a\\b,c;d\r\ne\rf\ng"),
    "a\\\\b\\,c\\;d\\ne\\nf\\ng",
  );
});

test("malicious dynamic fields cannot inject properties or end VEVENT", () => {
  const result = calendar({
    summary: "Training\r\nATTENDEE:mailto:victim@example.invalid",
    description: "x\nURL:javascript:alert(1)\nORGANIZER:evil",
    location: "Hall\rEND:VEVENT\rBEGIN:VEVENT",
  });
  assert.ok(result);
  assert.doesNotMatch(result, /\r\nATTENDEE:/u);
  assert.doesNotMatch(result, /\r\nURL:/u);
  assert.doesNotMatch(result, /\r\nORGANIZER:/u);
  const physicalLines = result.split("\r\n");
  assert.equal(physicalLines.filter((line) => line === "BEGIN:VEVENT").length, 1);
  assert.equal(physicalLines.filter((line) => line === "END:VEVENT").length, 1);
  assert.match(result, /SUMMARY:Training\\nATTENDEE:/u);
});

test("folds UTF-8 lines to at most 75 octets without splitting characters", () => {
  const folded = foldIcsLine(`DESCRIPTION:${"Żółć,".repeat(40)}`);
  for (const [index, line] of folded.split("\r\n").entries()) {
    assert.ok(Buffer.byteLength(line, "utf8") <= 75, `line ${index + 1} exceeds 75 octets`);
    if (index > 0) assert.match(line, /^ /u);
  }
});

test("stable opaque UID contains neither source id nor user data", () => {
  const first = getCalendarUid("reservation", RECORD_ID);
  const second = getCalendarUid("reservation", RECORD_ID);
  assert.equal(first, second);
  assert.doesNotMatch(first, new RegExp(RECORD_ID, "u"));
  assert.doesNotMatch(first, /@example|customer|token/iu);
  assert.notEqual(first, getCalendarUid("event-registration", RECORD_ID));
});

test("reservation labels and public event fields remain correctly escaped", () => {
  const wholeLane = calendar({ description: "Rezerwacja: Oś 100 m" });
  const child = calendar({ description: "Rezerwacja: Oś 100 m — Stanowisko 1" });
  const event = calendar({
    recordType: "event-registration",
    summary: "CSK — Szkolenie, poziom 1",
    description: "Jan & Anna; teoria i praktyka",
    location: "Oś A, hala 1",
  });
  assert.match(wholeLane ?? "", /DESCRIPTION:Rezerwacja: Oś 100 m/u);
  assert.match(child ?? "", /Oś 100 m — Stanowisko 1/u);
  assert.match(event ?? "", /SUMMARY:CSK — Szkolenie\\, poziom 1/u);
  assert.match(event ?? "", /DESCRIPTION:Jan & Anna\\; teoria i praktyka/u);
  assert.match(event ?? "", /LOCATION:Oś A\\, hala 1/u);
});

test("calendar does not introduce attendee, organizer, URL or secret fields", () => {
  const result = calendar();
  for (const forbidden of [
    "ATTENDEE",
    "ORGANIZER",
    "URL:",
    "EMAIL",
    "PHONE",
    "JWT",
    "SERVICE_ROLE",
    "CHECK_IN_TOKEN",
  ]) {
    assert.doesNotMatch(result ?? "", new RegExp(`(?:^|\\r\\n)${forbidden}`, "iu"));
  }
});
