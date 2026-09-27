const GLOBAL_LOGIN_REDIRECTS: ReadonlySet<string> = new Set([
  "/", "/dashboard", "/account", "/platform-admin", "/booking", "/events", "/my-reservations", "/my-events",
  "/admin", "/admin/users", "/admin/check-in", "/admin/events",
  "/admin/reservations", "/admin/reports", "/admin/calendar",
  "/admin/lane-blocks", "/admin/lane-configuration",
]);

const TENANT_LOGIN_PATH = /^\/t\/[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\/(?:booking|events|my-reservations|my-events|admin(?:\/(?:users|check-in|events|reservations|reports|calendar|lane-blocks|lane-configuration))?)$/;
const RESERVE_CONFIRMATION_PATH = /^\/events\/confirm\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Public slug is a selector only; the destination still performs its own availability checks.
const PUBLIC_LANDING_PATH = /^\/[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
const AUTH_ENTRY_PATHS = new Set(["/login", "/register", "/forgot-password", "/reset-password", "/auth"]);

/** Same-origin path allowlist. Query strings, fragments and encoded path tricks fail closed. */
export function getSafeLoginRedirect(redirectTo: string | null) {
  return redirectTo &&
    !AUTH_ENTRY_PATHS.has(redirectTo) &&
    (GLOBAL_LOGIN_REDIRECTS.has(redirectTo) || TENANT_LOGIN_PATH.test(redirectTo) || RESERVE_CONFIRMATION_PATH.test(redirectTo) || PUBLIC_LANDING_PATH.test(redirectTo))
    ? redirectTo
    : "/";
}
