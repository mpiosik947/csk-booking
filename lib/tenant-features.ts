export const TENANT_FEATURE_KEYS = [
  "booking",
  "events",
  "instructors",
  "staff",
  "checkin",
  "reports",
  "lane_blocks",
  "advanced_calendar",
  "branding",
  "custom_domain",
] as const;

export type TenantFeatureKey = (typeof TENANT_FEATURE_KEYS)[number];

const ROUTE_FEATURES: Readonly<Record<string, TenantFeatureKey>> = {
  booking: "booking",
  events: "events",
  "admin/reservations": "booking",
  "admin/lane-configuration": "booking",
  "admin/events": "events",
  "admin/users": "staff",
  "admin/check-in": "checkin",
  "admin/reports": "reports",
  "admin/lane-blocks": "lane_blocks",
  "admin/calendar": "advanced_calendar",
};

export function featureForTenantRoute(path: string): TenantFeatureKey | null {
  return ROUTE_FEATURES[path] ?? null;
}

export function isTenantFeatureKey(value: unknown): value is TenantFeatureKey {
  return typeof value === "string" &&
    (TENANT_FEATURE_KEYS as readonly string[]).includes(value);
}
