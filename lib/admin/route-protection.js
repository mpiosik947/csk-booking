export const ADMIN_STAFF_ROLES = Object.freeze([
  "admin",
  "pracownik",
  "instruktor",
]);

export const ADMIN_ROUTE_PERMISSIONS = Object.freeze({
  "/admin/lane-configuration": Object.freeze(["admin"]),
  "/admin/users": Object.freeze(["admin"]),
  "/admin/reports": Object.freeze(["admin"]),
  "/admin/reservations": Object.freeze(["admin", "pracownik"]),
  "/admin/lane-blocks": Object.freeze(["admin", "pracownik"]),
  "/admin/calendar": Object.freeze(["admin", "pracownik", "instruktor"]),
  "/admin/check-in": Object.freeze(["admin", "pracownik"]),
  "/admin/events": Object.freeze(["admin", "pracownik", "instruktor"]),
});

const ROOT_ADMIN_ROLES = ADMIN_STAFF_ROLES;
const UNKNOWN_ADMIN_ROUTE_ROLES = Object.freeze(["admin"]);

export function isAdminRoutePath(pathname) {
  return pathname === "/admin" || pathname === "/admin/" || pathname.startsWith("/admin/");
}

function matchesRouteSegment(pathname, route) {
  return pathname === route || pathname.startsWith(`${route}/`);
}

export function getAdminRouteRoles(pathname) {
  if (!isAdminRoutePath(pathname)) return null;
  if (pathname === "/admin" || pathname === "/admin/") return ROOT_ADMIN_ROLES;

  const matchingRoute = Object.keys(ADMIN_ROUTE_PERMISSIONS)
    .sort((left, right) => right.length - left.length)
    .find((route) => matchesRouteSegment(pathname, route));

  return matchingRoute
    ? ADMIN_ROUTE_PERMISSIONS[matchingRoute]
    : UNKNOWN_ADMIN_ROUTE_ROLES;
}

export function canRoleAccessAdminRoute(pathname, role) {
  const allowedRoles = getAdminRouteRoles(pathname);
  return allowedRoles !== null && allowedRoles.includes(role);
}
