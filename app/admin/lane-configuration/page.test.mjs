import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const pagePath = new URL("./page.tsx", import.meta.url);
const editorPath = new URL("./_components/LaneConfigurationEditor.tsx", import.meta.url);
const dashboardPath = new URL("../page.tsx", import.meta.url);
const middlewarePath = new URL("../../../middleware.ts", import.meta.url);
const helperPath = new URL("../../../lib/admin/lane-configuration.ts", import.meta.url);

async function sources() {
  return Promise.all([
    readFile(pagePath, "utf8"),
    readFile(editorPath, "utf8"),
    readFile(dashboardPath, "utf8"),
    readFile(middlewarePath, "utf8"),
    readFile(helperPath, "utf8"),
  ]);
}

test("runtime uses only the admin V2 read contract", async () => {
  const [page, editor, , , helper] = await sources();
  const runtime = `${page}\n${editor}`;

  assert.match(page, /rpc\(\s*"admin_get_lane_booking_configuration_v2"/);
  assert.doesNotMatch(runtime, /admin_get_lane_booking_configuration_v1/);
  assert.match(helper, /ADMIN_LANE_CONFIGURATION_CONTRACT_VERSION = 2/);
  assert.match(helper, /value\.contract_version !== ADMIN_LANE_CONFIGURATION_CONTRACT_VERSION/);
  assert.match(helper, /!Array\.isArray\(value\.families\)/);
  assert.match(helper, /duplicate_family/);
  assert.match(helper, /duplicate_resource/);
  assert.match(helper, /invalid_hierarchy/);
});

test("route, dashboard tile and runtime role check remain admin-only", async () => {
  const [page, , dashboard, middleware] = await sources();

  assert.match(middleware, /"\/admin\/lane-configuration": \["admin"\]/);
  assert.doesNotMatch(
    middleware,
    /"\/admin\/lane-configuration": \["admin",\s*"pracownik"/
  );
  assert.match(page, /roleData !== "admin"/);
  assert.ok(
    page.indexOf('rpc("get_my_role")') <
      page.indexOf('"admin_get_lane_booking_configuration_v2"')
  );
  assert.match(
    dashboard,
    /title: "Konfiguracja osi",[\s\S]*?href: "\/admin\/lane-configuration",[\s\S]*?roles: \["admin"\],[\s\S]*?hiddenWhenDenied: true/
  );
});

test("the family V2 RPC is the only configuration write path", async () => {
  const [page, editor] = await sources();
  const runtime = `${page}\n${editor}`;

  assert.match(page, /rpc\(\s*"admin_set_lane_booking_family_configuration_v2"/);
  assert.doesNotMatch(runtime, /admin_set_lane_booking_configuration\s*["'(]/);
  assert.doesNotMatch(runtime, /\.(?:insert|update|delete|upsert)\s*\(/);
  for (const table of [
    "shooting_lanes",
    "lane_booking_rules",
    "lane_booking_durations",
    "lane_pricing_rules",
  ]) {
    assert.doesNotMatch(runtime, new RegExp(`\\.from\\("${table}"\\)`));
  }
});

test("write adapter sends a complete family with the snapshot version", async () => {
  const [page, editor, , , helper] = await sources();

  assert.match(helper, /family\.resources[\s\S]*durations_minutes/);
  assert.match(helper, /resource\.durations[\s\S]*\.filter\(\(duration\) => duration\.is_active\)/);
  assert.match(helper, /resource\.pricing[\s\S]*\.filter\(\(rule\) => rule\.is_active\)/);
  assert.match(editor, /expectedVersion: family\.configuration_version/);
  assert.match(page, /p_expected_version: expectedVersion/);
  assert.match(page, /p_resources: payload/);
});

test("save is explicit, dirty-aware and presents only before/after changes", async () => {
  const [, editor, , , helper] = await sources();

  assert.match(editor, /Zapisz zmiany/);
  assert.match(editor, /disabled=\{!dirty \|\| !validation\.valid \|\| saving\}/);
  assert.match(editor, /setStep\("review"\)/);
  assert.match(editor, /Podsumowanie zmian/);
  assert.match(editor, /getLaneFamilyChanges/);
  assert.match(helper, /if \(before !== after\)/);
  assert.match(helper, /edited\.maxShooters !== resource\.max_shooters/);
  assert.doesNotMatch(editor, /autoSave|autosave/);
});

test("confirmation is two-step and reuses one frozen payload and version", async () => {
  const [, editor] = await sources();

  assert.match(editor, /pendingWrite\.expectedVersion/);
  assert.match(editor, /pendingWrite\.payload/);
  assert.match(editor, /submit\(false\)/);
  assert.match(editor, /submit\(true\)/);
  assert.match(editor, /result\.code === "confirmation_required"/);
  assert.match(editor, /Ta zmiana wpłynie na istniejące przyszłe zobowiązania\./);
  assert.match(editor, /futureReservationsCount/);
  assert.match(editor, /futureLaneBlocksCount/);
  assert.match(editor, /futureEventsCount/);
  assert.match(editor, /Potwierdzam zmianę/);
  assert.doesNotMatch(editor, /retry/i);
});

test("stale and capacity results are fail-closed and never auto-overwrite", async () => {
  const [, editor] = await sources();

  assert.match(editor, /result\.code === "stale_configuration"/);
  assert.match(
    editor,
    /Konfiguracja została w międzyczasie zmieniona\. Odśwież dane przed ponowną edycją\./
  );
  assert.match(editor, /reservation_capacity_conflict/);
  assert.match(
    editor,
    /Nie można obniżyć pojemności, ponieważ istnieje przyszła rezerwacja/
  );
  assert.doesNotMatch(editor, /current_version[\s\S]*onWrite/);
});

test("all ten backend result codes and unknown responses have controlled handling", async () => {
  const [, editor, , , helper] = await sources();
  const codes = [
    "updated",
    "no_change",
    "not_allowed",
    "family_not_found",
    "invalid_payload",
    "invalid_hierarchy",
    "invalid_configuration",
    "stale_configuration",
    "confirmation_required",
    "reservation_capacity_conflict",
  ];
  for (const code of codes) {
    assert.match(`${editor}\n${helper}`, new RegExp(code));
  }
  assert.match(helper, /throw new Error\("unknown_write_code"\)/);
  assert.match(editor, /Nie udało się bezpiecznie zapisać konfiguracji\./);
  assert.doesNotMatch(editor, /error\.message/);
});

test("active state, position online state, durations and pricing stay read-only", async () => {
  const [, editor] = await sources();

  assert.match(editor, /Status: \{family\.root\.is_active \? "Aktywna" : "Nieaktywna"\} — tylko odczyt/);
  assert.match(editor, /Status i dostępność online stanowisk są w tym etapie tylko do odczytu\./);
  assert.match(editor, /Czasy i cennik — tylko odczyt/);
  assert.doesNotMatch(editor, /Aktywuj|Dezaktywuj/);
  assert.doesNotMatch(editor, /child\.online_bookable[^\n]*onChange/);
  assert.doesNotMatch(editor, /duration_minutes[^\n]*onChange/);
  assert.doesNotMatch(editor, /hourly_price[^\n]*onChange/);
});

test("uses business-friendly capacity and reservation labels without changing field mapping", async () => {
  const [page, editor, , , helper] = await sources();

  assert.match(page, /Pojemność osi/);
  assert.match(page, /Pojemność stanowiska/);
  assert.match(editor, /Pojemność stanowiska/);
  assert.match(editor, /Maks\. osób w jednej rezerwacji/);
  assert.match(
    editor,
    /Maksymalna liczba osób, które mogą jednocześnie korzystać z tej osi\./
  );
  assert.match(
    editor,
    /Maksymalna liczba osób, które mogą jednocześnie korzystać z tego stanowiska\./
  );
  assert.match(
    editor,
    /Największa liczba osób, którą klient może wskazać w jednej nowej rezerwacji/
  );
  assert.match(helper, /max_shooters/);
  assert.match(helper, /max_people_online/);
});

test("incomplete dormant children remain visible and block invalid positions mode", async () => {
  const [, editor, , , helper] = await sources();

  assert.match(editor, /family\.children\.map/);
  assert.match(editor, /child\.is_active \? "Aktywne" : "Nieaktywne"/);
  assert.match(editor, /child\.online_bookable \? "Online" : "Offline"/);
  assert.match(
    helper,
    /Najpierw skonfiguruj co najmniej jedno stanowisko do rezerwacji online\./
  );
});

test("success closes edit mode and refreshes from V2 instead of trusting local state", async () => {
  const [page, editor] = await sources();

  assert.match(editor, /result\.code === "updated"/);
  assert.match(editor, /await onCompleted\("Konfiguracja została zapisana\."\)/);
  assert.match(page, /setSelectedFamilyId\(null\)[\s\S]*await loadConfiguration\(\)/);
  assert.doesNotMatch(page, /setSnapshot\([^)]*payload/);
});

test("dirty refresh and close require confirmation", async () => {
  const [page, editor] = await sources();

  assert.match(page, /editorDirty[\s\S]*window\.confirm\("Masz niezapisane zmiany/);
  assert.match(editor, /dirtyRef\.current &&[\s\S]*window\.confirm\([\s\S]*Masz niezapisane zmiany/);
  assert.match(editor, /event\.key === "Escape"/);
  assert.match(editor, /event\.target === event\.currentTarget/);
});

test("editor dialog is accessible and mobile-safe", async () => {
  const [, editor] = await sources();

  assert.match(editor, /role="dialog"/);
  assert.match(editor, /aria-modal="true"/);
  assert.match(editor, /aria-labelledby="lane-configuration-editor-title"/);
  assert.match(editor, /event\.key !== "Tab"/);
  assert.match(editor, /first\.focus\(\)/);
  assert.match(editor, /last\.focus\(\)/);
  assert.match(editor, /min-h-11/);
  assert.match(editor, /w-full overflow-y-auto overflow-x-hidden/);
  assert.match(editor, /grid gap-4 sm:grid-cols-2/);
});

test("runtime contains no production-name, UUID or fixed-position-count conditions", async () => {
  const [page, editor, , , helper] = await sources();
  const runtime = `${page}\n${editor}\n${helper}`;

  assert.doesNotMatch(runtime, /Oś 100 m/);
  assert.doesNotMatch(runtime, /254ca7f6-ce80-4267-8966-4558cc8f8fd2/);
  assert.doesNotMatch(runtime, /children\.length\s*===\s*5/);
});
