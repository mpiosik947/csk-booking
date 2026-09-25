/** Deployment configuration, never derived from caller-controlled headers. */
export const PLATFORM_BASE_URL = "https://strzelajtu.pl";
export const PLATFORM_HOST = "strzelajtu.pl";
export const OLD_PLATFORM_HOST = "csk-booking-5nwh.vercel.app";
export const LEGACY_AUTH_HOSTS: readonly string[] = ["krutla.pl", "www.krutla.pl", OLD_PLATFORM_HOST];
export function isLegacyAuthHost(host: string) { return LEGACY_AUTH_HOSTS.includes(host); }

export function normalizeHostname(raw: unknown): string | null {
  if (typeof raw !== "string" || raw.length > 253 || raw !== raw.trim()) return null;
  const value = raw.toLowerCase();
  if (!value.includes(".") || /^\d+(?:\.\d+){3}$/.test(value)) return null;
  if (!value.split(".").every(label => label.length <= 63 &&
      /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(label) && !label.startsWith("xn--"))) return null;
  return value;
}

/** Only fixed platform origin and validated internal paths; no credentials/fragments. */
export function platformUrl(path: string): string {
  if (!path.startsWith("/") || path.startsWith("//") || /[\\\r\n]/.test(path)) throw new Error("Invalid internal path");
  const url = new URL(path, PLATFORM_BASE_URL);
  if (url.origin !== PLATFORM_BASE_URL) throw new Error("Invalid origin");
  return url.toString();
}

export function hostFromRequest(raw: string | null, allowLocal: boolean): string | null {
  if (allowLocal && raw && /^(localhost|127\.0\.0\.1)(:\d{1,5})?$/.test(raw)) return "localhost";
  return normalizeHostname(raw);
}
