import { parseAdminLaneConfigurationSnapshot, type AdminLaneConfigurationSnapshot } from "./admin/lane-configuration.ts";
import { uuid } from "./platform-wizard.ts";

export const profileTextKeys = ["display_name", "city", "logo_path", "hero_image_path", "description", "regulations_path", "public_address", "public_phone", "public_email", "opening_hours", "about_offer", "about_audience", "public_map_url"] as const;
export const profileFlagKeys = ["show_booking", "show_pricing", "show_instructor", "show_events", "show_about", "show_contact", "show_regulations"] as const;
export type Profile = Record<typeof profileTextKeys[number], string | null> & Record<typeof profileFlagKeys[number], boolean> & { social_links: Record<string, string> };
export type PricingItem = { id: string | null; title: string; price: number; currency: string; unit: string; short_description: string | null; display_order: number; is_active: boolean };
export type Configuration = { tenantId: string; name: string; slug: string; publicSlug: string; status: "dormant" | "archived"; revision: string; profile: Profile; pricing: PricingItem[]; lanes: AdminLaneConfigurationSnapshot; planKey: string | null; features: Record<"booking" | "events" | "instructors", boolean> };
export type Section = "identity" | "profile" | "pricing" | "create_lane" | "update_lane" | "plan";
export type ConfigAttempt = { tenantId: string; revision: string; requestId: string; section: Section; payload: Record<string, unknown> };
const record = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);
const revision = (v: unknown): v is string => typeof v === "string" && /^[a-f0-9]{64}$/.test(v);
export const configStorageKey = (actor: string, tenant: string) => `strzelajtu:config:v1:${actor}:${tenant}`;
export function parseConfiguration(v: unknown, tenantId: string): Configuration | null {
  if (!record(v) || v.tenant_id !== tenantId || !uuid(tenantId) || !revision(v.revision) || typeof v.name !== "string" || typeof v.tenant_slug !== "string" || !["dormant", "archived"].includes(String(v.status)) || v.memberships !== 0 || v.public_access_state !== "coming_soon" || !record(v.profile) || v.profile.is_public !== false || typeof v.profile.public_slug !== "string" || !record(v.feature_access)) return null;
  const p = v.profile, flags = v.feature_access;
  if (profileTextKeys.some(k => p[k] !== null && typeof p[k] !== "string") || profileFlagKeys.some(k => typeof p[k] !== "boolean") || !record(p.social_links) || Object.values(p.social_links).some(x => typeof x !== "string") || ["booking", "events", "instructors"].some(k => typeof flags[k] !== "boolean")) return null;
  if (!Array.isArray(v.pricing_items) || v.pricing_items.some(i => !record(i) || !uuid(i.id) || typeof i.title !== "string" || typeof i.price !== "number" || typeof i.currency !== "string" || typeof i.unit !== "string" || (i.short_description !== null && typeof i.short_description !== "string") || !Number.isInteger(i.display_order) || typeof i.is_active !== "boolean")) return null;
  if (v.plan !== null && (!record(v.plan) || typeof v.plan.plan_key !== "string")) return null;
  try {
    return { tenantId, name: v.name, slug: v.tenant_slug, publicSlug: p.public_slug as string, status: v.status as Configuration["status"], revision: v.revision,
      profile: Object.fromEntries([...profileTextKeys, ...profileFlagKeys, "social_links"].map(k => [k, p[k]])) as Profile,
      pricing: v.pricing_items.map(i => Object.fromEntries(["id", "title", "price", "currency", "unit", "short_description", "display_order", "is_active"].map(k => [k, i[k]])) as PricingItem),
      lanes: parseAdminLaneConfigurationSnapshot(v.lanes), planKey: record(v.plan) ? v.plan.plan_key as string : null,
      features: { booking: flags.booking as boolean, events: flags.events as boolean, instructors: flags.instructors as boolean } };
  } catch { return null; }
}
export function parseConfigAttempt(raw: string, tenantId: string): ConfigAttempt | null {
  try { const a: unknown = JSON.parse(raw); if (!record(a) || a.tenantId !== tenantId || !uuid(tenantId) || !uuid(a.requestId) || !revision(a.revision) || !["identity", "profile", "pricing", "create_lane", "update_lane", "plan"].includes(String(a.section)) || !record(a.payload)) return null;
    return { tenantId, requestId: a.requestId, revision: a.revision, section: a.section as Section, payload: a.payload };
  } catch { return null; }
}
export function configReceipt(v: unknown, a: ConfigAttempt): Record<string, unknown> | null {
  return record(v) && v.tenant_id === a.tenantId && v.request_id === a.requestId && v.section === a.section && revision(v.revision) && record(v.mutation) && v.mutation.ok === true ? v.mutation : null;
}
export function configError(error: { code?: string; status?: number }): { kind: "denied" | "conflict" | "invalid" | "uncertain"; message: string } {
  if ([401, 403].includes(error.status ?? 0) || ["401", "403", "42501", "PGRST301", "PGRST302", "PGRST303"].includes(error.code ?? "")) return { kind: "denied", message: "Dostęp do konfiguracji wygasł albo draft został zarchiwizowany. Wróć do listy obiektów." };
  if (error.code === "PT409") return { kind: "conflict", message: "Konfiguracja zmieniła się w innej sesji. Zachowano wpisane wartości. Odczytaj bieżące dane przed kolejnym zapisem." };
  if (["22023", "23514", "22P02", "23505", "55000"].includes(error.code ?? "")) return { kind: "invalid", message: "Zapis odrzucony. Sprawdź format pól, kompletny cennik i zakres ustawień." };
  return { kind: "uncertain", message: "Nie potwierdzono wyniku zapisu. Odczytano stan serwera; ponów tę samą próbę, aby potwierdzić wynik." };
}
