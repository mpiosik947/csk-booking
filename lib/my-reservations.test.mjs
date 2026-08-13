import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  getMyReservationLaneDisplayName,
  loadAllMyReservations,
} from "./my-reservations.ts";

const IDS = [
  "10000000-0000-4000-8000-000000000001",
  "10000000-0000-4000-8000-000000000002",
  "10000000-0000-4000-8000-000000000003",
];

function reservation(id, laneDisplayName = "Trap") {
  return {
    id,
    reservation_date: "2026-08-13",
    start_time: "10:00:00",
    end_time: "11:00:00",
    price: 100,
    reservation_status: "confirmed",
    payment_status: "pending",
    check_in_token: "20000000-0000-4000-8000-000000000001",
    attendance_status: null,
    checked_in_at: null,
    lane_display_name: laneDisplayName,
  };
}

test("loads multiple RPC ranges and confirms an exact full-page boundary", async () => {
  const ranges = [];
  const pages = [
    [reservation(IDS[0]), reservation(IDS[1], "Oś 100 m")],
    [reservation(IDS[2], "Oś 100 m — Stanowisko 2")],
  ];

  const result = await loadAllMyReservations(async (from, to) => {
    ranges.push([from, to]);
    return { data: pages.shift() ?? [], error: null };
  }, 2);

  assert.equal(result.ok, true);
  assert.deepEqual(ranges, [[0, 1], [2, 3]]);
  assert.deepEqual(result.ok ? result.value.map(({ id }) => id) : [], IDS);
});

test("an exact final page triggers one empty range before completion", async () => {
  const ranges = [];
  const pages = [[reservation(IDS[0])], []];
  const result = await loadAllMyReservations(async (from, to) => {
    ranges.push([from, to]);
    return { data: pages.shift() ?? [], error: null };
  }, 1);

  assert.equal(result.ok, true);
  assert.deepEqual(ranges, [[0, 0], [1, 1]]);
});

test("a later page failure returns no partial history", async () => {
  let calls = 0;
  const result = await loadAllMyReservations(async () => {
    calls += 1;
    return calls === 1
      ? { data: [reservation(IDS[0])], error: null }
      : { data: null, error: { message: "private database detail" } };
  }, 1);

  assert.deepEqual(result, { ok: false, code: "page_error" });
  assert.equal("value" in result, false);
});

test("duplicate reservation ids fail closed across pages", async () => {
  const pages = [[reservation(IDS[0])], [reservation(IDS[0])]];
  const result = await loadAllMyReservations(async () => ({
    data: pages.shift() ?? [],
    error: null,
  }), 1);

  assert.deepEqual(result, { ok: false, code: "duplicate_id" });
});

test("RPC hierarchy labels cover standalone, parent, inactive child, and null", () => {
  assert.equal(getMyReservationLaneDisplayName(reservation(IDS[0], "Trap")), "Trap");
  assert.equal(
    getMyReservationLaneDisplayName(reservation(IDS[0], "Oś 100 m")),
    "Oś 100 m"
  );
  assert.equal(
    getMyReservationLaneDisplayName(
      reservation(IDS[0], "Oś 100 m — Stanowisko historyczne")
    ),
    "Oś 100 m — Stanowisko historyczne"
  );
  assert.equal(
    getMyReservationLaneDisplayName(reservation(IDS[0], null)),
    "Nieznana oś"
  );
});

test("my reservations uses only the ownership RPC for its main read", async () => {
  const source = await readFile(
    new URL("../app/my-reservations/page.tsx", import.meta.url),
    "utf8"
  );

  assert.match(source, /\.rpc\("get_my_reservations_v2"\)\s*\.range\(from, to\)/);
  assert.doesNotMatch(source, /\.from\("reservations"\)/);
  assert.doesNotMatch(source, /shooting_lanes/);
  assert.doesNotMatch(source, /Błąd pobierania rezerwacji/);
  assert.match(source, /Nie udało się pobrać pełnej historii rezerwacji/);
});

test("cancellation and check-in token flows remain in place", async () => {
  const source = await readFile(
    new URL("../app/my-reservations/page.tsx", import.meta.url),
    "utf8"
  );

  assert.match(source, /\.rpc\("cancel_reservation"/);
  assert.match(source, /reservation\.check_in_token/);
  assert.match(source, /<QRCode/);
  assert.match(source, /finally\s*\{[\s\S]*cancellationInProgressRef\.current = false/);
});
