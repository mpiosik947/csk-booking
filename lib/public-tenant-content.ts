export type PublicContent = {
  about_offer: string | null;
  about_audience: string | null;
  public_map_url: string | null;
  pricing_items: { title: string; price: number; currency: string; unit: string; short_description: string | null }[];
};

export function parsePublicContent(value: unknown): PublicContent | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const row = value as Record<string, unknown>;
  if (Object.keys(row).sort().join(",") !== "about_audience,about_offer,pricing_items,public_map_url") return null;
  for (const key of ["about_offer", "about_audience"]) if (row[key] !== null && (typeof row[key] !== "string" || row[key].length > 1200)) return null;
  if (row.public_map_url !== null) {
    if (typeof row.public_map_url !== "string" || row.public_map_url.length > 500) return null;
    try { if (new URL(row.public_map_url).protocol !== "https:") return null; } catch { return null; }
  }
  if (!Array.isArray(row.pricing_items) || row.pricing_items.length > 100) return null;
  for (const value of row.pricing_items) {
    if (!value || typeof value !== "object" || Array.isArray(value) ||
      Object.keys(value).sort().join(",") !== "currency,price,short_description,title,unit" ||
      typeof value.title !== "string" || value.title.length < 1 || value.title.length > 120 ||
      typeof value.price !== "number" || !Number.isFinite(value.price) || value.price < 0 || value.price > 9999999.99 ||
      typeof value.currency !== "string" || !/^[A-Z]{3}$/.test(value.currency) ||
      typeof value.unit !== "string" || value.unit.length < 1 || value.unit.length > 80 ||
      (value.short_description !== null && (typeof value.short_description !== "string" || value.short_description.length > 300))) return null;
  }
  return row as PublicContent;
}
