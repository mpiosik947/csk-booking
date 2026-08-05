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
  filterCalendarEntries,
  getCalendarEntryGeometry,
  getVisibleCalendarLanes,
  layoutCalendarLaneEntries,
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
  assert.match(pageSource, /Authorization: `Bearer \$\{session\.access_token\}`/);
  assert.match(pageSource, /viewState === "loading"/);
  assert.match(pageSource, /viewState === "error"/);
  assert.match(pageSource, /feed\.lanes\.length === 0/);
  assert.match(pageSource, /Brak wpisów dla wybranych filtrów/);
  assert.doesNotMatch(pageSource, /\.from\("profiles"\)|customer_name|customer_email|customer_phone|service_role/i);
  assert.doesNotMatch(entrySource, /customer_name|customer_email|customer_phone|address|token/i);
  assert.match(entrySource, /entry\.label/);
});
