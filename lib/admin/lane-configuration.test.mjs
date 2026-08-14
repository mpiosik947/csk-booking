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

function editedResource(state, laneId = ROOT_ID) {
  return state.resources.find((resource) => resource.lane_id === laneId);
}

function editPricing(dayGroup, min, max, label, price, key) {
  return {
    edit_key: key,
    day_group: dayGroup,
    min_shooters: String(min),
    max_shooters: String(max),
    label,
    hourly_price: String(price),
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

test("limit change requires matching editable pricing coverage", () => {
  const family = parseAdminLaneConfigurationSnapshot(validSnapshot()).families[0];
  const state = createLaneFamilyEditState(family);
  state.resources[0].max_people_online = "5";
  let validation = validateLaneFamilyEditState(family, state);
  assert.match(
    validation.errors.join(" "),
    /dostosuj cennik Pon–Czw do nowego maksymalnego limitu osób/i
  );
  const root = editedResource(state);
  for (const rule of root.pricing) rule.max_shooters = "5";
  validation = validateLaneFamilyEditState(family, state);
  assert.equal(validation.valid, true);
  assert.equal(buildLaneFamilyWritePayload(family, state)[0].max_people_online, 5);
  assert.deepEqual(
    buildLaneFamilyWritePayload(family, state)[0].pricing.map((rule) => rule.max_shooters),
    [5, 5]
  );
});

test("duration target supports add/delete and validates duplicates, bounds and booking step", () => {
  const family = parseAdminLaneConfigurationSnapshot(validSnapshot()).families[0];

  const valid = createLaneFamilyEditState(family);
  editedResource(valid).durations_minutes.push("120");
  assert.equal(validateLaneFamilyEditState(family, valid).valid, true);
  assert.deepEqual(buildLaneFamilyWritePayload(family, valid)[0].durations_minutes, [60, 120]);
  editedResource(valid).durations_minutes = ["120"];
  assert.equal(validateLaneFamilyEditState(family, valid).valid, true);

  const duplicate = createLaneFamilyEditState(family);
  editedResource(duplicate).durations_minutes.push("60");
  assert.match(validateLaneFamilyEditState(family, duplicate).errors.join(" "), /więcej niż raz/);

  const zero = createLaneFamilyEditState(family);
  editedResource(zero).durations_minutes = ["0"];
  assert.match(validateLaneFamilyEditState(family, zero).errors.join(" "), /od 1 do 1440 minut/);

  const wrongStep = createLaneFamilyEditState(family);
  editedResource(wrongStep).durations_minutes = ["90"];
  assert.match(validateLaneFamilyEditState(family, wrongStep).errors.join(" "), /podzielny przez krok 60 min/);
});

test("online requires a duration while an offline dormant position may keep none", () => {
  const family = parseAdminLaneConfigurationSnapshot(validSnapshot()).families[0];
  const online = createLaneFamilyEditState(family);
  editedResource(online).durations_minutes = [];
  assert.match(validateLaneFamilyEditState(family, online).errors.join(" "), /wymaga co najmniej jednego czasu/);

  const offline = createLaneFamilyEditState(family);
  const dormant = editedResource(offline, CHILD_A_ID);
  dormant.durations_minutes = [];
  dormant.pricing = [];
  assert.equal(validateLaneFamilyEditState(family, offline).valid, true);
});

test("pricing validates complete coverage, gaps, overlaps and both day groups", () => {
  const family = parseAdminLaneConfigurationSnapshot(validSnapshot()).families[0];

  const complete = createLaneFamilyEditState(family);
  editedResource(complete).pricing = [
    editPricing("mon_thu", 1, 2, "1–2 osoby", 50, "m1"),
    editPricing("mon_thu", 3, 6, "3–6 osób", 80, "m2"),
    editPricing("fri_sun", 1, 3, "1–3 osoby", 60, "f1"),
    editPricing("fri_sun", 4, 6, "4–6 osób", 90, "f2"),
  ];
  assert.equal(validateLaneFamilyEditState(family, complete).valid, true);

  const gap = structuredClone(complete);
  editedResource(gap).pricing[1].min_shooters = "4";
  assert.match(validateLaneFamilyEditState(family, gap).errors.join(" "), /zawiera lukę/);

  const overlap = structuredClone(complete);
  editedResource(overlap).pricing[1].min_shooters = "2";
  assert.match(validateLaneFamilyEditState(family, overlap).errors.join(" "), /nakładają się/);

  const missingWeekdays = structuredClone(complete);
  editedResource(missingWeekdays).pricing = editedResource(missingWeekdays).pricing.filter(
    (rule) => rule.day_group !== "mon_thu"
  );
  assert.match(validateLaneFamilyEditState(family, missingWeekdays).errors.join(" "), /brak cennika Pon–Czw/);

  const missingWeekend = structuredClone(complete);
  editedResource(missingWeekend).pricing = editedResource(missingWeekend).pricing.filter(
    (rule) => rule.day_group !== "fri_sun"
  );
  assert.match(validateLaneFamilyEditState(family, missingWeekend).errors.join(" "), /brak cennika Pt–Nd/);
});

test("pricing rejects invalid money and empty labels", () => {
  const family = parseAdminLaneConfigurationSnapshot(validSnapshot()).families[0];

  for (const [price, pattern] of [
    ["-1", /nieujemną liczbą/],
    ["12.345", /maksymalnie 2 miejscami/],
  ]) {
    const state = createLaneFamilyEditState(family);
    editedResource(state).pricing[0].hourly_price = price;
    assert.match(validateLaneFamilyEditState(family, state).errors.join(" "), pattern);
  }

  const emptyLabel = createLaneFamilyEditState(family);
  editedResource(emptyLabel).pricing[0].label = "   ";
  assert.match(validateLaneFamilyEditState(family, emptyLabel).errors.join(" "), /nazwa progu cenowego nie może być pusta/);

  const comma = createLaneFamilyEditState(family);
  editedResource(comma).pricing.find((rule) => rule.day_group === "mon_thu").hourly_price = "99,50";
  assert.equal(validateLaneFamilyEditState(family, comma).valid, true);
  assert.equal(buildLaneFamilyWritePayload(family, comma)[0].pricing[0].hourly_price, 120);
  assert.equal(buildLaneFamilyWritePayload(family, comma)[0].pricing[1].hourly_price, 99.5);
});

test("pricing change keeps the complete family and unchanged resources", () => {
  const family = parseAdminLaneConfigurationSnapshot(validSnapshot()).families[0];
  const state = createLaneFamilyEditState(family);
  editedResource(state).pricing[0].hourly_price = "130";
  const payload = buildLaneFamilyWritePayload(family, state);

  assert.equal(payload.length, 3);
  assert.equal(payload.find((resource) => resource.lane_id === ROOT_ID).pricing.some((rule) => rule.hourly_price === 130), true);
  assert.deepEqual(payload.find((resource) => resource.lane_id === CHILD_A_ID).pricing, []);
  assert.deepEqual(payload.find((resource) => resource.lane_id === CHILD_B_ID).durations_minutes, []);
});

test("dormant position can be prepared without activation or online change", () => {
  const family = parseAdminLaneConfigurationSnapshot(validSnapshot()).families[0];
  const state = createLaneFamilyEditState(family);
  const dormant = editedResource(state, CHILD_A_ID);
  dormant.durations_minutes = ["60", "120"];
  dormant.pricing = [
    editPricing("mon_thu", 1, 1, "1 osoba", 40, "dm"),
    editPricing("fri_sun", 1, 1, "1 osoba", 50, "df"),
  ];
  const validation = validateLaneFamilyEditState(family, state);
  assert.equal(validation.valid, true);
  const payload = buildLaneFamilyWritePayload(family, state).find(
    (resource) => resource.lane_id === CHILD_A_ID
  );
  assert.equal(payload.is_active, false);
  assert.equal(payload.online_bookable, false);
  assert.deepEqual(payload.durations_minutes, [60, 120]);
  assert.equal(payload.pricing.length, 2);
});

test("duration and pricing changes participate in dirty state, revert and before/after", () => {
  const family = parseAdminLaneConfigurationSnapshot(validSnapshot()).families[0];
  const state = createLaneFamilyEditState(family);
  const original = structuredClone(state);
  editedResource(state).durations_minutes.push("120");
  editedResource(state).pricing.find((rule) => rule.day_group === "mon_thu").hourly_price = "130";
  assert.equal(isLaneFamilyDirty(family, state), true);
  const changes = getLaneFamilyChanges(family, state);
  assert.equal(changes.some((change) => change.label === "Dostępne czasy rezerwacji"), true);
  assert.equal(changes.some((change) => change.label === "Cennik Pon–Czw"), true);

  state.resources = original.resources;
  assert.equal(isLaneFamilyDirty(family, state), false);
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
