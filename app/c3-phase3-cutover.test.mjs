import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("C3 retires all 18 bridge/owner call sites and eight get_my_role calls", async () => {
  const files = [
    "./admin/events/page.tsx", "./admin/lane-configuration/page.tsx",
    "./admin/reports/page.tsx", "./admin/users/page.tsx",
    "./booking/page.tsx", "./booking/BookingForm.tsx", "./events/page.tsx",
    "./my-reservations/page.tsx", "./my-events/page.tsx",
    "./api/calendar/reservations/[id]/route.ts", "./page.tsx",
    "./admin/page.tsx", "./admin/calendar/page.tsx",
    "./api/admin/calendar-feed/route.ts",
  ];
  const sources = await Promise.all(files.map(read));
  const forbidden = [
    "get_my_role", "admin_list_events_v1", "admin_create_event_v2",
    "admin_get_lane_booking_configuration_v2", "admin_create_lane_booking_family_v1",
    "admin_get_reservation_report_v2", "admin_get_reservation_report_export_v1",
    "admin_list_users_v1", "admin_set_user_role_v1", "admin_set_user_note_v1",
    "update_profile_verification", "update_profile_identity", "update_profile_contact_details",
    "get_public_booking_configuration_v1", "get_my_active_tenant_verification_v1",
    "get_public_event_list_v2", "get_my_reservations_v2", "get_my_event_registrations_v1",
  ];
  for (const [index, source] of sources.entries()) {
    for (const name of forbidden) {
      assert.equal(source.includes(`"${name}"`), false, `${files[index]} retains ${name}`);
    }
  }
});

test("all five tenant-admin destinations are real modules, never placeholders", async () => {
  const shell = await read("./t/[slug]/[...path]/page.tsx");
  for (const route of ["admin", "admin/reservations", "admin/calendar", "admin/check-in", "admin/lane-blocks"]) {
    assert.match(shell, new RegExp(`route\\.path === "${route}"`));
  }
  assert.doesNotMatch(shell, /Otwórz obecny widok CSK|legacyCskPath/);
  assert.match(shell, /getStaffRouteContext\(slug, route\.roles\)/);
});

test("legacy admin aliases use explicit CSK resolver and membership, never global role", async () => {
  const middleware = await read("../middleware.ts");
  assert.match(middleware, /LEGACY_CSK_SLUG = "csk"/);
  assert.match(middleware, /resolve_active_tenant_by_slug_v1/);
  assert.match(middleware, /get_my_tenant_role_v1/);
  assert.match(middleware, /Object\.hasOwn\(ADMIN_ROUTE_PERMISSIONS, path\)/);
  assert.doesNotMatch(middleware, /\.from\("profiles"\)|get_my_role/);
});

test("calendar feed and cancellation email authorize from resolved resource tenant", async () => {
  const calendar = await read("./api/admin/calendar-feed/route.ts");
  const email = await read("./api/send-reservation-cancellation/route.ts");
  assert.match(calendar, /resolvePublicTenantContext\(supabase, requestedSlug\)/);
  assert.match(calendar, /get_my_tenant_role_v1/);
  assert.equal((calendar.match(/\.eq\("tenant_id", tenant\.value\.tenantId\)/g) ?? []).length, 4);
  assert.match(email, /p_tenant_id: reservation\.tenant_id/);
  assert.doesNotMatch(email, /\.select\("user_id, role"\)/);
});
