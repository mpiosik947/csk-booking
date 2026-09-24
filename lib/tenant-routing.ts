import { getAdminRouteRoles } from "./admin/route-protection.js";

export type TenantRoute =
  | Readonly<{ kind: "public" | "user"; path: string }>
  | Readonly<{
      kind: "staff";
      path: string;
      roles: readonly ("admin" | "employee" | "instructor")[];
      known: boolean;
    }>
  | Readonly<{ kind: "not_found" }>;

const PUBLIC_PATHS = new Set(["booking", "events"]);
const USER_PATHS = new Set(["my-reservations", "my-events"]);
const KNOWN_ADMIN_PATHS = new Set([
  "admin", "admin/check-in", "admin/users", "admin/reports",
  "admin/reservations", "admin/calendar", "admin/events",
  "admin/lane-blocks", "admin/lane-configuration",
  "admin/settings",
]);

const TO_TENANT_ROLE = {
  admin: "admin",
  pracownik: "employee",
  instruktor: "instructor",
} as const;

/** Pure path classification; it grants nothing without the server membership check. */
export function classifyTenantRoute(segments: readonly string[]): TenantRoute {
  if (segments.some((part) => !/^[a-z0-9-]+$/.test(part))) {
    return { kind: "not_found" };
  }
  const path = segments.join("/");
  if (PUBLIC_PATHS.has(path)) return { kind: "public", path };
  if (USER_PATHS.has(path)) return { kind: "user", path };
  if (segments[0] !== "admin") return { kind: "not_found" };

  const legacyPath = `/${path}`;
  const legacyRoles = getAdminRouteRoles(legacyPath);
  if (!legacyRoles) return { kind: "not_found" };
  const roles = legacyRoles
    .filter((role): role is keyof typeof TO_TENANT_ROLE => role in TO_TENANT_ROLE)
    .map((role) => TO_TENANT_ROLE[role]);
  return { kind: "staff", path, roles, known: KNOWN_ADMIN_PATHS.has(path) };
}

/** Only the legacy CSK path is offered, never an implicit selected-tenant fallback. */
export function legacyCskPath(slug: string, route: TenantRoute): string | null {
  return slug === "csk" && route.kind !== "not_found" &&
    (route.kind !== "staff" || route.known)
    ? `/${route.path}` : null;
}
