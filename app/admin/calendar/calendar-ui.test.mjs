import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import ts from "typescript";

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

const timeModuleUrl = await compileModule("../../../lib/admin/calendar/time.ts");
const time = await import(timeModuleUrl);
const ui = await import(
  await compileModule(
    "./calendar-ui.ts",
    new Map([
      ["@/lib/admin/calendar/time", timeModuleUrl],
      ["@/lib/admin/calendar/types", moduleDataUrl("export {};\n")],
    ])
  )
);

const {
  addCalendarDays,
  buildCalendarPageUrl,
  filterCalendarEntries,
  formatCalendarWeekRange,
  getCalendarEntryGeometry,
  getVisibleCalendarLanes,
  getCalendarWeekDates,
  getCalendarWeekPresentation,
  getCalendarWeekRange,
  groupCalendarWeekDays,
  layoutCalendarLaneEntries,
  parseCalendarPageState,
  resolveCalendarLaneId,
} = ui;

function reservation(id, startTime, endTime, overrides = {}) {
  return {
    id,
    type: "reservation",
    date: "2026-08-05",
    startTime,
    endTime,
    label: "Gotowa etykieta",
    occupiesLane: true,
    isHistorical: false,
    links: { primary: "/admin/reservations", checkIn: null },
    laneId: "lane-1",
    laneName: "Oś 1",
    laneMetadataAvailable: true,
    status: "confirmed",
    shootersCount: 1,
    ...overrides,
  };
}

function block(id, startTime, endTime, overrides = {}) {
  return {
    ...reservation(id, startTime, endTime, overrides),
    type: "lane_block",
    label: "Blokada osi",
    status: "active",
    reason: "Serwis",
    isActive: true,
    links: { primary: "/admin/lane-blocks", checkIn: null },
  };
}

function event(id, overrides = {}) {
  return {
    id,
    type: "event",
    date: "2026-08-05",
    startTime: "10:00",
    endTime: "11:00",
    label: "Szkolenie",
    occupiesLane: false,
    isHistorical: false,
    links: { primary: "/admin/events", checkIn: null },
    laneId: null,
    laneName: null,
    status: "active",
    location: "Obiekt testowy",
    maxParticipants: 10,
    ...overrides,
  };
}

for (const [name, startTime, endTime, expected] of [
  ["08:00-09:00", "08:00", "09:00", { top: 0, height: 72, isClipped: false }],
  ["10:00-13:00", "10:00", "13:00", { top: 144, height: 216, isClipped: false }],
  ["19:00-20:00", "19:00", "20:00", { top: 792, height: 72, isClipped: false }],
  ["07:00-09:00", "07:00", "09:00", { top: 0, height: 72, isClipped: true }],
  ["19:00-21:00", "19:00", "21:00", { top: 792, height: 72, isClipped: true }],
]) {
  test(`geometry positions ${name}`, () => {
    assert.deepEqual(
      getCalendarEntryGeometry({ startTime, endTime }, "08:00", "20:00"),
      expected
    );
  });
}

test("geometry omits an entry fully outside opening hours", () => {
  assert.equal(
    getCalendarEntryGeometry(
      { startTime: "21:00", endTime: "22:00" },
      "08:00",
      "20:00"
    ),
    null
  );
});

for (const [name, entries, columns] of [
  ["disjoint", [reservation("a", "09:00", "10:00"), reservation("b", "11:00", "12:00")], [1, 1]],
  ["touching", [reservation("a", "10:00", "13:00"), reservation("b", "13:00", "14:00")], [1, 1]],
  ["overlapping", [reservation("a", "10:00", "13:00"), reservation("b", "12:00", "14:00")], [2, 2]],
  ["three with two columns", [reservation("a", "10:00", "12:00"), reservation("b", "11:00", "13:00"), reservation("c", "12:00", "14:00")], [2, 2, 2]],
  ["three with three columns", [reservation("a", "10:00", "14:00"), reservation("b", "11:00", "13:00"), reservation("c", "12:00", "15:00")], [3, 3, 3]],
]) {
  test(`collision layout handles ${name} entries`, () => {
    const result = layoutCalendarLaneEntries(entries, "08:00", "20:00");
    assert.deepEqual(result.map((item) => item.columnCount), columns);
  });
}

test("collision layout is stable for unordered input", () => {
  const result = layoutCalendarLaneEntries(
    [reservation("c", "12:00", "15:00"), reservation("a", "10:00", "14:00"), reservation("b", "11:00", "13:00")],
    "08:00",
    "20:00"
  );
  assert.deepEqual(result.map((item) => item.entry.id), ["a", "b", "c"]);
  assert.deepEqual(result.map((item) => item.columnIndex), [0, 1, 2]);
});

const filterEntries = [
  reservation("reservation", "10:00", "11:00"),
  block("block", "11:00", "12:00"),
  event("event"),
  reservation("other-lane", "12:00", "13:00", { laneId: "lane-2" }),
  reservation("historical", "13:00", "14:00", { isHistorical: true }),
];

function applyFilters(overrides = {}) {
  return filterCalendarEntries(filterEntries, {
    date: "2026-08-05",
    laneId: "all",
    types: ["reservation", "lane_block", "event"],
    includeHistoricalStatuses: false,
    ...overrides,
  });
}

test("filtering supports each entry type", () => {
  assert.deepEqual(applyFilters({ types: ["reservation"] }).map((entry) => entry.id), ["reservation", "other-lane"]);
  assert.deepEqual(applyFilters({ types: ["lane_block"] }).map((entry) => entry.id), ["block"]);
  assert.deepEqual(applyFilters({ types: ["event"] }).map((entry) => entry.id), ["event"]);
});

test("filtering keeps global events for a concrete lane", () => {
  assert.deepEqual(applyFilters({ laneId: "lane-1" }).map((entry) => entry.id), ["reservation", "block", "event"]);
});

test("filtering distinguishes current and historical entries", () => {
  assert.equal(applyFilters().some((entry) => entry.id === "historical"), false);
  assert.equal(applyFilters({ includeHistoricalStatuses: true }).some((entry) => entry.id === "historical"), true);
});

test("calendar date navigation does not depend on local timezone", () => {
  assert.equal(addCalendarDays("2026-08-05", -1), "2026-08-04");
  assert.equal(addCalendarDays("2026-08-05", 1), "2026-08-06");
  assert.equal(addCalendarDays("2026-02-28", 1), "2026-03-01");
});

test("lane filtering supports all five lanes and one concrete lane", () => {
  const lanes = Array.from({ length: 5 }, (_, index) => ({
    id: `lane-${index + 1}`,
    name: `Oś ${index + 1}`,
    isActive: true,
    isHistoricalOnly: false,
    displayOrder: (index + 1) * 10,
    bookingStepMinutes: 60,
  }));
  assert.equal(getVisibleCalendarLanes(lanes, "all").length, 5);
  assert.deepEqual(
    getVisibleCalendarLanes(lanes, "lane-3").map((lane) => lane.id),
    ["lane-3"]
  );
});

test("calendar page keeps explicit screen states and consumes only the feed DTO", async () => {
  const pageSource = await readFile(new URL("./page.tsx", import.meta.url), "utf8");
  const entrySource = await readFile(
    new URL("./_components/CalendarEntryBlock.tsx", import.meta.url),
    "utf8"
  );
  const weekSummarySource = await readFile(
    new URL("./_components/WeekSummary.tsx", import.meta.url),
    "utf8"
  );
  const weekCalendarSource = await readFile(
    new URL("./_components/WeekCalendar.tsx", import.meta.url),
    "utf8"
  );
  assert.match(pageSource, /Authorization: `Bearer \$\{session\.access_token\}`/);
  assert.match(pageSource, /viewState === "loading"/);
  assert.match(pageSource, /viewState === "error"/);
  assert.match(pageSource, /feed\.lanes\.length === 0/);
  assert.match(pageSource, /Brak wpisów dla wybranych filtrów/);
  assert.doesNotMatch(pageSource, /\.from\("profiles"\)|customer_name|customer_email|customer_phone|service_role/i);
  assert.doesNotMatch(entrySource, /customer_name|customer_email|customer_phone|address|token/i);
  assert.match(entrySource, /entry\.label/);
  assert.doesNotMatch(`${weekSummarySource}\n${weekCalendarSource}`, /customer_name|customer_email|customer_phone|address|profiles|service_role/i);
  assert.match(weekSummarySource, /entry\.label/);
  assert.equal((pageSource.match(/fetch\(/g) ?? []).length, 1);
});

for (const [name, anchor, expected] of [
  ["Monday", "2026-08-03", { rangeStart: "2026-08-03", rangeEnd: "2026-08-09" }],
  ["Wednesday", "2026-08-05", { rangeStart: "2026-08-03", rangeEnd: "2026-08-09" }],
  ["Sunday", "2026-08-09", { rangeStart: "2026-08-03", rangeEnd: "2026-08-09" }],
  ["month boundary", "2026-09-02", { rangeStart: "2026-08-31", rangeEnd: "2026-09-06" }],
  ["year boundary", "2027-01-01", { rangeStart: "2026-12-28", rangeEnd: "2027-01-03" }],
]) {
  test(`week range handles ${name}`, () => {
    assert.deepEqual(getCalendarWeekRange(anchor), expected);
  });
}

test("week navigation moves exactly seven calendar days", () => {
  assert.equal(addCalendarDays("2026-08-05", -7), "2026-07-29");
  assert.equal(addCalendarDays("2026-08-05", 7), "2026-08-12");
});

test("today in Warsaw anchors the expected week across a UTC boundary", () => {
  const today = time.getWarsawCalendarDate(new Date("2026-03-29T22:30:00Z"));
  assert.equal(today, "2026-03-30");
  assert.deepEqual(getCalendarWeekRange(today), {
    rangeStart: "2026-03-30",
    rangeEnd: "2026-04-05",
  });
});

test("invalid week dates are rejected", () => {
  assert.equal(getCalendarWeekRange("2026-02-30"), null);
  assert.equal(getCalendarWeekDates("not-a-date"), null);
});

test("Polish week range uses a genitive month within one month", () => {
  assert.equal(
    formatCalendarWeekRange("2026-08-03", "2026-08-09"),
    "3–9 sierpnia 2026"
  );
});

test("Polish week range formats two different months", () => {
  assert.equal(
    formatCalendarWeekRange("2026-08-31", "2026-09-06"),
    "31 sierpnia – 6 września 2026"
  );
});

test("Polish week range formats two different years", () => {
  assert.equal(
    formatCalendarWeekRange("2026-12-28", "2027-01-03"),
    "28 grudnia 2026 – 3 stycznia 2027"
  );
});

test("week grouping always returns Monday through Sunday", () => {
  const dates = getCalendarWeekDates("2026-08-05");
  const grouped = groupCalendarWeekDays(
    dates,
    [
      reservation("wednesday", "10:00", "11:00"),
      event("monday", { date: "2026-08-03" }),
    ],
    []
  );
  assert.equal(grouped.length, 7);
  assert.deepEqual(grouped.map((day) => day.date), [
    "2026-08-03", "2026-08-04", "2026-08-05", "2026-08-06",
    "2026-08-07", "2026-08-08", "2026-08-09",
  ]);
  assert.deepEqual(grouped[0].entries.map((entry) => entry.id), ["monday"]);
  assert.deepEqual(grouped[2].entries.map((entry) => entry.id), ["wednesday"]);
  assert.equal(grouped[6].entries.length, 0);
});

test("entries from separate days get separate collision layouts", () => {
  const monday = reservation("monday", "10:00", "13:00", { date: "2026-08-03" });
  const tuesday = reservation("tuesday", "10:00", "13:00", { date: "2026-08-04" });
  const days = groupCalendarWeekDays(
    getCalendarWeekDates("2026-08-05"),
    [monday, tuesday],
    []
  );
  assert.equal(layoutCalendarLaneEntries(days[0].entries, "08:00", "20:00")[0].columnCount, 1);
  assert.equal(layoutCalendarLaneEntries(days[1].entries, "08:00", "20:00")[0].columnCount, 1);
});

test("view selection chooses summaries, a desktop grid, or mobile cards", () => {
  assert.equal(getCalendarWeekPresentation("all", false), "cards");
  assert.equal(getCalendarWeekPresentation("lane-1", false), "grid");
  assert.equal(getCalendarWeekPresentation("lane-1", true), "cards");
});

test("calendar URL parsing and day navigation are canonical", () => {
  const validLane = "11111111-1111-4111-8111-111111111111";
  assert.deepEqual(
    parseCalendarPageState(
      new URLSearchParams(`view=week&date=2026-08-05&lane=${validLane}`),
      "2026-08-06"
    ),
    { view: "week", date: "2026-08-05", laneId: validLane }
  );
  assert.equal(
    buildCalendarPageUrl({ view: "day", date: "2026-08-07", laneId: validLane }),
    `/admin/calendar?view=day&date=2026-08-07&lane=${validLane}`
  );
});

test("calendar view changes preserve date and lane in both directions", () => {
  const laneId = "11111111-1111-4111-8111-111111111111";
  const current = { date: "2026-08-07", laneId };
  assert.equal(
    buildCalendarPageUrl({ ...current, view: "week" }),
    `/admin/calendar?view=week&date=2026-08-07&lane=${laneId}`
  );
  assert.equal(
    buildCalendarPageUrl({ ...current, view: "day" }),
    `/admin/calendar?view=day&date=2026-08-07&lane=${laneId}`
  );
});

test("calendar view switch remains visible and accessible on mobile", async () => {
  const pageSource = await readFile(new URL("./page.tsx", import.meta.url), "utf8");
  const switchSource = await readFile(
    new URL("./_components/CalendarViewSwitch.tsx", import.meta.url),
    "utf8"
  );
  assert.match(pageSource, /className="mb-3 md:hidden"/);
  assert.match(switchSource, /className="flex w-full/);
  assert.match(switchSource, /flex-1[^"`]*md:flex-none/);
  assert.match(switchSource, /aria-pressed=\{active\}/);
  assert.match(switchSource, /active\s*\?\s*"bg-\[#536143\] text-\[#f2efe4\]"/);
  assert.match(switchSource, /\(aktywny widok\)/);
});

test("invalid URL values fall back safely", () => {
  assert.deepEqual(
    parseCalendarPageState(
      new URLSearchParams("view=month&date=2026-02-30&lane=missing"),
      "2026-08-06"
    ),
    { view: "day", date: "2026-08-06", laneId: "all" }
  );
  const lanes = [{ id: "known", isActive: true }];
  assert.equal(resolveCalendarLaneId("missing", lanes, "week", false), "all");
  assert.equal(resolveCalendarLaneId("all", lanes, "day", true), "known");
});
