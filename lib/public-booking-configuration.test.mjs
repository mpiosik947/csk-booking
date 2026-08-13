import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  adaptPublicBookingConfiguration,
  parsePublicBookingConfiguration,
} from "./public-booking-configuration.ts";

const LANE_IDS = [
  "10000000-0000-4000-8000-000000000001",
  "10000000-0000-4000-8000-000000000002",
  "10000000-0000-4000-8000-000000000003",
  "10000000-0000-4000-8000-000000000004",
  "10000000-0000-4000-8000-000000000005",
  "10000000-0000-4000-8000-000000000006",
  "10000000-0000-4000-8000-000000000007",
  "10000000-0000-4000-8000-000000000008",
  "10000000-0000-4000-8000-000000000009",
];

function pricing(maxPeople = 6) {
  return [
    {
      day_group: "mon_thu",
      min_shooters: 1,
      max_shooters: maxPeople,
      hourly_price: 100,
      label: "Poniedziałek–czwartek",
    },
    {
      day_group: "fri_sun",
      min_shooters: 1,
      max_shooters: maxPeople,
      hourly_price: 120,
      label: "Piątek–niedziela",
    },
  ];
}

function resource(overrides = {}) {
  const maxPeople = overrides.max_people_online ?? 6;

  return {
    lane_id: LANE_IDS[0],
    parent_lane_id: null,
    resource_kind: "lane",
    name: "Oś 100 m",
    display_name: "Oś 100 m",
    display_order: 10,
    effective_online_bookable: true,
    whole_lane_bookable: true,
    positions_bookable: false,
    max_people_online: maxPeople,
    booking_step_minutes: 60,
    currency_code: "PLN",
    durations_minutes: [60, 120, 180, 240],
    pricing: pricing(maxPeople),
    ...overrides,
  };
}

function fiveProductionLanes() {
  return [
    resource({ lane_id: LANE_IDS[0], name: "Oś 50 m — stanowisko 1", display_name: "Oś 50 m — stanowisko 1", display_order: 10, max_people_online: 5, pricing: pricing(5) }),
    resource({ lane_id: LANE_IDS[1], name: "Oś 50 m — stanowisko 2", display_name: "Oś 50 m — stanowisko 2", display_order: 20, max_people_online: 5, pricing: pricing(5) }),
    resource({ lane_id: LANE_IDS[2], name: "Oś 100 m", display_name: "Oś 100 m", display_order: 30 }),
    resource({ lane_id: LANE_IDS[3], name: "Trap", display_name: "Trap", display_order: 40 }),
    resource({ lane_id: LANE_IDS[4], name: "Skeet", display_name: "Skeet", display_order: 50 }),
  ];
}

test("booking page uses only the public configuration RPC", async () => {
  const source = await readFile(
    new URL("../app/booking/page.tsx", import.meta.url),
    "utf8"
  );

  assert.match(source, /\.rpc\(\s*"get_public_booking_configuration_v1"\s*\)/);
  assert.equal((source.match(/supabase\.rpc\(/g) ?? []).length, 1);
});

test("booking config flow has no direct shooting_lanes SELECT", async () => {
  const source = await readFile(new URL("../app/booking/page.tsx", import.meta.url), "utf8");
  assert.doesNotMatch(source, /\.from\(\s*"shooting_lanes"/);
});

test("booking config flow has no direct duration SELECT", async () => {
  const source = await readFile(new URL("../app/booking/page.tsx", import.meta.url), "utf8");
  assert.doesNotMatch(source, /\.from\(\s*"lane_booking_durations"/);
});

test("booking config flow has no direct pricing SELECT", async () => {
  const source = await readFile(new URL("../app/booking/page.tsx", import.meta.url), "utf8");
  assert.doesNotMatch(source, /\.from\(\s*"lane_pricing_rules"/);
});

test("five current top-level lanes map to the existing UX shape", () => {
  const parsed = parsePublicBookingConfiguration(fiveProductionLanes());
  assert.ok(parsed);
  const adapted = adaptPublicBookingConfiguration(parsed);

  assert.equal(adapted.lanes.length, 5);
  assert.deepEqual(
    adapted.lanes.map((lane) => lane.name),
    ["Oś 50 m — stanowisko 1", "Oś 50 m — stanowisko 2", "Oś 100 m", "Trap", "Skeet"]
  );
  assert.deepEqual(adapted.lanes.map((lane) => lane.id), LANE_IDS.slice(0, 5));
  assert.deepEqual(
    adapted.lanes.map((lane) => lane.max_people_online),
    [5, 5, 6, 6, 6]
  );
  assert.equal(adapted.durations.length, 20);
  assert.equal(adapted.pricingRules.length, 10);
  assert.equal(
    adapted.durations.every(({ lane_id }) => LANE_IDS.slice(0, 5).includes(lane_id)),
    true
  );
  assert.equal(
    adapted.pricingRules.every(({ lane_id }) => LANE_IDS.slice(0, 5).includes(lane_id)),
    true
  );
});

test("adapter preserves authoritative RPC ordering", () => {
  const input = fiveProductionLanes();
  const parsed = parsePublicBookingConfiguration(input);
  assert.ok(parsed);
  assert.deepEqual(
    adaptPublicBookingConfiguration(parsed).lanes.map((lane) => lane.id),
    LANE_IDS.slice(0, 5)
  );
});

test("future positions-only families expose children without selecting the container", () => {
  const input = [
    resource({
      lane_id: LANE_IDS[0],
      name: "Oś 100 m",
      display_name: "Oś 100 m",
      effective_online_bookable: false,
      whole_lane_bookable: false,
      positions_bookable: true,
      max_people_online: null,
      durations_minutes: [],
      pricing: [],
    }),
    resource({
      lane_id: LANE_IDS[2],
      parent_lane_id: LANE_IDS[0],
      resource_kind: "position",
      name: "Stanowisko 2",
      display_name: "Oś 100 m — Stanowisko 2",
      display_order: 20,
      whole_lane_bookable: false,
      max_people_online: 2,
      durations_minutes: [60],
      pricing: pricing(2),
    }),
    resource({
      lane_id: LANE_IDS[1],
      parent_lane_id: LANE_IDS[0],
      resource_kind: "position",
      name: "Stanowisko 1",
      display_name: "Oś 100 m — Stanowisko 1",
      display_order: 10,
      whole_lane_bookable: false,
      max_people_online: 1,
      durations_minutes: [120],
      pricing: pricing(1),
    }),
    resource({
      lane_id: LANE_IDS[3],
      parent_lane_id: LANE_IDS[0],
      resource_kind: "position",
      name: "Stanowisko 3",
      display_name: "Oś 100 m — Stanowisko 3",
      display_order: 30,
      whole_lane_bookable: false,
      max_people_online: 3,
      durations_minutes: [180],
      pricing: pricing(3),
    }),
  ];
  const parsed = parsePublicBookingConfiguration(input);
  assert.ok(parsed);
  const adapted = adaptPublicBookingConfiguration(parsed);

  assert.deepEqual(
    adapted.lanes.map(({ id, name, max_people_online }) => ({
      id,
      name,
      max_people_online,
    })),
    [
      { id: LANE_IDS[1], name: "Oś 100 m — Stanowisko 1", max_people_online: 1 },
      { id: LANE_IDS[2], name: "Oś 100 m — Stanowisko 2", max_people_online: 2 },
      { id: LANE_IDS[3], name: "Oś 100 m — Stanowisko 3", max_people_online: 3 },
    ]
  );
  assert.deepEqual(
    adapted.durations.map(({ lane_id, duration_minutes }) => [lane_id, duration_minutes]),
    [[LANE_IDS[1], 120], [LANE_IDS[2], 60], [LANE_IDS[3], 180]]
  );
  assert.deepEqual(
    adapted.pricingRules.map(({ lane_id }) => lane_id),
    [LANE_IDS[1], LANE_IDS[1], LANE_IDS[2], LANE_IDS[2], LANE_IDS[3], LANE_IDS[3]]
  );
});

test("a selectable whole lane and its children have unambiguous labels once", () => {
  const parent = resource({
    lane_id: LANE_IDS[0],
    name: "Oś 100 m",
    display_name: "Oś 100 m",
    positions_bookable: true,
  });
  const children = [1, 2, 3].map((number) =>
    resource({
      lane_id: LANE_IDS[number],
      parent_lane_id: LANE_IDS[0],
      resource_kind: "position",
      name: `Stanowisko ${number}`,
      display_name: `Oś 100 m — Stanowisko ${number}`,
      display_order: number * 10,
      whole_lane_bookable: false,
    })
  );
  const parsed = parsePublicBookingConfiguration([parent, ...children]);
  assert.ok(parsed);

  assert.deepEqual(
    adaptPublicBookingConfiguration(parsed).lanes.map(({ id, name }) => ({ id, name })),
    [
      { id: LANE_IDS[0], name: "Oś 100 m — Cała oś" },
      { id: LANE_IDS[1], name: "Oś 100 m — Stanowisko 1" },
      { id: LANE_IDS[2], name: "Oś 100 m — Stanowisko 2" },
      { id: LANE_IDS[3], name: "Oś 100 m — Stanowisko 3" },
    ]
  );
});

test("standalone resources use display_name without a synthetic whole-lane suffix", () => {
  const parsed = parsePublicBookingConfiguration([
    resource({ name: "Internal name", display_name: "Trap" }),
  ]);
  assert.ok(parsed);
  assert.equal(adaptPublicBookingConfiguration(parsed).lanes[0].name, "Trap");
});

test("malformed hierarchy and missing child sales config fail closed", () => {
  const child = resource({
    lane_id: LANE_IDS[1],
    parent_lane_id: LANE_IDS[0],
    resource_kind: "position",
    display_name: "Oś 100 m — Stanowisko 1",
    whole_lane_bookable: false,
  });

  assert.equal(parsePublicBookingConfiguration([child]), null);
  assert.equal(
    parsePublicBookingConfiguration([
      resource({
        lane_id: LANE_IDS[0],
        positions_bookable: true,
        effective_online_bookable: false,
        whole_lane_bookable: false,
        max_people_online: null,
        durations_minutes: [],
        pricing: [],
      }),
      { ...child, durations_minutes: [], pricing: [] },
    ]),
    null
  );
  assert.equal(
    parsePublicBookingConfiguration([
      resource({ lane_id: LANE_IDS[0], positions_bookable: false }),
      child,
    ]),
    null
  );
});

test("max_people_online becomes the public people limit", () => {
  const parsed = parsePublicBookingConfiguration([resource({ max_people_online: 3, pricing: pricing(3) })]);
  assert.ok(parsed);
  const [lane] = adaptPublicBookingConfiguration(parsed).lanes;
  assert.equal(lane.max_people_online, 3);
  assert.equal("max_shooters" in lane, false);
});

test("durations map without synthetic database identifiers", () => {
  const parsed = parsePublicBookingConfiguration([resource()]);
  assert.ok(parsed);
  assert.deepEqual(adaptPublicBookingConfiguration(parsed).durations, [
    { lane_id: LANE_IDS[0], duration_minutes: 60 },
    { lane_id: LANE_IDS[0], duration_minutes: 120 },
    { lane_id: LANE_IDS[0], duration_minutes: 180 },
    { lane_id: LANE_IDS[0], duration_minutes: 240 },
  ]);
});

test("pricing maps without synthetic rule identifiers", () => {
  const parsed = parsePublicBookingConfiguration([resource()]);
  assert.ok(parsed);
  const rules = adaptPublicBookingConfiguration(parsed).pricingRules;
  assert.equal(rules.length, 2);
  assert.equal(rules.every((rule) => rule.lane_id === LANE_IDS[0]), true);
  assert.equal(rules.some((rule) => "id" in rule), false);
});

test("both mon_thu and fri_sun pricing remain available", () => {
  const parsed = parsePublicBookingConfiguration([resource()]);
  assert.ok(parsed);
  assert.deepEqual(
    adaptPublicBookingConfiguration(parsed).pricingRules.map((rule) => rule.day_group),
    ["mon_thu", "fri_sun"]
  );
});

test("malformed resources fail closed", () => {
  assert.equal(parsePublicBookingConfiguration([resource({ lane_id: "invalid" })]), null);
  assert.equal(parsePublicBookingConfiguration([resource({ parent_lane_id: "invalid" })]), null);
  assert.equal(parsePublicBookingConfiguration([resource({ name: "" })]), null);
  assert.equal(parsePublicBookingConfiguration([resource({ display_name: "" })]), null);
  assert.equal(parsePublicBookingConfiguration([resource({ display_order: 1.5 })]), null);
  assert.equal(parsePublicBookingConfiguration([resource({ effective_online_bookable: "true" })]), null);
  assert.equal(parsePublicBookingConfiguration([resource({ max_people_online: 0 })]), null);
  assert.equal(parsePublicBookingConfiguration([resource({ booking_step_minutes: 0 })]), null);
  assert.equal(parsePublicBookingConfiguration([resource({ currency_code: "pln" })]), null);
  assert.equal(parsePublicBookingConfiguration([resource({ durations_minutes: [60, 60] })]), null);
  assert.equal(parsePublicBookingConfiguration([resource({ resource_kind: "position", parent_lane_id: null })]), null);
  assert.equal(parsePublicBookingConfiguration(null), null);
  assert.equal(
    parsePublicBookingConfiguration([
      resource(),
      resource({ name: "Duplikat", display_name: "Duplikat" }),
    ]),
    null
  );
});

test("malformed pricing fails closed", () => {
  assert.equal(parsePublicBookingConfiguration([resource({ pricing: [{ ...pricing()[0], max_shooters: 5 }] })]), null);
  assert.equal(parsePublicBookingConfiguration([resource({ pricing: [{ ...pricing()[0], hourly_price: Number.NaN }, pricing()[1]] })]), null);
  assert.equal(parsePublicBookingConfiguration([resource({ pricing: [{ ...pricing()[0], day_group: "weekend" }, pricing()[1]] })]), null);
});

test("unknown resource kinds fail closed", () => {
  assert.equal(parsePublicBookingConfiguration([resource({ resource_kind: "unknown" })]), null);
});

test("RPC errors use the controlled existing error state", async () => {
  const source = await readFile(new URL("../app/booking/page.tsx", import.meta.url), "utf8");
  assert.match(source, /if \(configurationResult\.error\)/);
  assert.match(source, /setMessage\([\s\S]*?Nie uda/);
});

test("a valid empty response produces the normal empty configuration", () => {
  const parsed = parsePublicBookingConfiguration([]);
  assert.deepEqual(parsed, []);
  assert.deepEqual(adaptPublicBookingConfiguration(parsed), {
    lanes: [],
    durations: [],
    pricingRules: [],
  });
});

test("booking does not retain a direct-table fallback", async () => {
  const source = await readFile(new URL("../app/booking/page.tsx", import.meta.url), "utf8");
  assert.doesNotMatch(source, /Promise\.all/);
  assert.doesNotMatch(source, /supabase\s*\.from\(/);
});

test("existing top-level lane notices remain based on canonical lane names", async () => {
  const source = await readFile(new URL("../app/booking/BookingForm.tsx", import.meta.url), "utf8");
  assert.match(source, /getLanePricingNotice\(selectedLane\.name\)/);
  assert.match(source, /includes\("100 m"\)/);
  assert.match(source, /includes\("50 m"\)/);
  assert.match(source, /includes\("trap"\) \|\| normalizedName\.includes\("skeet"\)/);
});

test("Booking keeps selected resource UUIDs for availability and reservation creation", async () => {
  const source = await readFile(new URL("../app/booking/BookingForm.tsx", import.meta.url), "utf8");
  assert.match(source, /p_lane_id:\s*targetLaneId/);
  assert.match(source, /body:\s*JSON\.stringify\(\{[\s\S]*?laneId,/);
  assert.doesNotMatch(source, /parent_lane_id|parentLaneId/);
});

test("Booking summary and confirmation use the verified hierarchy-aware option label", async () => {
  const source = await readFile(new URL("../app/booking/BookingForm.tsx", import.meta.url), "utf8");
  assert.match(source, /laneName:\s*selectedLane\.name/);
  assert.match(source, /\{lane\.name\}\s*·\s*maks\./);
  assert.match(source, /\{confirmationData\.laneName\}/);
});

test("parser and adapter do not mutate the RPC response", () => {
  const input = fiveProductionLanes();
  const before = JSON.stringify(input);
  const parsed = parsePublicBookingConfiguration(input);
  assert.ok(parsed);
  adaptPublicBookingConfiguration(parsed);
  assert.equal(JSON.stringify(input), before);
});
