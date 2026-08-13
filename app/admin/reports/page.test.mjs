import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const source = readFileSync(new URL("./page.tsx", import.meta.url), "utf8");

test("Reports loads exact counts and paginates both source datasets", () => {
  assert.equal((source.match(/count: "exact", head: true/g) ?? []).length, 2);
  assert.equal(
    (source.match(/fetchCompleteReportDataset</g) ?? []).length,
    2,
  );
  assert.match(source, /\.order\("display_order", \{ ascending: true \}\)/);
  assert.match(source, /\.order\("reservation_date", \{ ascending: true \}\)/);
  assert.match(source, /\.order\("start_time", \{ ascending: true \}\)/);
  assert.ok((source.match(/\.order\("id", \{ ascending: true \}\)/g) ?? []).length >= 2);
  assert.equal((source.match(/\.range\(from, to\)/g) ?? []).length, 2);
  assert.match(source, /const requestId = \+\+reportRequestRef\.current/);
  assert.ok(
    (source.match(/requestId !== reportRequestRef\.current/g) ?? []).length >=
      6,
  );
});

test("Reports reads hierarchy and online-bookability configuration", () => {
  assert.match(source, /resource_kind,parent_lane_id/);
  assert.match(source, /whole_lane_bookable,positions_bookable/);
  assert.match(source, /lane_booking_rules\(online_bookable\)/);
  assert.match(source, /calculateHierarchyUtilization/);
});

test("incomplete or invalid data fails closed without rendering partial KPI", () => {
  const controlledMessage =
    "Nie udało się pobrać kompletnego zestawu danych raportu.";

  assert.ok((source.match(new RegExp(controlledMessage, "g")) ?? []).length >= 5);
  assert.match(source, /setReportReady\(false\)/);
  assert.match(
    source,
    /!loading && hasAccess && reportReady && utilization\.ok/,
  );
  assert.doesNotMatch(source, /lanesCountError\.message|countError\.message/);
});

test("existing financial and most-used-lane semantics remain in place", () => {
  assert.match(source, /!isCancelledReservationStatus/);
  assert.match(source, /reservation_status !== RESERVATION_STATUS\.NO_SHOW/);
  assert.match(source, /const paidReservations = activeReservations\.filter/);
  assert.match(source, /const totalRevenue = activeReservations\.reduce/);
  assert.match(source, /const paidRevenue = paidReservations\.reduce/);
  assert.match(source, /const unpaidRevenue = activeReservations/);
  assert.match(source, /const cancelledReservations = reservations\.filter/);
  assert.match(source, /const noShowReservations = reservations\.filter/);
  assert.match(source, /const laneName = getLaneName\(reservation\)/);
  assert.match(source, /getLaneRelationDisplay/);
});
