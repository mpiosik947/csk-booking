export const PARTNER_KINDS = { partner: "Partner", sponsor: "Sponsor", commercial_partner: "Partner komercyjny" } as const;
export const PARTNER_FORMATS = { logo: "Logo", banner: "Baner" } as const;
export const PARTNER_STATUSES = { active: "Opublikowany", inactive: "Wyłączony", scheduled: "Zaplanowany", expired: "Zakończony", archived: "Archiwum" } as const;
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export type PartnerValues = {
  name: string; kind: keyof typeof PARTNER_KINDS; display_format: keyof typeof PARTNER_FORMATS;
  target_url: string | null; short_description: string | null; is_active: boolean; display_order: number;
  starts_at: string | null; ends_at: string | null;
};
export type PublicPartner = Pick<PartnerValues, "name" | "kind" | "display_format" | "target_url" | "short_description" | "display_order"> & { id: string; media_id: string };
export type AdminPartner = PublicPartner & PartnerValues & { revision: string; archived_at: string | null; status: keyof typeof PARTNER_STATUSES };
export type PartnerList = { tenant_id: string; public_slug: string | null; items: AdminPartner[] };
export function safePartnerUrl(value: unknown): value is string | null {
  if (value === null) return true;
  if (typeof value !== "string" || value.length > 1000 || !/^https:\/\/[a-z0-9]([a-z0-9.-]*[a-z0-9])?([/?#][^\s\\<>"\u0000-\u001f]*)?$/i.test(value) || /%(00|0a|0d)/i.test(value)) return false;
  try { const u = new URL(value); return u.protocol === "https:" && !u.username && !u.password && !u.port; } catch { return false; }
}
const object = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);
const date = (v: unknown): v is string | null => v === null || (typeof v === "string" && /^\d{4}-\d\d-\d\dT/.test(v) && Number.isFinite(Date.parse(v)));
export function validPartnerValues(v: unknown): v is PartnerValues {
  if (!object(v)) return false;
  return Object.keys(v).sort().join(",") === "display_format,display_order,ends_at,is_active,kind,name,short_description,starts_at,target_url" &&
    typeof v.name === "string" && v.name.trim() === v.name && v.name.length > 0 && v.name.length <= 120 &&
    typeof v.kind === "string" && Object.hasOwn(PARTNER_KINDS, v.kind) && typeof v.display_format === "string" && Object.hasOwn(PARTNER_FORMATS, v.display_format) &&
    safePartnerUrl(v.target_url) && (v.short_description === null || (typeof v.short_description === "string" && v.short_description.trim() === v.short_description && v.short_description.length > 0 && v.short_description.length <= 300)) &&
    typeof v.is_active === "boolean" && Number.isInteger(v.display_order) && Number(v.display_order) >= 0 && Number(v.display_order) <= 9999 &&
    date(v.starts_at) && date(v.ends_at) && (!v.starts_at || !v.ends_at || Date.parse(v.ends_at) > Date.parse(v.starts_at));
}
export function readPublicPartners(value: unknown): PublicPartner[] | null {
  if (!Array.isArray(value) || value.length > 100) return null;
  const result: PublicPartner[] = [];
  for (const p of value) {
    if (!object(p) || typeof p.id !== "string" || !UUID.test(p.id) || typeof p.media_id !== "string" || !UUID.test(p.media_id) ||
      !validPartnerValues({ name: p.name, kind: p.kind, display_format: p.display_format, target_url: p.target_url, short_description: p.short_description,
        display_order: p.display_order, is_active: false, starts_at: null, ends_at: null })) return null;
    result.push({ id: p.id, media_id: p.media_id, name: p.name as string, kind: p.kind as PublicPartner["kind"], display_format: p.display_format as PublicPartner["display_format"],
      target_url: p.target_url as string | null, short_description: p.short_description as string | null, display_order: p.display_order as number });
  }
  return result;
}
export function readPartnerList(value: unknown): PartnerList | null {
  if (!object(value) || typeof value.tenant_id !== "string" || !UUID.test(value.tenant_id) || (value.public_slug !== null && (typeof value.public_slug !== "string" || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(value.public_slug)))) return null;
  const publicRows = readPublicPartners(value.items);
  if (!publicRows || !Array.isArray(value.items)) return null;
  for (const p of value.items) {
    if (!object(p) || typeof p.revision !== "string" || !UUID.test(p.revision) || !date(p.archived_at) ||
      !date(p.starts_at) || !date(p.ends_at) || typeof p.is_active !== "boolean" || typeof p.status !== "string" || !Object.hasOwn(PARTNER_STATUSES, p.status)) return null;
  }
  return value as PartnerList;
}
export function partnerValues(p: AdminPartner): PartnerValues {
  return { name: p.name, kind: p.kind, display_format: p.display_format, target_url: p.target_url, short_description: p.short_description,
    is_active: p.is_active, display_order: p.display_order, starts_at: p.starts_at, ends_at: p.ends_at };
}
export const partnerMediaUrl = (id: string) => `/api/tenant-partners/media/${id}`;
