import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const pagePath = new URL("./page.tsx", import.meta.url);
const dashboardPath = new URL("../page.tsx", import.meta.url);
const middlewarePath = new URL("../../../middleware.ts", import.meta.url);
const helperPath = new URL("../../../lib/admin/lane-configuration.ts", import.meta.url);

async function sources() {
  return Promise.all([
    readFile(pagePath, "utf8"),
    readFile(dashboardPath, "utf8"),
    readFile(middlewarePath, "utf8"),
    readFile(helperPath, "utf8"),
  ]);
}

test("lane configuration uses only the admin v1 snapshot RPC", async () => {
  const [page] = await sources();

  assert.match(page, /rpc\(\s*"admin_get_lane_booking_configuration_v1"/);
  assert.doesNotMatch(page, /get_public_booking_configuration_v1/);
  for (const table of [
    "shooting_lanes",
    "lane_booking_rules",
    "lane_booking_durations",
    "lane_pricing_rules",
  ]) {
    assert.doesNotMatch(page, new RegExp(`\\.from\\("${table}"\\)`));
  }
});

test("route and dashboard tile are admin-only", async () => {
  const [page, dashboard, middleware] = await sources();

  assert.match(middleware, /"\/admin\/lane-configuration": \["admin"\]/);
  assert.doesNotMatch(
    middleware,
    /"\/admin\/lane-configuration": \["admin",\s*"pracownik"/
  );
  assert.match(page, /roleData !== "admin"/);
  assert.ok(page.indexOf('rpc("get_my_role")') < page.indexOf('"admin_get_lane_booking_configuration_v1"'));
  assert.match(
    dashboard,
    /title: "Konfiguracja osi",[\s\S]*?href: "\/admin\/lane-configuration",[\s\S]*?roles: \["admin"\],[\s\S]*?hiddenWhenDenied: true/
  );
  assert.match(dashboard, /!tile\.hiddenWhenDenied \|\| hasAccess\(role, tile\.roles\)/);
});

test("contract validation is fail-closed before snapshot rendering", async () => {
  const [page, , , helper] = await sources();

  assert.match(page, /parseAdminLaneConfigurationSnapshot\(data\)/);
  assert.match(page, /setSnapshot\(null\)/);
  assert.match(page, /Nie udało się bezpiecznie odczytać konfiguracji osi\./);
  assert.match(helper, /value\.contract_version !== ADMIN_LANE_CONFIGURATION_CONTRACT_VERSION/);
  assert.match(helper, /!Array\.isArray\(value\.resources\)/);
  assert.match(helper, /throw new Error\("duplicate_resource"\)/);
  assert.match(helper, /throw new Error\("invalid_hierarchy"\)/);
});

test("hierarchy and dormant resources remain visible with neutral diagnostics", async () => {
  const [page] = await sources();

  assert.match(page, /family\.children\.map/);
  assert.match(page, /Nieaktywna/);
  assert.match(page, /Offline/);
  assert.match(page, /Nie skonfigurowano sprzedaży/);
  assert.match(page, /Brak skonfigurowanych czasów rezerwacji\./);
  assert.match(page, /Brak skonfigurowanego cennika\./);
  assert.doesNotMatch(page, /Oś 100 m|254ca7f6-ce80-4267-8966-4558cc8f8fd2/);
});

test("read-only cards distinguish limits and whole-versus-position modes", async () => {
  const [page] = await sources();

  assert.match(page, /Limit fizyczny/);
  assert.match(page, /Limit online/);
  assert.match(page, /Rezerwacja całej osi/);
  assert.match(page, /Rezerwacja stanowisk/);
  assert.match(page, /booking_step_minutes/);
  assert.match(page, /currency_code/);
  assert.match(page, /activeChildren/);
  assert.match(page, /family\.children\.length/);
});

test("details dialog presents own durations, pricing groups and inactive history", async () => {
  const [page] = await sources();

  assert.match(page, /role="dialog"/);
  assert.match(page, /aria-modal="true"/);
  assert.match(page, /Status zasobu/);
  assert.match(page, /Dostępne czasy/);
  assert.match(page, /Cennik/);
  assert.match(page, /Pon–Czw/);
  assert.match(page, /Pt–Nd/);
  assert.match(page, /Nieaktywne czasy/);
  assert.match(page, /Nieaktywne reguły/);
  assert.match(page, /Oś nadrzędna/);
  assert.match(page, /resource\.durations\.filter/);
  assert.match(page, /resource\.pricing\.filter/);
});

test("panel has controlled states, refresh, search and accessible modal behavior", async () => {
  const [page] = await sources();

  assert.match(page, /Tylko odczyt/);
  assert.match(page, /Wczytywanie konfiguracji osi/);
  assert.match(page, /Brak skonfigurowanych osi i stanowisk\./);
  assert.match(page, /Brak zasobów pasujących do wyszukiwania\./);
  assert.match(page, /Szukaj po nazwie osi lub stanowiska/);
  assert.match(page, /Odśwież/);
  assert.match(page, /event\.key === "Escape"/);
  assert.match(page, /event\.key !== "Tab"/);
  assert.match(page, /detailsTriggerRef\.current\?\.focus/);
  assert.match(page, /min-h-11/);
  assert.match(page, /sm:max-w-3xl/);
});

test("runtime contains no configuration write path", async () => {
  const [page] = await sources();

  assert.doesNotMatch(page, /admin_set_lane_booking_configuration/);
  assert.doesNotMatch(page, /\.(?:insert|update|delete|upsert)\s*\(/);
  assert.doesNotMatch(page, /Zapisz|Aktywuj|Dezaktywuj/);
  assert.doesNotMatch(page, /\/booking|\/admin\/calendar|\/admin\/events|\/admin\/lane-blocks/);
});
