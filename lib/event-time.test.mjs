import assert from "node:assert/strict";
import test from "node:test";
import {
  isEventCancellationBeforeCutoff,
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
