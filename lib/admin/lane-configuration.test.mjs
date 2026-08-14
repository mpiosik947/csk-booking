import assert from "node:assert/strict";
import test from "node:test";
import {
  LANE_CONFIGURATION_WRITE_CODES,
  buildLaneFamilyWritePayload,
  createLaneFamilyEditState,
  filterLaneConfigurationHierarchy,
  getLaneConfigurationSummary,
  getLaneFamilyChanges,
  isLaneFamilyDirty,
  parseAdminLaneConfigurationSnapshot,
  parseLaneConfigurationWriteResult,
  validateLaneFamilyEditState,
} from "./lane-configuration.ts";

const ROOT_ID = "11111111-1111-4111-8111-111111111111";
const CHILD_A_ID = "22222222-2222-4222-8222-222222222222";
const CHILD_B_ID = "33333333-3333-4333-8333-333333333333";
const OTHER_ROOT_ID = "44444444-4444-4444-8444-444444444444";

function pricing(maxShooters = 6) {
  return [
    {
      day_group: "mon_thu",
      min_shooters: 1,
      max_shooters: maxShooters,
      label: `1–${maxShooters} osób`,
      hourly_price: 100,
      display_order: 10,
      is_active: true,
    },
    {
      day_group: "fri_sun",
      min_shooters: 1,
      max_shooters: maxShooters,
      label: `1–${maxShooters} osób`,
      hourly_price: 120,
      display_order: 10,
      is_active: true,
    },
  ];
}

function rootResource(overrides = {}) {
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
      { duration_minutes: 120, display_order: 20, is_active: false },
    ],
    pricing: [
      ...pricing(),
      {
        day_group: "mon_thu",
        min_shooters: 1,
        max_shooters: 5,
        label: "historyczna",
        hourly_price: 80,
        display_order: 20,
        is_active: false,
      },
    ],
    ...overrides,
  };
}

function dormantChild(id = CHILD_A_ID, overrides = {}) {
  return {
    lane_id: id,
    name: id === CHILD_A_ID ? "Stanowisko A" : "Stanowisko B",
    resource_kind: "position",
    parent_lane_id: ROOT_ID,
    display_order: id === CHILD_A_ID ? 1 : 2,
    is_active: false,
    max_shooters: 1,
    whole_lane_bookable: false,
    positions_bookable: false,
    booking_step_minutes: 60,
    currency_code: "PLN",
    online_bookable: false,
    max_people_online: 1,
    durations: [],
    pricing: [],
    ...overrides,
  };
}

function validSnapshot() {
  return {
    contract_version: 2,
    families: [
      {
        root_lane_id: ROOT_ID,
        configuration_version: 7,
        resources: [rootResource(), dormantChild(), dormantChild(CHILD_B_ID)],
      },
    ],
  };
}

test("validates the exact V2 family contract and preserves full nested read data", () => {
  const parsed = parseAdminLaneConfigurationSnapshot(validSnapshot());

  assert.equal(parsed.contract_version, 2);
  assert.equal(parsed.families.length, 1);
  assert.equal(parsed.families[0].configuration_version, 7);
  assert.equal(parsed.families[0].root.lane_id, ROOT_ID);
  assert.deepEqual(parsed.families[0].children.map((child) => child.lane_id), [
    CHILD_A_ID,
    CHILD_B_ID,
  ]);
  assert.equal(parsed.resources[0].durations.length, 2);
  assert.equal(parsed.resources[0].pricing.length, 3);
});

test("fails closed for unknown contract, malformed family, duplicate roots and resources", () => {
  assert.throws(
    () => parseAdminLaneConfigurationSnapshot({ ...validSnapshot(), contract_version: 1 }),
    /invalid_contract/
  );
  assert.throws(
    () =>
      parseAdminLaneConfigurationSnapshot({
        contract_version: 2,
        families: [{ root_lane_id: ROOT_ID, configuration_version: 1 }],
      }),
    /invalid_family/
  );

  const duplicateFamily = validSnapshot();
  duplicateFamily.families.push(structuredClone(duplicateFamily.families[0]));
  assert.throws(
    () => parseAdminLaneConfigurationSnapshot(duplicateFamily),
    /duplicate_family/
  );

  const duplicateResource = validSnapshot();
  duplicateResource.families[0].resources.push(
    structuredClone(duplicateResource.families[0].resources[1])
  );
  assert.throws(
    () => parseAdminLaneConfigurationSnapshot(duplicateResource),
    /duplicate_resource/
  );
});

test("fails closed for orphan, position outside family, missing root and multiple roots", () => {
  const orphan = validSnapshot();
  orphan.families[0].resources[1].parent_lane_id = OTHER_ROOT_ID;
  assert.throws(() => parseAdminLaneConfigurationSnapshot(orphan), /invalid_hierarchy/);

  const missingRoot = validSnapshot();
  missingRoot.families[0].resources = missingRoot.families[0].resources.slice(1);
  assert.throws(
    () => parseAdminLaneConfigurationSnapshot(missingRoot),
    /invalid_hierarchy/
  );

  const multipleRoots = validSnapshot();
  multipleRoots.families[0].resources.push(
    rootResource({ lane_id: OTHER_ROOT_ID, name: "Inna oś" })
  );
  assert.throws(
    () => parseAdminLaneConfigurationSnapshot(multipleRoots),
    /invalid_hierarchy/
  );
});

test("fails closed for malformed nested duration, pricing and limits", () => {
  const malformedDuration = validSnapshot();
  malformedDuration.families[0].resources[0].durations[0].duration_minutes = 0;
  assert.throws(
    () => parseAdminLaneConfigurationSnapshot(malformedDuration),
    /invalid_duration/
  );

  const malformedPricing = validSnapshot();
  malformedPricing.families[0].resources[0].pricing[0].hourly_price = -1;
  assert.throws(
    () => parseAdminLaneConfigurationSnapshot(malformedPricing),
    /invalid_pricing/
  );

  const malformedLimits = validSnapshot();
  malformedLimits.families[0].resources[0].max_people_online = 7;
  assert.throws(
    () => parseAdminLaneConfigurationSnapshot(malformedLimits),
    /invalid_resource/
  );
});

test("builds the exact full-family writer payload and preserves immutable settings", () => {
  const family = parseAdminLaneConfigurationSnapshot(validSnapshot()).families[0];
  const state = createLaneFamilyEditState(family);
  state.resources[0].max_shooters = "7";
  const payload = buildLaneFamilyWritePayload(family, state);

  assert.equal(payload.length, 3);
  assert.deepEqual(
    Object.keys(payload[0]).sort(),
    [
      "durations_minutes",
      "is_active",
      "lane_id",
      "max_people_online",
      "max_shooters",
      "online_bookable",
      "positions_bookable",
      "pricing",
      "whole_lane_bookable",
    ].sort()
  );
  const root = payload.find((resource) => resource.lane_id === ROOT_ID);
  const childA = payload.find((resource) => resource.lane_id === CHILD_A_ID);
  assert.equal(root.max_shooters, 7);
  assert.deepEqual(root.durations_minutes, [60]);
  assert.equal(root.pricing.length, 2);
  assert.deepEqual(Object.keys(root.pricing[0]).sort(), [
    "day_group",
    "hourly_price",
    "label",
    "max_shooters",
    "min_shooters",
  ]);
  assert.deepEqual(childA, {
    lane_id: CHILD_A_ID,
    is_active: false,
    whole_lane_bookable: false,
    positions_bookable: false,
    max_shooters: 1,
    online_bookable: false,
    max_people_online: 1,
    durations_minutes: [],
    pricing: [],
  });
  assert.equal(family.configuration_version, 7);
});

test("dirty state and before/after contain only real editable changes", () => {
  const family = parseAdminLaneConfigurationSnapshot(validSnapshot()).families[0];
  const state = createLaneFamilyEditState(family);
  assert.equal(isLaneFamilyDirty(family, state), false);
  assert.deepEqual(getLaneFamilyChanges(family, state), []);

  state.resources[1].max_shooters = "2";
  assert.equal(isLaneFamilyDirty(family, state), true);
  assert.deepEqual(getLaneFamilyChanges(family, state), [
    {
      resourceName: "Stanowisko A",
      label: "Pojemność stanowiska",
      before: "1",
      after: "2",
    },
  ]);
  state.resources[1].max_shooters = "1";
  assert.equal(isLaneFamilyDirty(family, state), false);
  state.resources[1].max_shooters = "";
  assert.equal(isLaneFamilyDirty(family, state), true);
});

test("before/after uses lane capacity and per-reservation terminology", () => {
  const family = parseAdminLaneConfigurationSnapshot(validSnapshot()).families[0];
  const state = createLaneFamilyEditState(family);
  state.resources[0].max_shooters = "7";
  state.resources[0].max_people_online = "5";

  assert.deepEqual(getLaneFamilyChanges(family, state), [
    {
      resourceName: "Oś testowa",
      label: "Pojemność osi",
      before: "6",
      after: "7",
    },
    {
      resourceName: "Oś testowa",
      label: "Maks. osób w jednej rezerwacji",
      before: "6",
      after: "5",
    },
  ]);
});

test("local validation blocks invalid limits and incomplete positions mode", () => {
  const family = parseAdminLaneConfigurationSnapshot(validSnapshot()).families[0];
  const state = createLaneFamilyEditState(family);
  state.resources[1].max_people_online = "2";
  assert.match(
    validateLaneFamilyEditState(family, state).errors.join(" "),
    /maks\. osób w jednej rezerwacji nie może przekraczać pojemności stanowiska/
  );

  const positionsState = createLaneFamilyEditState(family);
  positionsState.root_positions_bookable = true;
  assert.match(
    validateLaneFamilyEditState(family, positionsState).errors.join(" "),
    /Najpierw skonfiguruj co najmniej jedno stanowisko/
  );
});

test("local validation preserves pricing coverage while pricing remains read-only", () => {
  const family = parseAdminLaneConfigurationSnapshot(validSnapshot()).families[0];
  const state = createLaneFamilyEditState(family);
  state.resources[0].max_people_online = "5";
  const validation = validateLaneFamilyEditState(family, state);
  assert.equal(validation.valid, false);
  assert.match(
    validation.errors.join(" "),
    /Obecny cennik obejmuje rezerwacje dla innej liczby osób/i
  );
  assert.match(
    validation.errors.join(" "),
    /Edycja cennika będzie dostępna w kolejnym etapie konfiguracji/
  );
});

test("summary and search preserve family context for dormant positions", () => {
  const parsed = parseAdminLaneConfigurationSnapshot(validSnapshot());
  assert.deepEqual(getLaneConfigurationSummary(parsed.resources), {
    lanes: 1,
    positions: 2,
    activeResources: 1,
    onlineResources: 1,
  });
  const result = filterLaneConfigurationHierarchy(parsed.families, "stanowisko a");
  assert.equal(result.length, 1);
  assert.equal(result[0].root.name, "Oś testowa");
  assert.deepEqual(result[0].children.map((child) => child.name), ["Stanowisko A"]);
});

test("all ten write result codes are controlled and unknown codes fail closed", () => {
  assert.equal(LANE_CONFIGURATION_WRITE_CODES.length, 10);
  for (const code of LANE_CONFIGURATION_WRITE_CODES) {
    const input =
      code === "confirmation_required"
        ? {
            code,
            ok: false,
            changed: false,
            future_reservations_count: 2,
            future_lane_blocks_count: 3,
            future_events_count: 4,
          }
        : {
            code,
            ok: code === "updated" || code === "no_change",
            changed: code === "updated",
          };
    assert.equal(parseLaneConfigurationWriteResult(input).code, code);
  }
  assert.deepEqual(
    parseLaneConfigurationWriteResult({
      code: "confirmation_required",
      ok: false,
      changed: false,
      future_reservations_count: 2,
      future_lane_blocks_count: 3,
      future_events_count: 4,
    }),
    {
      code: "confirmation_required",
      futureReservationsCount: 2,
      futureLaneBlocksCount: 3,
      futureEventsCount: 4,
    }
  );
  assert.throws(
    () => parseLaneConfigurationWriteResult({ code: "mystery", ok: false, changed: false }),
    /unknown_write_code/
  );
  assert.throws(
    () =>
      parseLaneConfigurationWriteResult({
        code: "confirmation_required",
        ok: false,
        changed: false,
      }),
    /invalid_write_result/
  );
  assert.throws(
    () => parseLaneConfigurationWriteResult({ code: "updated", ok: true, changed: false }),
    /invalid_write_result/
  );
});
