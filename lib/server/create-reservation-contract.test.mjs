import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
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
  assert.equal(getCreateReservationHttpStatus("profile_incomplete"), 422);
  assert.equal(getCreateReservationHttpStatus("invalid_duration"), 400);
  assert.equal(getCreateReservationHttpStatus("internal_error"), 500);
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

test("route uses the caller JWT and never the service role", async () => {
  const source = await readFile(
    new URL("../../app/api/create-reservation/route.ts", import.meta.url),
    "utf8"
  );

  assert.match(source, /Authorization: `Bearer \$\{accessToken\}`/);
  assert.match(source, /\.rpc\("create_reservation"/);
  assert.doesNotMatch(source, /p_day_group|p_pricing_day_group/);
  assert.doesNotMatch(source, /SUPABASE_SERVICE_ROLE_KEY|service_role/i);
});

test("route logs only the database error code", async () => {
  const source = await readFile(
    new URL("../../app/api/create-reservation/route.ts", import.meta.url),
    "utf8"
  );

  assert.match(source, /code: error\.code/);
  assert.doesNotMatch(source, /error\.message|error\.details|error\.hint/);
});
