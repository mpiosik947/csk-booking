import { PLATFORM_BASE_URL } from "./platform-domain";

const SECTIONS = new Set(["/", "/cennik", "/o-obiekcie", "/kontakt"]);
export function isCustomPublicPath(path: string) { return SECTIONS.has(path); }

/** Host selects public content only. Operational routes still authorize membership/resource in DB. */
export function customOperationalDestination(path: string, tenantSlug: string): string | null {
  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(tenantSlug)) return null;
  if (/^\/(?:booking|events|my-events|my-reservations)$/.test(path) ||
      /^\/admin(?:\/(?:users|check-in|events|reservations|reports|calendar|lane-blocks|lane-configuration|settings))?$/.test(path)) {
    return `${PLATFORM_BASE_URL}/t/${tenantSlug}${path}`;
  }
  if (/^\/(?:login|register|forgot-password|account|dashboard|platform-admin)$/.test(path)) {
    const url = new URL(path, PLATFORM_BASE_URL);
    if (path === "/login") url.searchParams.set("redirectTo", `/t/${tenantSlug}/booking`);
    return url.toString();
  }
  // Never accept another tenant's /t/<slug> supplied on a custom host.
  return null;
}
