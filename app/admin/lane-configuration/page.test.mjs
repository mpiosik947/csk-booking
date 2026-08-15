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
  assert.equal(
    [...runtime.matchAll(/admin_set_lane_booking_family_configuration_v2/g)].length,
    1
  );
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
  assert.match(helper, /durations_minutes: edited\.durationsMinutes/);
  assert.match(helper, /pricing: edited\.pricing/);
  assert.match(helper, /\.filter\(\(duration\) => duration\.is_active\)/);
  assert.match(helper, /\.filter\(\(rule\) => rule\.is_active\)/);
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

test("root activation stays read-only while position activation is controlled locally", async () => {
  const [, editor, , , helper] = await sources();

  assert.match(editor, /Status: \{family\.root\.is_active \? "Aktywna" : "Nieaktywna"\} — tylko odczyt/);
  assert.match(editor, /function PositionActivationControls/);
  assert.match(editor, /label="Aktywne"/);
  assert.match(editor, /label="Rezerwacje online"/);
  assert.match(editor, /getLanePositionReadiness/);
  assert.match(editor, /Gotowe do uruchomienia/);
  assert.match(editor, /Wymaga konfiguracji/);
  assert.match(editor, /updatePositionActivation/);
  assert.match(editor, /is_active: false, online_bookable: false/);
  assert.match(helper, /is_active: isRoot \? resource\.is_active : edited\.isActive/);
  assert.match(editor, /Czasy rezerwacji/);
  assert.match(editor, /\+ Dodaj czas/);
  assert.match(editor, /Cennik/);
  assert.match(editor, /\+ Dodaj próg Pon–Czw/);
  assert.match(editor, /\+ Dodaj próg Pt–Nd/);
  assert.match(editor, /Usuń próg/);
  assert.doesNotMatch(editor, /family\.root\.is_active[^\n]*onChange/);
});

test("pricing UI uses the existing hourly model, day groups and read-only currency", async () => {
  const [, editor, , , helper] = await sources();

  assert.match(editor, /rule\.day_group === "mon_thu"/);
  assert.match(editor, /rule\.day_group === "fri_sun"/);
  assert.match(editor, /Pon–Czw/);
  assert.match(editor, /Pt–Nd/);
  assert.match(editor, /Liczba osób — od/);
  assert.match(editor, /Liczba osób — do/);
  assert.match(editor, /Opis \/ nazwa progu/);
  assert.match(editor, /\{resource\.currency_code\}\/h/);
  assert.match(editor, /Waluta: \{resource\.currency_code\} — tylko odczyt/);
  assert.match(editor, /Edytuj zakres i opis/);
  assert.match(editor, /<details/);
  assert.match(editor, /Number\(first\.min_shooters\)/);
  assert.match(editor, /Number\(first\.max_shooters\)/);
  assert.match(helper, /hourly_price: hourlyPrice/);
  assert.doesNotMatch(editor, /valid_from|valid_to|discount|promotion/);
});

test("duration and pricing editors are mobile-safe, labelled and keyboard accessible", async () => {
  const [, editor] = await sources();

  assert.match(editor, /md:grid-cols-\[minmax\(7rem,0\.8fr\)_minmax\(0,1fr\)_minmax\(0,1fr\)\]/);
  assert.match(editor, /overflow-x-hidden/);
  assert.match(editor, /min-w-0/);
  assert.match(editor, /aria-label=\{`Usuń czas/);
  assert.match(editor, /aria-label=\{`Usuń próg/);
  assert.match(editor, /htmlFor=\{`new-duration-/);
  assert.match(editor, /inputMode="decimal"/);
  assert.match(editor, /min-h-11/);
  assert.match(editor, /focus-visible:ring-2/);
});

test("inactive history is diagnostic only and position flags come from local family state", async () => {
  const [, editor, , , helper] = await sources();

  assert.match(editor, /Historyczne nieaktywne czasy pozostają zachowane/);
  assert.match(editor, /Historyczne nieaktywne progi pozostają zachowane/);
  assert.match(helper, /\.filter\(\(duration\) => duration\.is_active\)/);
  assert.match(helper, /\.filter\(\(rule\) => rule\.is_active\)/);
  assert.match(helper, /is_active: isRoot \? resource\.is_active : edited\.isActive/);
  assert.match(helper, /online_bookable: isRoot[\s\S]*edited\.onlineBookable/);
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

  assert.match(editor, /positions\.map/);
  assert.match(editor, /edit\?\.is_active \? "Aktywne" : "Nieaktywne"/);
  assert.match(editor, /edit\?\.online_bookable \? "Online" : "Offline"/);
  assert.match(editor, /!state\.root_positions_bookable &&[\s\S]*!hasUsableOnlinePosition/);
  assert.match(
    helper,
    /Najpierw skonfiguruj co najmniej jedno stanowisko do rezerwacji online\./
  );
});

test("families with positions use root and positions tabs while standalone lanes skip them", async () => {
  const [, editor] = await sources();

  assert.match(editor, /family\.children\.length > 0 && \(/);
  assert.match(editor, /role="tablist"/);
  assert.match(editor, /role="tab"/);
  assert.match(editor, /aria-selected=\{activeTab === "root"\}/);
  assert.match(editor, /aria-selected=\{activeTab === "positions"\}/);
  assert.match(editor, />\s*Oś główna\s*<\/button>/);
  assert.match(editor, />\s*Stanowiska\s*<\/button>/);
  assert.match(editor, /activeTab === "root" \|\| family\.children\.length === 0/);
});

test("positions tab shows a distinct parent summary and local bulk activation confirmation", async () => {
  const [, editor, , , helper] = await sources();
  const bulkHandler = editor.slice(
    editor.indexOf("function applyBulkPositionActivation"),
    editor.indexOf("async function submit")
  );

  assert.match(editor, /function ParentPositionsSummary/);
  assert.match(editor, /Status osi/);
  assert.match(editor, /Rezerwacja całej osi/);
  assert.match(editor, /Rezerwacja stanowisk/);
  assert.match(editor, /Liczba stanowisk/);
  assert.match(editor, /Gotowe do uruchomienia/);
  assert.match(editor, /Aktywne stanowiska/);
  assert.match(editor, /Stanowiska online/);
  assert.match(
    editor,
    /Status osi i dostępność rezerwacji stanowisk są niezależnymi stanami\./
  );
  assert.match(editor, /Uruchom wszystkie gotowe stanowiska/);
  assert.match(editor, /Przygotuj uruchomienie/);
  assert.match(editor, /Potwierdź lokalne przygotowanie/);
  assert.match(editor, /„Rezerwacja stanowisk” zostanie włączona\./);
  assert.match(editor, /„Rezerwacja całej osi” pozostanie bez zmian/);
  assert.match(editor, /Pominięte stanowiska/);
  assert.match(bulkHandler, /prepareLanePositionBulkActivation/);
  assert.match(bulkHandler, /setState\(result\.state\)/);
  assert.doesNotMatch(bulkHandler, /onWrite|admin_set_lane_booking_family_configuration_v2/);
  assert.match(helper, /getLaneFamilyPositionSummary/);
  assert.match(helper, /getLanePositionBulkActivationPlan/);
  assert.match(helper, /root_positions_bookable: true/);
  assert.match(helper, /is_active: true, online_bookable: true/);
});

test("positions are configured one at a time and returning to the list preserves family edit state", async () => {
  const [, editor] = await sources();

  assert.match(editor, /const \[state, setState\] = useState/);
  assert.match(editor, /const \[selectedPositionId, setSelectedPositionId\]/);
  assert.match(editor, /selectedPosition \? \(/);
  assert.match(editor, /<PositionList[\s\S]*positions=\{family\.children\}/);
  assert.match(editor, /← Wróć do stanowisk/);
  assert.match(editor, /setSelectedPositionId\(null\)/);
  assert.doesNotMatch(editor, /returnToPositions[\s\S]{0,200}createLaneFamilyEditState/);
});

test("position copy is explicit, local-only and does not invoke the family writer", async () => {
  const [, editor, , , helper] = await sources();
  const copyHandler = editor.slice(
    editor.indexOf("function applyPositionCopy"),
    editor.indexOf("async function submit")
  );
  const copyHelper = helper.slice(
    helper.indexOf("export function copyLanePositionEditSettings"),
    helper.indexOf("function parsePositiveInteger")
  );

  assert.match(editor, /Skopiuj ustawienia do innych stanowisk/);
  assert.match(editor, />Kopiowane<\/dt>[\s\S]*Limity, czasy i cennik/);
  assert.match(editor, /Zaznacz wszystkie pozostałe/);
  assert.match(editor, /selectedTargetIds/);
  assert.match(copyHandler, /copyLanePositionEditSettings/);
  assert.match(copyHandler, /setState/);
  assert.doesNotMatch(copyHandler, /onWrite/);
  assert.doesNotMatch(copyHelper, /is_active: source\.is_active/);
  assert.doesNotMatch(copyHelper, /online_bookable: source\.online_bookable/);
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
