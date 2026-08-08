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
});

test("adapter preserves authoritative RPC ordering", () => {
  const input = fiveProductionLanes();
  const parsed = parsePublicBookingConfiguration(input);
  assert.ok(parsed);
  assert.deepEqual(
    adaptPublicBookingConfiguration(parsed).lanes.map((lane) => lane.id),
    LANE_IDS
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

test("parser and adapter do not mutate the RPC response", () => {
  const input = fiveProductionLanes();
  const before = JSON.stringify(input);
  const parsed = parsePublicBookingConfiguration(input);
  assert.ok(parsed);
  adaptPublicBookingConfiguration(parsed);
  assert.equal(JSON.stringify(input), before);
});
