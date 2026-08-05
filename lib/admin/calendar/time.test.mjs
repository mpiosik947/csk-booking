import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import ts from "typescript";
import {
  calendarTimeRangesOverlap,
  calendarTimeToMinutes,
  clipCalendarTimeRange,
  compareCalendarDates,
  countCalendarDaysInclusive,
  getCalendarRangeDurationMinutes,
  getCalendarTimeRangesUnionMinutes,
  getWarsawCalendarDate,
  isValidCalendarDate,
  mergeCalendarTimeRanges,
} from "./time.ts";

function moduleDataUrl(source) {
  return `data:text/javascript;charset=utf-8,${encodeURIComponent(source)}`;
}

async function compileModule(fileName, replacements = new Map()) {
  const source = await readFile(new URL(fileName, import.meta.url), "utf8");
  let output = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.ES2022, target: ts.ScriptTarget.ES2022 },
  }).outputText;

  for (const [specifier, replacement] of replacements) {
    output = output.replaceAll(`"${specifier}"`, `"${replacement}"`);
  }

  return moduleDataUrl(output);
}

const typesModuleUrl = await compileModule("./types.ts");
const timeModuleUrl = await compileModule("./time.ts");
const dependencies = new Map([
  ["./types", typesModuleUrl],
  ["./time", timeModuleUrl],
]);
const queryModule = await import(await compileModule("./query.ts", dependencies));
const feedModule = await import(await compileModule("./feed.ts", dependencies));
const { parseCalendarFeedQuery } = queryModule;
const {
  buildCalendarFeed,
  buildCalendarReservationLabel,
  getReservationCalendarState,
  getReservationSelectColumns,
} = feedModule;

test("calendar dates are validated without Date string parsing", () => {
  assert.equal(isValidCalendarDate("2026-08-04"), true);
  assert.equal(isValidCalendarDate("2026-02-30"), false);
  assert.equal(isValidCalendarDate("04.08.2026"), false);
  assert.equal(compareCalendarDates("2026-08-04", "2026-08-03"), 1);
});

test("inclusive calendar ranges accept one and 42 days but reject 43", () => {
  assert.equal(countCalendarDaysInclusive("2026-08-04", "2026-08-04"), 1);
  assert.equal(countCalendarDaysInclusive("2026-08-01", "2026-09-11"), 42);
  assert.equal(countCalendarDaysInclusive("2026-08-01", "2026-09-12"), 43);
  assert.equal(countCalendarDaysInclusive("2026-08-05", "2026-08-04"), null);
});

test("Warsaw business date handles winter and summer midnight boundaries", () => {
  assert.equal(getWarsawCalendarDate(new Date("2026-01-01T23:30:00Z")), "2026-01-02");
  assert.equal(getWarsawCalendarDate(new Date("2026-06-01T22:30:00Z")), "2026-06-02");
});

test("calendar time uses half-open ranges", () => {
  assert.equal(calendarTimeToMinutes("08:00"), 480);
  assert.equal(calendarTimeToMinutes("20:00"), 1200);
  assert.equal(getCalendarRangeDurationMinutes("10:00", "13:00"), 180);
  assert.equal(getCalendarRangeDurationMinutes("13:00", "10:00"), null);
  assert.equal(
    calendarTimeRangesOverlap(
      { startTime: "10:00", endTime: "13:00" },
      { startTime: "13:00", endTime: "14:00" }
    ),
    false
  );
});

for (const [name, ranges, expectedRanges, expectedMinutes] of [
  ["one range", [{ startTime: "10:00", endTime: "11:00" }], [{ startTime: "10:00", endTime: "11:00" }], 60],
  ["disjoint ranges", [{ startTime: "10:00", endTime: "11:00" }, { startTime: "12:00", endTime: "13:00" }], [{ startTime: "10:00", endTime: "11:00" }, { startTime: "12:00", endTime: "13:00" }], 120],
  ["overlapping ranges", [{ startTime: "10:00", endTime: "13:00" }, { startTime: "12:00", endTime: "14:00" }], [{ startTime: "10:00", endTime: "14:00" }], 240],
  ["touching ranges", [{ startTime: "10:00", endTime: "13:00" }, { startTime: "13:00", endTime: "14:00" }], [{ startTime: "10:00", endTime: "14:00" }], 240],
  ["three connected ranges", [{ startTime: "08:00", endTime: "10:00" }, { startTime: "09:00", endTime: "11:00" }, { startTime: "11:00", endTime: "12:00" }], [{ startTime: "08:00", endTime: "12:00" }], 240],
  ["unordered ranges", [{ startTime: "11:00", endTime: "12:00" }, { startTime: "08:00", endTime: "10:00" }, { startTime: "09:00", endTime: "11:00" }], [{ startTime: "08:00", endTime: "12:00" }], 240],
]) {
  test(`range union handles ${name}`, () => {
    assert.deepEqual(mergeCalendarTimeRanges(ranges), expectedRanges);
    assert.equal(getCalendarTimeRangesUnionMinutes(ranges), expectedMinutes);
  });
}

for (const [name, range, expected] of [
  ["fully before opening", { startTime: "06:00", endTime: "07:00" }, null],
  ["fully after closing", { startTime: "21:00", endTime: "22:00" }, null],
  ["partly before opening", { startTime: "07:00", endTime: "09:00" }, { startTime: "08:00", endTime: "09:00" }],
  ["partly after closing", { startTime: "19:00", endTime: "21:00" }, { startTime: "19:00", endTime: "20:00" }],
  ["covering the full day", { startTime: "07:00", endTime: "21:00" }, { startTime: "08:00", endTime: "20:00" }],
  ["exact opening hours", { startTime: "08:00", endTime: "20:00" }, { startTime: "08:00", endTime: "20:00" }],
]) {
  test(`opening-hours clipping handles ${name}`, () => {
    assert.deepEqual(clipCalendarTimeRange(range), expected);
  });
}

test("one minute of overlap remains an overlap", () => {
  assert.equal(
    calendarTimeRangesOverlap(
      { startTime: "10:00", endTime: "13:00" },
      { startTime: "12:59", endTime: "14:00" }
    ),
    true
  );
});

test("query parser applies safe defaults", () => {
  const result = parseCalendarFeedQuery(
    new URLSearchParams({ rangeStart: "2026-08-10", rangeEnd: "2026-08-16" })
  );
  assert.equal(result.ok, true);
  assert.deepEqual(result.ok && result.value, {
    rangeStart: "2026-08-10",
    rangeEnd: "2026-08-16",
    laneId: "all",
    types: ["reservation", "lane_block", "event"],
    includeHistoricalStatuses: false,
  });
});

for (const [name, query, code] of [
  ["missing required date", "rangeStart=2026-08-10", "invalid_date"],
  ["unknown parameter", "rangeStart=2026-08-10&rangeEnd=2026-08-11&x=1", "invalid_query"],
  ["repeated parameter", "rangeStart=2026-08-10&rangeStart=2026-08-11&rangeEnd=2026-08-12", "invalid_query"],
  ["invalid UUID", "rangeStart=2026-08-10&rangeEnd=2026-08-11&laneId=nope", "invalid_query"],
  ["empty types", "rangeStart=2026-08-10&rangeEnd=2026-08-11&types=", "invalid_types"],
  ["unknown type", "rangeStart=2026-08-10&rangeEnd=2026-08-11&types=event,profile", "invalid_types"],
  ["invalid boolean", "rangeStart=2026-08-10&rangeEnd=2026-08-11&includeHistoricalStatuses=yes", "invalid_query"],
  ["reverse range", "rangeStart=2026-08-12&rangeEnd=2026-08-11", "invalid_range"],
  ["43 day range", "rangeStart=2026-08-01&rangeEnd=2026-09-12", "range_too_large"],
]) {
  test(`query parser rejects ${name}`, () => {
    const result = parseCalendarFeedQuery(new URLSearchParams(query));
    assert.equal(result.ok, false);
    assert.equal(!result.ok && result.error.code, code);
  });
}

test("reservation labels use compact Polish-safe personal data", () => {
  assert.equal(buildCalendarReservationLabel("Jan Kowalski", 1, "admin"), "Jan K. — 1 osoba");
  assert.equal(buildCalendarReservationLabel("Jan Kowalski", 3, "pracownik"), "Jan K. — 3 osoby");
  assert.equal(buildCalendarReservationLabel("Jan Kowalski", 5, "admin"), "Jan K. — 5 osób");
  assert.equal(buildCalendarReservationLabel("Jan Adam Kowalski", 22, "admin"), "Jan A. — 22 osoby");
  assert.equal(buildCalendarReservationLabel(null, 12, "admin"), "Klient — 12 osób");
  assert.equal(buildCalendarReservationLabel("Kowalski", 1, "admin"), "Klient — 1 osoba");
  assert.equal(buildCalendarReservationLabel("Jan Kowalski", 2, "instruktor"), "Rezerwacja — 2 osoby");
  assert.equal(buildCalendarReservationLabel("Jan Kowalski", 2, "admin").includes("Kowalski"), false);
});

test("reservation states follow occupancy and history rules", () => {
  assert.deepEqual(getReservationCalendarState("confirmed", false), {
    status: "confirmed",
    occupiesLane: true,
    isHistorical: false,
  });
  assert.equal(getReservationCalendarState("completed", false), null);
  assert.equal(getReservationCalendarState("completed", true)?.occupiesLane, false);
  assert.equal(getReservationCalendarState("no_show", true)?.isHistorical, true);
  assert.equal(getReservationCalendarState("cancelled", true), null);
  assert.equal(getReservationCalendarState("cancelled_by_user", true), null);
});

const query = {
  rangeStart: "2026-08-10",
  rangeEnd: "2026-08-16",
  laneId: "all",
  types: ["reservation", "lane_block", "event"],
  includeHistoricalStatuses: true,
};

function sampleRows() {
  return {
    lanes: [
      { id: "lane-active", name: "Oś 50 m", is_active: true, display_order: 10, booking_step_minutes: 60 },
      { id: "lane-old", name: "Stara oś", is_active: false, display_order: 90, booking_step_minutes: 60 },
    ],
    reservations: [
      {
        id: "reservation-1",
        lane_id: "lane-active",
        lane_name_snapshot: "Oś 50 m",
        reservation_date: "2026-08-10",
        start_time: "10:00:00",
        end_time: "12:00:00",
        duration_minutes: 120,
        shooters_count: 3,
        reservation_status: "confirmed",
        customer_name: "Jan Kowalski",
      },
    ],
    laneBlocks: [
      {
        id: "block-1",
        lane_id: "lane-old",
        block_date: "2026-08-11",
        start_time: "08:00:00",
        end_time: "09:00:00",
        reason: "Historia",
        is_active: false,
      },
    ],
    events: [
      {
        id: "event-1",
        title: "Szkolenie",
        event_date: "2026-08-12",
        start_time: "09:00:00",
        end_time: "11:00:00",
        location: "Strzelnica",
        max_participants: 10,
        is_active: true,
      },
    ],
  };
}

test("feed normalizes records and preserves global event semantics", () => {
  const feed = buildCalendarFeed(query, "admin", sampleRows(), "2026-08-20");
  assert.equal(feed.lanes.length, 2);
  assert.equal(feed.lanes[1].isHistoricalOnly, true);
  assert.equal(feed.entries[0].type, "reservation");
  assert.equal(feed.entries[0].startTime, "10:00");
  const event = feed.entries.find((entry) => entry.type === "event");
  assert.equal(event?.laneId, null);
  assert.equal(event?.occupiesLane, false);
});

test("instructor feed never exposes customer name", () => {
  const feed = buildCalendarFeed(query, "instruktor", sampleRows(), "2026-08-20");
  const serialized = JSON.stringify(feed);
  assert.equal(serialized.includes("Kowalski"), false);
  assert.equal(serialized.includes("customer_name"), false);
  assert.equal(getReservationSelectColumns("instruktor").includes("customer_name"), false);
  assert.equal(getReservationSelectColumns("admin").includes("customer_name"), true);
});

test("calendar endpoint keeps authentication, RLS and read-only scope", async () => {
  const source = await readFile(
    new URL("../../../app/api/admin/calendar-feed/route.ts", import.meta.url),
    "utf8"
  );
  assert.match(source, /Authorization: `Bearer \$\{accessToken\}`/);
  assert.match(source, /\^Bearer \(\[\^\\s\]\+\)\$\/i/);
  assert.match(source, /auth\.getUser\(accessToken\)/);
  assert.match(source, /rpc\("get_my_role"\)/);
  assert.doesNotMatch(source, /SUPABASE_SERVICE_ROLE_KEY|event_registrations/);
  assert.doesNotMatch(source, /\.insert\(|\.update\(|\.delete\(|\.upsert\(/);
});
