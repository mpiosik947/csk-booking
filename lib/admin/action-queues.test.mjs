import assert from "node:assert/strict";
import test from "node:test";
import {
  ADMIN_QUEUE_TIME_ZONE,
  buildAdminActionQueueLinks,
  getWarsawDateISO,
  isExpectedTodayReservation,
  isUnpaidActionReservation,
  isValidIsoDate,
} from "./action-queues.js";

test("queue dates use Europe/Warsaw before UTC midnight", () => {
  assert.equal(ADMIN_QUEUE_TIME_ZONE, "Europe/Warsaw");
  assert.equal(getWarsawDateISO(new Date("2026-01-01T23:30:00Z")), "2026-01-02");
});

test("queue dates use Europe/Warsaw during summer time", () => {
  assert.equal(getWarsawDateISO(new Date("2026-07-01T22:30:00Z")), "2026-07-02");
});

test("expected-today link is explicit and resets page", () => {
  assert.equal(
    buildAdminActionQueueLinks(new Date("2026-09-06T10:00:00Z")).expectedToday,
    "/admin/check-in?date=2026-09-06&attendance=expected&page=1"
  );
});

test("unpaid link uses canonical confirmed and unpaid statuses", () => {
  assert.equal(
    buildAdminActionQueueLinks(new Date("2026-09-06T10:00:00Z")).unpaid,
    "/admin/reservations?date=2026-09-06&status=confirmed&payment=unpaid&page=1"
  );
});

test("event reserve link prepares the bounded participant filter", () => {
  assert.equal(
    buildAdminActionQueueLinks().eventReserve,
    "/admin/events?participantStatus=reserve&participantPage=1&page=1"
  );
});

test("today-reservations link has deterministic Warsaw date", () => {
  assert.equal(
    buildAdminActionQueueLinks(new Date("2026-09-06T10:00:00Z")).todayReservations,
    "/admin/reservations?date=2026-09-06&page=1"
  );
});

test("expected queue includes confirmed planned visits", () => {
  assert.equal(isExpectedTodayReservation({ reservation_status: "confirmed", attendance_status: "planned" }), true);
  assert.equal(isExpectedTodayReservation({ reservation_status: "confirmed", attendance_status: null }), true);
});

test("expected queue excludes checked-in and terminal visits", () => {
  assert.equal(isExpectedTodayReservation({ reservation_status: "confirmed", attendance_status: "present" }), false);
  assert.equal(isExpectedTodayReservation({ reservation_status: "cancelled", attendance_status: "planned" }), false);
  assert.equal(isExpectedTodayReservation({ reservation_status: "completed", attendance_status: "completed" }), false);
});

test("unpaid queue includes only confirmed unpaid reservations", () => {
  assert.equal(isUnpaidActionReservation({ reservation_status: "confirmed", payment_status: "unpaid" }), true);
});

test("unpaid queue excludes cancelled reservations", () => {
  assert.equal(isUnpaidActionReservation({ reservation_status: "cancelled", payment_status: "unpaid" }), false);
  assert.equal(isUnpaidActionReservation({ reservation_status: "cancelled_by_user", payment_status: "unpaid" }), false);
});

test("unpaid queue excludes non-actionable payment statuses", () => {
  assert.equal(isUnpaidActionReservation({ reservation_status: "confirmed", payment_status: "pay_on_site" }), false);
  assert.equal(isUnpaidActionReservation({ reservation_status: "confirmed", payment_status: "paid" }), false);
});

test("date validator fails safe for malformed and impossible dates", () => {
  assert.equal(isValidIsoDate("2026-09-06"), true);
  assert.equal(isValidIsoDate("2026-02-30"), false);
  assert.equal(isValidIsoDate("javascript:alert(1)"), false);
  assert.equal(isValidIsoDate(null), false);
});

test("queue URLs contain no PII or identifiers", () => {
  const urls = Object.values(buildAdminActionQueueLinks());
  for (const url of urls) {
    assert.doesNotMatch(url, /user_id|email|phone|token|customer/iu);
  }
});
