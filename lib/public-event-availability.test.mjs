import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  getPublicRegistrationAvailability,
  parsePublicEventAvailability,
} from "./public-event-availability.ts";

const EVENT_ID = "10000000-0000-4000-8000-000000000001";

function row(overrides = {}) {
  return {
    event_id: EVENT_ID,
    title: "[TEST] Szkolenie",
    description: "Opis",
    event_date: "2026-12-10",
    start_time: "10:00:00",
    end_time: "12:00:00",
    location: "Strzelnica",
    price: 100,
    max_participants: 10,
    registered_count: 3,
    reserve_count: 0,
    available_spots: 7,
    sold_out: false,
    ...overrides,
  };
}

test("capacity 10 with three participants exposes seven available spots", () => {
  const parsed = parsePublicEventAvailability([row()]);

  assert.equal(parsed?.[0].registered_count, 3);
  assert.equal(parsed?.[0].available_spots, 7);
});

test("reserve registrations do not consume capacity but preserve queue fairness", () => {
  const parsed = parsePublicEventAvailability([row({ reserve_count: 2 })]);

  assert.equal(parsed?.[0].available_spots, 7);
  assert.deepEqual(getPublicRegistrationAvailability(parsed[0]), {
    directlyAvailableSpots: 0,
    requiresReserveList: true,
  });
});

test("sold-out response is accepted only with zero available spots", () => {
  const parsed = parsePublicEventAvailability([
    row({ registered_count: 10, available_spots: 0, sold_out: true }),
  ]);

  assert.equal(parsed?.[0].sold_out, true);
  assert.equal(parsePublicEventAvailability([row({ sold_out: true })]), null);
});

test("malformed or duplicate rows fail closed", () => {
  assert.equal(parsePublicEventAvailability({}), null);
  assert.equal(parsePublicEventAvailability([row(), row()]), null);
  assert.equal(
    parsePublicEventAvailability([row({ available_spots: 8 })]),
    null
  );
});

test("public response rejects PII and internal registration identifiers", () => {
  for (const extraField of [
    "user_id",
    "customer_name",
    "customer_email",
    "customer_phone",
    "registration_id",
    "promotion_token",
  ]) {
    assert.equal(
      parsePublicEventAvailability([row({ [extraField]: "secret" })]),
      null
    );
  }
});

test("events page uses only the authoritative public availability RPC", async () => {
  const source = await readFile(
    new URL("../app/events/page.tsx", import.meta.url),
    "utf8"
  );

  assert.match(source, /\.rpc\(\s*"get_public_event_availability_v1"\s*\)/);
  assert.doesNotMatch(source, /\.from\(\s*"event_registrations"/);
  assert.doesNotMatch(source, /event_registrations\s*\(/);
  assert.doesNotMatch(source, /getParticipantsCount|getReserveCount/);
});

test("event registration write path remains atomic and unchanged", async () => {
  const source = await readFile(
    new URL("../app/events/page.tsx", import.meta.url),
    "utf8"
  );

  assert.match(source, /fetch\(\s*"\/api\/register-event"/);
  assert.doesNotMatch(source, /\.from\(\s*"event_registrations"\s*\)\s*\.insert/);
});

test("public events expose authoritative availability to anon without local counting", async () => {
  const source = await readFile(
    new URL("../app/events/page.tsx", import.meta.url),
    "utf8"
  );

  assert.match(source, /const participantsCount = event\.registered_count/);
  assert.match(source, /const reserveCount = event\.reserve_count/);
  assert.match(source, /const publicFreePlaces = directlyAvailableSpots/);
  assert.doesNotMatch(source, /Dostępność po zalogowaniu/);
  assert.doesNotMatch(source, /Limit: \$\{event\.max_participants\}/);
});

test("public event CTA closes at the canonical Warsaw start without changing the RPC", async () => {
  const source = await readFile(
    new URL("../app/events/page.tsx", import.meta.url),
    "utf8"
  );

  assert.match(source, /hasWarsawEventStarted/);
  assert.match(source, /Zapisy na to szkolenie są zakończone\./);
  assert.match(source, /\.rpc\(\s*"get_public_event_availability_v1"\s*\)/);
  assert.equal(
    (source.match(/await fetchPublicEvents\(\)/g) ?? []).length,
    2,
    "initial load and post-registration refresh must both use the public RPC"
  );
});
