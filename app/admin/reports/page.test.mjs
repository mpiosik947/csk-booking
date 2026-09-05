import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const source = readFileSync(new URL("./page.tsx", import.meta.url), "utf8");

test("Reports uses one bounded authoritative RPC instead of browser-side raw datasets", () => {
  assert.equal((source.match(/admin_get_reservation_report_v2/g) ?? []).length, 1);
  assert.match(source, /p_start_date: filters\.startDate/);
  assert.match(source, /p_end_date: filters\.endDate/);
  assert.match(source, /p_resource_id: filters\.resourceId/);
  assert.match(source, /p_reservation_status: filters\.reservationStatus/);
  assert.match(source, /p_payment_status: filters\.paymentStatus/);
  assert.match(source, /p_booking_type: filters\.bookingType/);
  assert.match(source, /p_detail_limit: REPORT_DETAIL_PAGE_SIZE/);
  assert.match(source, /p_detail_offset: detailOffset/);
  assert.doesNotMatch(source, /\.from\("reservations"\)/);
  assert.doesNotMatch(source, /\.from\("shooting_lanes"\)/);
  assert.doesNotMatch(source, /fetchCompleteReportDataset/);
});

test("filters are URL-restorable, reset pagination and fail closed", () => {
  assert.match(source, /parseReportFiltersFromSearchParams/);
  assert.match(source, /buildReportSearchParams/);
  assert.match(source, /window\.history\.pushState/);
  assert.match(source, /addEventListener\("popstate"/);
  assert.match(source, /setDetailOffset\(0\)/);
  assert.match(source, /Wyczyść filtry/);
  for (const id of [
    "report-from",
    "report-to",
    "report-resource",
    "report-status",
    "report-payment",
    "report-type",
  ]) {
    assert.match(source, new RegExp(`id="${id}"`));
  }
  assert.match(source, /reportFiltersEqual\(parsedReport\.filters, filters\)/);
});

test("CSV export uses the dedicated filtered PII-minimal contract", () => {
  assert.equal(
    (source.match(/admin_get_reservation_report_export_v1/g) ?? []).length,
    1,
  );
  assert.match(source, /buildAdminReservationCsv\(parsed\.export\.rows\)/);
  assert.match(source, /text\/csv;charset=utf-8/);
  assert.match(source, /Zawęź filtry do maksymalnie/);
  assert.match(source, /Eksportuj CSV/);
  assert.doesNotMatch(source, /service_role|SUPABASE_SERVICE_ROLE/);
});

test("Reports remains admin-only and protects against stale responses", () => {
  assert.match(source, /roleData !== "admin"/);
  assert.match(source, /const requestId = \+\+reportRequestRef\.current/);
  assert.ok((source.match(/requestId !== reportRequestRef\.current/g) ?? []).length >= 3);
});

test("malformed report data fails closed with a controlled message", () => {
  const controlledMessage = "Nie udało się pobrać kompletnego zestawu danych raportu\.";
  assert.match(source, /parseAdminReservationReport\(data\)/);
  assert.ok((source.match(new RegExp(controlledMessage, "g")) ?? []).length >= 2);
  assert.match(source, /setReportReady\(false\)/);
  assert.match(source, /!loading && hasAccess && reportReady && report && summary/);
  assert.doesNotMatch(source, /error\.message|error\.details|error\.hint/);
});

test("canonical financial and occupancy values come from the report contract", () => {
  assert.match(source, /summary\.activeReservationCount/);
  assert.match(source, /summary\.plannedRevenue/);
  assert.match(source, /summary\.paidRevenue/);
  assert.match(source, /summary\.outstandingRevenue/);
  assert.match(source, /summary\.cancelledReservationCount/);
  assert.match(source, /summary\.noShowReservationCount/);
  assert.match(source, /summary\.occupancyPercent/);
  assert.match(source, /summary\.topResource\?\.laneName/);
  assert.match(source, /efektywnych jednostek zasobu x 12h dziennie/);
  assert.doesNotMatch(source, /16h|16 \* 60/);
});

test("details are bounded and retain hierarchy labels and snapshot disclosure", () => {
  assert.match(source, /reservation\.laneDisplayName/);
  assert.match(source, /reservation\.customerName/);
  assert.match(source, /reservation\.customerEmail/);
  assert.match(source, /reservation\.customerPhone/);
  assert.match(source, /setDetailOffset\(0\)/);
  assert.match(source, /offset - REPORT_DETAIL_PAGE_SIZE/);
  assert.match(source, /offset \+ REPORT_DETAIL_PAGE_SIZE/);
  assert.match(source, /Historyczne obłożenie jest szacowane według aktualnej konfiguracji zasobów\./);
  assert.match(source, /dla stanowiska prefiks osi nadrzędnej jest aktualny\./);
});
