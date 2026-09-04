export type AdminRole = "admin" | "pracownik" | "instruktor" | "user";

export const ADMIN_STAFF_ROLES: readonly AdminRole[];
export const ADMIN_ROUTE_PERMISSIONS: Readonly<
  Record<string, readonly AdminRole[]>
>;

export function isAdminRoutePath(pathname: string): boolean;
export function getAdminRouteRoles(
  pathname: string,
): readonly AdminRole[] | null;
export function canRoleAccessAdminRoute(
  pathname: string,
  role: string,
): boolean;
