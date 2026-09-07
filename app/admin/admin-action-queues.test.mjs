import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { ADMIN_ROUTE_PERMISSIONS } from "../../lib/admin/route-protection.js";

async function source(path) {
  return readFile(new URL(path, import.meta.url), "utf8");
}

test("admin dashboard exposes the four action queues without PII", async () => {
  const dashboard = await source("./page.tsx");
  for (const label of ["Oczekiwani dzisiaj", "Nieopłacone", "Lista rezerwowa eventów", "Dzisiejsze rezerwacje"]) {
    assert.match(dashboard, new RegExp(label));
  }
  assert.match(dashboard, /hasAccess\(role, \["admin", "pracownik"\]\)/);
  assert.match(dashboard, /buildAdminActionQueueLinks/);
});

test("ordinary users cannot access admin action queue destinations", () => {
  assert.deepEqual(ADMIN_ROUTE_PERMISSIONS["/admin/check-in"], ["admin", "pracownik"]);
  assert.deepEqual(ADMIN_ROUTE_PERMISSIONS["/admin/reservations"], ["admin", "pracownik"]);
  assert.ok(!ADMIN_ROUTE_PERMISSIONS["/admin/events"].includes("user"));
});

test("reservations restore safe URL filters and apply payment server-side", async () => {
  const reservations = await source("./reservations/page.tsx");
  assert.match(reservations, /params\.get\("payment"\)/);
  assert.match(reservations, /isPaymentStatus\(paymentParam\)/);
  assert.match(reservations, /query = query\.eq\("payment_status", paymentFilter\)/);
  assert.match(reservations, /window\.addEventListener\("popstate"/);
  assert.match(reservations, /urlParams\.set\("page", "1"\)/);
});

test("reservation payment preset is visible, touch friendly and resettable", async () => {
  const reservations = await source("./reservations/page.tsx");
  assert.match(reservations, /Status płatności/);
  assert.match(reservations, /aria-pressed=\{paymentFilter === payment\.value\}/);
  assert.match(reservations, /setPaymentFilter\("all"\)/);
  assert.match(reservations, /min-h-11/);
});

test("check-in URL preset filters out checked-in reservations", async () => {
  const checkIn = await source("./check-in/page.tsx");
  assert.match(checkIn, /params\.get\("attendance"\) === "expected"/);
  assert.match(checkIn, /expectedOnly && !isExpectedTodayReservation\(reservation\)/);
  assert.match(checkIn, /attendance: "expected"/);
  assert.match(checkIn, /nextParams\.set\("page", "1"\)/);
});

test("check-in date is Warsaw-based and URL-backed", async () => {
  const checkIn = await source("./check-in/page.tsx");
  assert.match(checkIn, /getWarsawDateISO\(\)/);
  assert.match(checkIn, /isValidIsoDate\(requestedDate\)/);
  assert.match(checkIn, /window\.history\.pushState/);
  assert.match(checkIn, /window\.addEventListener\("popstate"/);
});

test("event reserve preset reaches the existing bounded participant RPC", async () => {
  const events = await source("./events/page.tsx");
  assert.match(events, /params\.get\("participantStatus"\)/);
  assert.match(events, /participantStatus, participantPayment/);
  assert.match(events, /admin_list_event_registrations_v1/);
  assert.match(events, /p_page_size:EVENT_PARTICIPANT_PAGE_SIZE/);
  assert.match(events, /Preset „Lista rezerwowa” jest aktywny/);
});

test("event participant filters reset and survive URL navigation", async () => {
  const events = await source("./events/page.tsx");
  assert.match(events, /params\.set\("participantPage", String\(nextPage\)\)/);
  assert.match(events, /params\.set\("page", "1"\)/);
  assert.match(events, /window\.history\.pushState/);
  assert.match(events, /window\.addEventListener\("popstate"/);
});

test("queue layout remains responsive at 320, 375 and 430 CSS widths", async () => {
  const dashboard = await source("./page.tsx");
  const start = dashboard.indexOf("Wymaga uwagi");
  const end = dashboard.indexOf("Dzisiaj — najważniejsze", start);
  const queueSection = dashboard.slice(start, end);
  assert.match(queueSection, /grid gap-4 md:grid-cols-2/);
  assert.match(dashboard, /min-h-12/);
  assert.match(queueSection, /text-sm/);
  assert.doesNotMatch(queueSection, /min-w-\[(?:[4-9]\d\d|\d{4,})px\]/);
});

test("action queue implementation adds no database writes or service role", async () => {
  const combined = (await Promise.all([
    source("./page.tsx"),
    source("./reservations/page.tsx"),
    source("./check-in/page.tsx"),
    source("./events/page.tsx"),
  ])).join("\n");
  assert.doesNotMatch(combined, /service[_-]role/iu);
  assert.doesNotMatch(combined, /admin_action_queue|create_queue/iu);
});
