import assert from "node:assert/strict";
import test from "node:test";

import {
  LaneParentHydrationError,
  hydrateLaneRows,
  hydrateReservationLaneParents,
} from "./lane-parent-hydration.js";

const PARENT_A = "10000000-0000-4000-8000-000000000001";
const PARENT_B = "10000000-0000-4000-8000-000000000002";

function lane(id, parentLaneId = null) {
  return {
    id,
    name: id,
    resource_kind: parentLaneId ? "position" : "lane",
    parent_lane_id: parentLaneId,
    display_order: 1,
    is_active: true,
  };
}

function client(parents, error = null) {
  const calls = [];

  return {
    calls,
    from(table) {
      assert.equal(table, "shooting_lanes");
      return {
        select(columns) {
          assert.equal(
            columns,
            "id,name,resource_kind,parent_lane_id,display_order,is_active",
          );
          return {
            async in(column, ids) {
              assert.equal(column, "id");
              calls.push([...ids]);
              return { data: parents, error };
            },
          };
        },
      };
    },
  };
}

test("root lanes preserve the UI shape without a parent query", async () => {
  const supabase = client([]);
  const result = await hydrateLaneRows(supabase, [lane(PARENT_A)]);

  assert.equal(supabase.calls.length, 0);
  assert.equal(result[0].parent_lane, null);
});

test("a child lane is hydrated with its parent", async () => {
  const parent = lane(PARENT_A);
  const child = lane("20000000-0000-4000-8000-000000000001", PARENT_A);
  const supabase = client([parent]);
  const result = await hydrateLaneRows(supabase, [child]);

  assert.deepEqual(supabase.calls, [[PARENT_A]]);
  assert.deepEqual(result[0].parent_lane, parent);
});

test("children sharing a parent use one deduplicated batch lookup", async () => {
  const parent = lane(PARENT_A);
  const supabase = client([parent]);
  const result = await hydrateReservationLaneParents(supabase, [
    { id: "r1", shooting_lanes: lane("c1", PARENT_A) },
    { id: "r2", shooting_lanes: [lane("c2", PARENT_A)] },
  ]);

  assert.deepEqual(supabase.calls, [[PARENT_A]]);
  assert.deepEqual(result[0].shooting_lanes.parent_lane, parent);
  assert.deepEqual(result[1].shooting_lanes[0].parent_lane, parent);
});

test("different parents are loaded in one batch", async () => {
  const parentA = lane(PARENT_A);
  const parentB = lane(PARENT_B);
  const supabase = client([parentA, parentB]);

  await hydrateLaneRows(supabase, [
    lane("c1", PARENT_A),
    lane("c2", PARENT_B),
  ]);

  assert.deepEqual(supabase.calls, [[PARENT_A, PARENT_B]]);
});

test("a missing parent fails closed", async () => {
  const supabase = client([]);

  await assert.rejects(
    hydrateLaneRows(supabase, [lane("c1", PARENT_A)]),
    (error) =>
      error instanceof LaneParentHydrationError &&
      error.code === "lane_parent_missing",
  );
});

test("a parent read error is controlled", async () => {
  const supabase = client(null, { code: "read_failed" });

  await assert.rejects(
    hydrateLaneRows(supabase, [lane("c1", PARENT_A)]),
    (error) =>
      error instanceof LaneParentHydrationError &&
      error.code === "lane_parent_read_failed",
  );
});

test("reservation DTO fields and relation cardinality remain unchanged", async () => {
  const parent = lane(PARENT_A);
  const source = {
    id: "reservation",
    customer_name: "Test",
    shooting_lanes: [lane("child", PARENT_A)],
  };
  const result = await hydrateReservationLaneParents(client([parent]), [source]);

  assert.equal(result[0].id, source.id);
  assert.equal(result[0].customer_name, source.customer_name);
  assert.ok(Array.isArray(result[0].shooting_lanes));
  assert.deepEqual(result[0].shooting_lanes[0].parent_lane, parent);
});
