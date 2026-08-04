import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  addMinutesToTime,
  bookingSlotIsAvailable,
  classifyBookingSlot,
  getOccupiedSlotStarts,
  normalizeBookingTime,
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

  assert.match(source, /\.rpc\(\s*"get_lane_booking_busy_ranges"/);
  assert.match(source, /\.from\("lane_blocks"\)/);
  assert.match(source, /result\.code === "slot_unavailable"/);
  assert.match(source, /await loadAvailability\(laneId, reservationDate\)/);
  assert.match(
    source,
    /Ten przedział został właśnie zajęty\. Wybierz inną godzinę\./
  );
  assert.doesNotMatch(source, /\.from\("reservations"\)[\s\S]*?\.insert\(/);
  assert.doesNotMatch(source, /SUPABASE_SERVICE_ROLE_KEY|service_role/i);
});
