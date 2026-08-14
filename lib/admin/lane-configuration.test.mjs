import assert from "node:assert/strict";
import test from "node:test";
import {
  buildLaneConfigurationHierarchy,
  filterLaneConfigurationHierarchy,
  getLaneConfigurationSummary,
  parseAdminLaneConfigurationSnapshot,
} from "./lane-configuration.ts";

const ROOT_ID = "11111111-1111-4111-8111-111111111111";
const CHILD_ID = "22222222-2222-4222-8222-222222222222";

function resource(overrides = {}) {
  return {
    lane_id: ROOT_ID,
    name: "Oś testowa",
    resource_kind: "lane",
    parent_lane_id: null,
    display_order: 10,
    is_active: true,
    max_shooters: 6,
    whole_lane_bookable: true,
    positions_bookable: false,
    booking_step_minutes: 60,
    currency_code: "PLN",
    online_bookable: true,
    max_people_online: 6,
    durations: [
      { duration_minutes: 60, display_order: 10, is_active: true },
    ],
    pricing: [
      {
        day_group: "mon_thu",
        min_shooters: 1,
        max_shooters: 6,
        label: "1–6 osób",
        hourly_price: 100,
        display_order: 10,
        is_active: true,
      },
    ],
    ...overrides,
  };
}

function validSnapshot() {
  return {
    contract_version: 1,
    resources: [
      resource(),
      resource({
        lane_id: CHILD_ID,
        name: "Stanowisko testowe",
        resource_kind: "position",
        parent_lane_id: ROOT_ID,
        display_order: 1,
        is_active: false,
        max_shooters: 1,
        whole_lane_bookable: false,
        positions_bookable: false,
        online_bookable: false,
        max_people_online: 1,
        durations: [],
        pricing: [],
      }),
    ],
  };
}

test("validates the exact v1 snapshot and preserves resource-owned configuration", () => {
  const parsed = parseAdminLaneConfigurationSnapshot(validSnapshot());

  assert.equal(parsed.contract_version, 1);
  assert.equal(parsed.resources.length, 2);
  assert.deepEqual(parsed.resources[0].durations, [
    { duration_minutes: 60, display_order: 10, is_active: true },
  ]);
  assert.deepEqual(parsed.resources[1].durations, []);
  assert.deepEqual(parsed.resources[1].pricing, []);
});

test("groups a generic parent and dormant child without flattening hierarchy", () => {
  const parsed = parseAdminLaneConfigurationSnapshot(validSnapshot());
  const families = buildLaneConfigurationHierarchy(parsed.resources);

  assert.equal(families.length, 1);
  assert.equal(families[0].root.lane_id, ROOT_ID);
  assert.equal(families[0].children.length, 1);
  assert.equal(families[0].children[0].lane_id, CHILD_ID);
  assert.equal(families[0].children[0].is_active, false);
  assert.equal(families[0].children[0].online_bookable, false);
});

test("summary excludes a dormant child from active and online counts", () => {
  const parsed = parseAdminLaneConfigurationSnapshot(validSnapshot());

  assert.deepEqual(getLaneConfigurationSummary(parsed.resources), {
    lanes: 1,
    positions: 1,
    activeResources: 1,
    onlineResources: 1,
  });
});

test("search keeps family context for a matching child", () => {
  const parsed = parseAdminLaneConfigurationSnapshot(validSnapshot());
  const families = buildLaneConfigurationHierarchy(parsed.resources);
  const result = filterLaneConfigurationHierarchy(families, "stanowisko");

  assert.equal(result.length, 1);
  assert.equal(result[0].root.name, "Oś testowa");
  assert.deepEqual(result[0].children.map((child) => child.name), [
    "Stanowisko testowe",
  ]);
  assert.equal(filterLaneConfigurationHierarchy(families, "brak").length, 0);
});

test("fails closed for an unknown version and a non-array resource collection", () => {
  assert.throws(
    () => parseAdminLaneConfigurationSnapshot({ ...validSnapshot(), contract_version: 2 }),
    /invalid_contract/
  );
  assert.throws(
    () =>
      parseAdminLaneConfigurationSnapshot({
        contract_version: 1,
        resources: {},
      }),
    /invalid_contract/
  );
});

test("fails closed for duplicate resources and an orphaned position", () => {
  const duplicate = validSnapshot();
  duplicate.resources.push({ ...duplicate.resources[0] });
  assert.throws(
    () => parseAdminLaneConfigurationSnapshot(duplicate),
    /duplicate_resource/
  );

  const orphan = validSnapshot();
  orphan.resources = [orphan.resources[1]];
  assert.throws(
    () => parseAdminLaneConfigurationSnapshot(orphan),
    /invalid_hierarchy/
  );
});

test("fails closed for malformed nested configuration instead of partial rendering", () => {
  const malformedDuration = validSnapshot();
  malformedDuration.resources[0].durations = [
    { duration_minutes: 0, display_order: 10, is_active: true },
  ];
  assert.throws(
    () => parseAdminLaneConfigurationSnapshot(malformedDuration),
    /invalid_duration/
  );

  const overlappingPricing = validSnapshot();
  overlappingPricing.resources[0].pricing.push({
    ...overlappingPricing.resources[0].pricing[0],
    min_shooters: 2,
    display_order: 20,
  });
  assert.throws(
    () => parseAdminLaneConfigurationSnapshot(overlappingPricing),
    /overlapping_pricing/
  );
});
