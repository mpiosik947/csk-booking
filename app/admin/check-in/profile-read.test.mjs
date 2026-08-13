import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const pagePath = new URL("./page.tsx", import.meta.url);

test("check-in reads profiles only through reservation-scoped RPC", async () => {
  const source = await readFile(pagePath, "utf8");
  const start = source.indexOf("async function loadProfilesForReservations");
  const end = source.indexOf("async function loadReservations", start);
  const loader = start >= 0 && end > start ? source.slice(start, end) : "";

  assert.ok(loader);
  assert.match(loader, /get_reservation_customer_profiles_v1/);
  assert.match(loader, /p_reservation_ids:\s*reservationIds\.slice/);
  assert.doesNotMatch(loader, /\.from\("profiles"\)/);
  assert.doesNotMatch(loader, /admin_note|weapon_permit|range_officer_number|instructor_number/);
});
