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

const typesModuleUrl = await compileModule("./types.ts");
const timeModuleUrl = await compileModule("./time.ts");
const feedModule = await import(
  await compileModule(
    "./feed.ts",
    new Map([
      ["./types", typesModuleUrl],
      ["./time", timeModuleUrl],
    ])
  )
);
const { buildCalendarFeed } = feedModule;

const DATE = "2026-08-10";

function query(overrides = {}) {
  return {
    rangeStart: DATE,
    rangeEnd: DATE,
    laneId: "all",
    types: ["reservation", "lane_block", "event"],
    includeHistoricalStatuses: true,
    ...overrides,
  };
}

function lane(id, isActive = true, displayOrder = 10) {
  return {
    id,
    name: `Lane ${id}`,
    is_active: isActive,
    display_order: displayOrder,
    booking_step_minutes: 60,
  };
}

function reservation(id, laneId, startTime, endTime, status = "confirmed", date = DATE) {
  const [startHour, startMinute] = startTime.split(":").map(Number);
  const [endHour, endMinute] = endTime.split(":").map(Number);
  return {
    id,
    lane_id: laneId,
    lane_name_snapshot: `Lane ${laneId}`,
    reservation_date: date,
    start_time: `${startTime}:00`,
    end_time: `${endTime}:00`,
    duration_minutes: endHour * 60 + endMinute - startHour * 60 - startMinute,
    shooters_count: 1,
    reservation_status: status,
    customer_name: "Test User",
  };
}

function block(id, laneId, startTime, endTime, isActive = true, date = DATE) {
  return {
    id,
    lane_id: laneId,
    block_date: date,
    start_time: `${startTime}:00`,
    end_time: `${endTime}:00`,
    reason: "Test block",
    is_active: isActive,
  };
}

function event(id, date = DATE) {
  return {
    id,
    title: "Test event",
    event_date: date,
    start_time: "10:00:00",
    end_time: "11:00:00",
    location: "Test location",
    max_participants: 10,
    is_active: true,
  };
}

function feed(rows, queryOverrides = {}) {
  return buildCalendarFeed(
    query(queryOverrides),
    "admin",
    {
      lanes: rows.lanes ?? [],
      reservations: rows.reservations ?? [],
      laneBlocks: rows.laneBlocks ?? [],
      events: rows.events ?? [],
    },
    "2026-08-20"
  );
}

test("no active lanes gives a null percentage and is never full", () => {
  const summary = feed({}).dailySummaries[0];
  assert.deepEqual(summary, {
    date: DATE,
    reservationCount: 0,
    blockCount: 0,
    eventCount: 0,
    availableMinutes: 0,
    occupiedMinutes: 0,
    occupancyPercent: null,
    isFull: false,
    flags: [],
  });
});

test("one active lane provides 720 empty minutes", () => {
  const summary = feed({ lanes: [lane("one")] }).dailySummaries[0];
  assert.equal(summary.availableMinutes, 720);
  assert.equal(summary.occupiedMinutes, 0);
  assert.equal(summary.occupancyPercent, 0);
});

test("five active lanes and 180 occupied minutes round to five percent", () => {
  const lanes = [1, 2, 3, 4, 5].map((id) => lane(String(id), true, id * 10));
  const summary = feed({
    lanes,
    reservations: [reservation("r1", "1", "10:00", "13:00")],
  }).dailySummaries[0];
  assert.equal(summary.availableMinutes, 3600);
  assert.equal(summary.occupiedMinutes, 180);
  assert.equal(summary.occupancyPercent, 5);
});

test("a full active block fills one lane and sets both full flags", () => {
  const summary = feed({
    lanes: [lane("one")],
    laneBlocks: [block("b1", "one", "08:00", "20:00")],
  }).dailySummaries[0];
  assert.equal(summary.occupiedMinutes, 720);
  assert.equal(summary.occupancyPercent, 100);
  assert.equal(summary.isFull, true);
  assert.deepEqual(summary.flags, ["full_day", "full_lane_block"]);
});

test("all active lanes can be exactly full", () => {
  const summary = feed({
    lanes: [lane("one"), lane("two")],
    reservations: [
      reservation("r1", "one", "08:00", "20:00"),
      reservation("r2", "two", "08:00", "20:00"),
    ],
  }).dailySummaries[0];
  assert.equal(summary.availableMinutes, 1440);
  assert.equal(summary.occupiedMinutes, 1440);
  assert.equal(summary.isFull, true);
  assert.deepEqual(summary.flags, ["full_day"]);
});

test("overlapping reservation and block are counted as one union", () => {
  const summary = feed({
    lanes: [lane("one")],
    reservations: [reservation("r1", "one", "08:00", "12:00")],
    laneBlocks: [block("b1", "one", "10:00", "14:00")],
  }).dailySummaries[0];
  assert.equal(summary.occupiedMinutes, 360);
});

test("an inactive historical lane does not increase the denominator", () => {
  const summary = feed({
    lanes: [lane("old", false)],
    reservations: [reservation("r1", "old", "10:00", "12:00")],
  }).dailySummaries[0];
  assert.equal(summary.availableMinutes, 0);
  assert.equal(summary.occupiedMinutes, 0);
  assert.equal(summary.reservationCount, 1);
});

test("completed and no-show entries count but do not occupy", () => {
  const summary = feed({
    lanes: [lane("one")],
    reservations: [
      reservation("r1", "one", "10:00", "11:00", "completed"),
      reservation("r2", "one", "11:00", "12:00", "no_show"),
    ],
  }).dailySummaries[0];
  assert.equal(summary.reservationCount, 2);
  assert.equal(summary.occupiedMinutes, 0);
});

test("a global event counts but never occupies a lane", () => {
  const summary = feed({ lanes: [lane("one")], events: [event("e1")] })
    .dailySummaries[0];
  assert.equal(summary.eventCount, 1);
  assert.equal(summary.occupiedMinutes, 0);
});

test("overlapping active blocks are diagnosed", () => {
  const summary = feed({
    lanes: [lane("one")],
    laneBlocks: [
      block("b1", "one", "10:00", "13:00"),
      block("b2", "one", "12:00", "14:00"),
    ],
  }).dailySummaries[0];
  assert.equal(summary.flags.includes("overlapping_blocks"), true);
});

test("touching active blocks are not diagnosed as overlapping", () => {
  const summary = feed({
    lanes: [lane("one")],
    laneBlocks: [
      block("b1", "one", "10:00", "12:00"),
      block("b2", "one", "12:00", "14:00"),
    ],
  }).dailySummaries[0];
  assert.equal(summary.flags.includes("overlapping_blocks"), false);
  assert.equal(summary.occupiedMinutes, 240);
});

test("time outside opening hours is clipped and diagnosed", () => {
  const summary = feed({
    lanes: [lane("one")],
    reservations: [reservation("r1", "one", "07:00", "09:00")],
    laneBlocks: [block("b1", "one", "21:00", "22:00")],
  }).dailySummaries[0];
  assert.equal(summary.occupiedMinutes, 60);
  assert.equal(summary.flags.includes("outside_opening_hours"), true);
});

test("missing lane metadata is diagnosed and never adds occupancy", () => {
  const summary = feed({
    reservations: [reservation("r1", "missing", "10:00", "11:00")],
  }).dailySummaries[0];
  assert.equal(summary.reservationCount, 1);
  assert.equal(summary.occupiedMinutes, 0);
  assert.deepEqual(summary.flags, ["missing_lane_metadata"]);
});

test("flags are unique and returned in a stable order", () => {
  const summary = feed({
    lanes: [lane("one")],
    reservations: [reservation("r1", "missing", "07:00", "09:00")],
    laneBlocks: [
      block("b1", "one", "07:00", "21:00"),
      block("b2", "one", "08:00", "09:00"),
    ],
  }).dailySummaries[0];
  assert.deepEqual(summary.flags, [
    "full_day",
    "full_lane_block",
    "overlapping_blocks",
    "outside_opening_hours",
    "missing_lane_metadata",
  ]);
  assert.equal(new Set(summary.flags).size, summary.flags.length);
});

test("daily summaries include every date in ascending order", () => {
  const result = feed(
    { lanes: [lane("one")] },
    { rangeStart: "2026-08-10", rangeEnd: "2026-08-16" }
  );
  assert.equal(result.dailySummaries.length, 7);
  assert.deepEqual(
    result.dailySummaries.map((summary) => summary.date),
    [
      "2026-08-10",
      "2026-08-11",
      "2026-08-12",
      "2026-08-13",
      "2026-08-14",
      "2026-08-15",
      "2026-08-16",
    ]
  );
  assert.equal(result.dailySummaries.every((summary) => summary.occupiedMinutes === 0), true);
});

test("type filtering excludes hidden categories from counts and occupancy", () => {
  const summary = feed(
    {
      lanes: [lane("one")],
      laneBlocks: [block("b1", "one", "08:00", "20:00")],
      events: [event("e1")],
    },
    { types: ["reservation"] }
  ).dailySummaries[0];
  assert.equal(summary.blockCount, 0);
  assert.equal(summary.eventCount, 0);
  assert.equal(summary.occupiedMinutes, 0);
});

test("lane filtering excludes other lane entries while events remain global", () => {
  const result = feed(
    {
      lanes: [lane("one"), lane("two")],
      reservations: [
        reservation("r1", "one", "10:00", "11:00"),
        reservation("r2", "two", "10:00", "12:00"),
      ],
      laneBlocks: [block("b1", "two", "12:00", "13:00")],
      events: [event("e1")],
    },
    { laneId: "one" }
  );
  const summary = result.dailySummaries[0];
  assert.equal(result.lanes.length, 1);
  assert.equal(summary.availableMinutes, 720);
  assert.equal(summary.reservationCount, 1);
  assert.equal(summary.blockCount, 0);
  assert.equal(summary.eventCount, 1);
  assert.equal(summary.occupiedMinutes, 60);
});
