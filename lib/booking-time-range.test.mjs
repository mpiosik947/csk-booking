import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  addMinutesToTime,
  bookingSlotIsAvailable,
  classifyBookingSlot,
  getBookingSlotVisualClass,
  getOccupiedSlotStarts,
  normalizeBookingTime,
  parseBookingBusyRanges,
  rangesOverlap,
} from "./booking-time-range.ts";

const hourlySlots = [
  "08:00", "09:00", "10:00", "11:00", "12:00", "13:00",
  "14:00", "15:00", "16:00", "17:00", "18:00", "19:00",
];

function stateAt(slotStart, durationMinutes, busyRanges = [], blockedRanges = []) {
  return classifyBookingSlot({
    slotStart,
    slotMinutes: 60,
    durationMinutes,
    openingStart: "08:00",
    openingEnd: "20:00",
    busyRanges,
    blockedRanges,
  });
}

for (const [hours, expected] of [
  [1, ["10:00"]],
  [2, ["10:00", "11:00"]],
  [3, ["10:00", "11:00", "12:00"]],
  [4, ["10:00", "11:00", "12:00", "13:00"]],
]) {
  test(`${hours}h highlights ${hours} hourly slot(s)`, () => {
    assert.deepEqual(getOccupiedSlotStarts("10:00", hours * 60, hourlySlots), expected);
  });
}

test("the exact end hour is not highlighted", () => {
  assert.equal(getOccupiedSlotStarts("10:00", 180, hourlySlots).includes("13:00"), false);
  assert.equal(addMinutesToTime("10:00", 180), "13:00");
});

test("time normalization treats HH:mm and HH:mm:ss as the same slot", () => {
  assert.equal(normalizeBookingTime("10:00"), "10:00");
  assert.equal(normalizeBookingTime("10:00:00"), "10:00");

  const selectedState = (slotStart) =>
    classifyBookingSlot({
      slotStart,
      slotMinutes: 60,
      durationMinutes: 180,
      openingStart: "08:00:00",
      openingEnd: "20:00:00",
      busyRanges: [],
      blockedRanges: [],
      selectedStart: "10:00:00",
    });

  assert.equal(selectedState("10:00"), "selected_start");
  assert.equal(selectedState("11:00:00"), "selected_range");
  assert.equal(selectedState("12:00"), "selected_range");
  assert.equal(selectedState("13:00:00"), "available");
});
test("slot classification marks the start and the remaining selected range", () => {
  const selectedState = (slotStart) =>
    classifyBookingSlot({
      slotStart,
      slotMinutes: 60,
      durationMinutes: 180,
      openingStart: "08:00",
      openingEnd: "20:00",
      busyRanges: [],
      blockedRanges: [],
      selectedStart: "10:00",
    });

  assert.equal(selectedState("10:00"), "selected_start");
  assert.equal(selectedState("11:00"), "selected_range");
  assert.equal(selectedState("12:00"), "selected_range");
  assert.equal(selectedState("13:00"), "available");
});

test("visual classes distinguish selected slots from available slots", () => {
  const selectedStartClass = getBookingSlotVisualClass("selected_start");
  const selectedRangeClass = getBookingSlotVisualClass("selected_range");
  const availableClass = getBookingSlotVisualClass("available");

  assert.notEqual(selectedStartClass, availableClass);
  assert.notEqual(selectedRangeClass, availableClass);
  assert.notEqual(selectedStartClass, selectedRangeClass);
  assert.match(selectedRangeClass, /(?:^|\s)bg-\[/);
  assert.match(selectedRangeClass, /(?:^|\s)border-\[/);
  assert.match(selectedRangeClass, /(?:^|\s)disabled:opacity-100(?:\s|$)/);
  assert.doesNotMatch(selectedRangeClass, /\$\{|bg-\$|border-\$/);
});
test("ranges touching at a boundary do not overlap", () => {
  assert.equal(rangesOverlap(
    { startTime: "10:00", endTime: "13:00" },
    { startTime: "13:00", endTime: "15:00" }
  ), false);
});

test("partial overlap is detected", () => {
  assert.equal(rangesOverlap(
    { startTime: "10:00", endTime: "13:00" },
    { startTime: "12:00", endTime: "14:00" }
  ), true);
});

test("full containment is detected", () => {
  assert.equal(rangesOverlap(
    { startTime: "10:00", endTime: "14:00" },
    { startTime: "11:00", endTime: "12:00" }
  ), true);
});

test("a candidate ending after opening hours is unavailable", () => {
  assert.equal(stateAt("19:00", 120), "outside_hours");
});

test("a candidate crossing a lane block is unavailable", () => {
  const block = [{ startTime: "12:00", endTime: "13:00" }];
  assert.equal(stateAt("10:00", 180, block, block), "insufficient_time");
  assert.equal(stateAt("12:00", 60, block, block), "blocked");
});

test("changing duration can invalidate an earlier start", () => {
  const busy = [{ startTime: "12:00", endTime: "13:00" }];
  assert.equal(bookingSlotIsAvailable(stateAt("10:00", 120, busy)), true);
  assert.equal(bookingSlotIsAvailable(stateAt("10:00", 180, busy)), false);
});

test("duration change clears a selected start when the new range crosses an event", async () => {
  const busy = [{ startTime: "11:00", endTime: "14:00" }];
  const selectedStart = "10:00";

  assert.equal(bookingSlotIsAvailable(stateAt(selectedStart, 60, busy)), true);
  assert.equal(bookingSlotIsAvailable(stateAt(selectedStart, 180, busy)), false);

  const source = await readFile(
    new URL("../app/booking/BookingForm.tsx", import.meta.url),
    "utf8"
  );

  assert.match(
    source,
    /getSlotState\(selectedHour,\s*nextDuration,\s*""\)/
  );
  assert.doesNotMatch(
    source,
    /getSlotState\(selectedHour,\s*nextDuration,\s*selectedHour\)/
  );
});

test("duration change preserves a selected start at busy range boundaries", () => {
  assert.equal(
    bookingSlotIsAvailable(
      stateAt("10:00", 180, [{ startTime: "13:00", endTime: "14:00" }])
    ),
    true
  );
  assert.equal(
    bookingSlotIsAvailable(
      stateAt("14:00", 180, [{ startTime: "11:00", endTime: "14:00" }])
    ),
    true
  );
  assert.equal(
    bookingSlotIsAvailable(
      stateAt("10:00", 120, [{ startTime: "12:00", endTime: "14:00" }])
    ),
    true
  );
});

test("10:00-13:00 blocks starts at 10:00, 11:00 and 12:00", () => {
  const busy = [{ startTime: "10:00", endTime: "13:00" }];
  assert.equal(stateAt("10:00", 60, busy), "occupied");
  assert.equal(stateAt("11:00", 60, busy), "occupied");
  assert.equal(stateAt("12:00", 60, busy), "occupied");
});

test("a start at the exact end boundary remains available", () => {
  const busy = [{ startTime: "10:00", endTime: "13:00" }];
  assert.equal(stateAt("13:00", 120, busy), "available");
});

test("booking form refreshes trusted availability after a server collision", async () => {
  const source = await readFile(
    new URL("../app/booking/BookingForm.tsx", import.meta.url),
    "utf8"
  );

  assert.match(source, /\.rpc\(\s*"get_lane_booking_busy_ranges_v3"/);
  assert.doesNotMatch(source, /get_lane_booking_busy_ranges_v2/);
  assert.doesNotMatch(source, /\.from\("lane_blocks"\)/);
  assert.match(
    source,
    /result\.code === "slot_unavailable" \|\|\s*result\.code === "lane_blocked"/
  );
  assert.match(source, /await loadAvailability\(laneId, reservationDate\)/);
  assert.match(
    source,
    /Ten przedział został właśnie zajęty\. Wybierz inną godzinę\./
  );
  assert.doesNotMatch(source, /\.from\("reservations"\)[\s\S]*?\.insert\(/);
  assert.doesNotMatch(source, /SUPABASE_SERVICE_ROLE_KEY|service_role/i);
});

test("lane_blocked invalidates the selected start and refreshes without retrying", async () => {
  const source = await readFile(
    new URL("../app/booking/BookingForm.tsx", import.meta.url),
    "utf8"
  );
  const conflictBranch = source.match(
    /if \(\s*result\.code === "slot_unavailable" \|\|\s*result\.code === "lane_blocked"\s*\) \{([\s\S]*?)\n\s*\}/
  )?.[1] ?? "";

  assert.match(conflictBranch, /setSelectedHour\(""\)/);
  assert.match(conflictBranch, /await loadAvailability\(laneId, reservationDate\)/);
  assert.match(conflictBranch, /CODE_MESSAGES\.lane_blocked/);
  assert.equal(
    (source.match(/fetch\("\/api\/create-reservation"/g) ?? []).length,
    1
  );
  assert.doesNotMatch(conflictBranch, /handleSubmit\(|fetch\("\/api\/create-reservation"/);
});

test("V2 preparation errors are controlled without retry or availability refresh", async () => {
  const source = await readFile(
    new URL("../app/booking/BookingForm.tsx", import.meta.url),
    "utf8"
  );
  const branchStart = source.indexOf(
    'if (\n          result.code === "contact_required" ||'
  );
  const branchEnd = source.indexOf(
    "\n        setMessage(\n          CODE_MESSAGES[result.code] ??",
    branchStart
  );

  assert.notEqual(branchStart, -1);
  assert.equal(branchEnd > branchStart, true);
  const controlledBranch = source.slice(branchStart, branchEnd);

  assert.match(
    source,
    /contact_required:\s*"Dla większej liczby osób wymagany jest kontakt z obsługą CSK\."/
  );
  assert.match(
    source,
    /lane_not_bookable:\s*"Ten zasób nie jest obecnie dostępny do rezerwacji online\."/
  );
  assert.match(
    controlledBranch,
    /if \(result\.code === "lane_not_bookable"\) \{\s*setSelectedHour\(""\)/
  );
  assert.match(controlledBranch, /setMessage\(CODE_MESSAGES\[result\.code\]\)/);
  assert.doesNotMatch(controlledBranch, /loadAvailability|handleSubmit|fetch\(/);
  assert.doesNotMatch(
    controlledBranch,
    /setLaneId|setReservationDate|setDurationMinutes|setShootersCount/
  );
  assert.equal((source.match(/fetch\("\/api\/create-reservation"/g) ?? []).length, 1);
  assert.doesNotMatch(source, /create_reservation_v2/);
});

test("reservation success and existing controlled results remain unchanged", async () => {
  const source = await readFile(
    new URL("../app/booking/BookingForm.tsx", import.meta.url),
    "utf8"
  );

  assert.match(source, /result\.code === "already_created"/);
  assert.match(source, /idempotency_conflict:/);
  assert.match(source, /setConfirmationData\(\{/);
  assert.match(source, /sendConfirmationEmail\(/);
});

test("typed busy ranges preserve occupied and blocked presentation", () => {
  const sourceRows = [
    { start_time: "09:00:00", end_time: "10:00:00", busy_type: "reservation" },
    { start_time: "10:00:00", end_time: "11:00:00", busy_type: "event" },
    { start_time: "11:00:00", end_time: "12:00:00", busy_type: "lane_block" },
  ];
  const snapshot = structuredClone(sourceRows);
  const { busyRanges, blockedRanges } = parseBookingBusyRanges(sourceRows);

  assert.equal(stateAt("09:00", 60, busyRanges, blockedRanges), "occupied");
  assert.equal(stateAt("10:00", 60, busyRanges, blockedRanges), "occupied");
  assert.equal(stateAt("11:00", 60, busyRanges, blockedRanges), "blocked");
  assert.deepEqual(sourceRows, snapshot);
});

test("lane blocks win presentation overlaps with events and reservations", () => {
  for (const competingType of ["event", "reservation"]) {
    const { busyRanges, blockedRanges } = parseBookingBusyRanges([
      { start_time: "10:00", end_time: "12:00", busy_type: "lane_block" },
      { start_time: "11:00", end_time: "14:00", busy_type: competingType },
    ]);
    assert.equal(stateAt("11:00", 60, busyRanges, blockedRanges), "blocked");
  }
});

test("typed busy ranges keep touching boundaries and 1-4 hour decisions", () => {
  const { busyRanges, blockedRanges } = parseBookingBusyRanges([
    { start_time: "12:00", end_time: "13:00", busy_type: "event" },
  ]);

  assert.equal(stateAt("09:00", 60, busyRanges, blockedRanges), "available");
  assert.equal(stateAt("10:00", 120, busyRanges, blockedRanges), "available");
  assert.equal(stateAt("10:00", 180, busyRanges, blockedRanges), "insufficient_time");
  assert.equal(stateAt("09:00", 240, busyRanges, blockedRanges), "insufficient_time");
  assert.equal(stateAt("13:00", 60, busyRanges, blockedRanges), "available");
});

test("unknown or malformed availability fails closed", () => {
  for (const malformed of [
    null,
    new Array(1),
    [{ start_time: "10:00:30", end_time: "11:00", busy_type: "event" }],
    [{ start_time: "10:00", end_time: "11:00" }],
    [{ start_time: "10:00", end_time: "11:00", busy_type: "unknown" }],
    [{ start_time: "invalid", end_time: "11:00", busy_type: "event" }],
    [{ start_time: "11:00", end_time: "10:00", busy_type: "reservation" }],
  ]) {
    assert.throws(() => parseBookingBusyRanges(malformed));
  }
});

test("both collision refresh paths use v3 without an automatic retry or v2 fallback", async () => {
  const source = await readFile(
    new URL("../app/booking/BookingForm.tsx", import.meta.url),
    "utf8"
  );
  const conflictBranch = source.match(
    /if \(\s*result\.code === "slot_unavailable" \|\|\s*result\.code === "lane_blocked"\s*\) \{([\s\S]*?)\n\s*\}/
  )?.[1] ?? "";

  assert.match(source, /"get_lane_booking_busy_ranges_v3"/);
  assert.doesNotMatch(source, /get_lane_booking_busy_ranges_v2/);
  assert.match(conflictBranch, /await loadAvailability\(laneId, reservationDate\)/);
  assert.equal((source.match(/fetch\("\/api\/create-reservation"/g) ?? []).length, 1);
  assert.doesNotMatch(conflictBranch, /handleSubmit\(|fetch\("\/api\/create-reservation"/);
});

test("availability v3 keeps stale-response protection and fails closed", async () => {
  const source = await readFile(
    new URL("../app/booking/BookingForm.tsx", import.meta.url),
    "utf8"
  );

  assert.match(source, /const requestNumber = \+\+availabilityRequestRef\.current/);
  assert.match(
    source,
    /if \(requestNumber !== availabilityRequestRef\.current\) \{\s*return false;\s*\}/
  );
  assert.match(source, /availabilityRequestRef\.current \+= 1/g);
  assert.match(
    source,
    /if \(busyResult\.error\) \{[\s\S]*?setAvailabilityReady\(false\)/
  );
  assert.match(
    source,
    /catch \{[\s\S]*?setAvailabilityReady\(false\)/
  );
  assert.doesNotMatch(source, /get_lane_booking_busy_ranges_v2/);
});
