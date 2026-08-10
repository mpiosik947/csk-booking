import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  CREATE_RESERVATION_CODES,
  CREATE_RESERVATION_MESSAGES,
  getCreateReservationHttpStatus,
  isCreateReservationRpcResult,
  parseCreateReservationPayload,
} from "./create-reservation-contract.ts";

const validPayload = {
  laneId: "11111111-1111-4111-8111-111111111111",
  reservationDate: "2030-07-24",
  startTime: "10:30",
  durationMinutes: 90,
  shootersCount: 2,
  creationRequestId: "22222222-2222-4222-8222-222222222222",
  reservationNote: "  test  ",
};

test("accepts only the RPC business inputs", () => {
  assert.deepEqual(parseCreateReservationPayload(validPayload), {
    ...validPayload,
    reservationNote: "test",
  });
  assert.equal(
    parseCreateReservationPayload({ ...validPayload, userId: validPayload.laneId }),
    null
  );
  assert.equal(
    parseCreateReservationPayload({ ...validPayload, totalPrice: 1 }),
    null
  );
  assert.equal(
    parseCreateReservationPayload({ ...validPayload, dayGroup: "mon_thu" }),
    null
  );
});

test("rejects an invalid UUID", () => {
  assert.equal(parseCreateReservationPayload({ ...validPayload, laneId: "x" }), null);
  assert.equal(
    parseCreateReservationPayload({ ...validPayload, creationRequestId: "x" }),
    null
  );
});

test("rejects missing required fields", () => {
  const withoutLane = { ...validPayload };
  delete withoutLane.laneId;
  assert.equal(parseCreateReservationPayload(withoutLane), null);
});

test("rejects malformed dates, times and counts", () => {
  assert.equal(
    parseCreateReservationPayload({
      ...validPayload,
      reservationDate: "2030-02-31",
    }),
    null
  );
  assert.equal(
    parseCreateReservationPayload({ ...validPayload, startTime: "25:00" }),
    null
  );
  assert.equal(
    parseCreateReservationPayload({ ...validPayload, shootersCount: 1.5 }),
    null
  );
});

test("maps RPC business codes to stable HTTP statuses", () => {
  assert.equal(getCreateReservationHttpStatus("created"), 200);
  assert.equal(getCreateReservationHttpStatus("already_created"), 200);
  assert.equal(getCreateReservationHttpStatus("unauthorized"), 401);
  assert.equal(getCreateReservationHttpStatus("not_allowed"), 403);
  assert.equal(getCreateReservationHttpStatus("slot_unavailable"), 409);
  assert.equal(getCreateReservationHttpStatus("lane_not_bookable"), 409);
  assert.equal(getCreateReservationHttpStatus("contact_required"), 422);
  assert.equal(getCreateReservationHttpStatus("profile_incomplete"), 422);
  assert.equal(getCreateReservationHttpStatus("invalid_duration"), 400);
  assert.equal(getCreateReservationHttpStatus("internal_error"), 500);
});

test("accepts every create_reservation_v2 business error code with its stable HTTP class", () => {
  const expectedStatuses = new Map([
    ["unauthorized", 401],
    ["not_allowed", 403],
    ["profile_rejected", 403],
    ["verification_limit_reached", 409],
    ["lane_blocked", 409],
    ["lane_not_bookable", 409],
    ["slot_unavailable", 409],
    ["idempotency_conflict", 409],
    ["profile_not_found", 422],
    ["profile_incomplete", 422],
    ["contact_required", 422],
    ["lane_inactive", 422],
    ["pricing_not_configured", 422],
    ["internal_error", 500],
  ]);

  const errorCodes = CREATE_RESERVATION_CODES.filter(
    (code) => code !== "created" && code !== "already_created"
  );

  assert.equal(errorCodes.length, 24);

  for (const code of errorCodes) {
    assert.equal(
      isCreateReservationRpcResult({ ok: false, changed: false, code }),
      true,
      `${code} should be accepted as a controlled V2 result`
    );
    assert.equal(
      getCreateReservationHttpStatus(code),
      expectedStatuses.get(code) ?? 400,
      `${code} should keep its HTTP mapping`
    );
    assert.equal(typeof CREATE_RESERVATION_MESSAGES[code], "string");
    assert.notEqual(CREATE_RESERVATION_MESSAGES[code].length, 0);
  }
});

test("allows the controlled V2 preparation codes without treating them as internal errors", () => {
  for (const code of ["contact_required", "lane_not_bookable"]) {
    assert.equal(CREATE_RESERVATION_CODES.includes(code), true);
    assert.equal(
      isCreateReservationRpcResult({ ok: false, changed: false, code }),
      true
    );
    assert.notEqual(getCreateReservationHttpStatus(code), 500);
    assert.notEqual(
      CREATE_RESERVATION_MESSAGES[code],
      CREATE_RESERVATION_MESSAGES.internal_error
    );
  }

  assert.equal(
    CREATE_RESERVATION_MESSAGES.contact_required,
    "Dla większej liczby osób wymagany jest kontakt z obsługą CSK."
  );
  assert.equal(
    CREATE_RESERVATION_MESSAGES.lane_not_bookable,
    "Ten zasób nie jest obecnie dostępny do rezerwacji online."
  );
});

test("unknown RPC codes remain fail-closed", () => {
  assert.equal(
    isCreateReservationRpcResult({
      ok: false,
      changed: false,
      code: "future_unknown_code",
    }),
    false
  );
});

test("validates successful RPC data", () => {
  const baseResult = {
    ok: true,
    changed: true,
    code: "created",
    reservation_id: "33333333-3333-4333-8333-333333333333",
    reservation_status: "confirmed",
    lane_name: "Oś 1",
    shooters_count: 2,
    duration_minutes: 90,
    pricing_day_group: "mon_thu",
    price_per_hour: 100,
    total_price: 150,
    currency_code: "PLN",
  };

  assert.equal(isCreateReservationRpcResult(baseResult), true);
  assert.equal(
    isCreateReservationRpcResult({
      ...baseResult,
      changed: false,
      code: "already_created",
    }),
    true
  );
  assert.equal(
    isCreateReservationRpcResult({
      ...baseResult,
      pricing_day_group: "holiday",
    }),
    false
  );
});

test("rejects malformed or contradictory RPC data", () => {
  assert.equal(isCreateReservationRpcResult({ ok: true, code: "created" }), false);
  assert.equal(
    isCreateReservationRpcResult({
      ok: true,
      changed: false,
      code: "slot_unavailable",
    }),
    false
  );
});

test("route calls only create_reservation_v2 with the caller JWT and exact parameters", async () => {
  const source = await readFile(
    new URL("../../app/api/create-reservation/route.ts", import.meta.url),
    "utf8"
  );

  assert.match(source, /Authorization: `Bearer \$\{accessToken\}`/);
  assert.match(source, /\.rpc\("create_reservation_v2"/);
  assert.doesNotMatch(source, /\.rpc\("create_reservation"\s*,/);
  assert.equal((source.match(/\.rpc\(/g) ?? []).length, 1);
  for (const parameter of [
    "p_lane_id",
    "p_reservation_date",
    "p_start_time",
    "p_duration_minutes",
    "p_shooters_count",
    "p_creation_request_id",
    "p_reservation_note",
  ]) {
    assert.equal(
      (source.match(new RegExp(`\\b${parameter}\\b`, "g")) ?? []).length,
      1,
      `${parameter} should be passed exactly once`
    );
  }
  assert.doesNotMatch(source, /p_day_group|p_pricing_day_group/);
  assert.doesNotMatch(source, /SUPABASE_SERVICE_ROLE_KEY|service_role/i);
});

test("route has no runtime fallback or retry to create_reservation v1", async () => {
  const source = await readFile(
    new URL("../../app/api/create-reservation/route.ts", import.meta.url),
    "utf8"
  );

  assert.equal((source.match(/create_reservation_v2/g) ?? []).length, 1);
  assert.equal((source.match(/\.rpc\(/g) ?? []).length, 1);
  assert.doesNotMatch(source, /create_reservation["']/);
  assert.doesNotMatch(source, /retry|fallback/i);
});

test("route logs only the database error code", async () => {
  const source = await readFile(
    new URL("../../app/api/create-reservation/route.ts", import.meta.url),
    "utf8"
  );

  assert.match(source, /code: error\.code/);
  assert.doesNotMatch(source, /error\.message|error\.details|error\.hint/);
});
