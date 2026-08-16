import assert from "node:assert/strict";
import test from "node:test";
import {
  calculateHierarchyUtilization,
  fetchCompleteReportDataset,
} from "./reports.ts";

const uuid = (value) => `00000000-0000-4000-8000-${String(value).padStart(12, "0")}`;

function lane(value, overrides = {}) {
  return {
    id: uuid(value),
    name: `Resource ${value}`,
    resource_kind: "lane",
    parent_lane_id: null,
    display_order: value,
    is_active: true,
    whole_lane_bookable: true,
    positions_bookable: false,
    lane_booking_rules: { online_bookable: true },
    ...overrides,
  };
}

function position(value, parent, active = true, overrides = {}) {
  return lane(value, {
    resource_kind: "position",
    parent_lane_id: parent.id,
    is_active: active,
    whole_lane_bookable: false,
    positions_bookable: false,
    lane_booking_rules: { online_bookable: active },
    ...overrides,
  });
}

function reservation(value, resource, duration = 60) {
  return { id: uuid(1000 + value), lane_id: resource.id, duration_minutes: duration };
}

test("flat active lanes preserve the previous utilization denominator", () => {
  const lanes = [lane(1), lane(2), lane(3), lane(4), lane(5)];
  const result = calculateHierarchyUtilization(
    lanes,
    [reservation(1, lanes[0], 180)],
    1,
  );

  assert.deepEqual(result, {
    ok: true,
    effectiveCapacity: 5,
    occupiedResourceMinutes: 180,
    availableResourceMinutes: 4800,
    utilizationPercent: 4,
  });
});

test("whole-lane-only family remains one capacity unit", () => {
  const parent = lane(1);
  const result = calculateHierarchyUtilization(
    [parent],
    [reservation(1, parent)],
    1,
  );

  assert.equal(result.ok && result.effectiveCapacity, 1);
  assert.equal(result.ok && result.occupiedResourceMinutes, 60);
});

test("Reports accepts fresh resource names without changing UUID-based capacity", () => {
  const before = lane(1, { name: "Oś pierwotna" });
  const after = { ...before, name: "Oś dynamiczna" };

  const beforeResult = calculateHierarchyUtilization(
    [before],
    [reservation(1, before)],
    1,
  );
  const afterResult = calculateHierarchyUtilization(
    [after],
    [reservation(1, after)],
    1,
  );

  assert.equal(after.id, before.id);
  assert.equal(after.name, "Oś dynamiczna");
  assert.deepEqual(afterResult, beforeResult);
});

test("positions-only family uses active children as capacity", () => {
  const parent = lane(1, {
    whole_lane_bookable: false,
    positions_bookable: true,
  });
  const positions = Array.from({ length: 5 }, (_, index) =>
    position(index + 2, parent),
  );

  const one = calculateHierarchyUtilization(
    [parent, ...positions],
    [reservation(1, positions[0])],
    1,
  );
  const five = calculateHierarchyUtilization(
    [parent, ...positions],
    positions.map((child, index) => reservation(index + 1, child)),
    1,
  );

  assert.equal(one.ok && one.effectiveCapacity, 5);
  assert.equal(one.ok && one.occupiedResourceMinutes, 60);
  assert.equal(five.ok && five.occupiedResourceMinutes, 300);
});

test("whole plus positions is N rather than N+1 and weights a parent booking", () => {
  const parent = lane(1, { positions_bookable: true });
  const positions = Array.from({ length: 5 }, (_, index) =>
    position(index + 2, parent),
  );
  const result = calculateHierarchyUtilization(
    [parent, ...positions],
    [reservation(1, parent)],
    1,
  );

  assert.equal(result.ok && result.effectiveCapacity, 5);
  assert.equal(result.ok && result.occupiedResourceMinutes, 300);
});

test("inactive positions do not increase capacity or duplicate source rows", () => {
  const parent = lane(1, { positions_bookable: true });
  const first = position(2, parent);
  const second = position(3, parent);
  const dormant = position(4, parent, false);
  const result = calculateHierarchyUtilization(
    [parent, first, second, dormant],
    [reservation(1, first)],
    1,
  );

  assert.equal(result.ok && result.effectiveCapacity, 2);
  assert.equal(result.ok && result.occupiedResourceMinutes, 60);
});

test("active but offline positions do not increase effective capacity", () => {
  const parent = lane(1, { positions_bookable: true });
  const online = position(2, parent);
  const offline = position(3, parent, true, {
    lane_booking_rules: { online_bookable: false },
  });
  const result = calculateHierarchyUtilization(
    [parent, online, offline],
    [reservation(1, online)],
    1,
  );

  assert.equal(result.ok && result.effectiveCapacity, 1);
  assert.equal(result.ok && result.occupiedResourceMinutes, 60);
});

test("mixed standalone and multiple families use their exact active capacity", () => {
  const standalone = lane(1);
  const parentA = lane(2, { positions_bookable: true });
  const childrenA = [position(3, parentA), position(4, parentA), position(5, parentA)];
  const parentB = lane(6, { positions_bookable: true });
  const childB = position(7, parentB);
  const dormant = position(8, parentB, false);
  const lanes = [standalone, parentA, ...childrenA, parentB, childB, dormant];
  const result = calculateHierarchyUtilization(
    lanes,
    [
      reservation(1, standalone),
      reservation(2, parentA),
      reservation(3, childrenA[0]),
      reservation(4, childB),
    ],
    1,
  );

  assert.equal(result.ok && result.effectiveCapacity, 5);
  assert.equal(result.ok && result.occupiedResourceMinutes, 360);
  assert.equal(result.ok && result.utilizationPercent, 8);
});

test("families with one and twenty positions remain data-driven", () => {
  const firstParent = lane(1, { positions_bookable: true });
  const secondParent = lane(3, { positions_bookable: true });
  const firstChildren = [position(2, firstParent)];
  const secondChildren = Array.from({ length: 20 }, (_, index) =>
    position(index + 4, secondParent),
  );
  const result = calculateHierarchyUtilization(
    [firstParent, ...firstChildren, secondParent, ...secondChildren],
    [],
    1,
  );

  assert.equal(result.ok && result.effectiveCapacity, 21);
});

test("pagination loads full, full and partial pages without duplicates", async () => {
  const source = Array.from({ length: 12 }, (_, index) => ({ id: String(index) }));
  const calls = [];
  const result = await fetchCompleteReportDataset(
    source.length,
    async (from, to) => {
      calls.push([from, to]);
      return source.slice(from, to + 1);
    },
    5,
  );

  assert.equal(result.ok && result.rows.length, 12);
  assert.deepEqual(calls, [[0, 4], [5, 9], [10, 11]]);
  assert.deepEqual(result.ok && result.rows.map((row) => row.id), source.map((row) => row.id));
});

test("exact page boundary is confirmed by exact count", async () => {
  const source = Array.from({ length: 10 }, (_, index) => ({ id: String(index) }));
  let calls = 0;
  const result = await fetchCompleteReportDataset(
    10,
    async (from, to) => {
      calls += 1;
      return source.slice(from, to + 1);
    },
    5,
  );

  assert.equal(result.ok, true);
  assert.equal(calls, 2);
});

test("page failure and count mismatch fail closed", async () => {
  const failed = await fetchCompleteReportDataset(6, async (from) =>
    from === 0 ? [{ id: "1" }, { id: "2" }] : null,
  2);
  const available = [{ id: "1" }, { id: "2" }, { id: "3" }, { id: "4" }];
  const short = await fetchCompleteReportDataset(
    5,
    async (from, to) => available.slice(from, to + 1),
    2,
  );

  assert.equal(failed.ok, false);
  assert.deepEqual(short, { ok: false, code: "invalid_page" });
});

test("duplicate rows across pages fail closed", async () => {
  const result = await fetchCompleteReportDataset(
    3,
    async (from) =>
      from === 0 ? [{ id: "1" }, { id: "2" }] : [{ id: "2" }],
    2,
  );

  assert.deepEqual(result, { ok: false, code: "duplicate_row" });
});
