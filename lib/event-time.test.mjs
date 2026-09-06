import assert from "node:assert/strict";
import test from "node:test";
import {
  EVENT_CANCELLATION_CUTOFF_HOURS,
  RESERVATION_CANCELLATION_CUTOFF_HOURS,
  formatWarsawCancellationDeadline,
  getWarsawCancellationDeadline,
  isEventCancellationBeforeCutoff,
  isBeforeWarsawCancellationCutoff,
  getWarsawEventStartInstant,
  hasWarsawEventStarted,
} from "./event-time.ts";

test("Warsaw event start uses winter and summer offsets", () => {
  assert.equal(
    getWarsawEventStartInstant("2026-01-10", "12:00")?.toISOString(),
    "2026-01-10T11:00:00.000Z"
  );
  assert.equal(
    getWarsawEventStartInstant("2026-07-10", "12:00")?.toISOString(),
    "2026-07-10T10:00:00.000Z"
  );
});

test("cancellation is allowed before and exactly at the 72 hour cutoff", () => {
  assert.equal(
    isEventCancellationBeforeCutoff(
      "2026-07-10",
      "12:00",
      new Date("2026-07-07T09:59:59.999Z")
    ),
    true
  );
  assert.equal(
    isEventCancellationBeforeCutoff(
      "2026-07-10",
      "12:00",
      new Date("2026-07-07T10:00:00.000Z")
    ),
    true
  );
});

test("cancellation is denied after the cutoff", () => {
  assert.equal(
    isEventCancellationBeforeCutoff(
      "2026-07-10",
      "12:00",
      new Date("2026-07-07T10:00:00.001Z")
    ),
    false
  );
});

test("reservation cancellation uses the inclusive canonical 12-hour boundary", () => {
  const deadline = getWarsawCancellationDeadline(
    "2026-07-10",
    "12:00",
    RESERVATION_CANCELLATION_CUTOFF_HOURS
  );

  assert.equal(deadline?.toISOString(), "2026-07-09T22:00:00.000Z");
  assert.equal(
    isBeforeWarsawCancellationCutoff(
      "2026-07-10",
      "12:00",
      RESERVATION_CANCELLATION_CUTOFF_HOURS,
      new Date("2026-07-09T22:00:00.000Z")
    ),
    true
  );
  assert.equal(
    isBeforeWarsawCancellationCutoff(
      "2026-07-10",
      "12:00",
      RESERVATION_CANCELLATION_CUTOFF_HOURS,
      new Date("2026-07-09T22:00:00.001Z")
    ),
    false
  );
});

test("exact deadlines are formatted in Europe/Warsaw without a fixed UTC offset", () => {
  assert.equal(EVENT_CANCELLATION_CUTOFF_HOURS, 72);
  assert.equal(
    formatWarsawCancellationDeadline("2026-01-10", "12:00", 12),
    "10 stycznia 2026 00:00 (Europe/Warsaw)"
  );
  assert.equal(
    formatWarsawCancellationDeadline("2026-07-10", "12:00", 12),
    "10 lipca 2026 00:00 (Europe/Warsaw)"
  );
});

test("deadlines remain elapsed-time safe across both Warsaw DST transitions", () => {
  assert.equal(
    getWarsawCancellationDeadline("2026-03-30", "12:00", 12)?.toISOString(),
    "2026-03-29T22:00:00.000Z"
  );
  assert.equal(
    getWarsawCancellationDeadline("2026-10-26", "12:00", 12)?.toISOString(),
    "2026-10-25T23:00:00.000Z"
  );
});

test("public registration closes exactly at the Warsaw event start", () => {
  assert.equal(
    hasWarsawEventStarted(
      "2026-07-10",
      "12:00",
      new Date("2026-07-10T09:59:59.999Z")
    ),
    false
  );
  assert.equal(
    hasWarsawEventStarted(
      "2026-07-10",
      "12:00",
      new Date("2026-07-10T10:00:00.000Z")
    ),
    true
  );
});

test("invalid and nonexistent Warsaw wall times fail closed", () => {
  assert.equal(getWarsawEventStartInstant("2026-02-30", "10:00"), null);
  assert.equal(getWarsawEventStartInstant("2026-03-29", "02:30"), null);
  assert.equal(hasWarsawEventStarted("invalid", "10:00"), true);
});
