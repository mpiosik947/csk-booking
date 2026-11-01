import "server-only";
import sharp from "sharp";
import { createClient } from "@supabase/supabase-js";

// Defense in depth on patched sharp: partner uploads never need the SVG loader.
sharp.block({ operation: ["VipsForeignLoadSvg"] });

export const PARTNER_UPLOAD_LIMIT = 4 * 1024 * 1024;
export const PARTNER_MEDIA_LIMIT = 1024 * 1024;
export async function normalizePartnerImage(bytes: Buffer, mime: string) {
  if (!bytes.length || bytes.length > PARTNER_UPLOAD_LIMIT || !["image/png", "image/jpeg", "image/webp"].includes(mime)) throw new Error("invalid_image");
  const source = sharp(bytes, { limitInputPixels: 16_000_000, failOn: "warning", animated: false });
  const meta = await source.metadata();
  if (!meta.format || !["png", "jpeg", "webp"].includes(meta.format) || `image/${meta.format}` !== mime ||
    !meta.width || !meta.height || meta.width > 8000 || meta.height > 8000 || (meta.pages ?? 1) > 1) throw new Error("invalid_image");
  // Full decode, orientation applied, metadata discarded, bounded raster output.
  const { data, info } = await source.rotate().resize({ width: 2400, height: 2400, fit: "inside", withoutEnlargement: true }).webp({ quality: 85 }).toBuffer({ resolveWithObject: true });
  if (data.length > PARTNER_MEDIA_LIMIT) throw new Error("image_too_large");
  return { bytes: data, width: info.width, height: info.height };
}
export function partnerStorageClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL, key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) throw new Error("storage_unavailable");
  // Infrastructure only. Never use this client for the admin content writer.
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
}
export const partnerHeaders = { "Cache-Control": "private, no-store, max-age=0, must-revalidate", "X-Content-Type-Options": "nosniff", "Vary": "Cookie" };
