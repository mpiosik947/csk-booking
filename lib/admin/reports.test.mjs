import assert from "node:assert/strict";
import test from "node:test";
import {
  calculateHierarchyUtilization,
  countReportDaysInclusive,
  getReportDateRange,
  getWarsawToday,
  parseAdminReservationReport,
  REPORT_OPEN_MINUTES_PER_DAY,
} from "./reports.ts";

const uuid = (value) =>
  `00000000-0000-4000-8000-${String(value).padStart(12, "0")}`;

function lane(value, overrides = {}) {
  return {
    id: uuid(value),
    name: `Resource ${value}`,
    resource_kind: "lane",
    parent_lane_id: null,
    display_order: value,
    is_active: true,
    whole_lane_bookable: true,
    positions_bookable: false,
    lane_booking_rules: { online_bookable: true },
    ...overrides,
  };
}

function position(value, parent, active = true, overrides = {}) {
  return lane(value, {
    resource_kind: "position",
    parent_lane_id: parent.id,
    is_active: active,
    whole_lane_bookable: false,
    positions_bookable: false,
    lane_booking_rules: { online_bookable: active },
    ...overrides,
  });
}

function reservation(value, resource, duration = 60) {
  return {
    id: uuid(1000 + value),
    lane_id: resource.id,
    duration_minutes: duration,
  };
}

function validPayload(overrides = {}) {
  return {
    ok: true,
    code: "ok",
    contract_version: 1,
    range: {
      start_date: "2026-03-01",
      end_date: "2026-03-31",
      end_inclusive: true,
      days: 31,
      time_zone: "Europe/Warsaw",
      opening_start: "08:00",
      opening_end: "20:00",
      opening_minutes_per_day: 720,
    },
    summary: {
      active_reservation_count: 1,
      completed_reservation_count: 2,
      cancelled_reservation_count: 3,
      no_show_reservation_count: 4,
      planned_revenue: 100,
      paid_revenue: 60,
      outstanding_revenue: 40,
      effective_capacity: 5,
      occupied_minutes: 300,
      available_minutes: 111600,
      occupancy_percent: 0,
      best_day: { date: "2026-03-15", planned_revenue: 100 },
      top_resource: {
        lane_id: uuid(1),
        lane_name: "Oś historyczna",
        reservation_count: 3,
      },
    },
    details: [
      {
        id: uuid(101),
        lane_id: uuid(1),
        lane_name_snapshot: "Oś historyczna",
        lane_display_name: "Oś historyczna",
        resource_kind: "lane",
        parent_lane_id: null,
        customer_name: "Test",
        customer_email: "test@example.invalid",
        customer_phone: null,
        reservation_date: "2026-03-15",
        start_time: "10:00:00",
        end_time: "11:00:00",
        duration_minutes: 60,
        total_price: 100,
        reservation_status: "confirmed",
        payment_status: "paid",
      },
    ],
    pagination: { total: 1, limit: 50, offset: 0 },
    history: {
      name_basis: "reservation_snapshot",
      position_parent_name_basis: "current_configuration",
      capacity_basis: "current_configuration",
    },
    ...overrides,
  };
}

test("one report day is always one civil day", () => {
  assert.equal(countReportDaysInclusive("2026-09-05", "2026-09-05"), 1);
  assert.deepEqual(getReportDateRange("day", "2026-09-05"), {
    startDate: "2026-09-05",
    endDate: "2026-09-05",
    label: "2026-09-05",
    days: 1,
  });
});

test("spring DST month has 31 report days", () => {
  const range = getReportDateRange("month", "2026-03-29");
  assert.equal(range?.startDate, "2026-03-01");
  assert.equal(range?.endDate, "2026-03-31");
  assert.equal(range?.days, 31);
});

test("autumn DST month has 31 report days", () => {
  const range = getReportDateRange("month", "2026-10-25");
  assert.equal(range?.startDate, "2026-10-01");
  assert.equal(range?.endDate, "2026-10-31");
  assert.equal(range?.days, 31);
});

test("month and year boundaries use UTC calendar arithmetic", () => {
  assert.deepEqual(getReportDateRange("week", "2026-12-31"), {
    startDate: "2026-12-28",
    endDate: "2027-01-03",
    label: "2026-12-28 - 2027-01-03",
    days: 7,
  });
  assert.equal(getReportDateRange("year", "2028-06-01")?.days, 366);
  assert.equal(countReportDaysInclusive("2026-12-31", "2027-01-01"), 2);
});

test("Warsaw today is independent from the UTC calendar date", () => {
  assert.equal(getWarsawToday(new Date("2026-01-01T23:30:00Z")), "2026-01-02");
  assert.equal(getWarsawToday(new Date("2026-07-01T22:30:00Z")), "2026-07-02");
});

test("invalid and reversed dates fail closed", () => {
  assert.equal(getReportDateRange("day", "2026-02-30"), null);
  assert.equal(countReportDaysInclusive("2026-09-06", "2026-09-05"), null);
});

test("default utilization uses 08:00-20:00 instead of sixteen hours", () => {
  const resource = lane(1);
  const result = calculateHierarchyUtilization(
    [resource],
    [reservation(1, resource, 720)],
    1,
  );
  assert.equal(REPORT_OPEN_MINUTES_PER_DAY, 720);
  assert.equal(result.ok && result.availableResourceMinutes, 720);
  assert.equal(result.ok && result.utilizationPercent, 100);
});

test("whole-lane-only family remains one capacity unit", () => {
  const parent = lane(1);
  const result = calculateHierarchyUtilization(
    [parent],
    [reservation(1, parent)],
    1,
  );
  assert.equal(result.ok && result.effectiveCapacity, 1);
  assert.equal(result.ok && result.occupiedResourceMinutes, 60);
});

test("positions-only family uses active children as capacity", () => {
  const parent = lane(1, {
    whole_lane_bookable: false,
    positions_bookable: true,
  });
  const positions = Array.from({ length: 5 }, (_, index) =>
    position(index + 2, parent),
  );
  const result = calculateHierarchyUtilization(
    [parent, ...positions],
    [reservation(1, positions[0])],
    1,
  );
  assert.equal(result.ok && result.effectiveCapacity, 5);
  assert.equal(result.ok && result.occupiedResourceMinutes, 60);
});

test("whole plus positions is N rather than N+1 and weights the root once per unit", () => {
  const parent = lane(1, { positions_bookable: true });
  const positions = Array.from({ length: 5 }, (_, index) =>
    position(index + 2, parent),
  );
  const result = calculateHierarchyUtilization(
    [parent, ...positions],
    [reservation(1, parent), reservation(2, positions[0])],
    1,
  );
  assert.equal(result.ok && result.effectiveCapacity, 5);
  assert.equal(result.ok && result.occupiedResourceMinutes, 360);
});

test("inactive and offline positions do not increase current capacity", () => {
  const parent = lane(1, { positions_bookable: true });
  const online = position(2, parent);
  const inactive = position(3, parent, false);
  const offline = position(4, parent, true, {
    lane_booking_rules: { online_bookable: false },
  });
  const result = calculateHierarchyUtilization(
    [parent, online, inactive, offline],
    [reservation(1, online)],
    1,
  );
  assert.equal(result.ok && result.effectiveCapacity, 1);
  assert.equal(result.ok && result.occupiedResourceMinutes, 60);
});

test("mixed families remain data-driven without production hardcodes", () => {
  const standalone = lane(1);
  const parent = lane(2, { positions_bookable: true });
  const children = [position(3, parent), position(4, parent), position(5, parent)];
  const result = calculateHierarchyUtilization(
    [standalone, parent, ...children],
    [reservation(1, standalone), reservation(2, parent), reservation(3, children[0])],
    1,
  );
  assert.equal(result.ok && result.effectiveCapacity, 4);
  assert.equal(result.ok && result.occupiedResourceMinutes, 300);
});

test("valid aggregate response is parsed and normalizes time values", () => {
  const parsed = parseAdminReservationReport(validPayload());
  assert.equal(parsed?.range.days, 31);
  assert.equal(parsed?.details[0].startTime, "10:00");
  assert.equal(parsed?.details[0].totalPrice, 100);
  assert.equal(parsed?.history.nameBasis, "reservation_snapshot");
});

test("malformed opening hours, date counts and pagination fail closed", () => {
  const badOpening = validPayload({
    range: { ...validPayload().range, opening_minutes_per_day: 960 },
  });
  const badDays = validPayload({
    range: { ...validPayload().range, days: 30 },
  });
  const badPage = validPayload({ pagination: { total: 0, limit: 50, offset: 0 } });
  assert.equal(parseAdminReservationReport(badOpening), null);
  assert.equal(parseAdminReservationReport(badDays), null);
  assert.equal(parseAdminReservationReport(badPage), null);
});

test("unexpected detail PII or internal fields are not mapped into the client model", () => {
  const payload = validPayload();
  payload.details[0].check_in_token = "secret";
  payload.details[0].admin_note = "internal";
  const parsed = parseAdminReservationReport(payload);
  assert.ok(parsed);
  assert.equal("checkInToken" in parsed.details[0], false);
  assert.equal("adminNote" in parsed.details[0], false);
});

test("90-day and one-year aggregate contracts stay bounded to one detail page", () => {
  const ninety = validPayload({
    range: {
      ...validPayload().range,
      start_date: "2026-01-01",
      end_date: "2026-03-31",
      days: 90,
    },
    pagination: { total: 50000, limit: 50, offset: 0 },
  });
  const year = validPayload({
    range: {
      ...validPayload().range,
      start_date: "2028-01-01",
      end_date: "2028-12-31",
      days: 366,
    },
    pagination: { total: 50000, limit: 50, offset: 0 },
  });
  assert.equal(parseAdminReservationReport(ninety)?.details.length, 1);
  assert.equal(parseAdminReservationReport(year)?.details.length, 1);
});
