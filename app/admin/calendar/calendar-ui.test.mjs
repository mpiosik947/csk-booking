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
  addCalendarMonths,
  buildCalendarPageUrl,
  filterCalendarEntries,
  formatCalendarMonth,
  formatCalendarWeekRange,
  getCalendarEntryPreviewData,
  getCalendarEntryPreviewNavigation,
  getCalendarEntryGeometry,
  getCalendarLaneFamilies,
  getCalendarLaneLabel,
  getCalendarResourceScopeLabel,
  getCalendarMonthDates,
  getCalendarMonthRange,
  getVisibleCalendarLanes,
  getCalendarWeekDates,
  getCalendarWeekPresentation,
  getCalendarWeekRange,
  groupCalendarWeekDays,
  groupCalendarMonthDays,
  layoutCalendarLaneEntries,
  parseCalendarPageState,
  parseCalendarPreviewRole,
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
    laneResource: null,
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
    laneMetadataAvailable: false,
    laneResource: null,
    isLaneProjection: false,
    sourceEventId: id,
    laneIds: [],
    resources: [],
    status: "active",
    location: "Obiekt testowy",
    maxParticipants: 10,
    ...overrides,
  };
}

function calendarLane(overrides = {}) {
  return {
    id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    name: "Oś rodzic",
    displayName: "Oś rodzic",
    parentName: null,
    isActive: true,
    isHistoricalOnly: false,
    displayOrder: 10,
    bookingStepMinutes: 60,
    resourceKind: "lane",
    parentLaneId: null,
    depth: 0,
    isParent: true,
    isPosition: false,
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

test("day hierarchy groups a whole lane with its positions without flattening labels", () => {
  const parent = calendarLane();
  const child = calendarLane({
    id: "11111111-1111-4111-8111-111111111111",
    name: "Stanowisko 1",
    displayName: "Oś rodzic — Stanowisko 1",
    parentName: "Oś rodzic",
    displayOrder: 1,
    resourceKind: "position",
    parentLaneId: parent.id,
    depth: 1,
    isParent: false,
    isPosition: true,
  });

  assert.deepEqual(getCalendarLaneFamilies([parent, child]), [
    { id: parent.id, displayName: "Oś rodzic", resources: [parent, child] },
  ]);
  assert.equal(getCalendarResourceScopeLabel(parent), "Cała oś");
  assert.equal(getCalendarResourceScopeLabel(child), "Stanowisko");
});

test("calendar family grouping fails closed for an orphaned position", () => {
  const orphan = calendarLane({
    resourceKind: "position",
    parentLaneId: null,
    parentName: null,
    depth: 1,
    isParent: false,
    isPosition: true,
  });
  assert.equal(getCalendarLaneFamilies([orphan]), null);
});

test("day view renders a family header and distinct whole-lane and position labels", async () => {
  const source = await readFile(
    new URL("./_components/DayCalendar.tsx", import.meta.url),
    "utf8"
  );
  assert.match(source, /getCalendarLaneFamilies\(lanes\)/);
  assert.match(source, /family\.displayName/);
  assert.match(source, /lane\.isPosition \? lane\.name : "Cała oś"/);
  assert.match(source, /ResourceTypeBadge isPosition=\{lane\.isPosition\}/);
  assert.doesNotMatch(source, /flatMap|children\.map\([^)]*entry/i);
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

test("month lane label identifies all lanes and exact selected lane names", () => {
  const lanes = [
    {
      id: "11111111-1111-4111-8111-111111111111",
      displayName: "Oś 50 m — stanowisko 1",
      name: "Oś 50 m — stanowisko 1",
      isActive: true,
      isHistoricalOnly: false,
      displayOrder: 10,
      bookingStepMinutes: 60,
      resourceKind: "position",
      parentLaneId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      parentName: "Oś 50 m",
      depth: 1,
      isParent: false,
      isPosition: true,
    },
    {
      id: "22222222-2222-4222-8222-222222222222",
      displayName: "Oś 100 m",
      name: "Oś 100 m",
      isActive: true,
      isHistoricalOnly: false,
      displayOrder: 30,
      bookingStepMinutes: 60,
      resourceKind: "lane",
      parentLaneId: null,
      parentName: null,
      depth: 0,
      isParent: true,
      isPosition: false,
    },
  ];
  assert.equal(getCalendarLaneLabel("all", lanes), "Wszystkie osie");
  assert.equal(
    getCalendarLaneLabel("11111111-1111-4111-8111-111111111111", lanes),
    "Oś 50 m — stanowisko 1"
  );
  assert.equal(
    getCalendarLaneLabel("22222222-2222-4222-8222-222222222222", lanes),
    "Oś 100 m"
  );
});

test("month heading lane badge wraps without forcing horizontal scrolling", async () => {
  const pageSource = await readFile(new URL("./page.tsx", import.meta.url), "utf8");
  assert.match(pageSource, /flex min-w-0 flex-wrap items-center gap-2/);
  assert.match(pageSource, /inline-flex max-w-full flex-wrap items-center gap-2 rounded-xl/);
  assert.match(pageSource, /\{calendarLaneLabel\}/);
});

test("week heading reuses the responsive lane scope badge", async () => {
  const pageSource = await readFile(new URL("./page.tsx", import.meta.url), "utf8");
  assert.match(pageSource, /\(view === "week" \|\| view === "month"\)/);
  assert.match(
    pageSource,
    /const calendarLaneLabel = getCalendarLaneLabel\(requestLaneId, knownLanes\)/
  );
  assert.equal((pageSource.match(/\{calendarLaneLabel\}/g) ?? []).length, 1);
});

for (const [name, anchor, expected] of [
  ["five-week month starting Monday", "2026-06-15", { rangeStart: "2026-06-01", rangeEnd: "2026-07-05", dayCount: 35 }],
  ["six-week month", "2026-08-05", { rangeStart: "2026-07-27", rangeEnd: "2026-09-06", dayCount: 42 }],
  ["month starting Sunday", "2026-02-10", { rangeStart: "2026-01-26", rangeEnd: "2026-03-01", dayCount: 35 }],
  ["ordinary February", "2027-02-10", { rangeStart: "2027-02-01", rangeEnd: "2027-03-07", dayCount: 35 }],
  ["leap February", "2028-02-29", { rangeStart: "2028-01-31", rangeEnd: "2028-03-05", dayCount: 35 }],
  ["December crossing into January", "2026-12-15", { rangeStart: "2026-11-30", rangeEnd: "2027-01-03", dayCount: 35 }],
  ["January containing previous December", "2027-01-15", { rangeStart: "2026-12-28", rangeEnd: "2027-01-31", dayCount: 35 }],
]) {
  test(`month range handles ${name}`, () => {
    const range = getCalendarMonthRange(anchor);
    assert.deepEqual(
      range && {
        rangeStart: range.rangeStart,
        rangeEnd: range.rangeEnd,
        dayCount: range.dayCount,
      },
      expected
    );
    const dates = getCalendarMonthDates(anchor);
    assert.equal(dates?.length, expected.dayCount);
    assert.equal(new Date(`${dates?.[0]}T12:00:00Z`).getUTCDay(), 1);
    assert.equal(new Date(`${dates?.at(-1)}T12:00:00Z`).getUTCDay(), 0);
  });
}

test("month navigation clamps the anchor day and crosses years", () => {
  assert.equal(addCalendarMonths("2026-01-31", 1), "2026-02-28");
  assert.equal(addCalendarMonths("2028-01-31", 1), "2028-02-29");
  assert.equal(addCalendarMonths("2028-02-29", 1), "2028-03-29");
  assert.equal(addCalendarMonths("2026-12-31", 1), "2027-01-31");
  assert.equal(addCalendarMonths("2027-01-31", -1), "2026-12-31");
});

test("Polish month heading uses a lowercase standalone month", () => {
  assert.equal(formatCalendarMonth("2026-08-05"), "sierpień 2026");
  assert.equal(formatCalendarMonth("2027-01-31"), "styczeń 2027");
  assert.equal(formatCalendarMonth("2028-02-29"), "luty 2028");
});

test("month summaries cover all cells and preserve outside-month data", () => {
  const dates = getCalendarMonthDates("2026-08-05");
  const outsideDate = "2026-07-27";
  const days = groupCalendarMonthDays(dates, [
    {
      date: outsideDate,
      reservationCount: 1,
      blockCount: 2,
      eventCount: 3,
      availableMinutes: 720,
      occupiedMinutes: 240,
      occupancyPercent: 33,
      isFull: false,
      flags: ["outside_opening_hours"],
    },
  ]);
  assert.equal(days.length, 42);
  assert.equal(days[0].date, outsideDate);
  assert.equal(days[0].summary.occupancyPercent, 33);
  assert.equal(days[1].summary.reservationCount, 0);
});

test("an empty five-week month still contains all 35 cells", () => {
  const dates = getCalendarMonthDates("2026-06-15");
  const days = groupCalendarMonthDays(dates, []);
  assert.equal(days.length, 35);
  assert.equal(days.every((day) => day.summary.reservationCount === 0), true);
});

test("month view uses summaries without entry labels or customer data", async () => {
  const source = await readFile(
    new URL("./_components/MonthCalendar.tsx", import.meta.url),
    "utf8"
  );
  assert.doesNotMatch(source, /entry\.label|customer_name|customer_email|customer_phone|profiles|service_role/i);
  assert.match(source, /summary\.eventCount/);
  assert.match(source, /summary\.isFull/);
  assert.match(source, /summary\.flags/);
  assert.match(source, /grid-cols-7/);
});

test("month tiles emphasize the date and render full labels only for non-zero activity counters", async () => {
  const source = await readFile(
    new URL("./_components/MonthCalendar.tsx", import.meta.url),
    "utf8"
  );

  assert.match(source, /text-base font-black leading-none tabular-nums sm:text-lg/);
  assert.match(source, /Number\(day\.date\.slice\(8, 10\)\)/);
  assert.match(source, /summary\.reservationCount > 0 &&/);
  assert.match(source, /Rezerwacje: <strong[^>]*>\{summary\.reservationCount\}<\/strong>/);
  assert.match(source, /summary\.blockCount > 0 &&/);
  assert.match(source, /Blokady: <strong[^>]*>\{summary\.blockCount\}<\/strong>/);
  assert.match(source, /summary\.eventCount > 0 &&/);
  assert.match(source, /Eventy: <strong[^>]*>\{summary\.eventCount\}<\/strong>/);
  assert.match(source, /hasActivityCounts &&/);
  assert.doesNotMatch(source, /occupiedMinutes|availableMinutes|>R \{|>B \{|>E \{/);
  assert.match(source, /flex min-w-0 flex-col gap-0\.5/);
});

test("month tiles retain occupancy percentage, progress, today and responsive wrapping", async () => {
  const source = await readFile(
    new URL("./_components/MonthCalendar.tsx", import.meta.url),
    "utf8"
  );

  assert.match(source, /summary\.occupancyPercent/);
  assert.match(source, /style=\{\{ width: `\$\{percent \?\? 0\}%` \}\}/);
  assert.match(source, /isToday &&/);
  assert.match(source, />\s*Dzisiaj\s*</);
  assert.match(source, /min-w-0 break-words/);
  assert.doesNotMatch(source, /min-w-\[[^\]]+\]/);
});

test("month hides the redundant R B E legend without changing day or week", async () => {
  const [pageSource, legendSource] = await Promise.all([
    readFile(new URL("./page.tsx", import.meta.url), "utf8"),
    readFile(new URL("./_components/CalendarLegend.tsx", import.meta.url), "utf8"),
  ]);

  assert.match(pageSource, /view !== "month" && <CalendarLegend \/>/);
  assert.match(legendSource, /Rezerwacja/);
  assert.match(legendSource, /Blokada/);
  assert.match(legendSource, /Event/);
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

test("month query state is canonical and a selected day preserves the lane", () => {
  const laneId = "11111111-1111-4111-8111-111111111111";
  assert.deepEqual(
    parseCalendarPageState(
      new URLSearchParams(`view=month&date=2026-08-05&lane=${laneId}`),
      "2026-08-06"
    ),
    { view: "month", date: "2026-08-05", laneId }
  );
  assert.equal(
    buildCalendarPageUrl({ view: "month", date: "2026-08-05", laneId }),
    `/admin/calendar?view=month&date=2026-08-05&lane=${laneId}`
  );
  assert.equal(
    buildCalendarPageUrl({ view: "day", date: "2026-08-31", laneId }),
    `/admin/calendar?view=day&date=2026-08-31&lane=${laneId}`
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
  assert.match(switchSource, /\["day", "week", "month"\]/);
  assert.match(switchSource, /"Miesiąc"/);
});

test("invalid URL values fall back safely", () => {
  assert.deepEqual(
    parseCalendarPageState(
      new URLSearchParams("view=year&date=2026-02-30&lane=missing"),
      "2026-08-06"
    ),
    { view: "day", date: "2026-08-06", laneId: "all" }
  );
  const lanes = [{ id: "known", isActive: true }];
  assert.equal(resolveCalendarLaneId("missing", lanes, "week", false), "all");
  assert.equal(resolveCalendarLaneId("all", lanes, "day", true), "known");
});

test("preview DTO exposes only the approved reservation fields", () => {
  const preview = getCalendarEntryPreviewData(
    reservation("private-id", "08:00", "12:00", {
      label: "Neutralna etykieta",
      laneName: "Oś 50 m",
      shootersCount: 2,
      isHistorical: true,
      customer_name: "must-not-leak",
    })
  );
  assert.deepEqual(preview, {
    type: "reservation",
    title: "Rezerwacja",
    resource: null,
    time: "08:00–12:00",
    laneName: "Oś 50 m",
    label: "Neutralna etykieta",
    shootersCount: 2,
    isHistorical: true,
  });
  assert.equal("id" in preview, false);
  assert.equal("links" in preview, false);
  assert.equal("customer_name" in preview, false);
});

test("preview DTO exposes optional block reason and no technical fields", () => {
  assert.deepEqual(
    getCalendarEntryPreviewData(
      {
        ...block("block-id", "10:00", "13:00", {
          laneName: "Oś 100 m",
          isHistorical: true,
        }),
        reason: null,
      }
    ),
    {
      type: "lane_block",
      title: "Blokada osi",
      resource: null,
      time: "10:00–13:00",
      laneName: "Oś 100 m",
      reason: null,
      isHistorical: true,
    }
  );
});

test("preview DTO exposes event details without technical fields or PII", () => {
  const preview = getCalendarEntryPreviewData(
    event("event-id", { location: "Strzelnica CSK" })
  );
  assert.deepEqual(preview, {
    type: "event",
    title: "Wydarzenie",
    resources: [],
    date: "2026-08-05",
    time: "10:00–11:00",
    label: "Szkolenie",
    location: "Strzelnica CSK",
    laneName: null,
    maxParticipants: 10,
  });
  assert.equal("id" in preview, false);
  assert.equal("laneIds" in preview, false);
});

test("calendar read model requests hierarchy metadata without adding database writes", async () => {
  const routeSource = await readFile(
    new URL("../../api/admin/calendar-feed/route.ts", import.meta.url),
    "utf8"
  );
  assert.match(
    routeSource,
    /id,name,is_active,display_order,booking_step_minutes,resource_kind,parent_lane_id/
  );
  assert.doesNotMatch(routeSource, /\.insert\(|\.update\(|\.delete\(|\.upsert\(/);
});

test("instructor calendar remains available without querying or emitting reservations", async () => {
  const [routeSource, feedSource] = await Promise.all([
    readFile(new URL("../../api/admin/calendar-feed/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../../../lib/admin/calendar/feed.ts", import.meta.url), "utf8"),
  ]);

  assert.match(
    routeSource,
    /if \(role !== "instruktor" && query\.types\.includes\("reservation"\)\)/
  );
  assert.match(
    feedSource,
    /if \(role !== "instruktor" && query\.types\.includes\("reservation"\)\)/
  );
  assert.match(routeSource, /\.from\("lane_blocks"\)/);
  assert.match(routeSource, /\.from\("events"\)/);
  assert.doesNotMatch(routeSource, /service_role|SUPABASE_SERVICE_ROLE_KEY/);
});

test("preview distinguishes whole-lane and child resources with full labels", async () => {
  const parentResource = {
    id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    displayName: "Oś rodzic",
    depth: 0,
    isActive: true,
    isPosition: false,
  };
  const childResource = {
    id: "11111111-1111-4111-8111-111111111111",
    displayName: "Oś rodzic — Stanowisko 1",
    depth: 1,
    isActive: true,
    isPosition: true,
  };
  const parentPreview = getCalendarEntryPreviewData(
    reservation("parent", "10:00", "11:00", {
      laneName: parentResource.displayName,
      laneResource: parentResource,
    })
  );
  const childPreview = getCalendarEntryPreviewData(
    reservation("child", "11:00", "12:00", {
      laneName: childResource.displayName,
      laneResource: childResource,
    })
  );
  assert.equal(parentPreview.resource.displayName, "Oś rodzic");
  assert.equal(getCalendarResourceScopeLabel(parentPreview.resource), "Cała oś");
  assert.equal(childPreview.resource.displayName, "Oś rodzic — Stanowisko 1");
  assert.equal(getCalendarResourceScopeLabel(childPreview.resource), "Stanowisko");

  const source = await readFile(
    new URL("./_components/CalendarEntryPreview.tsx", import.meta.url),
    "utf8"
  );
  assert.match(source, /HierarchyResourceLabel resource=\{resource\} compact/);
  assert.match(source, /getCalendarResourceScopeLabel\(resource\)/);
});

test("week uses hierarchy labels while month remains summary-only", async () => {
  const weekSummarySource = await readFile(
    new URL("./_components/WeekSummary.tsx", import.meta.url),
    "utf8"
  );
  const weekCalendarSource = await readFile(
    new URL("./_components/WeekCalendar.tsx", import.meta.url),
    "utf8"
  );
  const monthSource = await readFile(
    new URL("./_components/MonthCalendar.tsx", import.meta.url),
    "utf8"
  );
  assert.match(weekSummarySource, /entry\.laneName/);
  assert.match(weekSummarySource, /entry\.laneResource\?\.isPosition/);
  assert.match(weekCalendarSource, /resource\.displayName/);
  assert.doesNotMatch(monthSource, /laneResource|resources\.map|displayName/);
});

test("preview navigation uses a strict local allowlist", () => {
  assert.deepEqual(getCalendarEntryPreviewNavigation("reservation", "admin"), {
    href: "/admin/reservations",
    label: "Otwórz rezerwacje",
  });
  assert.deepEqual(getCalendarEntryPreviewNavigation("lane_block", "pracownik"), {
    href: "/admin/lane-blocks",
    label: "Otwórz blokady",
  });
  assert.deepEqual(getCalendarEntryPreviewNavigation("event", "instruktor"), {
    href: "/admin/events",
    label: "Otwórz eventy",
  });
  assert.equal(getCalendarEntryPreviewNavigation("unknown", "admin"), null);
  const spoofed = reservation("id", "10:00", "11:00", {
    links: { primary: "https://example.invalid", checkIn: null },
  });
  assert.equal(
    getCalendarEntryPreviewNavigation(spoofed.type, "admin").href,
    "/admin/reservations"
  );
});

test("preview role permissions fail closed", () => {
  for (const role of ["admin", "pracownik"]) {
    assert.ok(getCalendarEntryPreviewNavigation("reservation", role));
    assert.ok(getCalendarEntryPreviewNavigation("lane_block", role));
    assert.ok(getCalendarEntryPreviewNavigation("event", role));
  }
  assert.equal(getCalendarEntryPreviewNavigation("reservation", "instruktor"), null);
  assert.equal(getCalendarEntryPreviewNavigation("lane_block", "instruktor"), null);
  assert.ok(getCalendarEntryPreviewNavigation("event", "instruktor"));
  assert.equal(getCalendarEntryPreviewNavigation("event", null), null);
  assert.equal(parseCalendarPreviewRole("unknown"), null);
  assert.equal(parseCalendarPreviewRole(undefined), null);
});

test("entry preview is accessible and restores focus without nested controls", async () => {
  const previewSource = await readFile(
    new URL("./_components/CalendarEntryPreview.tsx", import.meta.url),
    "utf8"
  );
  const blockSource = await readFile(
    new URL("./_components/CalendarEntryBlock.tsx", import.meta.url),
    "utf8"
  );
  const eventsSource = await readFile(
    new URL("./_components/CalendarEvents.tsx", import.meta.url),
    "utf8"
  );
  const pageSource = await readFile(new URL("./page.tsx", import.meta.url), "utf8");
  assert.match(previewSource, /role="dialog"/);
  assert.match(previewSource, /aria-modal="true"/);
  assert.match(previewSource, /aria-labelledby=/);
  assert.match(previewSource, /aria-describedby=/);
  assert.match(previewSource, /event\.key === "Escape"/);
  assert.match(previewSource, /closeButtonRef\.current\?\.focus\(\)/);
  assert.match(previewSource, />\s*Zamknij\s*</);
  assert.match(previewSource, /event\.currentTarget === event\.target/);
  assert.equal((previewSource.match(/<Link\b/g) ?? []).length, 1);
  assert.match(blockSource, /<button/);
  assert.doesNotMatch(blockSource, /<article|<Link|<a\b/);
  assert.match(eventsSource, /<button/);
  assert.doesNotMatch(eventsSource, /<article|<Link|<a\b/);
  assert.match(blockSource, /focus-visible:ring/);
  assert.match(eventsSource, /focus-visible:ring/);
  assert.match(pageSource, /activator\?\.isConnected/);
  assert.match(pageSource, /activator\.focus\(\)/);
});

test("only day and exact desktop week wire entry selection", async () => {
  const pageSource = await readFile(new URL("./page.tsx", import.meta.url), "utf8");
  const daySource = await readFile(
    new URL("./_components/DayCalendar.tsx", import.meta.url),
    "utf8"
  );
  const weekSource = await readFile(
    new URL("./_components/WeekCalendar.tsx", import.meta.url),
    "utf8"
  );
  const summarySource = await readFile(
    new URL("./_components/WeekSummary.tsx", import.meta.url),
    "utf8"
  );
  const monthSource = await readFile(
    new URL("./_components/MonthCalendar.tsx", import.meta.url),
    "utf8"
  );
  assert.match(daySource, /onSelectEntry/);
  assert.match(weekSource, /onSelectEntry/);
  assert.match(pageSource, /weekPresentation === "cards"/);
  assert.match(pageSource, /requestLaneId !== "all"/);
  assert.doesNotMatch(summarySource, /onSelectEntry|CalendarEntryPreview/);
  assert.doesNotMatch(monthSource, /onSelectEntry|CalendarEntryPreview/);
});

test("day and week grids render lane event projections while event lists keep source events only", async () => {
  const [pageSource, daySource, weekSource, entryBlockSource] = await Promise.all(
    [
      "./page.tsx",
      "./_components/DayCalendar.tsx",
      "./_components/WeekCalendar.tsx",
      "./_components/CalendarEntryBlock.tsx",
    ].map((file) => readFile(new URL(file, import.meta.url), "utf8"))
  );
  assert.match(pageSource, /entry\.type === "event" && !entry\.isLaneProjection/);
  assert.match(daySource, /entries: CalendarLaneOccupyingEntry\[\]/);
  assert.match(weekSource, /entry\.isLaneProjection/);
  assert.match(entryBlockSource, /E Event/);
  assert.doesNotMatch(entryBlockSource, /event_id|lane_id|customer_name|customer_email|customer_phone/i);
  const weekSummarySource = await readFile(
    new URL("./_components/WeekSummary.tsx", import.meta.url),
    "utf8"
  );
  assert.match(weekSummarySource, /entry\.type === "event" && !entry\.isLaneProjection/);
});

test("calendar preview reads role once and does not add sensitive queries", async () => {
  const files = await Promise.all(
    [
      "./page.tsx",
      "./calendar-ui.ts",
      "./_components/CalendarEntryPreview.tsx",
      "./_components/CalendarEntryBlock.tsx",
      "./_components/CalendarEvents.tsx",
      "./_components/DayCalendar.tsx",
      "./_components/WeekCalendar.tsx",
    ].map((file) => readFile(new URL(file, import.meta.url), "utf8"))
  );
  const source = files.join("\n");
  const pageSource = files[0];
  assert.equal((pageSource.match(/rpc\("get_my_role"\)/g) ?? []).length, 1);
  assert.doesNotMatch(
    source,
    /customer_name|customer_email|customer_phone|event_registrations|\.from\(["']profiles["']\)/i
  );
  const previewSource = files[2];
  assert.doesNotMatch(previewSource, /entry\.id|links\.primary/);
  assert.match(previewSource, /entry\.label/);
  assert.match(previewSource, /entry\.maxParticipants/);
  assert.doesNotMatch(previewSource, /entry\.shootersCount|peopleLabel/);
});

test("calendar always renders one admin return link outside the preview modal", async () => {
  const pageSource = await readFile(new URL("./page.tsx", import.meta.url), "utf8");
  const previewSource = await readFile(
    new URL("./_components/CalendarEntryPreview.tsx", import.meta.url),
    "utf8"
  );
  const linkIndex = pageSource.indexOf('href="/admin"');
  const lastViewIndex = pageSource.lastIndexOf('view === "month"');
  const modalIndex = pageSource.indexOf("{selectedEntry &&");
  assert.match(pageSource, /import Link from "next\/link"/);
  assert.equal((pageSource.match(/href="\/admin"/g) ?? []).length, 1);
  assert.match(pageSource, /← Wróć do panelu administracyjnego/);
  assert.match(pageSource, /href="\/admin"[\s\S]*focus-visible:ring/);
  assert.ok(linkIndex > lastViewIndex);
  assert.ok(linkIndex < modalIndex);
  assert.doesNotMatch(previewSource, /← Wróć do panelu administracyjnego|href="\/admin"/);
});

test("event preview preserves null location and renders a safe fallback", async () => {
  const preview = getCalendarEntryPreviewData(
    event("event-id", { location: null })
  );
  const previewSource = await readFile(
    new URL("./_components/CalendarEntryPreview.tsx", import.meta.url),
    "utf8"
  );

  assert.equal(preview.type, "event");
  assert.equal(preview.location, null);
  assert.match(previewSource, /entry\.location \?\? "Lokalizacja niepodana"/);
  assert.doesNotMatch(previewSource, />null</i);
  assert.equal("id" in preview, false);
  assert.equal("laneIds" in preview, false);
});
