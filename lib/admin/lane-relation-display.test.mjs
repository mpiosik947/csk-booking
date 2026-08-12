import assert from "node:assert/strict";
import test from "node:test";

import { getLaneRelationDisplay } from "./lane-relation-display.js";

const PARENT = "10000000-0000-4000-8000-000000000001";
const CHILD = "10000000-0000-4000-8000-000000000002";
const STANDALONE = "10000000-0000-4000-8000-000000000003";

function lane(overrides = {}) {
  return {
    id: STANDALONE,
    name: "Zasób samodzielny",
    resource_kind: "lane",
    parent_lane_id: null,
    display_order: 10,
    is_active: true,
    parent_lane: null,
    ...overrides,
  };
}

test("standalone and parent lane relations retain their unambiguous names", () => {
  assert.equal(getLaneRelationDisplay(lane()).displayName, "Zasób samodzielny");
  assert.equal(
    getLaneRelationDisplay([lane({ id: PARENT, name: "Zasób nadrzędny" })])
      .displayName,
    "Zasób nadrzędny"
  );
});

test("a child relation receives the full parent and child display name", () => {
  const parent = lane({ id: PARENT, name: "Zasób nadrzędny", is_active: false });
  const child = lane({
    id: CHILD,
    name: "Pozycja lokalna",
    resource_kind: "position",
    parent_lane_id: PARENT,
    display_order: 2,
    is_active: false,
    parent_lane: parent,
  });

  const display = getLaneRelationDisplay(child);
  assert.equal(display.displayName, "Zasób nadrzędny — Pozycja lokalna");
  assert.equal(display.isPosition, true);
  assert.equal(display.isActive, false);
});

test("malformed or ambiguous relations fail closed", () => {
  const childWithoutParent = lane({
    id: CHILD,
    resource_kind: "position",
    parent_lane_id: PARENT,
  });

  assert.equal(getLaneRelationDisplay(childWithoutParent), null);
  assert.equal(getLaneRelationDisplay([lane(), lane()]), null);
  assert.equal(getLaneRelationDisplay({ ...lane(), resource_kind: "unknown" }), null);
});

test("relation adapter contains no production resource assumptions", async () => {
  const { readFile } = await import("node:fs/promises");
  const source = await readFile(
    new URL("./lane-relation-display.js", import.meta.url),
    "utf8"
  );

  assert.doesNotMatch(source, /Oś 100 m|Stanowisko \d|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
  assert.match(source, /buildLaneHierarchyDisplayModel/);
});
