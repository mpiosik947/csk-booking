import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const surfaces = [
  ["Reservations", "./reservations/page.tsx"],
  ["Reports", "./reports/page.tsx"],
  ["Check-in", "./check-in/page.tsx"],
  ["Dashboard", "./page.tsx"],
];

async function source(file) {
  return readFile(new URL(file, import.meta.url), "utf8");
}

test("all operational admin surfaces request and resolve hierarchy metadata", async () => {
  for (const [name, file] of surfaces) {
    const content = await source(file);

    if (name === "Reports") {
      assert.match(content, /admin_get_reservation_report_v2/);
      assert.match(content, /reservation\.laneDisplayName/);
      assert.doesNotMatch(content, /\.from\("shooting_lanes"\)/);
      continue;
    }

    assert.match(content, /resource_kind/, `${name} resource_kind`);
    assert.match(content, /parent_lane_id/, `${name} parent_lane_id`);
    assert.match(content, /display_order/, `${name} display_order`);
    assert.match(content, /is_active/, `${name} is_active`);
    assert.match(
      content,
      /parent_lane:shooting_lanes!parent_lane_id/,
      `${name} explicit parent relation`
    );
    assert.match(content, /getLaneRelationDisplay/, `${name} shared resolver`);
    assert.match(content, /\.displayName/, `${name} full display name`);
  }
});

test("reservations keep exports, actions and cancellation RPC while using full labels", async () => {
  const [content, legacyTable] = await Promise.all([
    source("./reservations/page.tsx"),
    source("./AdminReservationsTable.tsx"),
  ]);

  assert.match(content, /getLaneName\(reservation\)/);
  assert.match(content, /cancel_reservation/);
  assert.match(content, /completeReservation/);
  assert.match(content, /markNoShow/);
  assert.match(content, /updateReservationPayment/);
  assert.match(content, /downloadReservationsCsv/);
  assert.doesNotMatch(content, /shooting_lanes\?\.name/);
  assert.match(legacyTable, /getLaneRelationDisplay/);
  assert.match(legacyTable, /getLaneName\(reservation\)/);
  assert.doesNotMatch(legacyTable, /shooting_lanes\?\.name/);
});

test("reports change only the grouping label and retain totals without extra rows", async () => {
  const content = await source("./reports/page.tsx");

  assert.match(content, /admin_get_reservation_report_v2/);
  assert.match(content, /summary\.activeReservationCount/);
  assert.match(content, /summary\.plannedRevenue/);
  assert.match(content, /summary\.topResource/);
  assert.match(content, /reservation\.laneDisplayName/);
  assert.doesNotMatch(content, /\.from\("reservations"\)/);
  assert.doesNotMatch(content, /flatMap|buildLaneHierarchyDisplayModel/);
});

test("check-in token lookup and controlled operational actions remain available", async () => {
  const content = await source("./check-in/page.tsx");

  assert.match(content, /"get_check_in_reservation_v1"/);
  assert.match(content, /p_token: checkInToken/);
  assert.doesNotMatch(content, /\.eq\("check_in_token", checkInToken\)/);
  assert.match(content, /updateReservationPayment/);
  assert.match(content, /update_reservation_attendance/);
  assert.match(content, /p_action: action/);
  assert.match(content, /cancel_reservation/);
  assert.doesNotMatch(content, /shooting_lanes\?\.\[0\]\?\.name/);
});

test("dashboard business datasets and calculations remain intact", async () => {
  const content = await source("./page.tsx");

  assert.match(content, /setTodayReservations/);
  assert.match(content, /setMonthReservations/);
  assert.match(content, /activeMonthReservations\.reduce/);
  assert.match(content, /const topLane = Object\.entries\(/);
  assert.match(content, /const laneName = getLaneName\(reservation\)/);
  assert.doesNotMatch(content, /flatMap|buildLaneHierarchyDisplayModel/);
});

test("operational hierarchy integration contains no production resource hardcodes", async () => {
  const contents = await Promise.all(surfaces.map(([, file]) => source(file)));
  const combined = contents.join("\n");

  assert.doesNotMatch(combined, /Oś 100 m|Stanowisko \d+/i);
  assert.doesNotMatch(
    combined,
    /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i
  );
});
