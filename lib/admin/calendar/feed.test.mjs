import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import ts from "typescript";
import { calculateHierarchyUtilization } from "../reports.ts";

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
const hierarchyModuleUrl = moduleDataUrl(
  await readFile(new URL("../lane-hierarchy.js", import.meta.url), "utf8")
);
const capacityModuleUrl = moduleDataUrl(
  await readFile(new URL("../lane-capacity.js", import.meta.url), "utf8")
);
const feedModule = await import(
  await compileModule(
    "./feed.ts",
    new Map([
      ["./types", typesModuleUrl],
      ["./time", timeModuleUrl],
      ["../lane-hierarchy.js", hierarchyModuleUrl],
      ["../lane-capacity.js", capacityModuleUrl],
    ])
  )
);
const { buildCalendarFeed, parseCalendarFeedRole } = feedModule;

const DATE = "2026-08-10";
const PARENT = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const CHILD = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const INACTIVE_CHILD = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const TEST_LANE_IDS = new Map([
  ["one", "11111111-1111-4111-8111-111111111111"],
  ["two", "22222222-2222-4222-8222-222222222222"],
  ["missing", "99999999-9999-4999-8999-999999999999"],
  ["old", "88888888-8888-4888-8888-888888888888"],
  ["1", "10000000-0000-4000-8000-000000000001"],
  ["2", "20000000-0000-4000-8000-000000000002"],
  ["3", "30000000-0000-4000-8000-000000000003"],
  ["4", "40000000-0000-4000-8000-000000000004"],
  ["5", "50000000-0000-4000-8000-000000000005"],
]);

test("calendar role parser accepts admin and rejects an ordinary user", () => {
  assert.equal(parseCalendarFeedRole("admin"), "admin");
  assert.equal(parseCalendarFeedRole("user"), null);
});

function testLaneId(id) {
  return TEST_LANE_IDS.get(id) ?? id;
}

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

function lane(id, isActive = true, displayOrder = 10, overrides = {}) {
  return {
    id: testLaneId(id),
    name: `Lane ${id}`,
    is_active: isActive,
    display_order: displayOrder,
    booking_step_minutes: 60,
    resource_kind: "lane",
    parent_lane_id: null,
    whole_lane_bookable: true,
    positions_bookable: false,
    lane_booking_rules: { online_bookable: isActive },
    ...overrides,
  };
}

function position(
  id,
  parentId = PARENT,
  name = "Stanowisko 1",
  isActive = true,
  displayOrder = 10,
  overrides = {},
) {
  return {
    id,
    name,
    is_active: isActive,
    display_order: displayOrder,
    booking_step_minutes: 60,
    resource_kind: "position",
    parent_lane_id: parentId,
    whole_lane_bookable: false,
    positions_bookable: false,
    lane_booking_rules: { online_bookable: isActive },
    ...overrides,
  };
}

function fivePositionFamily({
  rootActive = true,
  positionsBookable = true,
  positionsOnline = true,
} = {}) {
  const root = {
    ...lane(PARENT, rootActive, 10),
    name: "Oś rodzic",
    positions_bookable: positionsBookable,
  };
  const positions = Array.from({ length: 5 }, (_, index) =>
    position(
      testLaneId(String(index + 1)),
      PARENT,
      `Stanowisko ${index + 1}`,
      true,
      (index + 1) * 10,
      { lane_booking_rules: { online_bookable: positionsOnline } },
    ),
  );
  return { root, positions, lanes: [root, ...positions] };
}

function toReportLane(resource) {
  return {
    id: resource.id,
    name: resource.name,
    resource_kind: resource.resource_kind,
    parent_lane_id: resource.parent_lane_id,
    display_order: resource.display_order,
    is_active: resource.is_active,
    whole_lane_bookable: resource.whole_lane_bookable,
    positions_bookable: resource.positions_bookable,
    lane_booking_rules: resource.lane_booking_rules,
  };
}

function reservation(id, laneId, startTime, endTime, status = "confirmed", date = DATE) {
  const [startHour, startMinute] = startTime.split(":").map(Number);
  const [endHour, endMinute] = endTime.split(":").map(Number);
  return {
    id,
    lane_id: testLaneId(laneId),
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
    lane_id: testLaneId(laneId),
    block_date: date,
    start_time: `${startTime}:00`,
    end_time: `${endTime}:00`,
    reason: "Test block",
    is_active: isActive,
  };
}

function event(id, date = DATE, laneIds = []) {
  return {
    id,
    title: "Test event",
    event_date: date,
    start_time: "10:00:00",
    end_time: "11:00:00",
    location: "Test location",
    max_participants: 10,
    is_active: true,
    event_lanes: laneIds.map((laneId) => ({
      lane_id: testLaneId(laneId),
      shooting_lanes: { id: testLaneId(laneId), name: `Lane ${laneId}` },
    })),
  };
}

function feed(rows, queryOverrides = {}) {
  const normalizedOverrides = {
    ...queryOverrides,
    ...(queryOverrides.laneId && queryOverrides.laneId !== "all"
      ? { laneId: testLaneId(queryOverrides.laneId) }
      : {}),
  };
  return buildCalendarFeed(
    query(normalizedOverrides),
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

test("active offline children do not increase a whole-only family capacity", () => {
  const family = fivePositionFamily({
    positionsBookable: false,
    positionsOnline: false,
  });
  const result = feed({ lanes: family.lanes });

  assert.equal(result.lanes.length, 6);
  assert.equal(result.dailySummaries[0].availableMinutes, 720);
  assert.equal(result.occupancyBasis, "effective_family_capacity");
});

test("an active offline child occupies the shared whole-only unit without adding capacity", () => {
  const family = fivePositionFamily({
    positionsBookable: false,
    positionsOnline: false,
  });
  const summary = feed({
    lanes: family.lanes,
    laneBlocks: [block("offline-child", "1", "10:00", "11:00")],
  }).dailySummaries[0];

  assert.equal(summary.availableMinutes, 720);
  assert.equal(summary.occupiedMinutes, 60);
});

test("five usable positions provide capacity five without adding the root", () => {
  const family = fivePositionFamily();
  const summary = feed({ lanes: family.lanes }).dailySummaries[0];

  assert.equal(summary.availableMinutes, 5 * 720);
  assert.notEqual(summary.availableMinutes, 6 * 720);
});

test("a whole-family reservation occupies every physical position once", () => {
  const family = fivePositionFamily();
  const summary = feed({
    lanes: family.lanes,
    reservations: [reservation("whole", PARENT, "10:00", "11:00")],
  }).dailySummaries[0];

  assert.equal(summary.occupiedMinutes, 5 * 60);
  assert.equal(summary.occupiedMinutes / (5 * 60), 1);
});

test("one and three child reservations have weights one and three", () => {
  const family = fivePositionFamily();
  const one = feed({
    lanes: family.lanes,
    reservations: [reservation("one-child", "1", "10:00", "11:00")],
  }).dailySummaries[0];
  const three = feed({
    lanes: family.lanes,
    reservations: [
      reservation("child-1", "1", "10:00", "11:00"),
      reservation("child-2", "2", "10:00", "11:00"),
      reservation("child-3", "3", "10:00", "11:00"),
    ],
  }).dailySummaries[0];
  const five = feed({
    lanes: family.lanes,
    reservations: family.positions.map((child, index) =>
      reservation(`child-${index}`, child.id, "10:00", "11:00"),
    ),
  }).dailySummaries[0];

  assert.equal(one.occupiedMinutes, 60);
  assert.equal(three.occupiedMinutes, 3 * 60);
  assert.equal(five.occupiedMinutes, 5 * 60);
  assert.equal(one.occupiedMinutes / (5 * 60), 0.2);
  assert.equal(three.occupiedMinutes / (5 * 60), 0.6);
  assert.equal(five.occupiedMinutes / (5 * 60), 1);
  assert.equal(five.occupiedMinutes <= five.availableMinutes, true);
});

test("root and child blocks use full-family and single-position weights", () => {
  const family = fivePositionFamily();
  const rootBlock = feed({
    lanes: family.lanes,
    laneBlocks: [block("root-block", PARENT, "10:00", "11:00")],
  }).dailySummaries[0];
  const childBlock = feed({
    lanes: family.lanes,
    laneBlocks: [block("child-block", "1", "10:00", "11:00")],
  }).dailySummaries[0];

  assert.equal(rootBlock.occupiedMinutes, 5 * 60);
  assert.equal(childBlock.occupiedMinutes, 60);
});

test("root and child events use full-family and single-position weights", () => {
  const family = fivePositionFamily();
  const rootEvent = feed({
    lanes: family.lanes,
    events: [event("root-event", DATE, [PARENT])],
  }).dailySummaries[0];
  const childrenEvent = feed({
    lanes: family.lanes,
    events: [event("children-event", DATE, ["1", "2", "3"])],
  }).dailySummaries[0];

  assert.equal(rootEvent.occupiedMinutes, 5 * 60);
  assert.equal(childrenEvent.occupiedMinutes, 3 * 60);
});

test("overlapping whole and child data is unioned per physical position", () => {
  const family = fivePositionFamily();
  const summary = feed({
    lanes: family.lanes,
    reservations: [reservation("whole", PARENT, "10:00", "11:00")],
    laneBlocks: [block("child", "1", "10:00", "11:00")],
    events: [event("child-event", DATE, ["2"])],
  }).dailySummaries[0];

  assert.equal(summary.occupiedMinutes, 5 * 60);
});

test("inactive family contributes zero capacity", () => {
  const family = fivePositionFamily({ rootActive: false });
  const summary = feed({ lanes: family.lanes }).dailySummaries[0];

  assert.equal(summary.availableMinutes, 0);
  assert.equal(summary.occupiedMinutes, 0);
});

test("multiple families sum standalone, whole-only and position capacities", () => {
  const family = fivePositionFamily();
  const summary = feed({
    lanes: [lane("one"), lane("two"), ...family.lanes],
  }).dailySummaries[0];

  assert.equal(summary.availableMinutes, 7 * 720);
});

test("Calendar and Reports share the same effective family capacity", () => {
  const current = fivePositionFamily({
    positionsBookable: false,
    positionsOnline: false,
  });
  const final = fivePositionFamily();
  const calendarCurrent = feed({ lanes: current.lanes }).dailySummaries[0];
  const calendarFinal = feed({ lanes: final.lanes }).dailySummaries[0];
  const reportsCurrent = calculateHierarchyUtilization(
    current.lanes.map(toReportLane),
    [],
    1,
    720,
  );
  const reportsFinal = calculateHierarchyUtilization(
    final.lanes.map(toReportLane),
    [],
    1,
    720,
  );

  assert.equal(calendarCurrent.availableMinutes, 720);
  assert.equal(reportsCurrent.ok && reportsCurrent.availableResourceMinutes, 720);
  assert.equal(calendarFinal.availableMinutes, 5 * 720);
  assert.equal(reportsFinal.ok && reportsFinal.availableResourceMinutes, 5 * 720);
});

test("feed groups a parent and active child and hides an unreferenced inactive child", () => {
  const result = feed({
    lanes: [
      { ...lane(PARENT), name: "Oś rodzic" },
      position(CHILD),
      position(INACTIVE_CHILD, PARENT, "Stanowisko 2", false, 20),
    ],
    reservations: [reservation("r-child", CHILD, "10:00", "11:00")],
  });

  assert.deepEqual(
    result.lanes.map(({ id, displayName, depth }) => ({ id, displayName, depth })),
    [
      { id: PARENT, displayName: "Oś rodzic", depth: 0 },
      { id: CHILD, displayName: "Oś rodzic — Stanowisko 1", depth: 1 },
    ]
  );
  assert.equal(result.lanes.some((resource) => resource.id === INACTIVE_CHILD), false);
  const entry = result.entries.find((candidate) => candidate.id === "r-child");
  assert.equal(entry.laneName, "Oś rodzic — Stanowisko 1");
  assert.equal(entry.laneResource.isPosition, true);
});

test("Calendar uses fresh hierarchy names without changing effective capacity", () => {
  const original = fivePositionFamily();
  const renamed = fivePositionFamily();
  renamed.root.name = "Oś dynamiczna";
  renamed.positions[0].name = "Stanowisko lewe";

  const originalFeed = feed({ lanes: original.lanes });
  const renamedFeed = feed({ lanes: renamed.lanes });
  assert.equal(renamedFeed.lanes[0].displayName, "Oś dynamiczna");
  assert.equal(renamedFeed.lanes[1].displayName, "Oś dynamiczna — Stanowisko lewe");
  assert.equal(
    renamedFeed.dailySummaries[0].availableMinutes,
    originalFeed.dailySummaries[0].availableMinutes,
  );
});

test("whole-lane entry is not copied to child resources or double-counted", () => {
  const result = feed({
    lanes: [
      { ...lane(PARENT), name: "Oś rodzic" },
      position(CHILD),
    ],
    reservations: [reservation("r-parent", PARENT, "10:00", "11:00")],
  });

  const reservations = result.entries.filter((entry) => entry.type === "reservation");
  assert.equal(reservations.length, 1);
  assert.equal(reservations[0].laneId, PARENT);
  assert.equal(reservations[0].laneResource.isPosition, false);
  assert.equal(result.dailySummaries[0].reservationCount, 1);
  assert.equal(result.dailySummaries[0].occupiedMinutes, 60);
});

test("malformed calendar hierarchy fails closed", () => {
  assert.throws(
    () =>
      feed({
        lanes: [position(CHILD, "ffffffff-ffff-4fff-8fff-ffffffffffff")],
      }),
    /Invalid calendar lane hierarchy/
  );
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

test("a lane event keeps one list entry and projects once to its assigned lane", () => {
  const result = feed({
    lanes: [lane("one"), lane("two")],
    events: [event("e1", DATE, ["one"])],
  });
  const sourceEvents = result.entries.filter(
    (entry) => entry.type === "event" && !entry.isLaneProjection
  );
  const projections = result.entries.filter(
    (entry) => entry.type === "event" && entry.isLaneProjection
  );
  assert.equal(sourceEvents.length, 1);
  assert.equal(projections.length, 1);
  assert.equal(projections[0].laneId, testLaneId("one"));
  assert.equal(projections[0].occupiesLane, true);
  assert.equal(result.dailySummaries[0].eventCount, 1);
  assert.equal(result.dailySummaries[0].occupiedMinutes, 60);
});

test("a multi-lane event projects once per distinct lane without duplicating its count", () => {
  const result = feed({
    lanes: [lane("one"), lane("two")],
    events: [event("e1", DATE, ["one", "one", "two"])],
  });
  const projections = result.entries.filter(
    (entry) => entry.type === "event" && entry.isLaneProjection
  );
  assert.deepEqual(projections.map((entry) => entry.laneId), [
    testLaneId("one"),
    testLaneId("two"),
  ]);
  assert.equal(result.dailySummaries[0].eventCount, 1);
  assert.equal(result.dailySummaries[0].occupiedMinutes, 120);
});

test("an inactive event never creates a source entry or lane geometry", () => {
  const inactiveEvent = event("e1", DATE, ["one"]);
  inactiveEvent.is_active = false;
  const result = feed({ lanes: [lane("one")], events: [inactiveEvent] });
  assert.equal(result.entries.length, 0);
  assert.equal(result.dailySummaries[0].eventCount, 0);
  assert.equal(result.dailySummaries[0].occupiedMinutes, 0);
});

test("a damaged lane relation is ignored without affecting the source event", () => {
  const damagedEvent = event("e1", DATE, ["one"]);
  damagedEvent.event_lanes.push(
    null,
    { lane_id: "", shooting_lanes: { id: "", name: "" } },
    { lane_id: "two", shooting_lanes: null }
  );
  const result = feed({ lanes: [lane("one"), lane("two")], events: [damagedEvent] });
  const source = result.entries.find(
    (entry) => entry.type === "event" && !entry.isLaneProjection
  );
  assert.deepEqual(source.laneIds, [testLaneId("one")]);
  assert.equal(
    result.entries.filter((entry) => entry.type === "event" && entry.isLaneProjection).length,
    1
  );
});

test("event projections respect the lane filter while the source event remains informational", () => {
  const result = feed(
    {
      lanes: [lane("one"), lane("two")],
      events: [event("e1", DATE, ["one", "two"])],
    },
    { laneId: "one" }
  );
  assert.equal(result.entries.filter((entry) => entry.type === "event" && !entry.isLaneProjection).length, 1);
  assert.deepEqual(
    result.entries
      .filter((entry) => entry.type === "event" && entry.isLaneProjection)
      .map((entry) => entry.laneId),
    [testLaneId("one")]
  );
  assert.equal(result.dailySummaries[0].occupiedMinutes, 60);
});

test("event occupancy uses the same per-lane interval union as reservations and blocks", () => {
  const summary = feed({
    lanes: [lane("one")],
    reservations: [reservation("r1", "one", "10:00", "12:00")],
    laneBlocks: [block("b1", "one", "11:00", "13:00")],
    events: [event("e1", DATE, ["one"])],
  }).dailySummaries[0];
  assert.equal(summary.occupiedMinutes, 180);
});

test("an overlapping lane block and event use one interval union", () => {
  const laneEvent = event("e1", DATE, ["one"]);
  laneEvent.start_time = "11:00:00";
  laneEvent.end_time = "14:00:00";
  const summary = feed({
    lanes: [lane("one")],
    laneBlocks: [block("b1", "one", "10:00", "12:00")],
    events: [laneEvent],
  }).dailySummaries[0];
  assert.equal(summary.occupiedMinutes, 240);
});

test("overlapping events use one interval union", () => {
  const firstEvent = event("e1", DATE, ["one"]);
  firstEvent.start_time = "10:00:00";
  firstEvent.end_time = "12:00:00";
  const secondEvent = event("e2", DATE, ["one"]);
  secondEvent.start_time = "11:00:00";
  secondEvent.end_time = "14:00:00";
  const result = feed({
    lanes: [lane("one")],
    events: [firstEvent, secondEvent],
  });
  assert.equal(result.dailySummaries[0].occupiedMinutes, 240);
  assert.equal(result.dailySummaries[0].eventCount, 2);
});

test("global and lane events accept a null location", () => {
  const globalEvent = event("global");
  globalEvent.location = null;
  const laneEvent = event("lane", DATE, ["one"]);
  laneEvent.location = null;
  const result = feed({
    lanes: [lane("one")],
    events: [globalEvent, laneEvent],
  });
  const sourceEvents = result.entries.filter(
    (entry) => entry.type === "event" && !entry.isLaneProjection
  );

  assert.equal(sourceEvents.length, 2);
  assert.equal(sourceEvents.every((entry) => entry.location === null), true);
  assert.equal(result.dailySummaries[0].eventCount, 2);
  assert.equal(result.dailySummaries[0].occupiedMinutes, 60);
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

test("instructor feed excludes reservation rows while keeping safe event and lane-block data", () => {
  const result = buildCalendarFeed(
    query(),
    "instruktor",
    {
      lanes: [lane("one")],
      reservations: [reservation("private", "one", "10:00", "11:00")],
      laneBlocks: [block("safe-block", "one", "11:00", "12:00")],
      events: [event("safe-event")],
    },
    DATE
  );

  assert.equal(result.entries.some((entry) => entry.type === "reservation"), false);
  assert.equal(result.entries.some((entry) => entry.type === "lane_block"), true);
  assert.equal(result.entries.some((entry) => entry.type === "event"), true);
  assert.equal(result.dailySummaries[0].reservationCount, 0);
});
