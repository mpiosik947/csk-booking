import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { getBookingDayGroup } from "./booking-day-group.ts";

test("maps fixed calendar dates to booking tariff groups", () => {
  assert.equal(getBookingDayGroup("2030-07-22"), "mon_thu");
  assert.equal(getBookingDayGroup("2030-07-25"), "mon_thu");
  assert.equal(getBookingDayGroup("2030-07-26"), "fri_sun");
  assert.equal(getBookingDayGroup("2030-07-28"), "fri_sun");
});

test("rejects malformed or impossible calendar dates", () => {
  assert.equal(getBookingDayGroup(""), null);
  assert.equal(getBookingDayGroup("2030-02-30"), null);
  assert.equal(getBookingDayGroup("2030-7-22"), null);
});

test("booking UI uses day-group pricing without sending it to the endpoint", async () => {
  const formSource = await readFile(
    new URL("../app/booking/BookingForm.tsx", import.meta.url),
    "utf8"
  );
  const pageSource = await readFile(
    new URL("../app/booking/page.tsx", import.meta.url),
    "utf8"
  );
  const requestBlock = formSource.match(
    /fetch\("\/api\/create-reservation"[\s\S]*?const result:/
  )?.[0];

  assert.ok(requestBlock);
  assert.doesNotMatch(requestBlock, /dayGroup|day_group/);
  assert.match(pageSource, /lane_id,day_group,min_shooters/);
  assert.match(formSource, /Taryfa \{BOOKING_DAY_GROUP_LABELS/);
  assert.match(
    formSource,
    /Grupy powyżej 5 osób prosimy o kontakt z obsługą\./
  );
  assert.match(
    formSource,
    /Grupy powyżej 6 osób prosimy o kontakt z obsługą\./
  );
  assert.match(
    formSource,
    /Cena obejmuje wyłączną rezerwację osi\. Rzutki i amunicja rozliczane są oddzielnie na miejscu\./
  );
  assert.doesNotMatch(formSource, /Promatic/i);
});
