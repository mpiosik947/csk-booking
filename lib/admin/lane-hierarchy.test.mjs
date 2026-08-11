import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { buildLaneHierarchyDisplayModel } from "./lane-hierarchy.js";

const ROOT_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const ROOT_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const CHILD_A1 = "11111111-1111-4111-8111-111111111111";
const CHILD_A2 = "22222222-2222-4222-8222-222222222222";
const CHILD_A3 = "33333333-3333-4333-8333-333333333333";
const CHILD_A4 = "44444444-4444-4444-8444-444444444444";
const CHILD_A5 = "55555555-5555-4555-8555-555555555555";

function lane(overrides = {}) {
  return {
    id: ROOT_A,
    name: "Oś główna",
    resource_kind: "lane",
    parent_lane_id: null,
    display_order: 10,
    is_active: true,
    ...overrides,
  };
}

function position(id, name, displayOrder, overrides = {}) {
  return lane({
    id,
    name,
    resource_kind: "position",
    parent_lane_id: ROOT_A,
    display_order: displayOrder,
    ...overrides,
  });
}

function requireModel(input) {
  const result = buildLaneHierarchyDisplayModel(input);
  assert.equal(result.ok, true);
  return result.value;
}

test("standalone lane and parent-only lane use their own safe label", () => {
  const model = requireModel([lane()]);
  assert.deepEqual(
    model.map(({ displayName, depth, isParent, isPosition }) => ({
      displayName,
      depth,
      isParent,
      isPosition,
    })),
    [
      {
        displayName: "Oś główna",
        depth: 0,
        isParent: true,
        isPosition: false,
      },
    ]
  );
});

test("parent and five children receive complete hierarchy labels", () => {
  const model = requireModel([
    position(CHILD_A3, "Stanowisko 3", 3),
    position(CHILD_A1, "Stanowisko 1", 1),
    lane(),
    position(CHILD_A5, "Stanowisko 5", 5),
    position(CHILD_A2, "Stanowisko 2", 2),
    position(CHILD_A4, "Stanowisko 4", 4),
  ]);

  assert.deepEqual(
    model.map((resource) => resource.displayName),
    [
      "Oś główna",
      "Oś główna — Stanowisko 1",
      "Oś główna — Stanowisko 2",
      "Oś główna — Stanowisko 3",
      "Oś główna — Stanowisko 4",
      "Oś główna — Stanowisko 5",
    ]
  );
  assert.equal(model[1].parentName, "Oś główna");
  assert.equal(model[1].depth, 1);
});

test("multiple parents and standalone resources are deterministically grouped", () => {
  const model = requireModel([
    position(CHILD_A2, "Drugie", 2),
    lane({ id: ROOT_B, name: "B", display_order: 20 }),
    position(CHILD_A1, "Pierwsze", 1),
    lane({ name: "A", display_order: 20 }),
  ]);

  assert.deepEqual(
    model.map((resource) => resource.displayName),
    ["A", "A — Pierwsze", "A — Drugie", "B"]
  );
});

test("inactive child remains visible and explicitly inactive", () => {
  const model = requireModel([
    lane(),
    position(CHILD_A1, "Stanowisko", 1, { is_active: false }),
  ]);

  assert.equal(model[1].displayName, "Oś główna — Stanowisko");
  assert.equal(model[1].isActive, false);
  assert.equal(model[1].isPosition, true);
});

test("duplicate IDs fail closed", () => {
  assert.deepEqual(buildLaneHierarchyDisplayModel([lane(), lane()]), {
    ok: false,
    code: "duplicate_id",
  });
});

test("a position with a missing parent fails closed", () => {
  assert.deepEqual(
    buildLaneHierarchyDisplayModel([
      position(CHILD_A1, "Stanowisko", 1, { parent_lane_id: ROOT_B }),
    ]),
    { ok: false, code: "missing_parent" }
  );
});

test("depth greater than one fails closed", () => {
  assert.deepEqual(
    buildLaneHierarchyDisplayModel([
      lane(),
      position(CHILD_A1, "Poziom 1", 1),
      position(CHILD_A2, "Poziom 2", 1, { parent_lane_id: CHILD_A1 }),
    ]),
    { ok: false, code: "unsupported_depth" }
  );
});

test("malformed resources and invalid root relationships fail closed", () => {
  assert.deepEqual(buildLaneHierarchyDisplayModel([lane({ name: " " })]), {
    ok: false,
    code: "invalid_resource",
  });
  assert.deepEqual(
    buildLaneHierarchyDisplayModel([lane({ parent_lane_id: ROOT_B })]),
    { ok: false, code: "invalid_hierarchy" }
  );
});

test("helper contains no hardcoded production lane name or UUID", async () => {
  const source = await readFile(
    new URL("./lane-hierarchy.js", import.meta.url),
    "utf8"
  );

  assert.doesNotMatch(source, /100\s*m/i);
  assert.doesNotMatch(source, /254ca7f6-ce80-4267-8966-4558cc8f8fd2/i);
});
