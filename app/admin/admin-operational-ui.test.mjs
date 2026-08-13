import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

async function source(file) {
  return readFile(new URL(file, import.meta.url), "utf8");
}

test("reservations keep filter, action and export semantics inside the shared admin shell", async () => {
  const content = await source("./reservations/page.tsx");

  assert.match(content, /<AdminShell/);
  assert.match(content, /aria-labelledby="reservation-filters-heading"/);
  assert.match(content, /aria-pressed=\{statusFilter === status\.value\}/);
  assert.match(content, /onClick=\{loadReservations\}/);
  assert.match(content, /onClick=\{resetFilters\}/);
  assert.match(content, /onClick=\{downloadReservationsCsv\}/);
  assert.match(content, /updateReservation\(reservation/);
  assert.match(content, /getLaneName\(reservation\)/);
});

test("reports retain calculations and use a local scroll region for the detailed table", async () => {
  const content = await source("./reports/page.tsx");

  assert.match(content, /<AdminShell/);
  assert.match(content, /const totalRevenue = activeReservations\.reduce/);
  assert.match(content, /const paidRevenue = paidReservations\.reduce/);
  assert.match(content, /const occupancy =/);
  assert.match(content, /const topLane = Object\.entries/);
  assert.match(content, /getLaneName\(reservation\)/);
  assert.match(content, /aria-label="Tabela rezerwacji w okresie"/);
  assert.match(content, /overflow-x-auto/);
  assert.doesNotMatch(content, /overflow-x-auto[^\n]*<main/);
});

test("check-in retains token lookup and operational actions with an explicit empty state", async () => {
  const content = await source("./check-in/page.tsx");

  assert.match(content, /<AdminShell/);
  assert.match(content, /aria-labelledby="check-in-filters-heading"/);
  assert.match(content, /\.eq\("check_in_token", checkInToken\)/);
  assert.match(content, /verifyAccountAndStartVisit\(reservation\)/);
  assert.match(content, /markCompleted\(reservation\)/);
  assert.match(content, /markNoShow\(reservation\)/);
  assert.match(content, /handleCancelReservation\(reservation\)/);
  assert.match(content, /getLaneName\(reservation\)/);
  assert.match(content, /Brak rezerwacji do obsługi dla wybranego dnia\./);
});

test("instructor is fail-closed for check-in navigation and customer dashboard reads", async () => {
  const [middleware, dashboard, checkIn] = await Promise.all([
    source("../../middleware.ts"),
    source("./page.tsx"),
    source("./check-in/page.tsx"),
  ]);

  assert.match(
    middleware,
    /"\/admin\/check-in": \[\s*"admin",\s*"pracownik",\s*\]/
  );
  const checkInPermissions = middleware.match(
    /"\/admin\/check-in": \[([\s\S]*?)\],/
  )?.[1];
  assert.ok(checkInPermissions);
  assert.doesNotMatch(checkInPermissions, /"instruktor"/);
  assert.match(
    dashboard,
    /title: "Check-in",[\s\S]*?roles: \["admin", "pracownik"\]/
  );
  assert.match(
    dashboard,
    /const canReadCustomerOperations = hasAccess\(currentRole, \[[\s\S]*?"admin",[\s\S]*?"pracownik"/
  );
  assert.match(
    dashboard,
    /canReadCustomerOperations[\s\S]*?\.from\("reservations"\)/
  );
  assert.match(
    dashboard,
    /canReadCustomerOperations[\s\S]*?\.from\("profiles"\)/
  );
  assert.match(
    dashboard,
    /hasAccess\(role, \["admin", "pracownik"\]\) && \([\s\S]*?Najbliższe rezerwacje/
  );
  assert.match(checkIn, /useRouter, useSearchParams/);
  assert.match(
    checkIn,
    /loadedRole !== "admin" && loadedRole !== "pracownik"/
  );
  assert.match(checkIn, /router\.replace\("\/admin"\)/);
  assert.match(
    checkIn,
    /if \(!\(await loadCurrentUser\(\)\)\) \{[\s\S]*?return;[\s\S]*?\}[\s\S]*?\.from\("reservations"\)/
  );
});

test("all three operational pages expose mobile-sized controls and visible focus states", async () => {
  const pages = await Promise.all([
    source("./reservations/page.tsx"),
    source("./reports/page.tsx"),
    source("./check-in/page.tsx"),
  ]);

  for (const content of pages) {
    assert.match(content, /min-h-11/);
    assert.match(content, /focus-visible:ring-2/);
    assert.match(content, /break-words|overflow-x-auto/);
  }
});

test("visual polish does not introduce backend or public-surface changes", async () => {
  const pages = await Promise.all([
    source("./reservations/page.tsx"),
    source("./reports/page.tsx"),
    source("./check-in/page.tsx"),
  ]);
  const combined = pages.join("\n");

  assert.doesNotMatch(combined, /from\("events"\)\.(?:insert|update|delete)/);
  assert.doesNotMatch(combined, /from\("lane_blocks"\)\.(?:insert|update|delete)/);
  assert.doesNotMatch(combined, /\/booking|\/my-reservations|\/check-in\/\[token\]/);
});
