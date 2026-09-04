import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  ADMIN_ROUTE_PERMISSIONS,
  canRoleAccessAdminRoute,
  getAdminRouteRoles,
  isAdminRoutePath,
} from "./route-protection.js";

const middlewarePath = new URL("../../middleware.ts", import.meta.url);
const calendarApiPath = new URL(
  "../../app/api/admin/calendar-feed/route.ts",
  import.meta.url,
);

const expectedRoutes = [
  "/admin/calendar",
  "/admin/check-in",
  "/admin/events",
  "/admin/lane-blocks",
  "/admin/lane-configuration",
  "/admin/reports",
  "/admin/reservations",
  "/admin/users",
];

test("SEC-011 recognizes only the /admin segment and its descendants", () => {
  assert.equal(isAdminRoutePath("/admin"), true);
  assert.equal(isAdminRoutePath("/admin/"), true);
  assert.equal(isAdminRoutePath("/admin/events"), true);
  assert.equal(isAdminRoutePath("/administrator"), false);
  assert.equal(isAdminRoutePath("/api/admin/calendar-feed"), false);
});

test("SEC-011 protects every current admin page with its exact role matrix", () => {
  assert.deepEqual(Object.keys(ADMIN_ROUTE_PERMISSIONS).sort(), expectedRoutes);

  for (const route of expectedRoutes) {
    assert.equal(canRoleAccessAdminRoute(route, "user"), false, route);
    assert.equal(canRoleAccessAdminRoute(route, ""), false, route);
  }

  assert.deepEqual(getAdminRouteRoles("/admin"), ["admin", "pracownik", "instruktor"]);
  assert.deepEqual(getAdminRouteRoles("/admin/users"), ["admin"]);
  assert.deepEqual(getAdminRouteRoles("/admin/reservations"), ["admin", "pracownik"]);
  assert.deepEqual(getAdminRouteRoles("/admin/calendar"), ["admin", "pracownik", "instruktor"]);
});

test("SEC-011 defaults every unknown future admin route to admin-only", () => {
  const futureRoute = "/admin/__future-test-route";

  assert.equal(canRoleAccessAdminRoute(futureRoute, "admin"), true);
  assert.equal(canRoleAccessAdminRoute(futureRoute, "pracownik"), false);
  assert.equal(canRoleAccessAdminRoute(futureRoute, "instruktor"), false);
  assert.equal(canRoleAccessAdminRoute(futureRoute, "user"), false);
  assert.equal(canRoleAccessAdminRoute(futureRoute, ""), false);
});

test("SEC-011 matches configured routes on segment boundaries", () => {
  assert.equal(canRoleAccessAdminRoute("/admin/events/archive", "instruktor"), true);
  assert.equal(canRoleAccessAdminRoute("/admin/events-extra", "instruktor"), false);
  assert.equal(canRoleAccessAdminRoute("/admin/users-extra", "pracownik"), false);
  assert.equal(canRoleAccessAdminRoute("/admin/users-extra", "admin"), true);
});

test("middleware applies authentication and trusted profile role before route access", async () => {
  const source = await readFile(middlewarePath, "utf8");
  const authIndex = source.indexOf("supabase.auth.getUser()");
  const profileIndex = source.indexOf('.from("profiles")');
  const accessIndex = source.indexOf("canRoleAccessAdminRoute(path, role)");

  assert.match(source, /matcher: \["\/admin\/:path\*"\]/);
  assert.match(source, /if \(userError \|\| !user\)/);
  assert.match(source, /profileError \|\|[\s\S]*?!profile\?\.role/);
  assert.match(source, /ADMIN_STAFF_ROLES\.includes\(role\)/);
  assert.ok(authIndex >= 0 && authIndex < profileIndex);
  assert.ok(profileIndex < accessIndex);
  assert.doesNotMatch(source, /localStorage|searchParams\.get\(["']role|request\.json\(\)/);
});

test("the /api/admin route keeps independent fail-closed server authorization", async () => {
  const source = await readFile(calendarApiPath, "utf8");
  const authIndex = source.indexOf("verifyAuthUser");
  const roleIndex = source.indexOf('supabase.rpc("get_my_role")');
  const dataIndex = source.indexOf('.from("shooting_lanes")');

  assert.match(source, /return jsonError\("unauthorized"[\s\S]*?401\)/);
  assert.match(source, /return jsonError\([\s\S]*?"auth_unavailable"[\s\S]*?503/);
  assert.match(source, /return jsonError\("forbidden"[\s\S]*?403\)/);
  assert.match(source, /parseCalendarFeedRole\(roleData\)/);
  assert.ok(authIndex >= 0 && authIndex < roleIndex);
  assert.ok(roleIndex < dataIndex);
  assert.doesNotMatch(source, /SUPABASE_SERVICE_ROLE_KEY|service_role/);
});
