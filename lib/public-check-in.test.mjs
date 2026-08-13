import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { getLaneRelationDisplay } from "./admin/lane-relation-display.js";

const PARENT = "10000000-0000-4000-8000-000000000001";
const CHILD = "10000000-0000-4000-8000-000000000002";

function lane(overrides = {}) {
  return {
    id: PARENT,
    name: "Oś 100 m",
    resource_kind: "lane",
    parent_lane_id: null,
    parent_lane: null,
    ...overrides,
  };
}

test("public check-in renders standalone, parent, and inactive child labels", () => {
  assert.equal(getLaneRelationDisplay(lane())?.displayName, "Oś 100 m");
  assert.equal(
    getLaneRelationDisplay([lane({ name: "Trap" })])?.displayName,
    "Trap"
  );
  const display = getLaneRelationDisplay({
    ...lane({
      id: CHILD,
      name: "Stanowisko 2",
      resource_kind: "position",
      parent_lane_id: PARENT,
    }),
    parent_lane: lane(),
  });
  assert.equal(display?.displayName, "Oś 100 m — Stanowisko 2");
  assert.equal(display?.isActive, false);
});

test("malformed child hierarchy uses no guessed label", () => {
  assert.equal(
    getLaneRelationDisplay(
      lane({
        id: CHILD,
        name: "Stanowisko 2",
        resource_kind: "position",
        parent_lane_id: PARENT,
      })
    ),
    null
  );
});

test("check-in lane query is hierarchy-aware and metadata-minimal", async () => {
  const source = await readFile(
    new URL("../app/check-in/[token]/page.tsx", import.meta.url),
    "utf8"
  );
  const relationSelection = source.match(
    /lanes:shooting_lanes![\s\S]*?\n\s*\)\n\s*`/
  )?.[0];

  assert.ok(relationSelection);
  for (const field of ["id", "name", "resource_kind", "parent_lane_id"]) {
    assert.match(relationSelection, new RegExp(`\\b${field}\\b`));
  }
  assert.match(relationSelection, /shooting_lanes_parent_lane_id_fkey/);
  assert.doesNotMatch(
    relationSelection,
    /pricing|booking_rule|max_people|capacity|customer_|email|phone/
  );
});

test("invalid-token behavior, PII surface, and read-only behavior are unchanged", async () => {
  const source = await readFile(
    new URL("../app/check-in/[token]/page.tsx", import.meta.url),
    "utf8"
  );

  assert.match(source, /Nie znaleziono rezerwacji/);
  assert.match(source, /customer_name/);
  assert.match(source, /customer_email/);
  assert.match(source, /customer_phone/);
  assert.doesNotMatch(source, /\.insert\(|\.update\(|\.delete\(|\.rpc\(/);
  assert.match(source, /getLaneRelationDisplay\(reservation\.lanes\)/);
  assert.match(source, /\?\.displayName \?\? "Nieznana oś"/);
});
